import DJCDomain

/// 저장한 파형 높이와 창에 실제로 들어가는 높이를 분리한다.
enum DeckLayout {
    static let defaultWaveformHeight = 150.0
    static let minimumWaveformHeight = 80.0
    static let maximumWaveformHeight = 480.0
    static let minimumLibraryHeight = 150.0
    static let splitHandleHeight = 7.0
    static let minimumDetailWidth = 620.0

    /// 조작부가 차지하는 최소 높이의 남는 자리는 확대 파형에 배분한다.
    static func minimumZoomWaveformHeight(scale: Double) -> Double {
        max(minimumWaveformHeight, TextScale.length(190, scale: scale) - 8
            - WaveformMetrics(scale: scale).overviewHeight - TextScale.length(28, scale: scale))
    }

    static func waveformHeight(requested: Double, detailHeight: Double,
                               deckChromeHeight: Double, otherHeight: Double,
                               minimum: Double = minimumWaveformHeight) -> Double {
        let available = detailHeight - deckChromeHeight - otherHeight - minimumLibraryHeight
        let upperBound = max(minimum, min(available, maximumWaveformHeight))
        return min(max(requested, minimum), upperBound)
    }

    /// 핸들 조절(VoiceOver)·메뉴 '파형 크게·작게' 한 번에 바뀌는 높이
    static let waveformHeightStep = 20.0

    /// 지금 보이는 높이에서 한 칸 키우거나(+1) 줄인다(−1). 저장한 높이가 창보다 커도 보이는 높이에서 움직인다.
    static func steppedWaveformHeight(displayed: Double, direction: Int, maximum: Double,
                                      minimum: Double = minimumWaveformHeight) -> Double {
        min(max(displayed + Double(direction) * waveformHeightStep, minimum), max(maximum, minimum))
    }

    /// 본문(덱·목록) 크기 측정인지. 인스펙터(`.inspector`)가 본문을 임시 높이로 한 번 더 배치해, 그 크기도 진짜 본문
    /// 크기와 번갈아 측정으로 왔다(#138). 본문에는 목록 최소 높이가 늘 들어가므로 그보다 낮은 측정은 버린다.
    static func isDetailMeasurement(height: Double) -> Bool { height >= minimumLibraryHeight }

    static func deckViewportHeight(contentHeight: Double, detailHeight: Double,
                                   otherHeight: Double) -> Double {
        min(contentHeight, max(0, detailHeight - otherHeight - minimumLibraryHeight))
    }
}

/// 메뉴 '파형 크게·작게'가 쓰는 파형 높이(보이는 높이·창에 들어가는 최대). 핸들과 같은 규칙으로 바꾼다.
struct WaveformHeightControl {
    var displayed: Double
    var maximum: Double
    var minimum = DeckLayout.minimumWaveformHeight
    var set: (Double) -> Void

    var canGrow: Bool { displayed < maximum - 0.5 }
    var canShrink: Bool { displayed > minimum + 0.5 }

    func grow() { set(DeckLayout.steppedWaveformHeight(displayed: displayed, direction: 1, maximum: maximum, minimum: minimum)) }
    func shrink() { set(DeckLayout.steppedWaveformHeight(displayed: displayed, direction: -1, maximum: maximum, minimum: minimum)) }
}

/// 메뉴 '파형 크게·작게'의 문맥(#155). 켤지만 값으로 싣고, 높이는 누를 때 그때의 값으로 정한다.
struct WaveformHeightMenu {
    var canGrow: Bool
    var canShrink: Bool
    var control: () -> WaveformHeightControl?

    func grow() { control()?.grow() }
    func shrink() { control()?.shrink() }
}

/// 덱 폭에 따른 배치 단계. 덱 본문은 폭 자체가 아니라 이 단계만 읽어, 창 크기·사이드바·인스펙터가 움직이는 동안
/// 프레임마다 덱 전체를 다시 계산하지 않는다(#138).
struct DeckWidthClass: Equatable {
    /// 큐 목록 폭(글자 배율 적용 전)
    var cueListWidth: Double

    init(width: Double) {
        cueListWidth = width < 1400 ? 250 : 290
    }
}
