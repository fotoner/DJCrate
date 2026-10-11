import Foundation

/// Flip 기록(`FlipRecording`)을 원본 구간을 차례로 이어 붙인 출력 시간표로 만든다.
///
/// 렌더·창 재생·큐 옮기기는 마디 편집과 같은 조각 규칙(`EditPieceTiming`)을 쓴다. 마디 편집과 달리 조각이 마디에 맞지 않을 수 있다
/// (퀀타이즈 없이 누른 핫큐·짧은 루프). 출력 그리드는 원본 박을 조각마다 옮기고, 박 간격·박 번호가 이어지지 않는 이음새에서
/// 새 템포 구간을 연다. 원본 시각은 rekordbox 시간축, 출력은 PCM이라 출력 시간축 = 음원 시간축이다.
public struct FlipEdit: Sendable, Equatable {
    public struct Piece: Sendable, Hashable, EditPieceTiming {
        public var sourceStart: Double
        public var sourceEnd: Double
        public var outputStart: Double
        public var outputEnd: Double

        public init(sourceStart: Double, sourceEnd: Double, outputStart: Double, outputEnd: Double) {
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd
            self.outputStart = outputStart
            self.outputEnd = outputEnd
        }
    }

    public let sourceDuration: Double
    public let pieces: [Piece]

    /// 이보다 짧은 조각은 버린다(같은 자리에서 곧바로 다시 뛴 점프)
    static let minimumPiece = 0.001

    public init(_ recording: FlipRecording, sourceDuration: Double) throws {
        guard sourceDuration > 0 else {
            throw DJCError.editRefused(String(ui: "곡 길이를 알 수 없어 Flip을 만들지 못했습니다. 곡을 다시 불러온 뒤 기록하세요"))
        }
        var ranges: [(start: Double, end: Double)] = []
        for segment in recording.path {
            let start = min(max(segment.start, 0), sourceDuration)
            let end = min(max(segment.end ?? sourceDuration, start), sourceDuration)
            guard end - start >= Self.minimumPiece else { continue }
            // 짧은 조각을 버려 앞 구간 끝에 바로 이어지게 됐으면 이음새가 아니니 합친다.
            if let last = ranges.last, abs(last.end - start) <= FlipRecording.tolerance {
                ranges[ranges.count - 1].end = end
            } else {
                ranges.append((start, end))
            }
        }
        guard ranges.count > 1 else {
            throw DJCError.editRefused(String(ui: "기록에 점프·루프가 없어 원곡과 같습니다. Flip 기록 중에 재생하며 핫큐·루프를 쓰세요"))
        }
        var output = 0.0
        pieces = ranges.map { range in
            let length = range.end - range.start
            defer { output += length }
            return Piece(sourceStart: range.start, sourceEnd: range.end, outputStart: output, outputEnd: output + length)
        }
        self.sourceDuration = sourceDuration
    }

    /// 출력 길이(초)
    public var duration: Double { pieces.last?.outputEnd ?? 0 }

    /// 이음새(원본에서 이어지지 않는 경계)의 출력 시각
    public var seams: [Double] { pieces.dropFirst().map(\.outputStart) }

    /// 출력 시각 → 원본 시각(미리 듣기용). 출력 끝을 넘으면 nil.
    public func sourceTime(atOutput time: Double) -> Double? { pieces.sourceTime(atOutput: time) }

    /// 큐를 출력 위치로 옮긴다(마디 편집과 같은 규칙: 처음 나오는 자리 하나, 루프는 한 조각 안에 들어야 한다).
    public func carry(_ cues: [EditableCue], newID: () -> UUID) -> CueCarry { pieces.carry(cues, newID: newID) }

    /// 조각마다 읽고 쓸 프레임(렌더·창 재생).
    public func frames(sampleRate: Double, sourceOffset: Double, crossfade: Double = TrackEdit.crossfadeSeconds) -> [EditFrameSpan] {
        pieces.frames(sampleRate: sampleRate, sourceOffset: sourceOffset, crossfade: crossfade)
    }

