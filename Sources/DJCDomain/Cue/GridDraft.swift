import Foundation

/// 템포 구간 하나. rekordbox XML의 `<TEMPO Inizio Bpm Metro Battito>`와 같은 모델이다.
public struct GridSegment: Codable, Hashable, Sendable {
    /// 구간 첫 박의 시각(초)
    public var start: Double
    public var bpm: Double
    /// 구간 첫 박의 박 번호(1~4)
    public var firstBeatNumber: Int

    public init(start: Double, bpm: Double, firstBeatNumber: Int) {
        self.start = start
        self.bpm = bpm
        self.firstBeatNumber = firstBeatNumber
    }
}

/// 곡 하나의 비트 그리드 초안. 변속곡은 구간이 여러 개다.
/// rekordbox에는 쓰지 않는다(검증된 반영 경로를 통해서만 나간다).
public struct GridDraft: Codable, Equatable, Sendable {
    public static let bpmRange: ClosedRange<Double> = 20...655.35

    public var trackUUID: String
    public var base: [GridSegment]
    public var segments: [GridSegment]
    /// 명시 대체를 승인한 원본 PQTZ 전체 박의 지문. 옛 초안은 nil이다.
    public var replacementSource: String?

    public init(trackUUID: String, grid: BeatGrid) {
        self.trackUUID = trackUUID
        base = GridDraft.segments(from: grid)
        segments = base
    }

    /// 원본 그리드(없으면 빈 배열)와 현재 구간으로 만든다. 추정 그리드를 적용할 때 쓴다.
    public init(trackUUID: String, base: [GridSegment], segments: [GridSegment]) {
        self.trackUUID = trackUUID
        self.base = base
        self.segments = segments
    }

    /// 부동소수 오차(±10ms 이동 후 되돌리기 등)는 변경으로 보지 않는다.
    public var hasChanges: Bool {
        // 구간값이 같아도 복잡 원본의 박을 명시 대체한 초안은 반영할 변경이다.
        if replacementSource != nil { return true }
        guard segments.count == base.count else { return true }
        return zip(segments, base).contains { a, b in
            abs(a.start - b.start) >= 0.0005 || abs(a.bpm - b.bpm) >= 0.0005 || a.firstBeatNumber != b.firstBeatNumber
        }
    }

    /// PQTZ 박 목록을 템포 구간으로 묶는다. BPM은 저장된 반올림 값(×100 정수) 대신
    /// 구간 첫 박~마지막 박 간격으로 다시 구해 재생성 오차를 줄인다.
    public static func segments(from grid: BeatGrid) -> [GridSegment] {
        var groups: [[BeatGrid.Beat]] = []
        for beat in grid.beats {
            // 템포가 같아도 박 간격이 예상과 5ms 넘게 다르면(위상 점프) 새 구간으로 본다.
            if let last = groups.last?.last, abs(last.bpm - beat.bpm) < 0.005,
               abs((beat.time - last.time) - 60 / beat.bpm) < 0.005 {
                groups[groups.count - 1].append(beat)
            } else {
                groups.append([beat])
            }
        }
        return groups.map { beats in
            let first = beats[0]
            var bpm = first.bpm
            if beats.count > 8, let last = beats.last {
                let interval = (last.time - first.time) / Double(beats.count - 1)
                if interval > 0 { bpm = 60 / interval }
            }
            return GridSegment(start: first.time, bpm: bpm, firstBeatNumber: first.number)
        }
    }

    /// 구간으로 박을 다시 만든다. 첫 구간은 곡 시작 쪽으로도 늘린다.
    public func grid(duration: Double) -> BeatGrid {
        var beats: [BeatGrid.Beat] = []
        let matched = matchingBaseIndices()
        for (index, segment) in segments.enumerated() where segment.bpm > 0 {
            let interval = 60 / segment.bpm
            // 상대 경계와 이전 BPM이 그대로면 기존 경계 직전 박도 유효하다.
            let retainsBoundary = preservesBoundary(after: index, matched: matched)
            let end = index + 1 < segments.count
                ? segments[index + 1].start - (retainsBoundary ? 0 : interval / 2)
                : duration + 0.0005
            var k = index == 0 ? -Int((segment.start / interval).rounded(.down)) : 0
            while true {
                let t = segment.start + Double(k) * interval
                if t >= end - 0.0005 { break }
                if t >= 0 {
                    let number = ((segment.firstBeatNumber - 1 + k) % 4 + 4) % 4 + 1
                    beats.append(.init(number: number, bpm: segment.bpm, time: (t * 1000).rounded() / 1000))
                }
                k += 1
            }
        }
        return BeatGrid(beats: beats)
    }

