import AppKit
import DJCDomain
import SwiftUI

/// 설정 › 파형: 색 모드. 덱의 확대·전체 파형과 곡 목록 미리 보기에 함께 적용된다.
/// 모드마다 같은 가짜 파형을 그 모드의 색으로 그린 견본을 곁에 두어, 글로 설명하지 않고 고르는 자리에서 차이를 보게 한다.
struct WaveformSettingsView: View {
    @Bindable var deck: DeckModel

    var body: some View {
        Form {
            Picker(.ui("색 모드"), selection: $deck.waveformColorMode) {
                ForEach(WaveformColorMode.allCases, id: \.self) { mode in
                    HStack(spacing: 10) {
                        WaveformSwatchView(mode: mode)
                        Text(mode.title)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            Toggle(.ui("전체 파형 아래 조성 띠 보이기"), isOn: $deck.showKeyBand)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 120)
    }
}

/// 색 모드 견본: 덱과 같은 비트맵 그리기로 가짜 파형 한 토막을 그린다(덱 배경은 늘 어둡다).
enum WaveformSwatch {
    static let size = CGSize(width: 56, height: 18)

    /// 대역 비율이 서로 다른 가짜 파형. 값이 고정이라 늘 같은 그림이다.
    static let columns: [WaveformColumn] = (0..<56).map { index in
        let t = Double(index) / 55
        let low = 0.55 + 0.4 * sin(t * .pi * 3.0)
        let mid = 0.40 + 0.3 * sin(t * .pi * 5.0 + 1.0)
        let high = 0.25 + 0.2 * sin(t * .pi * 9.0 + 2.0)
        return WaveformColumn(low: max(0.05, low), mid: max(0.05, mid), high: max(0.05, high))
    }

    static func image(for mode: WaveformColorMode) -> CGImage? {
        WaveformBitmap.image(columns, mode: mode, appearance: .darkAqua, height: Int(size.height) * 2, width: columns.count)
    }
}

struct WaveformSwatchView: View {
    let mode: WaveformColorMode

    var body: some View {
        Group {
            if let image = WaveformSwatch.image(for: mode) {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: WaveformSwatch.size.width, height: WaveformSwatch.size.height)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}
