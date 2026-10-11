@testable import DJCrate
import CoreGraphics
import SwiftUI
import Testing

/// 확대 파형 Canvas는 재생 중 매 프레임 그려진다. 글자(마디.박·큐 이름 등)를 매번 다시 해석하면 프레임마다
/// 메인 스레드 시간의 절반 가까이가 글자 해석에 들어가므로(#139), 해석한 글자를 두었다가 다시 쓴다.
@MainActor
struct WaveformTextCacheTests {
    private static let label = WaveformTextCache.Key.text("25.1", size: 10, weight: .semibold, digits: true, color: .white)

    /// 같은 색 공간의 8비트 RGBA 픽셀을 비교한다(`scale`: 화면 배율).
    private func render(scale: Double = 2, background: Color = .black, _ draw: @escaping (GraphicsContext, CGSize) -> Void) throws -> [UInt8] {
        let renderer = ImageRenderer(content: Canvas { context, size in draw(context, size) }
            .frame(width: 160, height: 40).background(background))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBufferPointer { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func maximumChannelDifference(_ first: [UInt8], _ second: [UInt8]) throws -> Int {
        try #require(first.count == second.count)
        return zip(first, second).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    @Test func 같은_글자는_한_번만_해석한다() throws {
        let cache = WaveformTextCache()
        _ = try render { context, _ in
            _ = cache.resolved(Self.label, in: context)
            _ = cache.resolved(Self.label, in: context)
        }
        #expect(cache.misses == 1)
        #expect(cache.hits == 1)
        _ = try render { context, _ in _ = cache.resolved(Self.label, in: context) }
        #expect(cache.misses == 1, "다음 프레임에서도 다시 해석하지 않는다")
        #expect(cache.hits == 2)
    }

    @Test func 글자_모양이_다르면_따로_해석한다() throws {
        let cache = WaveformTextCache()
        let bold = WaveformTextCache.Key.text("25.1", size: 10, weight: .bold, digits: true, color: .white)
        let bigger = WaveformTextCache.Key.text("25.1", size: 13, weight: .semibold, digits: true, color: .white)
        let colored = WaveformTextCache.Key.text("25.1", size: 10, weight: .semibold, digits: true, color: .yellow)
        let other = WaveformTextCache.Key.text("25.2", size: 10, weight: .semibold, digits: true, color: .white)
        _ = try render { context, _ in
            for key in [Self.label, bold, bigger, colored, other] { _ = cache.resolved(key, in: context) }
        }
        #expect(cache.misses == 5)
        #expect(cache.hits == 0)
    }

    @Test func 화면_배율이_바뀌면_다시_해석한다() throws {
        let cache = WaveformTextCache()
        _ = try render(scale: 2) { context, _ in _ = cache.resolved(Self.label, in: context) }
        _ = try render(scale: 1) { context, _ in _ = cache.resolved(Self.label, in: context) }
        #expect(cache.misses == 2, "다른 배율 환경에서 해석한 글자는 쓰지 않는다")
    }

    @Test func 너무_많이_쌓이면_비운다() throws {
        let cache = WaveformTextCache(capacity: 4)
        _ = try render { context, _ in
            for number in 0..<10 {
                _ = cache.resolved(.text("\(number)", size: 10, weight: .regular, digits: false, color: .white), in: context)
            }
        }
        #expect(cache.count <= 4)
    }

    @Test func 잰_크기도_두었다가_다시_쓴다() throws {
        let cache = WaveformTextCache()
        let proposal = CGSize(width: 160, height: 100)
        var sizes: [CGSize] = []
        var direct: CGSize = .zero
        _ = try render { context, _ in
            sizes.append(cache.label(Self.label, proposal: proposal, in: context).size)
            sizes.append(cache.label(Self.label, proposal: proposal, in: context).size)
            direct = context.resolve(Text(verbatim: "25.1").font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white)).measure(in: proposal)
        }
        #expect(sizes.count == 2)
        #expect(sizes[0] == sizes[1])
        #expect(sizes[0] == direct, "매번 해석해서 잰 값과 같다")
        #expect(cache.misses == 1)
    }

    /// 안에 심볼이 든 글자(루프 표시·+ 배지)도 쓴다.
    @Test func 심볼_글자도_같은_그림으로_그린다() throws {
        let cache = WaveformTextCache()
        let keys: [WaveformTextCache.Key] = [
            .init(content: .symbol("repeat"), style: .init(size: 10, weight: .bold, color: .orange)),
            .init(content: .symbolThenText(symbol: "repeat", text: "4"), style: .init(size: 10, weight: .bold, color: .orange)),
            .init(content: .textThenSymbol(text: "B", symbol: "repeat"), style: .init(size: 10, weight: .bold, color: .black)),
            .init(content: .symbol("plus"), style: .init(size: 11, weight: .bold, color: .black)),
        ]
        let direct: [Text] = [
            Text(Image(systemName: "repeat")), Text("\(Image(systemName: "repeat")) \("4")"),
            Text("\("B")\(Image(systemName: "repeat"))"), Text(Image(systemName: "plus")),
        ]
        let withoutSymbols: [Text] = [Text(verbatim: ""), Text(verbatim: " 4"), Text(verbatim: "B"), Text(verbatim: "")]
        func drawAll(_ context: GraphicsContext, cached: Bool, omitting: Int? = nil, color: Color? = nil) {
            for (index, key) in keys.enumerated() {
                let point = CGPoint(x: 8 + Double(index) * 36, y: 20)
                if cached {
                    context.draw(cache.resolved(key, in: context), at: point, anchor: .leading)
                } else {
                    let style = key.style
                    let text = index == omitting ? withoutSymbols[index] : direct[index]
                    context.draw(text.font(.system(size: style.size, weight: style.weight)).foregroundStyle(color ?? style.color),
                                 at: point, anchor: .leading)
                }
            }
        }
        // 검은 핫큐 글자·+ 심볼도 보여야 누락을 검출할 수 있다.
        let fresh = try render(background: .gray) { context, _ in drawAll(context, cached: false) }
        let first = try render(background: .gray) { context, _ in drawAll(context, cached: true) }
        let reused = try render(background: .gray) { context, _ in drawAll(context, cached: true) }
        let freshAfter = try render(background: .gray) { context, _ in drawAll(context, cached: false) }
        // 직접 렌더끼리도 심볼 가장자리의 8비트 채널이 1 달라져 그 차이만 허용한다(#156).
        for (name, image) in [("최초 캐시", first), ("캐시 재사용", reused), ("직접 반복", freshAfter)] {
            let difference = try maximumChannelDifference(image, fresh)
            #expect(difference <= 1, "\(name): 심볼 그림의 채널 차이")
        }
        // 허용 오차가 실제 누락·한 픽셀 이동·색 변경을 가리지 않는지 같은 그림으로 확인한다.
        for index in keys.indices {
            let missing = try render(background: .gray) { context, _ in drawAll(context, cached: false, omitting: index) }
            #expect(try maximumChannelDifference(missing, fresh) > 1, "\(index)번 심볼 누락을 검출한다")
        }
        let shifted = try render(background: .gray) { context, _ in
            var context = context
            context.translateBy(x: 0.5, y: 0) // 2배 화면의 한 픽셀
            drawAll(context, cached: false)
        }
        let recolored = try render(background: .gray) { context, _ in drawAll(context, cached: false, color: .cyan) }
        #expect(try maximumChannelDifference(shifted, fresh) > 1, "한 픽셀 이동을 검출한다")
        #expect(try maximumChannelDifference(recolored, fresh) > 1, "색 변경을 검출한다")
        #expect(cache.misses == keys.count)
        #expect(cache.hits == keys.count)
    }

    @Test func 글자를_두었다가_다시_써도_그림이_같다() throws {
        let cache = WaveformTextCache()
        func fresh(_ context: GraphicsContext) {
            context.draw(Text(verbatim: "25.1").font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white), at: CGPoint(x: 6, y: 10), anchor: .leading)
        }
        func cached(_ context: GraphicsContext) {
            context.draw(cache.resolved(Self.label, in: context), at: CGPoint(x: 6, y: 10), anchor: .leading)
        }
        let expected = try render { context, _ in fresh(context) }
        let first = try render { context, _ in cached(context) }
        let reused = try render { context, _ in cached(context) }
        #expect(first == expected)
        #expect(reused == expected)
        #expect(cache.hits == 1)
    }
}
