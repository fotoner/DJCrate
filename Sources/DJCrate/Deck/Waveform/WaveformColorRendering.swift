import AppKit
import DJCApplication
import DJCDomain
import SwiftUI

/// 목록은 #30 모양새 토큰, 항상 어두운 덱은 기존 3밴드 팔레트를 쓴다.
enum WaveformColors {
    static func color(_ column: WaveformColumn, mode: WaveformColorMode, appearance: NSAppearance.Name) -> NSColor {
        let dark = appearance == .darkAqua || appearance == .accessibilityHighContrastDarkAqua
        let highContrast = appearance == .accessibilityHighContrastAqua || appearance == .accessibilityHighContrastDarkAqua
        if mode == .blue {
            let base = UIColors.info.variants.resolved(for: appearance)
            // 라이트에서는 흰색 대신 짙은 잉크로 향해 배경 대비를 유지한다.
            return base.blended(withFraction: column.whiteness * (dark ? 0.85 : 0.65), of: dark ? .white : .black) ?? base
        }
        let c = column.rgb
        let scale = dark ? 0.65 : (highContrast ? 0.35 : 0.48), floor = dark ? (highContrast ? 0.5 : 0.35) : 0
        return NSColor(srgbRed: min(1, c.red * scale + floor), green: min(1, c.green * scale + floor),
                       blue: min(1, c.blue * scale + floor), alpha: 1)
    }

    static func bands(appearance: NSAppearance.Name) -> [NSColor] {
        [UIColors.info.variants.resolved(for: appearance), UIColors.cue.variants.resolved(for: appearance),
         highBand.resolved(for: appearance)]
    }

    private static let highBand = AppearanceColor("waveform.high", light: 0x414345, dark: 0xF2F0E8,
                                                 highLight: 0x202020, highDark: 0xFFFFFF)
}

/// 곡·모드가 바뀔 때만 비트맵을 만든다. 재생 틱에서는 보이는 구간만 잘라 그린다.
struct ColorWaveformRaster: Sendable {
    let detail: CGImage
    let overview: CGImage
    let rate: Double
    let duration: Double
    /// ANLZ는 이미 rekordbox 시간축, 자체 분석은 음원 시간축이다.
    let offset: Double

    /// - Parameter source: rekordbox 분석 파일의 색 파형(없으면 자체 파형으로 그린다)
    static func make(waveform: Waveform, source: ColorWaveformColumns?, mode: WaveformColorMode, audioOffset: Double) -> Self? {
        let columns = source?.columns ?? waveform.colorColumns
        let rate = source?.rate ?? waveform.rate
        guard !Task.isCancelled, !columns.isEmpty,
              let detail = WaveformBitmap.image(columns, mode: mode, appearance: .darkAqua, height: 128),
              let overview = WaveformBitmap.image(WaveformColumn.downsample(columns, to: 1400),
                                                   mode: mode, appearance: .darkAqua, height: 128) else { return nil }
        return Self(detail: detail, overview: overview, rate: rate, duration: Double(columns.count) / rate,
                    offset: source == nil ? audioOffset : 0)
    }

    func draw(_ context: GraphicsContext, from start: Double, to end: Double, in rect: CGRect, full: Bool = false) {
        guard end > start else { return }
        let image = full ? overview : detail
        let sampleRate = full ? Double(image.width) / duration : rate
        let a = max(0, Int(floor((start - offset) * sampleRate)))
        let b = min(image.width, Int(ceil((end - offset) * sampleRate)))
        guard a < b, let crop = image.cropping(to: CGRect(x: a, y: 0, width: b - a, height: image.height)) else { return }
        let x = rect.minX + (Double(a) / sampleRate + offset - start) / (end - start) * rect.width
        let width = Double(b - a) / sampleRate / (end - start) * rect.width
        var context = context
        context.clip(to: Path(rect))
        context.draw(Image(decorative: crop, scale: 1), in: CGRect(x: x, y: rect.minY, width: width, height: rect.height))
    }
}

enum WaveformBitmap {
    static func image(_ columns: [WaveformColumn], mode: WaveformColorMode, appearance: NSAppearance.Name,
                      height: Int, width requestedWidth: Int? = nil) -> CGImage? {
        let width = requestedWidth ?? columns.count
        guard !columns.isEmpty, width > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bandColors = WaveformColors.bands(appearance: appearance)
        context.setShouldAntialias(false)
        for (index, column) in columns.enumerated() {
            let x = index * width / columns.count, end = (index + 1) * width / columns.count
            func bar(_ amplitude: Double, _ color: NSColor) {
                guard amplitude > 0 else { return }
                let h = max(1, Int((amplitude * Double(height)).rounded()))
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x, y: (height - h) / 2, width: end - x, height: h))
            }
            if mode == .threeBand {
                bar(column.low, bandColors[0]); bar(column.mid * 0.78, bandColors[1]); bar(column.high * 0.5, bandColors[2])
            } else {
                bar(column.height, WaveformColors.color(column, mode: mode, appearance: appearance))
            }
        }
        return context.makeImage()
    }
}

extension DeckModel {
    func refreshColorWaveform() {
        colorWaveformTask?.cancel()
        colorWaveform = nil
        guard waveformColorMode != .threeBand, let waveform else { return }
        let mode = waveformColorMode, offset = timelineOffset, loader = loader
        let request = row.map(loadRequest)
        colorWaveformTask = Task {
            let job = Task.detached(priority: .userInitiated) {
                var source: ColorWaveformColumns?
                if let request { source = await loader.colorWaveform(request, mode: mode) }
                return ColorWaveformRaster.make(waveform: waveform, source: source, mode: mode, audioOffset: offset)
            }
            let raster = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled else { return }
            colorWaveform = raster
        }
    }
}
