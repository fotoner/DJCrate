/// 덱의 메인 CUE 지점(CDJ식). 초안·rekordbox에는 쓰지 않는다.
public enum DeckCuePoint {
    /// 곡을 불러오면 대기할 자리: 첫 메모리 큐(없으면 0초)를 곡 길이 안으로 맞춘다.
    public static func onLoad(cues: [EditableCue], duration: Double) -> Double {
        let first = cues.filter { $0.kind == .memory }.map(\.time).min() ?? 0
        return min(max(first, 0), duration)
    }
}
