import DJCDomain
import AppKit
import SwiftUI

/// 3밴드 파형을 가운데 기준 대칭으로 그린다.
/// 픽셀 열의 샘플 구간을 곡의 절대 시간(빈 = span/열 수)에 고정한다. 창이 움직여도 빈 경계가
/// 바뀌지 않아 스크롤 중 반짝임(에일리어싱)이 생기지 않는다.
func drawBands(_ context: GraphicsContext, waveform: Waveform, from start: Double, to end: Double,
                       in rect: CGRect, scales: (Double, Double, Double) = (1, 0.78, 0.5)) {
    let columns = max(1, Int(rect.width))
    let span = end - start
    guard span > 0, waveform.count > 0 else { return }
    let binDuration = span / Double(columns)
    let firstBin = Int((start / binDuration).rounded(.down))
    let cy = rect.midY, half = rect.height / 2
    // 가장자리 빈이 창 밖으로 반 칸 나가므로 가로만 잘라낸다.
    var context = context
    context.clip(to: Path(rect.insetBy(dx: 0, dy: -rect.height)))
    for (band, scale, color) in [(waveform.low, scales.0, Palette.low), (waveform.mid, scales.1, Palette.mid),
                                 (waveform.high, scales.2, Palette.high)] {
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        top.reserveCapacity(columns + 2); bottom.reserveCapacity(columns + 2)
        for k in 0...(columns + 1) {
            let t0 = Double(firstBin + k) * binDuration
            let a = Int((t0 * waveform.rate).rounded(.down))
            let b = max(a + 1, Int(((t0 + binDuration) * waveform.rate).rounded(.down)))
            var peak: UInt8 = 0
            if a < band.count, b > 0 {
                for i in max(0, a)..<min(band.count, b) where band[i] > peak { peak = band[i] }
            }
            let amplitude = Double(peak) / 255 * half * scale
            let x = rect.minX + CGFloat((t0 - start) / span) * rect.width
            top.append(CGPoint(x: x, y: cy - amplitude))
            bottom.append(CGPoint(x: x, y: cy + amplitude))
        }
        var path = Path()
        path.addLines(top + bottom.reversed())
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}

func chip(_ context: GraphicsContext, _ text: String, at point: CGPoint, color: Color, selected: Bool, maxX: CGFloat = .infinity) {
    chip(context, Text(text), at: point, color: color, selected: selected, maxX: maxX)
}

/// 글자 칩(핫큐 슬롯 등). `text`에 심볼을 끼워 넣으면 옆 글자와 같은 글꼴로 그려진다.
/// `height`: 칩 높이(없으면 확대 파형 칩 높이). 전체 파형은 더 낮은 칩을 쓴다.
func chip(_ context: GraphicsContext, _ text: Text, at point: CGPoint, color: Color, selected: Bool, maxX: CGFloat = .infinity,
          metrics: WaveformMetrics = WaveformMetrics(), height: Double? = nil) {
    let label = context.resolve(text.font(.system(size: metrics.labelSize, weight: .bold)).foregroundStyle(Color.black))
    chip(context, resolved: label, size: label.measure(in: WaveformMetrics.chipProposal), at: point, color: color, selected: selected,
         maxX: maxX, metrics: metrics, height: height)
}

/// 이미 해석하고 잰 글자로 칩을 그린다(확대 파형은 `WaveformTextCache`로 프레임마다 다시 해석하지 않는다).
func chip(_ context: GraphicsContext, resolved label: GraphicsContext.ResolvedText, size: CGSize, at point: CGPoint, color: Color, selected: Bool,
          maxX: CGFloat = .infinity, metrics: WaveformMetrics = WaveformMetrics(), height: Double? = nil) {
    let half = size.width / 2 + 4
    let cx = min(max(point.x, half + 1), maxX - half - 1)
    let rect = CGRect(x: cx - half, y: point.y, width: size.width + 8, height: height ?? metrics.chipHeight)
    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
    if selected { context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(.white), lineWidth: 1.5) }
    context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
}

// MARK: - 확대 파형

/// Canvas 렌더러 안에서 읽은 값은 관찰 추적이 되지 않으므로, 본문에서 읽어 넘긴다.
struct DrawState {
    var grid: BeatGrid?
    var waveform: Waveform?
    var colorWaveform: ColorWaveformRaster?
    var waveformColorMode: WaveformColorMode
    var sections: [PartAnalysis.Span]
    var energies: [SectionEnergy]
    var suggestions: [Double]
    var cues: [EditableCue]
    var selected: EditableCue.ID?
    var playhead: Double
    var cuePoint: Double
    var previewGrid: BeatGrid?
    /// 파형은 음원 시간축이다. rekordbox 시간축 창을 이만큼 당겨서 읽는다.
    var audioOffset: Double
    var zoomSeconds: Double
    var segments: [GridSegment]
    var gridEditing: Bool
    var engagedLoop: EditableCue.ID?
    var instantLoop: DeckModel.InstantLoop?
    var loopSizeText: String
    /// 포인터가 올라간 큐·제안(굵게·밝게)
    var hoveredCue: EditableCue.ID?
    var hoveredSuggestion: Double?
    /// 글자 배율에 맞춘 라벨·눈금 크기
    var metrics: WaveformMetrics

    @MainActor init(_ deck: DeckModel, hover: ZoomPointerTarget = .empty, metrics: WaveformMetrics = WaveformMetrics()) {
        grid = deck.grid
        waveform = deck.waveform
        colorWaveform = deck.colorWaveform
        waveformColorMode = deck.waveformColorMode
        sections = deck.analysis?.sections ?? []
        energies = deck.sectionEnergies
        suggestions = deck.suggestions
        cues = deck.draft?.cues ?? []
        selected = deck.selectedCueID
        playhead = deck.currentTime
        cuePoint = deck.cuePoint
        previewGrid = deck.grid == nil ? deck.suggestedGrid : nil
        audioOffset = deck.timelineOffset
        zoomSeconds = deck.zoomSeconds
        segments = deck.gridDraft?.segments ?? []
        engagedLoop = deck.engagedLoopID
        instantLoop = deck.instantLoop
        loopSizeText = deck.loopSizeText
        gridEditing = deck.gridEditing && deck.canEditGrid
        hoveredCue = hover.cue
        hoveredSuggestion = hover.suggestion
        self.metrics = metrics
    }
}
