import AppKit
import SwiftUI
import DJCDomain

/// 늘 어두운 파형의 데이터 색. 창 위 글자에는 UIColors를 쓴다.
enum Palette {
    /// Camelot 번호마다 색(휠 순서로 색상이 돈다). A/B는 밝기만 다르다.
    static func keyColor(_ camelot: String) -> Color {
        let text = camelot.uppercased()
        guard let number = Int(text.dropLast()), (1...12).contains(number) else { return .secondary }
        return Color(hue: Double(number - 1) / 12, saturation: 0.62, brightness: text.hasSuffix("A") ? 0.78 : 0.95)
    }

    /// 루프 구간·루프 큐(rekordbox처럼 주황)
    static let loop = Color(red: 1.0, green: 0.55, blue: 0.0)

    static let low = Color(red: 0.23, green: 0.44, blue: 0.96)
    static let mid = Color(red: 0.94, green: 0.64, blue: 0.24)
    static let high = Color(red: 0.95, green: 0.94, blue: 0.91)
    /// 핫큐: rekordbox 기본 핫큐 색(초록). 메모리 큐(빨강)와 한눈에 구분되게.
    static let hot = Color(red: 0.16, green: 0.86, blue: 0.24)
    static let memory = Color(red: 0.94, green: 0.25, blue: 0.25)
    static let cue = Color(red: 1.0, green: 0.56, blue: 0.08)
    /// 제안(메모리 큐 후보·추정 그리드): 핫큐 초록과 겹치지 않는 하늘색
    static let suggestion = Color(red: 0.35, green: 0.80, blue: 1.0)
    static let section = Color(red: 0.56, green: 0.53, blue: 1.0)
    static let well = Color(red: 0.043, green: 0.047, blue: 0.055)
    /// 파형 양옆 조작 열은 파형 우물보다 한 단계 밝게 둔다.
    static let controlRail = Color(white: 0.14)
    static let rulerText = Color(white: 0.65)
    static let meterLow = Color.green
    static let meterMid = Color.yellow
    static let meterHigh = Color.red

    /// 가장 밝은 조성 띠에서도 흰 글자가 4.5:1 이상으로 남는다.
    static func keyBandOpacity(changes: Bool) -> Double { changes ? 0.45 : 0.3 }

    /// 큐 표시 색: 루프 = 주황, 핫큐 = 초록, 메모리 큐 = 빨강
    static func color(for cue: EditableCue) -> Color {
        cue.loop != nil ? loop : cue.kind == .memory ? memory : hot
    }
}

/// 창·목록 위의 의미색. 작은 글자에도 쓰므로 네 모양새 모두 4.5:1 이상으로 잡는다.
enum UIColors: String, CaseIterable {
    case hot, memory, cue, loop, draft, suggestion, warning, tempo, info

    var variants: AppearanceColor { Self.colors[self]! }
    var nsColor: NSColor { variants.nsColor }
    var color: Color { Color(nsColor: nsColor) }

    static func color(for cue: EditableCue) -> Color {
        (cue.loop != nil ? Self.loop : cue.kind == .memory ? .memory : .hot).color
    }

    // 파형 색과 달리 라이트에서는 어둡게, 고대비에서는 한 단계 더 분명하게 표시한다.
    private static let colors: [Self: AppearanceColor] = [
        .hot: AppearanceColor("hot", light: 0x17672B, dark: 0x29DB3D, highLight: 0x074517, highDark: 0x7FFF8D),
        .memory: AppearanceColor("memory", light: 0xA82727, dark: 0xFF6E6E, highLight: 0x7C1414, highDark: 0xFFB0B0),
        .cue: AppearanceColor("cue", light: 0x8F4400, dark: 0xFF8F14, highLight: 0x602D00, highDark: 0xFFC77D),
        .loop: AppearanceColor("loop", light: 0x914200, dark: 0xFF8C00, highLight: 0x602B00, highDark: 0xFFC77D),
        .draft: AppearanceColor("draft", light: 0x7B4E00, dark: 0xF0A33D, highLight: 0x523300, highDark: 0xFFD18F),
        .suggestion: AppearanceColor("suggestion", light: 0x006078, dark: 0x59CCFF, highLight: 0x003E50, highDark: 0xA9E6FF),
        .warning: AppearanceColor("warning", light: 0x914400, dark: 0xFF9230, highLight: 0x632C00, highDark: 0xFFD18F),
        .tempo: AppearanceColor("tempo", light: 0x695800, dark: 0xFFDA30, highLight: 0x453900, highDark: 0xFFEC8A),
        .info: AppearanceColor("info", light: 0x175FA3, dark: 0x64AEFF, highLight: 0x0C3E6E, highDark: 0xBCDFFF),
    ]

