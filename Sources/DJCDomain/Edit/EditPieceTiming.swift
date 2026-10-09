import Foundation

/// 원본 구간 하나를 출력 자리에 놓은 조각. 마디 편집(`TrackEdit.Piece`)과 Flip(`FlipEdit.Piece`)이 함께 쓴다.
///
/// 원본 시각은 rekordbox 시간축이고, 출력은 PCM(WAV·AIFF)이라 출력 시간축 = 음원 시간축이다.
public protocol EditPieceTiming {
    var sourceStart: Double { get }
    var sourceEnd: Double { get }
    var outputStart: Double { get }
    var outputEnd: Double { get }
}

extension EditPieceTiming {
    /// 원본 시각이 이 조각에 드는지. ms로 잘린 다운비트 큐가 앞 조각 끝에 붙지 않게 1ms 당겨 본다.
    func holds(_ time: Double) -> Bool {
        time >= sourceStart - BarLayout.tolerance && time < sourceEnd - BarLayout.tolerance
    }
}

public extension Array where Element: EditPieceTiming {
    /// 원본 시각이 출력에서 나오는 시각들(나오는 순서). 편집에서 빠진 시각이면 빈 배열.
    func outputTimes(of sourceTime: Double) -> [Double] {
        filter { $0.holds(sourceTime) }.map { Swift.max(0, $0.outputStart + sourceTime - $0.sourceStart) }
    }

    /// 출력 시각 → 원본 시각(미리 듣기용). 출력 끝을 넘으면 nil.
    func sourceTime(atOutput time: Double) -> Double? {
        guard let piece = first(where: { time >= $0.outputStart && time < $0.outputEnd }) else { return nil }
        return piece.sourceStart + time - piece.outputStart
    }

    /// 큐(핫큐·메모리 큐·루프)를 출력 위치로 옮긴다. 같은 소리가 여러 번 나오면 처음 나오는 자리 하나에만 둔다
    /// (핫큐 슬롯이 겹치지 않고, 인트로를 늘려도 뒤 인트로에 같은 메모리 큐가 또 생기지 않는다).
    /// 루프는 끝까지 한 조각 안에 드는 첫 자리로 옮긴다. 옮긴 큐는 새 곡의 큐라 `newID`로 새 ID를 받는다.
    func carry(_ cues: [EditableCue], newID: () -> UUID) -> CueCarry {
        var result = CueCarry(placed: [], dropped: [])
        for cue in cues {
            let candidates = filter { $0.holds(cue.time) }
            guard !candidates.isEmpty else { result.dropped.append(.init(cue: cue, reason: .cut)); continue }
            let fits = candidates.first { piece in cue.loop.map { $0.end <= piece.sourceEnd + BarLayout.tolerance } ?? true }
            guard let piece = fits else { result.dropped.append(.init(cue: cue, reason: .loopAcrossSeam)); continue }
            let time = Swift.max(0, piece.outputStart + cue.time - piece.sourceStart)
            var loop = cue.loop
            loop?.end = piece.outputStart + (cue.loop?.end ?? 0) - piece.sourceStart
            result.placed.append(EditableCue(id: newID(), kind: cue.kind, time: time, name: cue.name, loop: loop))
        }
        result.placed.sort { $0.time < $1.time }
        return result
    }

    /// 조각마다 읽고 쓸 프레임. 경계는 각각 반올림해 조각이 많아도 어긋남이 쌓이지 않는다.
    /// - Parameter sourceOffset: 원본의 rekordbox 시간축 − 음원 시간축(초). MP3·AAC 인코더 지연(`RekordboxTimeline.predictedOffset`).
    func frames(sampleRate: Double, sourceOffset: Double, crossfade: Double = TrackEdit.crossfadeSeconds) -> [EditFrameSpan] {
        func frame(_ seconds: Double) -> Int64 { Int64((seconds * sampleRate).rounded()) }
        var spans: [EditFrameSpan] = []
        for piece in self {
            let start = frame(piece.outputStart)
            let count = frame(piece.outputEnd) - start
            let fade = spans.last.map { Swift.min(frame(crossfade), $0.frameCount) } ?? 0
            spans.append(EditFrameSpan(sourceFrame: frame(piece.sourceStart - sourceOffset), frameCount: count,
                                       outputFrame: start, crossfadeFrames: fade))
        }
        return spans
    }
}