    /// 원본과 현재 구간의 대응. 시작 시각이 같거나 이웃과 함께 이동한 원본만 연결한다.
    /// 번호·BPM 편집은 구간의 정체성을 바꾸지 않지만, 새로 넣은 변속 지점은 연결하지 않는다.
    public func matchingBaseIndices() -> [Int?] {
        if segments.count == base.count, let first = segments.first, let oldFirst = base.first {
            let shift = first.start - oldFirst.start
            if zip(segments, base).allSatisfy({ abs(($0.start - $1.start) - shift) < 0.0005 }) {
                return base.indices.map { Optional($0) }
            }
        }
        var matches = [Int?](repeating: nil, count: segments.count)
        for index in segments.indices {
            let candidates = base.indices.filter { abs(base[$0].start - segments[index].start) < 0.0005 }
            if candidates.count == 1 { matches[index] = candidates[0] }
        }
        guard segments.count > 1, base.count > 1 else { return matches }
        let candidatePairs: [[Int]] = (0..<(segments.count - 1)).map { index in
            let gap = segments[index + 1].start - segments[index].start
            return base.indices.dropLast().filter { oldIndex in
                abs(segments[index].bpm - base[oldIndex].bpm) < 0.005
                    && abs(gap - (base[oldIndex + 1].start - base[oldIndex].start)) < 0.0005
            }
        }
        var changed = true
        while changed {
            changed = false
            for index in 0..<(segments.count - 1) {
                let lower = matches[..<index].compactMap { $0 }.last ?? -1
                let upper = matches[(index + 2)...].compactMap { $0 }.first ?? base.count
                let candidates = candidatePairs[index].filter { oldIndex in
                    (matches[index].map { $0 == oldIndex } ?? true)
                        && (matches[index + 1].map { $0 == oldIndex + 1 } ?? true)
                        && oldIndex > lower && oldIndex + 1 < upper
                }
                if candidates.count == 1, let oldIndex = candidates.first {
                    if matches[index] == nil { matches[index] = oldIndex; changed = true }
                    if matches[index + 1] == nil { matches[index + 1] = oldIndex + 1; changed = true }
                }
            }
        }
        return matches
    }

    /// 원본의 인접 구간과 상대 경계가 같은지 확인한다. 박 번호 변경은 박 시각에 영향을 주지 않는다.
    public func preservesBoundary(after index: Int) -> Bool {
        preservesBoundary(after: index, matched: matchingBaseIndices())
    }

    /// 여러 경계를 순회할 때 한 번 계산한 원본 대응을 재사용한다.
    public func preservesBoundary(after index: Int, matched: [Int?]) -> Bool {
        guard segments.indices.contains(index), index + 1 < segments.count,
              matched.count == segments.count,
              let oldIndex = matched[index], matched[index + 1] == oldIndex + 1 else { return false }
        return abs(segments[index].bpm - base[oldIndex].bpm) < 0.005
            && abs((segments[index + 1].start - segments[index].start)
                   - (base[oldIndex + 1].start - base[oldIndex].start)) < 0.0005
    }


    public func segmentIndex(at time: Double) -> Int {
        segments.lastIndex { $0.start <= time + 0.0005 } ?? 0
    }

    // MARK: - rekordbox식 편집

    /// 그리드 전체를 옮긴다.
    public mutating func shift(by seconds: Double) {
        for i in segments.indices { segments[i].start += seconds }
    }

    public mutating func setBPM(_ bpm: Double, at time: Double) {
        guard Self.bpmRange.contains(bpm) else { return }
        let index = segmentIndex(at: time)
        // 표시값(소수 둘째 자리)을 그대로 다시 넣는 경우는 무시한다. 그렇지 않으면 실측 BPM
        // (예: 153.9987)이 154.00으로 바뀌어 500박이면 약 16ms 어긋난다.
        guard abs(segments[index].bpm - bpm) >= 0.005 else { return }
        segments[index].bpm = (bpm * 100).rounded() / 100
    }

