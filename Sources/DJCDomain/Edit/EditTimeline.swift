import Foundation

// 컷 편집 화면(#128)의 규칙: 원곡에서 끌어 마디 구간 고르기, 결과 타임라인의 클립 찾기·자르기·끌어 옮기기, 마디 단위 이동.

public extension BarLayout {
    /// 마디 줄(마디 시작) 시각. `count + 1`은 마지막 마디의 끝(끝에서 잘렸으면 곡 끝)이다.
    func time(ofBoundary bar: Int) -> Double {
        bar > count ? end(ofBar: count) : start(ofBar: bar)
    }

    /// 가장 가까운 마디 줄. 곡 머리가 있으면 0(곡 시작), 끝은 `count + 1`.
    func boundary(near time: Double) -> Int {
        let time = min(max(time, 0), duration)
        let bar = min(max(bar(at: time), hasLeadIn ? 0 : 1), count)
        return time - self.time(ofBoundary: bar) <= end(ofBar: bar) - time ? bar : bar + 1
    }

    /// 원곡 파형에서 끌어 고른 구간: 양 끝을 가까운 마디 줄에 붙인다. 한 마디 안에서 조금만 끌었으면 그 마디 하나.
    func selection(from a: Double, to b: Double) -> BarRange? {
        guard count > 0 else { return nil }
        let first = boundary(near: min(a, b)), end = boundary(near: max(a, b))
        if end > first { return BarRange(first, end - 1) }
        let middle = min(max((a + b) / 2, 0), duration)
        let bar = min(max(bar(at: middle), hasLeadIn ? 0 : 1), count)
        return BarRange(bar, bar)
    }

    /// 앞(−)·뒤(+)로 `bars`번째 마디 줄. 곡 앞·끝에서 멈춘다(←→ 키).
    func step(from time: Double, by bars: Int) -> Double {
        guard count > 0, bars != 0 else { return min(max(time, 0), duration) }
        let lines = ((hasLeadIn ? 0 : 1)...(count + 1)).map { min(self.time(ofBoundary: $0), duration) }
        var time = time
        for _ in 0..<abs(bars) {
            if bars > 0 {
                time = lines.first { $0 > time + Self.tolerance } ?? duration
            } else {
                time = lines.last { $0 < time - Self.tolerance } ?? 0
            }
        }
        return min(max(time, 0), duration)
    }
}

public extension BarRange {
    /// 결과에 넣을 모양: 곡 머리(0마디)는 맨 앞에 넣을 때만 살리고, 뒤에 붙이면 1마디부터. 곡 머리뿐이면 넣을 마디가 없다.
    func fitted(leading: Bool) -> BarRange? {
        guard first == 0, !leading else { return self }
        return last >= 1 ? BarRange(1, last) : nil
    }

    /// `bar` 앞에서 둘로 나눈다. 곡 머리(0마디)는 1마디와 떼지 않는다.
    func split(at bar: Int) -> [BarRange]? {
        guard bar > max(first, 1), bar <= last else { return nil }
        return [BarRange(first, bar - 1), BarRange(bar, last)]
    }
}

/// 결과 타임라인에서 자를 자리: 클립 순서, 뒤 조각의 첫 마디, 그 마디 줄의 출력 시각.
public struct EditSplit: Sendable, Equatable {
    public var clip: Int
    public var bar: Int
    public var outputTime: Double

    public init(clip: Int, bar: Int, outputTime: Double) {
        self.clip = clip
        self.bar = bar
        self.outputTime = outputTime
    }
}

public extension Array where Element == TrackEdit.Piece {
    /// 출력 시각이 든 클립. 출력 끝은 마지막 클립, 출력 밖이면 nil.
    func clipIndex(atOutput time: Double) -> Int? {
        guard let end = last?.outputEnd, time >= 0, time <= end + BarLayout.tolerance else { return nil }
        return firstIndex { time < $0.outputEnd } ?? count - 1
    }

    /// 끌어 온 클립을 놓을 순서(`move(fromOffsets:toOffset:)`의 toOffset): 가운데를 지난 클립 수.
    func dropOffset(atOutput time: Double) -> Int {
        filter { ($0.outputStart + $0.outputEnd) / 2 < time }.count
    }
}

public extension TrackEdit {
    func clipIndex(atOutput time: Double) -> Int? { clips.clipIndex(atOutput: time) }
    func dropOffset(atOutput time: Double) -> Int { clips.dropOffset(atOutput: time) }

