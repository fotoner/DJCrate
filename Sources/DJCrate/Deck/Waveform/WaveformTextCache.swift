import SwiftUI

/// 확대 파형 Canvas의 글자(마디.박·큐 이름·핫큐 칩 등)를 해석한 결과를 두었다가 다음 프레임에도 쓴다.
/// 글자는 재생 위치가 바뀌어도 그대로인 것이 대부분인데, 매 프레임 `resolve`를 다시 하면 프레임마다 메인 스레드 시간의
/// 절반 가까이가 글자 해석과 크기 재기에 들어갔다(#139). 같은 글자·모양이면 해석한 값과 잰 크기를 재사용한다.
/// 해석한 글자는 환경(화면 배율·명암·굵은 글자 설정)에 묶이므로, 환경이 바뀌면 모두 비우고 다시 해석한다.
@MainActor
final class WaveformTextCache {
    struct Style: Hashable {
        var size: Double
        var weight: Font.Weight
        var monospacedDigit = false
        var color: Color
    }

    /// 글자 내용. 심볼이 든 글자는 이름으로 가리킨다(`Image(systemName:)`).
    enum Content: Hashable {
        case text(String)
        case symbol(String)
        /// `\(Image) \(text)`
        case symbolThenText(symbol: String, text: String)
        /// `\(text)\(Image)`
        case textThenSymbol(text: String, symbol: String)
    }

    struct Key: Hashable {
        var content: Content
        var style: Style

        static func text(_ text: String, size: Double, weight: Font.Weight, digits: Bool = false, color: Color) -> Self {
            Self(content: .text(text), style: Style(size: size, weight: weight, monospacedDigit: digits, color: color))
        }
    }

    struct Label {
        let text: GraphicsContext.ResolvedText
        let size: CGSize
    }

    private final class Entry {
        let text: GraphicsContext.ResolvedText
        /// 제안 크기마다 잰 글자 크기(긴 글자는 제안 폭에 따라 줄바꿈이 달라진다)
        var sizes: [CGSize: CGSize] = [:]
        init(_ text: GraphicsContext.ResolvedText) { self.text = text }
    }

    /// 해석한 글자가 기대는 환경 값. 이것이 바뀌면 옛 글자를 쓰지 않는다.
    private struct Environment: Equatable {
        var displayScale: CGFloat
        var colorScheme: ColorScheme
        var contrast: ColorSchemeContrast
        var legibilityWeight: LegibilityWeight?

        init(_ values: EnvironmentValues) {
            displayScale = values.displayScale
            colorScheme = values.colorScheme
            contrast = values.colorSchemeContrast
            legibilityWeight = values.legibilityWeight
        }
    }

    private var entries: [Key: Entry] = [:]
    private var environment: Environment?
    private let capacity: Int
    /// 시험이 본다
    private(set) var hits = 0
    private(set) var misses = 0

    /// 한 프레임에 쓰는 글자는 수십 개다. 큐 이름은 사용자가 정한 글자라 끝없이 쌓이지 않게 상한을 둔다.
    init(capacity: Int = 512) { self.capacity = capacity }

    var count: Int { entries.count }

    func resolved(_ key: Key, in context: GraphicsContext) -> GraphicsContext.ResolvedText {
        entry(key, in: context).text
    }

    /// 해석한 글자와 `proposal`로 잰 크기
    func label(_ key: Key, proposal: CGSize, in context: GraphicsContext) -> Label {
        let entry = entry(key, in: context)
        if let size = entry.sizes[proposal] { return Label(text: entry.text, size: size) }
        let size = entry.text.measure(in: proposal)
        entry.sizes[proposal] = size
        return Label(text: entry.text, size: size)
    }

    private func entry(_ key: Key, in context: GraphicsContext) -> Entry {
        let current = Environment(context.environment)
        if current != environment {
            entries.removeAll(keepingCapacity: true)
            environment = current
        }
        if let entry = entries[key] {
            hits += 1
            return entry
        }
        misses += 1
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        let entry = Entry(context.resolve(Self.text(for: key)))
        entries[key] = entry
        return entry
    }

    private static func text(for key: Key) -> Text {
        let base: Text = switch key.content {
        case let .text(string): Text(verbatim: string)
        case let .symbol(name): Text(Image(systemName: name))
        case let .symbolThenText(symbol, text): Text("\(Image(systemName: symbol)) \(text)")
        case let .textThenSymbol(text, symbol): Text("\(text)\(Image(systemName: symbol))")
        }
        let style = key.style
        var font = Font.system(size: style.size, weight: style.weight)
        if style.monospacedDigit { font = font.monospacedDigit() }
        return base.font(font).foregroundStyle(style.color)
    }
}