    /// `time`에 가장 가까운 박을 1박(마디 시작)으로 만든다.
    public mutating func setDownbeat(nearest time: Double, duration: Double) {
        guard let beat = grid(duration: duration).beats.min(by: { abs($0.time - time) < abs($1.time - time) }) else { return }
        // 가장 가까운 박이 다음 구간에 속할 수 있으므로 박 위치로 구간을 고른다.
        let index = segmentIndex(at: beat.time)
        let f = segments[index].firstBeatNumber
        segments[index].firstBeatNumber = ((f - beat.number) % 4 + 4) % 4 + 1
    }

    /// `time`에 박을 정확히 놓고 그 박을 1박으로 만든다(해당 구간의 시작점 이동).
    public mutating func setAnchor(at time: Double) {
        let index = segmentIndex(at: time)
        guard index == 0 || time > segments[index - 1].start else { return }
        segments[index].start = time
        segments[index].firstBeatNumber = 1
    }

    /// `time`에 가장 가까운 박에서 새 템포 구간을 시작한다(변속 지점).
    public mutating func addTempoChange(nearest time: Double, duration: Double) {
        guard let beat = grid(duration: duration).beats.min(by: { abs($0.time - time) < abs($1.time - time) }),
              !segments.contains(where: { abs($0.start - beat.time) < 0.001 })
        else { return }
        let bpm = segments[segmentIndex(at: beat.time)].bpm
        segments.append(GridSegment(start: beat.time, bpm: bpm, firstBeatNumber: beat.number))
        segments.sort { $0.start < $1.start }
    }

    /// `time` 그대로 새 템포 구간을 시작한다(Q를 끈 변속 지점, #207). 박 번호는 경계가 대신하는 가장 가까운 박을 잇는다.
    /// 쓰기는 앞 구간에서 경계의 반 박 안쪽 박을 새 구간 첫 박으로 대체하므로(rekordbox 7.2.18 #11 실험),
    /// 앞 구간이나 새 구간의 박이 모두 사라지는 자리(이웃 변속 지점과 반 박 안쪽)와 첫 구간 시작 앞은 받지 않는다.
    @discardableResult
    public mutating func addTempoChange(at time: Double, duration: Double) -> Bool {
        guard time.isFinite, time >= 0, time < duration, let first = segments.first, time > first.start + 0.0005 else { return false }
        let index = segmentIndex(at: time)
        let previous = segments[index]
        guard previous.bpm > 0 else { return false }
        let interval = 60 / previous.bpm
        // grid(duration:)가 경계 앞 반 박(+0.5ms 오차)까지를 앞 구간으로 둔다. 1ms 여유를 둔다.
        guard time - previous.start > interval / 2 + 0.001 else { return false }
        if index + 1 < segments.count, segments[index + 1].start - time <= interval / 2 + 0.001 { return false }
        guard let beat = grid(duration: duration).beats.min(by: { abs($0.time - time) < abs($1.time - time) }) else { return false }
        segments.insert(GridSegment(start: time, bpm: previous.bpm, firstBeatNumber: beat.number), at: index + 1)
        return true
    }

    public mutating func removeTempoChange(at index: Int) {
        guard index > 0, segments.indices.contains(index) else { return }
        segments.remove(at: index)
    }

    public mutating func revert() {
        segments = base
        replacementSource = nil
    }
}

// MARK: - 시간축 이동

public extension GridDraft {
    /// 모든 구간(원본 포함)을 옮긴다. rekordbox 시간축 ↔ DJCrate 시간축 변환에 쓴다.
    func shifted(by seconds: Double) -> GridDraft {
        guard seconds != 0 else { return self }
        var copy = self
        copy.base = base.map { GridSegment(start: $0.start + seconds, bpm: $0.bpm, firstBeatNumber: $0.firstBeatNumber) }
        copy.segments = segments.map { GridSegment(start: $0.start + seconds, bpm: $0.bpm, firstBeatNumber: $0.firstBeatNumber) }
        return copy
    }
}

public extension BeatGrid {
    func shifted(by seconds: Double) -> BeatGrid {
        guard seconds != 0 else { return self }
        return BeatGrid(beats: beats.map { .init(number: $0.number, bpm: $0.bpm, time: $0.time + seconds) })
    }
}

// MARK: - 그리드를 따라 큐 옮기기

