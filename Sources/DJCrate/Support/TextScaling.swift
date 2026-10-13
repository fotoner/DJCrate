import AppKit
import DJCDomain
import SwiftUI

extension EnvironmentValues {
    /// 앱 안 글자 배율(보기 › 글자 크게·작게). 창마다 `AppTextScale`이 넣는다.
    @Entry var textScale: Double = 1
}

/// 저장된 글자 배율을 창의 환경에 넣는다. 디버그 빌드는 `--text-scale=1.3`으로 설정을 건드리지 않고 볼 수 있다.
/// 이름에 점이 들어 `@AppStorage`로 두면 다른 설정이 바뀔 때마다(창 크기를 바꾸는 동안 창 프레임 자동 저장 등) 다시 계산한다(#138).
struct AppTextScale: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.textScale, PerfProbe.textScale ?? SharedSettings.textScale.value)
    }
}

extension Font {
    /// 텍스트 스타일을 글자 배율만큼 키운다. 1배면 스타일 그대로다(macOS는 텍스트 스타일 크기가 고정이라 직접 곱한다).
    static func scaled(_ style: Font.TextStyle, design: Font.Design = .default, _ scale: Double) -> Font {
        guard scale != 1 else { return .system(style, design: design) }
        return .system(size: TextScale.pointSize(style.macPointSize, scale: scale), weight: style.macWeight, design: design)
    }

    /// 고정 pt 글자(CDJ 패드·파형 라벨)에 글자 배율을 곱한다. 10pt 밑으로는 내려가지 않는다.
    static func scaled(size: Double, weight: Font.Weight = .regular, design: Font.Design = .default, _ scale: Double) -> Font {
        .system(size: TextScale.pointSize(size, scale: scale), weight: weight, design: design)
    }
}

extension Font.TextStyle {
    /// macOS 기본 크기(`NSFont.preferredFont(forTextStyle:)`와 같다)
    var macPointSize: Double {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    var macWeight: Font.Weight {
        switch self {
        case .headline: .bold
        case .caption2: .medium
        default: .regular
        }
    }
}

extension ControlSize {
    /// 글자 배율이 크면 한 단계 큰 컨트롤(작은 컨트롤 글자 11pt → 보통 13pt)
    func scaled(_ scale: Double) -> ControlSize {
        guard TextScale.controlSizeBoost(scale) > 0 else { return self }
        switch self {
        case .mini: return .small
        case .small: return .regular
        case .regular: return .large
        default: return self
        }
    }
}

/// 파형 위 글자·띠 크기. 글자 배율을 따라 커지고, 가장 작은 글자는 10pt다.
struct WaveformMetrics: Equatable {
    var scale: Double = 1
    /// 전체 파형 아래 조성 띠를 그리는지(설정 › 파형, 기본 끔).
    var showsKeyBand = false

    /// 파형 위 글자는 이 한 가지 크기다: 눈금(마디.박)·박 번호·조성 이름·핫큐 칩·큐 이름·루프·변속 BPM
    var labelSize: Double { TextScale.pointSize(10, scale: scale) }
    /// 확대 파형 위 눈금 줄
    var rulerHeight: Double { TextScale.length(16, scale: scale) }
    var chipHeight: Double { TextScale.length(14, scale: scale) }
    /// 제안 배지(+) 지름
    var badgeSize: Double { TextScale.length(18, scale: scale) }
    /// 눈금 줄 아래에서 루프 글자·큐 이름 가운데까지
    var loopLabelOffset: Double { TextScale.length(14, scale: scale) }
    var cueNameOffset: Double { TextScale.length(18, scale: scale) }
    /// 그리드 편집 중 박 번호: 아래 끝에서 글자 가운데까지(핫큐 칩 위)
    var beatNumberInset: Double { TextScale.length(26, scale: scale) }
    /// 눈금 라벨 한 자의 폭(라벨 수 줄이기에 쓴다)
    var charWidth: Double { BeatRulerLabel.charWidth(pointSize: labelSize) }
    /// 칩·알약 글자를 잴 때 주는 제안 크기(한 줄로 들어가게 넉넉하다)
    static let chipProposal = CGSize(width: 200, height: 40)

    // MARK: 전체 파형

    /// 전체 파형의 핫큐 슬롯 칩(10pt 글자가 들어가는 가장 낮은 칩)
    var overviewChipHeight: Double { TextScale.length(12, scale: scale) }
    var sectionBandHeight: Double { TextScale.length(14, scale: scale) }
    var keyBandHeight: Double { TextScale.length(12, scale: scale) }
    /// 파형 아래 섹션·조성 띠 자리(위아래 여백 포함)
    var overviewBandsHeight: Double { 3 + sectionBandHeight + (showsKeyBand ? keyBandSpace : 0) + 3 }
    /// 전체 파형 아래 템포 구간(BPM) 띠. 바로 위 섹션 띠보다 1pt 높다(글자가 들어가고 눈으로 보기에 비슷하게).
    var tempoBandHeight: Double { TextScale.length(15, scale: scale) }
    /// 조성 띠와 그 위 간격. 띠를 끄면 이만큼 확대 파형이 커져 덱 높이는 그대로다.
    var keyBandSpace: Double { 2 + keyBandHeight }
    /// 파형은 위쪽 절반만 그려 높이 28pt를 쓴다(위아래가 같은 모양이라 절반이면 충분하다).
    var overviewHeight: Double { 28 + overviewBandsHeight }

    /// 한 줄에 놓는 라벨(큐 이름 등)을 왼쪽부터 놓고, 앞 라벨과 `gap`보다 가까이 겹치는 것은 뺀다.
    /// 자리가 모자라면 글자를 줄이지 않고 라벨 수를 줄인다. 결과는 들어온 순서다.
    static func visibleLabels(_ spans: [(start: Double, end: Double)], gap: Double) -> [Bool] {
        var visible = Array(repeating: false, count: spans.count)
        var lastEnd = -Double.infinity
        for index in spans.indices.sorted(by: { spans[$0].start < spans[$1].start }) where spans[index].start >= lastEnd + gap {
            visible[index] = true
            lastEnd = spans[index].end
        }
        return visible
    }
}
