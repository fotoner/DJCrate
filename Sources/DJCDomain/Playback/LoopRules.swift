import Foundation

/// 루프 길이·끝 계산(CDJ 오토 비트 루프와 같은 사다리).
public enum LoopRules {
    /// 즉석 루프 길이(박). ½ · ×2로 한 칸씩 옮긴다.
    public static let sizes: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]

    public static func text(_ beats: Double) -> String {
        switch beats {
        case 0.25: "¼"
        case 0.5: "½"
        default: String(Int(beats))
        }
    }

    /// 한 칸 줄이거나(-1) 늘인다(+1). 사다리 밖 값은 그 위 칸을 기준으로 본다. 끝을 넘으면 nil.
    public static func resized(_ size: Double, direction: Int) -> Double? {
        guard let index = sizes.firstIndex(where: { $0 >= size - 0.001 }) ?? sizes.indices.last,
              sizes.indices.contains(index + direction) else { return nil }
        return sizes[index + direction]
    }

    /// `start`에서 `beats`박 뒤. 그리드가 있으면 박에 맞추고(1박 이상 정수), 아니면 그 자리 BPM(없으면 `fallbackBPM`, 그것도 없으면 120)으로 나눈다.
    /// 곡 끝을 넘거나 너무 짧으면 nil.
    public static func end(from start: Double, beats: Double, grid: BeatGrid?, fallbackBPM: Double?, duration: Double) -> Double? {
        let end: Double
        if let grid, !grid.beats.isEmpty, beats >= 1, beats == beats.rounded() {
            end = grid.nudge(start, beats: Int(beats))
        } else {
            let index = grid.map { max(0, $0.firstIndex(atOrAfter: start + 0.001) - 1) }
            let local = index.flatMap { i in grid.flatMap { $0.beats.indices.contains(i) ? $0.beats[i].bpm : nil } }
            end = start + beats * 60 / max(local ?? fallbackBPM ?? 120, 1)
        }
        guard end > start + 0.01, end <= duration + 0.01 else { return nil }
        return end
    }

    /// 루프 큐의 박 수(그리드 기준, 대략). 루프가 아니면 nil.
    public static func beats(of cue: EditableCue, grid: BeatGrid?, bpm: Double?) -> Int? {
        guard let loop = cue.loop else { return nil }
        if let grid, !grid.beats.isEmpty {
            let a = grid.firstIndex(atOrAfter: cue.time - 0.005), b = grid.firstIndex(atOrAfter: loop.end - 0.005)
            return max(b - a, 0)
        }
        return bpm.map { Int(((loop.end - cue.time) * $0 / 60).rounded()) }
    }
}