public extension GridDraft {
    /// 그리드가 `old` → `new`로 바뀔 때 `time`에 있던 점이 따라갈 위치. 박 위의 점은 새 그리드의 같은 박으로,
    /// 박 사이의 점은 박 사이 같은 비율 자리로 간다.
    /// - 구간 수가 같으면 구간마다: 새 구간 시작에 가장 가까운 옛 박을 기준으로 옮기고 BPM 비율로 늘이거나 줄인다
    ///   (이동·BPM 변경·½박 이동은 그대로 따라가고, "여기서 그리드 시작"처럼 시작점이 멀리 뛰어도 반 박 안쪽만 움직인다).
    /// - 구간 수가 다르면(변속 지점 추가·삭제) 가장 가까운 박끼리 잇는다.
    static func carry(_ time: Double, from old: [GridSegment], to new: [GridSegment], duration: Double) -> Double {
        guard !old.isEmpty, !new.isEmpty, old != new else { return time }
        if old.count == new.count {
            let i = old.lastIndex { $0.start <= time + 0.0005 } ?? 0
            let o = old[i], n = new[i]
            guard o.bpm > 0, n.bpm > 0 else { return time }
            let interval = 60 / o.bpm
            let ratio = (n.start - o.start) / interval
            // 정확히 반 박(½박 이동)이면 옮긴 방향으로 간다.
            let k = abs(abs(ratio - ratio.rounded(.towardZero)) - 0.5) < 0.001 ? ratio.rounded(.towardZero) : ratio.rounded()
            let anchor = o.start + k * interval
            return n.start + (time - anchor) * o.bpm / n.bpm
        }
        let oldGrid = GridDraft(trackUUID: "", base: old, segments: old).grid(duration: duration)
        let newGrid = GridDraft(trackUUID: "", base: old, segments: new).grid(duration: duration)
        guard !oldGrid.beats.isEmpty, !newGrid.beats.isEmpty else { return time }
        let beat = oldGrid.snap(time)
        let oldBPM = oldGrid.beats[max(0, oldGrid.firstIndex(atOrAfter: beat - 0.0005))].bpm
        let target = newGrid.snap(beat)
        let newIndex = min(newGrid.beats.count - 1, newGrid.firstIndex(atOrAfter: target - 0.0005))
        let newBPM = newGrid.beats[newIndex].bpm
        return target + (time - beat) * oldBPM / newBPM
    }

    /// 그리드가 `old` → `new`로 바뀔 때 따라 옮긴 큐(핫큐·메모리 큐·루프 끝). 1ms 넘게 움직인 큐만 돌려준다.
    static func carried(_ cues: [EditableCue], from old: [GridSegment], to new: [GridSegment], duration: Double) -> [EditableCue] {
        guard old != new else { return [] }
        func carry(_ time: Double) -> Double { min(max(Self.carry(time, from: old, to: new, duration: duration), 0), duration) }
        return cues.compactMap { cue in
            var copy = cue
            copy.time = carry(cue.time)
            if let end = cue.loop?.end { copy.loop?.end = max(carry(end), copy.time + 0.01) }
            let moved = abs(copy.time - cue.time) >= 0.0005 || abs((copy.loop?.end ?? 0) - (cue.loop?.end ?? 0)) >= 0.0005
            return moved ? copy : nil
        }
    }
}

public extension GridSegment {
    /// 첫 구간은 곡 시작 쪽 첫 박(0초 이상)부터 쓰고, 박 번호도 그만큼 되돌린다. BPM은 소수 둘째 자리.
    static func rekordboxNormalized(_ segments: [GridSegment]) -> [GridSegment] {
        var result = segments.filter { $0.bpm > 0 }.map {
            GridSegment(start: $0.start, bpm: ($0.bpm * 100).rounded() / 100, firstBeatNumber: $0.firstBeatNumber)
        }
        guard var first = result.first else { return [] }
        let period = 60 / first.bpm
        let back = Int((first.start / period).rounded(.down))
        first.start -= Double(back) * period
        if first.start < 0 { first.start += period }
        let moved = Int(((first.start - result[0].start) / period).rounded())
        first.firstBeatNumber = ((first.firstBeatNumber - 1 + moved) % 4 + 4) % 4 + 1
        result[0] = first
        return result.filter { $0.start >= 0 }
    }
}
