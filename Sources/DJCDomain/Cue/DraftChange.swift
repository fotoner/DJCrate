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
    /// 그때 rekordbox 그리드 구간(그리드 초안의 base, 그리드가 없으면 nil). 저장 뒤 ⌘Z가 쓴 편집인지 가르고 새 base로 쓴다(R12)
    public var gridBase: [GridSegment]?
    /// 그때 rekordbox 오토게인(dB, 게인 초안의 base, R23)
    public var gainBase: Double?

    public init(cue: CueDraft, grid: GridDraft?, gain: Double?, gridBlockedReason: String?, gridBase: [GridSegment]? = nil, gainBase: Double? = nil) {
        self.cue = cue
        self.grid = grid
        self.gain = gain
        self.gridBlockedReason = gridBlockedReason
        self.gridBase = gridBase
        self.gainBase = gainBase
    }

    /// 저장 뒤 ⌘Z(R12): 이 스냅샷(편집 전)을 지금(`current`) 위로 옮긴 것. 편집 뒤(`after`)를 아직 쓰지 않았으면(그 종류의 base가 그대로) 그대로 되살린다.
    /// 썼으면 지금 초안 위에서 그 편집이 바꾼 것만 편집 전 값으로 되돌린 역편집 초안이다(base는 지금 rekordbox 값이다).
    /// - 큐는 ID(정체성)로 찾는다: 편집이 고친 큐는 지금 rekordbox ID로 고치고, 편집이 지운 큐는 rekordbox ID 없이 새 큐로 되살리며
    ///   (위치·종류·이름·색은 그대로, `restoredFrom`에 지우기 전 ID), 편집이 더한 큐는 지운다. 편집이 건드리지 않은 큐·앞 역편집이 바꾼 큐·
    ///   그 뒤 rekordbox에서 더한 큐는 지금 초안 그대로다(연속 ⌘Z가 앞 역편집을 덮지 않는다).
    /// - 그리드·게인은 그 편집이 바꿨을 때만 편집 전 구간·값을 지금 rekordbox 값 위의 초안으로 둔다.
    /// - 되돌릴 큐·그리드·게인의 지금 값이 그 편집 직후 값이 아니면(바깥에서 또 바뀜) nil이다. 쓴 큐를 지금 찾지 못해도 nil이다(정할 수 없다: ⌘Z를 끈다)
    public func rebased(from after: DeckDraftSnapshot, onto current: DeckDraftSnapshot) -> DeckDraftSnapshot? {
        var applied = self
        applied.gridBlockedReason = current.gridBlockedReason
        if current.cue.base != after.cue.base {
            let now = current.cue.cues
            let present = Dictionary(now.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let known = Set(current.cue.base.map(\.id)).union(present.keys)
            guard after.cue.cues.allSatisfy({ known.contains($0.id) }) else { return nil }
            let before = Dictionary(cue.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let edited = Dictionary(after.cue.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // 편집이 고치거나 더한 큐는 지금 그 편집 직후 값이어야 한다
            for new in after.cue.cues where before[new.id].map({ !Self.sameCue($0, new) }) ?? true {
                guard let value = present[new.id], Self.sameCue(value, new) else { return nil }
            }
            var cues: [EditableCue] = []
            for value in now {
                switch (before[value.id], edited[value.id]) {
                case let (old?, new?) where !Self.sameCue(old, new):
                    // 편집이 고친 큐: 편집 전 값으로(지금 rekordbox ID로 찾는다)
                    var target = old
                    target.sourceID = value.sourceID
                    target.restoredFrom = value.restoredFrom
                    if target.color == nil { target.color = value.color }
                    cues.append(target)
                case (nil, _?):
                    // 편집이 더한 큐: 지운다
                    continue
                default:
                    cues.append(value)
                }
            }
            // 편집이 지운 큐: 새 큐로 되살린다(ID만 새로 받는다). 지금 있으면 편집 직후 모양이 아니다
            for old in cue.cues where edited[old.id] == nil {
                guard present[old.id] == nil else { return nil }
                var restored = old
                restored.restoredFrom = old.sourceID ?? old.restoredFrom
                restored.sourceID = nil
                cues.append(restored)
            }
            applied.cue = CueDraft(trackUUID: cue.trackUUID, base: current.cue.base, cues: cues.sorted { $0.time < $1.time })
        }
        if current.gridBase != after.gridBase {
            let target = grid?.segments ?? gridBase, edited = after.grid?.segments ?? after.gridBase
            let now = current.grid?.segments ?? current.gridBase
            if let target, let edited, current.gridBase != nil, GridDraft.sameBeats(target, edited) {
                // 이 편집은 그리드를 바꾸지 않았다: 지금 그리드 그대로
                applied.grid = current.grid
            } else if let target, let base = current.gridBase {
                // 지금 그리드가 그 편집 직후 그리드여야 한다(같은 박)
                guard let edited, let now, GridDraft.sameBeats(now, edited) else { return nil }
                // 덱은 그리드가 있으면 고친 것이 없어도 그리드 초안을 들고 편집한다(저장은 고친 것이 없으면 지운다)
                applied.grid = GridDraft(trackUUID: cue.trackUUID, base: base, segments: target)
            } else if target != nil || current.gridBase != nil {
                // 그리드가 생기거나 없어진 편집(분석 붙이기)은 되돌릴 수 없다
                return nil
            }
            applied.gridBase = current.gridBase
        }
        if !Self.sameGain(current.gainBase, after.gainBase) {
            guard let base = current.gainBase else { return nil }
            let target = gain ?? gainBase, edited = after.gain ?? after.gainBase
            if let target, let edited, abs(target - edited) >= 0.05 {
                // 지금 게인이 그 편집 직후 값이어야 한다
                guard abs((current.gain ?? base) - edited) < 0.001 else { return nil }
                applied.gain = GainPolicy.draft(for: target, rekordbox: base)
            } else {
                // 이 편집은 게인을 바꾸지 않았다: 지금 그대로
                applied.gain = current.gain
            }
            applied.gainBase = base
        }
        return applied
    }

    /// 큐 값이 같은지(`CueDraft.changes`와 같은 기준: 시각·끝 1ms 미만 차이는 같다)
    private static func sameCue(_ a: EditableCue, _ b: EditableCue) -> Bool {
        a.kind == b.kind && abs(a.time - b.time) < 0.001 && a.name == b.name && a.loop?.active == b.loop?.active
            && abs((a.loop?.end ?? -1) - (b.loop?.end ?? -1)) < 0.001 && a.loop?.beats == b.loop?.beats
    }

    private static func sameGain(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case let (a?, b?): abs(a - b) < 0.0005
        case (nil, nil): true
        default: false
        }
    }
}
