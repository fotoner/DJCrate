import AppKit
import SwiftUI
import Testing
import DJCDomain
@testable import DJCrate

@Suite("색 대비", .serialized)
@MainActor
struct ColorContrastTests {
    @Test func 파형_색은_목록_배경과_구분된다() throws {
        let samples = [WaveformColumn(low: 1, mid: 0, high: 0), WaveformColumn(low: 0, mid: 1, high: 0),
                       WaveformColumn(low: 0, mid: 0, high: 1), WaveformColumn(low: 1, mid: 1, high: 1)]
        for name in Self.appearances {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for mode in [WaveformColorMode.blue, .rgb] {
                    for sample in samples {
                        for background in NSColor.alternatingContentBackgroundColors.map({ composite($0, on: .windowBackgroundColor) }) {
                            #expect(contrast(WaveformColors.color(sample, mode: mode, appearance: name), on: background) >= 3,
                                    "\(name.rawValue) \(mode)")
                        }
                    }
                }
            }
        }
    }

    static let appearances: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    @Test func 창과_목록의_색_글자는_네_모양새에서_본문_대비를_갖는다() throws {
        for name in Self.appearances {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
                let base = NSColor.windowBackgroundColor
                let backgrounds = [base, .controlBackgroundColor, .textBackgroundColor,
                                   NSColor(srgbRed: dark ? 0.196 : 0.925, green: dark ? 0.196 : 0.925,
                                           blue: dark ? 0.196 : 0.925, alpha: 1)]
                    + NSColor.alternatingContentBackgroundColors.map { composite($0, on: base) }
                for token in UIColors.allCases {
                    // NSAppearance(named:)는 시스템 대비 설정이 꺼져 있으면 고대비 이름을 일반 모양새로 바꾼다.
                    // 네 변형 값은 직접 풀어 검사하고, 동적 색 연결은 아래 테스트에서 별도로 확인한다.
                    let color = token.variants.resolved(for: name)
                    let minimum = backgrounds.map { contrast(color, on: $0) }.min()!
                    print("대비 \(name.rawValue) \(token): \(String(format: "%.2f", minimum)):1")
                    #expect(minimum >= 4.5, "\(name.rawValue) \(token): \(minimum):1")
                }
            }
        }
    }

    @Test func 동적_색은_SwiftUI와_AppKit의_모양새를_따른다() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                var environment = EnvironmentValues()
                environment.colorScheme = name == .aqua ? .light : .dark
                for token in UIColors.allCases {
                    let expected = token.variants.resolved(for: name).usingColorSpace(.sRGB)!
                    let appKit = token.nsColor.usingColorSpace(.sRGB)!
                    let swiftUI = token.color.resolve(in: environment)
                    #expect(abs(appKit.redComponent - expected.redComponent) < 0.001)
                    #expect(abs(appKit.greenComponent - expected.greenComponent) < 0.001)
                    #expect(abs(appKit.blueComponent - expected.blueComponent) < 0.001)
                    #expect(abs(Double(swiftUI.red) - expected.redComponent) < 0.001)
                    #expect(abs(Double(swiftUI.green) - expected.greenComponent) < 0.001)
                    #expect(abs(Double(swiftUI.blue) - expected.blueComponent) < 0.001)
                }
            }
        }
    }

    @Test func 대비_증가_색은_일반_색보다_더_분명하다() throws {
        for (normal, increased) in [(NSAppearance.Name.aqua, NSAppearance.Name.accessibilityHighContrastAqua),
                                     (.darkAqua, .accessibilityHighContrastDarkAqua)] {
            let appearance = try #require(NSAppearance(named: normal))
            appearance.performAsCurrentDrawingAppearance {
                for token in UIColors.allCases {
                    let base = contrast(token.variants.resolved(for: normal), on: .windowBackgroundColor)
                    let high = contrast(token.variants.resolved(for: increased), on: .windowBackgroundColor)
                    #expect(high > base, "\(token) \(normal.rawValue)")
                    #expect(high >= 7)
                }
            }
        }
    }

    @Test func 색_버튼과_초안_배지의_글자도_대비를_갖는다() throws {
        for name in Self.appearances {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for token in [UIColors.hot, .cue, .loop] {
                    #expect(contrast(UIColors.onFillVariants.resolved(for: name), on: token.variants.resolved(for: name)) >= 4.5)
                }
                #expect(contrast(UIColors.draft.variants.resolved(for: name), on: UIColors.draftFillVariants.resolved(for: name)) >= 4.5)
            }
        }
    }

    @Test func 조성_점은_스물네_색_모두_아이콘_대비를_갖는다() throws {
        for name in Self.appearances {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for number in 1...12 {
                    for mode in ["A", "B"] {
                        let key = "\(number)\(mode)"
                        #expect(contrast(UIColors.keyDots[key]!.resolved(for: name), on: .windowBackgroundColor) >= 3,
                                "\(name.rawValue) \(key)")
                    }
                }
            }
        }
    }

    @Test func 파형_눈금_글자는_고정_어두운_배경에서_읽힌다() {
        #expect(contrast(NSColor(Palette.rulerText), on: NSColor(Palette.well)) >= 4.5)
    }

    @Test func 파형_조성_띠의_글자는_가장_밝은_조성에서도_읽힌다() {
        for number in 1...12 {
            for mode in ["A", "B"] {
                let color = NSColor(Palette.keyColor("\(number)\(mode)"))
                for opacity in [Palette.keyBandOpacity(changes: false), Palette.keyBandOpacity(changes: true)] {
                    let band = composite(color.withAlphaComponent(opacity), on: NSColor(Palette.well))
                    #expect(contrast(.white, on: band) >= 4.5)
                }
            }
        }
    }

    @Test func 태그_셀은_선택과_모양새가_바뀌어도_읽힌다() throws {
        let cell = SheetCell(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            let appearance = try #require(NSAppearance(named: name))
            cell.appearance = appearance
            for selected in [false, true, false] {
                cell.configure(text: "초안", edited: true, readOnly: false, selected: selected, active: true)
                appearance.performAsCurrentDrawingAppearance {
                    let background = cell.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } ?? .clear
                    let surface = composite(background, on: .textBackgroundColor)
                    #expect(contrast(cell.label.textColor!, on: surface) >= 4.5)
                    #expect(contrast(NSColor(cgColor: cell.layer!.borderColor!)!, on: surface) >= 3)
                }
            }
        }
    }

    private func contrast(_ foreground: NSColor, on background: NSColor) -> Double {
        let foreground = composite(foreground, on: background)
        let background = background.usingColorSpace(.sRGB)!
        func luminance(_ color: NSColor) -> Double {
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func composite(_ foreground: NSColor, on background: NSColor) -> NSColor {
        let f = foreground.usingColorSpace(.sRGB)!, b = background.usingColorSpace(.sRGB)!
        let a = f.alphaComponent
        return NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a),
                       green: f.greenComponent * a + b.greenComponent * (1 - a),
                       blue: f.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }
}