    /// 재생선에서 가장 가까운 마디 줄로 자른다. 클립 끝이나 곡 머리 뒤(1마디 줄)가 더 가까우면 자를 곳이 없다.
    func split(atOutput time: Double) -> EditSplit? {
        guard let index = clipIndex(atOutput: time) else { return nil }
        let clip = clips[index]
        let base = layout.start(ofBar: clip.bars.first)
        var best: (bar: Int?, time: Double) = (nil, clip.outputStart)
        func consider(_ bar: Int?, _ at: Double) { if abs(at - time) < abs(best.time - time) { best = (bar, at) } }
        consider(nil, clip.outputEnd)
        if clip.bars.last > clip.bars.first {
            for bar in (clip.bars.first + 1)...clip.bars.last {
                consider(clip.bars.split(at: bar) == nil ? nil : bar, clip.outputStart + layout.start(ofBar: bar) - base)
            }
        }
        guard let bar = best.bar else { return nil }
        return EditSplit(clip: index, bar: bar, outputTime: best.time)
    }
}

// MARK: - 클립 가장자리 다듬기·원곡 구간 끌어 넣기(#134)

/// 클립의 가장자리
public enum EditEdge: Sendable, Equatable {
    case start, end
}

/// 누른 자리의 클립 가장자리(클립 순서)
public struct EditEdgeHit: Sendable, Equatable {
    public var clip: Int
    public var edge: EditEdge

    public init(clip: Int, edge: EditEdge) {
        self.clip = clip
        self.edge = edge
    }
}

/// 원곡에서 고른 구간을 결과에 놓을 자리: 놓는 순서(앞 클립 수)와 넣을 모양
public struct EditInsertion: Sendable, Equatable {
    public var offset: Int
    public var range: BarRange

    public init(offset: Int, range: BarRange) {
        self.offset = offset
        self.range = range
    }
}

public extension BarLayout {
    /// 클립 가장자리를 `seconds`만큼 끌어 다듬은 구간: 끈 자리를 가까운 마디 줄에 붙이고 적어도 1마디를 남긴다.
    /// 곡 머리(0마디)는 맨 앞 클립(`leading`)만, 끝에서 잘린 마지막 마디는 맨 뒤 클립(`trailing`)만 가진다(가운데 두면 박이 어긋난다).
    /// 가장자리가 가까운 마디 줄을 넘지 않았으면 그대로 둔다.
    func trimmed(_ range: BarRange, edge: EditEdge, by seconds: Double, leading: Bool, trailing: Bool) -> BarRange {
        switch edge {
        case .start:
            let bar = boundary(near: start(ofBar: range.first) + seconds)
            let lowest = leading && hasLeadIn ? 0 : 1
            guard bar != range.first, range.last >= lowest else { return range }
            return BarRange(min(max(bar, lowest), range.last), range.last)
        case .end:
            // 끝 마디 = 끈 자리에서 가까운 마디 줄 바로 앞 마디
            let bar = boundary(near: end(ofBar: range.last) + seconds) - 1
            let lowest = max(range.first, 1)
            let highest = max(trailing || !lastBarIsPartial ? count : count - 1, lowest)
            guard bar != range.last else { return range }
            return BarRange(range.first, min(max(bar, lowest), highest))
        }
    }
}

public extension Array where Element == TrackEdit.Piece {
    /// 누른 자리에서 `tolerance`(초) 안의 클립 가장자리. 두 클립이 맞닿은 줄에서는 누른 쪽 클립(줄 위는 뒤 클립의 시작)이다.
    /// 좁게 보이는 클립은 가운데 절반을 옮기기로 남긴다(가장자리는 클립 길이의 ¼까지).
    func edge(atOutput time: Double, tolerance: Double) -> EditEdgeHit? {
        guard tolerance > 0, let first, let last else { return nil }
        func reach(_ clip: TrackEdit.Piece) -> Double { Swift.min(tolerance, (clip.outputEnd - clip.outputStart) / 4) }
        if time > last.outputEnd { return time - last.outputEnd <= reach(last) ? EditEdgeHit(clip: count - 1, edge: .end) : nil }
        guard let index = clipIndex(atOutput: time) else {
            return first.outputStart - time <= reach(first) ? EditEdgeHit(clip: 0, edge: .start) : nil
        }
        let clip = self[index], reach = reach(clip)
        let fromStart = time - clip.outputStart, toEnd = clip.outputEnd - time
        if fromStart <= reach, fromStart <= toEnd { return EditEdgeHit(clip: index, edge: .start) }
        if toEnd <= reach { return EditEdgeHit(clip: index, edge: .end) }
        return nil
    }

    /// 원곡에서 고른 구간을 끌어 놓을 자리: 가운데를 지난 클립 수 뒤에 넣는다(`dropOffset`과 같다).
    /// 곡 머리로 시작하는 결과의 맨 앞에는 넣지 않고(곡 머리는 맨 앞에만), 고른 곡 머리는 맨 앞에 놓을 때만 살린다.
    /// 곡 머리뿐이라 넣을 마디가 없으면 nil.
    func insertion(of selection: BarRange, atOutput time: Double) -> EditInsertion? {
        var offset = dropOffset(atOutput: time)
        if offset == 0, first?.bars.first == 0 { offset = 1 }
        return selection.fitted(leading: offset == 0).map { EditInsertion(offset: offset, range: $0) }
    }
}
