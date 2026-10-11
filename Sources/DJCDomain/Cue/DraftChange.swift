/// 한 번의 편집 전후 값. 변하지 않은 편집은 이력에 넣지 않고, 실행 취소 때 전후를 맞바꾼다.
public struct DraftChange<State: Equatable & Sendable>: Equatable, Sendable {
    public let before: State
    public let after: State

    public init?(before: State, after: State) {
        guard before != after else { return nil }
        self.before = before
        self.after = after
    }

    public var reversed: Self { Self(before: after, after: before)! }
}

/// 그리드와 함께 움직인 큐도 한 번에 복원할 덱 초안이다. 재생 위치는 편집 이력에 넣지 않는다.
public struct DeckDraftSnapshot: Equatable, Sendable {
    public var cue: CueDraft
    public var grid: GridDraft?
    public var gain: Double?
    public var gridBlockedReason: String?

    public init(cue: CueDraft, grid: GridDraft?, gain: Double?, gridBlockedReason: String?) {
        self.cue = cue
        self.grid = grid
        self.gain = gain
        self.gridBlockedReason = gridBlockedReason
    }
}