    static let onFillVariants = AppearanceColor("onFill", light: 0xFFFFFF, dark: 0x000000,
                                                highLight: 0xFFFFFF, highDark: 0x000000)
    static let draftFillVariants = AppearanceColor("draftFill", light: 0xFFF0DB, dark: 0x493924,
                                                   highLight: 0xFFF6E8, highDark: 0x38291A)
    static let gridControlFillVariants = AppearanceColor("gridControlFill", light: 0xFFFBF5, dark: 0x211A14,
                                                         highLight: 0xFFFFFF, highDark: 0x120E0B)
    /// 큐 초안 줄은 그리드 편집의 주황 배경과 구별되는 푸른 회색을 쓴다.
    static let cueDraftFillVariants = AppearanceColor("cueDraftFill", light: 0xE8EFF8, dark: 0x293A4A,
                                                      highLight: 0xDFEBF8, highDark: 0x1F3852)
    static let onFill = Color(nsColor: onFillVariants.nsColor)
    static let draftFill = Color(nsColor: draftFillVariants.nsColor)
    static let gridControlFill = Color(nsColor: gridControlFillVariants.nsColor)
    static let cueDraftFill = Color(nsColor: cueDraftFillVariants.nsColor)
    static let subtleFill = Color(nsColor: .quaternarySystemFill)

    /// 조성 글자는 기본색으로 읽고, 점은 Camelot 색상을 유지한 채 3:1 이상으로 보정한다.
    static func keyDot(_ camelot: String) -> Color {
        Color(nsColor: keyDots[camelot.uppercased()]?.nsColor ?? .secondaryLabelColor)
    }

    static let keyDots: [String: AppearanceColor] = Dictionary(uniqueKeysWithValues: (1...12).flatMap { number in
        ["A", "B"].map { mode in
            let key = "\(number)\(mode)"
            let source = NSColor.black
            let data = NSColor(calibratedHue: Double(number - 1) / 12, saturation: 0.62,
                               brightness: mode == "A" ? 0.78 : 0.95, alpha: 1)
            let color = AppearanceColor("key.\(key)",
                                        light: data.blended(withFraction: 0.45, of: source)!,
                                        dark: data.blended(withFraction: 0.3, of: .white)!,
                                        highLight: data.blended(withFraction: 0.65, of: source)!,
                                        highDark: data.blended(withFraction: 0.55, of: .white)!)
            return (key, color)
        }
    })

}

/// 초안(파일·rekordbox에 아직 반영하지 않은 값) 표식. 색은 `UIColors.draft` 하나이고, 색만으로 알리지 않게 모양·VoiceOver 글자를 함께 쓴다.
/// 경고(`UIColors.warning`)도 같은 계열 주황이라 모양으로 나눈다: 초안은 연필, 경고는 느낌표 삼각형(`WarningMark`).
/// 곡 목록 칸·인스펙터 필드는 연필 심볼, 칸이 빽빽한 태그 시트는 칸 왼쪽 위 모서리 삼각형이다.
enum DraftMark {
    static let symbol = "pencil.circle.fill"
    static var spoken: String { String(ui: "초안") }
    static var help: String { String(ui: "초안: 파일·rekordbox에 아직 쓰지 않은 값") }
}

/// 경고 표식: 경고 주황 글자에는 늘 이 심볼을 붙인다(초안 주황과 모양으로 구분).
enum WarningMark {
    static let symbol = "exclamationmark.triangle"
}

/// 고대비 모양새를 시스템 설정과 독립적으로도 시험할 수 있게 네 값을 함께 둔다.
struct AppearanceColor {
    let nsColor: NSColor
    private let values: [NSAppearance.Name: NSColor]

    func resolved(for name: NSAppearance.Name) -> NSColor { values[name]! }

    init(_ name: String, light: Int, dark: Int, highLight: Int, highDark: Int) {
        func rgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                    green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        }
        self.init(name, light: rgb(light), dark: rgb(dark), highLight: rgb(highLight), highDark: rgb(highDark))
    }

    init(_ name: String, light: NSColor, dark: NSColor, highLight: NSColor, highDark: NSColor) {
        let values: [NSAppearance.Name: NSColor] = [
            .aqua: light, .darkAqua: dark,
            .accessibilityHighContrastAqua: highLight, .accessibilityHighContrastDarkAqua: highDark,
        ]
        self.values = values
        nsColor = NSColor(name: NSColor.Name("DJC.\(name)")) { appearance in
            let match = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                                   .aqua, .darkAqua]) ?? .aqua
            return values[match]!
        }
    }
}
