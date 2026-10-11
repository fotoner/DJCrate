import Observation

/// 원시 측정값은 관찰하지 않고, 실제 적용 높이가 바뀔 때만 작은 뷰에 알린다.
@MainActor
@Observable
final class LibraryLayoutMetrics {
    @ObservationIgnored private var requested = DeckLayout.defaultWaveformHeight
    @ObservationIgnored private var detailHeight = 650.0
    @ObservationIgnored private var deckChromeHeight = 240.0
    @ObservationIgnored private var fittedChromeHeight = 240.0
    @ObservationIgnored private var noticeHeight = 0.0
    @ObservationIgnored private var listHeaderHeight = 40.0

    private(set) var waveformHeight = 150.0
    private(set) var minimumWaveformHeight = DeckLayout.minimumWaveformHeight
    private(set) var maximumWaveformHeight = 213.0
    private(set) var viewportHeight = 390.0
    /// 메뉴 '파형 크게·작게'를 켤지. 상한은 창 높이를 바꾸는 동안 단계마다 바뀌므로 메뉴 문맥은 이 둘만 읽는다(#155).
    private(set) var canGrowWaveform = true
    private(set) var canShrinkWaveform = true

    /// 누를 때의 보이는 높이·상한으로 한 칸 움직인다. 높이를 읽지 않으므로 창 크기가 바뀌어도 메뉴를 다시 만들지 않는다.
    func waveformHeightMenu(set: @escaping (Double) -> Void) -> WaveformHeightMenu {
        WaveformHeightMenu(canGrow: canGrowWaveform, canShrink: canShrinkWaveform) { [weak self] in
            guard let self else { return nil }
            return WaveformHeightControl(displayed: waveformHeight, maximum: maximumWaveformHeight,
                                         minimum: minimumWaveformHeight, set: set)
        }
    }

    func request(_ height: Double) { requested = height; update() }
    func setTextScale(_ scale: Double) {
        minimumWaveformHeight = DeckLayout.minimumZoomWaveformHeight(scale: scale)
        update()
    }
    func measureNotice(_ height: Double) { noticeHeight = height; update() }
    func measureListHeader(_ height: Double) { listHeaderHeight = height; update() }

    func measureDetail(height: Double, deckHeight: Double, waveformHeight: Double, hasTrack: Bool) {
        guard DeckLayout.isDetailMeasurement(height: height) else { return }
        // 곡 로드로 내용이 늘어날 때는 파형을 줄이지 않고, 창 높이가 바뀔 때만 맞춘다(PR #151).
        if hasTrack, abs(detailHeight - height) > 1 { fittedChromeHeight = deckChromeHeight }
        detailHeight = height
        deckChromeHeight = max(0, deckHeight - waveformHeight)
        update()
    }

    private func update() {
        let other = noticeHeight + listHeaderHeight + DeckLayout.splitHandleHeight
        let waveform = DeckLayout.waveformHeight(requested: requested, detailHeight: detailHeight,
                                                 deckChromeHeight: fittedChromeHeight, otherHeight: other, minimum: minimumWaveformHeight)
        let maximum = DeckLayout.waveformHeight(requested: DeckLayout.maximumWaveformHeight, detailHeight: detailHeight,
                                                deckChromeHeight: fittedChromeHeight, otherHeight: other, minimum: minimumWaveformHeight)
        let viewport = DeckLayout.deckViewportHeight(contentHeight: deckChromeHeight + waveform,
                                                     detailHeight: detailHeight, otherHeight: other)
        if waveformHeight != waveform { waveformHeight = waveform }
        if maximumWaveformHeight != maximum { maximumWaveformHeight = maximum }
        if viewportHeight != viewport { viewportHeight = viewport }
        let control = WaveformHeightControl(displayed: waveform, maximum: maximum, minimum: minimumWaveformHeight) { _ in }
        if canGrowWaveform != control.canGrow { canGrowWaveform = control.canGrow }
        if canShrinkWaveform != control.canShrink { canShrinkWaveform = control.canShrink }
    }
}