    /// 출력 그리드: 조각마다 원본 템포 구간의 첫 박을 옮기고, 앞 구간의 박 줄(같은 BPM·박 번호)에 그대로 놓이면 새 구간을 열지 않는다.
    /// 원본 첫 구간은 곡 시작 쪽으로, 마지막 구간은 곡 끝까지 늘려 본다(`GridDraft.grid`와 같다). 원본 그리드가 없으면 빈 배열.
    ///
    /// 짧은 루프·스터터에서 박이 사라지거나 모두 같은 번호가 되지 않게 두 규칙을 더한다(`GridDraft.grid`는 구간마다 "다음 시작 − 반 박"에서 자른다).
    /// - 박 줄은 이어지고 번호만 다른 이음새에서, 뒤 조각이 한 마디보다 짧으면 번호를 이어 센다(1박 루프 8바퀴 = 1·2·3·4·1·…).
    ///   한 마디 이상 이어지는 조각(핫큐로 넘어간 뒤 곡이 흐르는 곳)은 원곡 번호로 새 구간을 연다.
    /// - 새 구간이 앞 구간 시작에서 반 박 안에 열리면 앞 구간에는 박이 하나도 남지 않으니 앞 구간을 뺀다(½박 루프는 그 앞 박 줄이 이어진다).
    public func outputGrid(_ source: [GridSegment]) -> [GridSegment] {
        let segments = source.filter { $0.bpm > 0 }.sorted { $0.start < $1.start }
        guard !segments.isEmpty else { return [] }
        var result: [GridSegment] = []
        for piece in pieces {
            var seam = true
            for (index, segment) in segments.enumerated() {
                let from = index == 0 ? -Double.infinity : segment.start
                let to = index + 1 < segments.count ? segments[index + 1].start : Double.infinity
                let lo = max(piece.sourceStart, from), hi = min(piece.sourceEnd, to)
                guard lo < hi else { continue }
                let interval = 60 / segment.bpm
                let k = ((lo - segment.start) / interval - 1e-9).rounded(.up)
                let beat = segment.start + k * interval
                guard beat < hi else { continue }
                let number = ((segment.firstBeatNumber - 1 + Int(k)) % 4 + 4) % 4 + 1
                let candidate = GridSegment(start: piece.outputStart + beat - piece.sourceStart, bpm: segment.bpm, firstBeatNumber: number)
                // 이음새 뒤 첫 박만 번호를 이어 셀 수 있다(조각 안에서 원곡 그리드가 번호를 바꾼 것은 그대로 둔다).
                let short = seam && piece.sourceEnd - piece.sourceStart < 4 * interval - FlipRecording.tolerance
                seam = false
                while let last = result.last, candidate.start - last.start <= 30 / last.bpm + Self.gridTolerance {
                    result.removeLast()
                }
                if let last = result.last, Self.continues(last, with: candidate, countingOn: short) { continue }
                result.append(candidate)
            }
        }
        return result
    }

    /// `GridDraft.grid`가 박을 자를 때 보는 여유(0.5ms)와 같다
    static let gridTolerance = 0.0005

    /// `next`의 첫 박이 `segment`의 박 줄 위(같은 BPM, 1ms 안)에 있고 박 번호도 이어지는지.
    /// `countingOn`이면 번호는 보지 않는다(그 박을 앞 박 줄의 다음 번호로 센다).
    static func continues(_ segment: GridSegment, with next: GridSegment, countingOn: Bool = false) -> Bool {
        guard abs(segment.bpm - next.bpm) < 0.0005 else { return false }
        let interval = 60 / segment.bpm
        let beats = ((next.start - segment.start) / interval).rounded()
        guard abs(next.start - (segment.start + beats * interval)) <= FlipRecording.tolerance else { return false }
        return countingOn || ((segment.firstBeatNumber - 1 + Int(beats)) % 4 + 4) % 4 + 1 == next.firstBeatNumber
    }
}
