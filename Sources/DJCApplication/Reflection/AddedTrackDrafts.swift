import DJCDomain
import Foundation

/// 곡 넣기로 새 곡에 옮긴 초안의 규칙(#197·#202).
/// 넣을 때: 큐가 막힌 곡의 큐 초안·분석을 못 붙인 곡의 그리드 초안·키가 막힌 곡의 고른 키를 새 곡의 초안으로 옮긴다.
/// 되돌릴 때: 새 곡에 남은 초안이 넣을 때 옮긴 사본이라고 확인될 때만 지운다(그 초안은 추가한 곡으로 되살아난다).
/// 나머지는 사용자가 넣은 뒤 만든 것일 수 있어 남긴다(연결 안 된 초안, 쓰기 대기 목록에서 버릴 수 있다).
public enum AddedTrackDrafts {
    public enum Kind: CaseIterable, Hashable, Sendable {
        case cue, grid, tag

        public var label: String {
            switch self {
            case .cue: String(ui: "큐")
            case .grid: String(ui: "그리드")
            case .tag: String(ui: "태그")
            }
        }
    }

    /// 되돌릴 때 새 곡 하나에 남은 초안(저장 못 한 입력이 있으면 그것이 최신이다)
    public struct Leftover: Sendable {
        public var cue: CueDraft?
        public var grid: GridDraft?
        public var tag: TagDraft?

        public init(cue: CueDraft? = nil, grid: GridDraft? = nil, tag: TagDraft? = nil) {
            self.cue = cue
            self.grid = grid
            self.tag = tag
        }
    }

    /// 넣을 때 큐가 막힌 곡의 큐 초안을 새 곡의 초안으로 옮긴 모양. 되돌릴 때 이 규칙으로 다시 만들어 새 곡에 남은 초안과 비교한다(#202).
    public static func movedCueDraft(from draft: CueDraft, to uuid: String) -> CueDraft {
        var moved = CueDraft(trackUUID: uuid)
        for var cue in draft.cues {
            cue.sourceID = nil
            moved.place(cue)
        }
        return moved
    }

    /// 분석을 붙이지 못한 곡의 그리드 초안을 새 곡의 초안으로 옮긴 모양(`movedCueDraft`와 같은 까닭).
    public static func movedGridDraft(from draft: GridDraft, to uuid: String) -> GridDraft {
        var moved = draft
        moved.trackUUID = uuid
        moved.base = []
        return moved
    }

    /// 키가 막혀 키 없이 넣은 곡은 고른 키를 새 곡의 키 초안으로 남긴다(막힌 큐를 옮기는 것과 같다: 고른 키가 조용히 사라지지 않게).
    /// 기준은 쓰기 결과(`keyBase`, 넣은 곡의 태그 값)에서 만든다. 다시 읽기가 실패해 새 곡 행이 아직 없어도 초안이 남고,
    /// 나중에 읽으면 곡 행의 값과 같아 기준 어긋남으로 막히지 않는다(#197).
    public static func blockedKeyDrafts(_ report: RekordboxTrackWriteReport, keys: [String: String]) -> [TagDraft] {
        report.added.filter { $0.written && $0.keyReason != nil }.compactMap { outcome in
            guard let uuid = outcome.uuid, let key = keys[outcome.path], let base = outcome.keyBase else { return nil }
            var draft = TagDraft(trackUUID: uuid, base: base)
            draft.fields.musicalKey = key
            return draft
        }
    }

    /// 되돌릴 때 넣은 곡 하나에 남은 초안 가운데 남길 종류. 빠진 종류의 초안은 지운다(태그는 초안이 있을 때만).
    /// 큐·그리드는 백업에 남긴 추가한 곡의 초안(`stagedCue`·`stagedGrid`)에서 넣을 때 옮긴 모양을 다시 만들어 같을 때만 사본이다.
    /// 옮겨 둔 키만 있는 태그 초안은 추가 목록 곡에 돌아온 고른 키(`stagedKey`)와 같을 때만 사본이다. 확인하지 못하면(옛 백업이라 사본이 없거나,
    /// 연결 안 된 초안을 버렸거나, 추가 목록 저장이 빠졌을 때) 사용자가 넣은 뒤 고른 키와 가를 수 없어 남긴다.
    public static func kept(after outcome: RekordboxTrackWriteOutcome, leftover: Leftover, stagedCue: CueDraft?, stagedGrid: GridDraft?,
                            stagedKey: String?) -> Set<Kind> {
        guard let uuid = outcome.uuid else { return [] }
        var kept: Set<Kind> = []
        let movedCue = outcome.cuesWritten == nil ? stagedCue.map { movedCueDraft(from: $0, to: uuid) } : nil
        if let cue = leftover.cue, cue.hasChanges, cue != movedCue { kept.insert(.cue) }
        let movedGrid = stagedGrid.map { movedGridDraft(from: $0, to: uuid) }
        if let grid = leftover.grid, grid.hasChanges, grid != movedGrid { kept.insert(.grid) }
        if let tag = leftover.tag {
            let isMovedKey = outcome.keyReason != nil && tag.changedKeys == [.musicalKey] && stagedKey == tag.fields.musicalKey
            if !isMovedKey { kept.insert(.tag) }
        }
        return kept
    }

    /// 추가한 곡을 넣을 때 함께 쓸 키(사용자가 고른 Camelot 이름, #5). 키를 고치지 않았거나 비웠으면(넣는 곡은 처음부터 키가 없다) nil.
    public static func confirmedKey(_ draft: TagDraft?) -> String? {
        guard let draft else { return nil }
        var base = draft.base
        base.musicalKey = ""
        let adopted = draft.adoptingMusicalKey(of: base)
        guard adopted.changedKeys.contains(.musicalKey), !adopted.fields.musicalKey.isEmpty else { return nil }
        return adopted.fields.musicalKey
    }

    /// 태그 초안(시트·인스펙터에서 고친 값)을 파일 태그 위에 얹는다(넣기 계획). 빈 칸은 태그 없음.
    public static func apply(_ fields: TagFields, to tags: inout AudioTags) {
        func text(_ value: String) -> String? { value.isEmpty ? nil : value }
        tags.title = text(fields.title) ?? tags.title
        tags.artist = text(fields.artist)
        tags.album = text(fields.album)
        tags.albumArtist = text(fields.albumArtist)
        tags.genre = text(fields.genre)
        tags.composer = text(fields.composer)
        tags.year = Int(fields.year)
        tags.trackNumber = Int(fields.trackNumber)
        tags.comment = text(fields.comment)
    }
}
