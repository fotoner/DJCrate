import DJCDomain
import Foundation

/// 곡별 초안 파일(포트): 저장 큐를 거치지 않고 초안 폴더의 곡 하나짜리 파일을 바로 읽고 쓴다.
/// XML 가져오기·USB 큐 가져오기(계획한 뒤 생긴 초안은 덮지 않으려고 쓰기 직전에 본다)와 CLI `djc draft`(앱이 꺼져 있을 때)가 쓴다.
/// 실제 구현은 DJCAdapters(`DraftFiles.live(home:)`).
public struct DraftFiles: Sendable {
    /// 곡의 초안 파일이 있는지(읽지 못하는 파일도 있는 것으로 본다: 덮지 않는다). 재생 목록은 늘 거짓
    public var exists: @Sendable (_ kind: XMLImportDrafts.Kind, _ trackUUID: String) -> Bool
    public var saveCue: @Sendable (CueDraft) throws -> Void
    public var saveGrid: @Sendable (GridDraft) throws -> Void
    public var saveTag: @Sendable (TagDraft) throws -> Void
    /// 재생 목록 초안 파일(CLI는 앱이 꺼져 있을 때 이 파일을 바로 고친다)
    public var playlist: @Sendable () -> PlaylistDraft
    /// 재생 목록 초안 파일(없으면 빈 초안, 읽지 못하면 던진다: CLI `djc draft playlist`가 손상 파일을 덮지 않게)
    public var readPlaylist: @Sendable () throws -> PlaylistDraft
    public var savePlaylist: @Sendable (PlaylistDraft) throws -> Void
    /// 지금 파일의 재생 목록 초안이 `expected`와 같을 때만 `draft`를 저장한다(CLI가 계획한 원본의 재확인과 저장을 한 번에). 다르면 저장하지 않고 false.
    /// 실제 구현은 쓴 뒤 정리(판 지정 삭제)와 같은 초안 잠금 안에서 하므로 재확인과 저장 사이에 정리가 끼어들어 쓴 단계를 되살리지 못한다(R22).
    /// nil이면(잠금이 없는 가짜) `savePlaylist(_:ifCurrentIs:)`가 `readPlaylist`로 읽어 견준 뒤 `savePlaylist`로 저장한다
    public var savePlaylistIfUnchanged: (@Sendable (_ expected: PlaylistDraft, _ draft: PlaylistDraft) throws -> Bool)?
    /// 재생 목록 초안 파일 잠금(#260): 잡으면 푸는 함수, 앱이 rekordbox에 쓰는 중이거나 다른 실행이 들고 있으면 nil.
    /// 읽기·계획·저장을 이 잠금 안에서 한다. 잠금이 없는 구현은 늘 잡는다
    public var lockPlaylist: @Sendable () -> (@Sendable () -> Void)? = { {} }
    /// 큐·태그 초안 파일을 읽는다. 없으면 nil, 읽지 못하면 던진다
    public var cue: @Sendable (_ trackUUID: String) throws -> CueDraft?
    public var tag: @Sendable (_ trackUUID: String) throws -> TagDraft?
    public var removeCue: @Sendable (_ trackUUID: String) throws -> Void
    public var removeTag: @Sendable (_ trackUUID: String) throws -> Void
    /// 그 종류의 초안 폴더와 곡 파일 자리가 심볼릭 링크가 아닌지(링크를 따라 초안 폴더 밖을 고치지 않게)
    public var isPlainPath: @Sendable (_ kind: XMLImportDrafts.Kind, _ trackUUID: String) -> Bool
    /// 초안에 새로 들이는 큐의 ID(`DraftStore.newCueID`와 같은 규칙)
    public var newCueID: @Sendable () -> UUID
    /// 이 포트로 저장하는 초안의 출처(R5, CLI는 CLI·AI·스킬은 agent). 정하지 않으면 모름이다. 실제 구현은 W1-B(#400)
    public var origin: DraftOrigin = .unknown
    /// 곡 초안의 도장(출처·판·저장한 때의 해시). 없거나 모르면 nil(기본값: 모름)
    public var stamp: @Sendable (DraftKey) -> DraftStamp? = { _ in nil }
    /// 같은 초안 폴더를 쓰되 출처만 다른 포트를 만든다(LINK 큐 편집). nil이면 `origin`만 바꾼 같은 포트다
    public var originVariant: (@Sendable (DraftOrigin) -> DraftFiles)?

    public init(exists: @escaping @Sendable (_ kind: XMLImportDrafts.Kind, _ trackUUID: String) -> Bool,
                saveCue: @escaping @Sendable (CueDraft) throws -> Void,
                saveGrid: @escaping @Sendable (GridDraft) throws -> Void,
                saveTag: @escaping @Sendable (TagDraft) throws -> Void,
                playlist: @escaping @Sendable () -> PlaylistDraft,
                readPlaylist: @escaping @Sendable () throws -> PlaylistDraft,
                savePlaylist: @escaping @Sendable (PlaylistDraft) throws -> Void,
                cue: @escaping @Sendable (_ trackUUID: String) throws -> CueDraft?,
                tag: @escaping @Sendable (_ trackUUID: String) throws -> TagDraft?,
                removeCue: @escaping @Sendable (_ trackUUID: String) throws -> Void,
                removeTag: @escaping @Sendable (_ trackUUID: String) throws -> Void,
                isPlainPath: @escaping @Sendable (_ kind: XMLImportDrafts.Kind, _ trackUUID: String) -> Bool,
                newCueID: @escaping @Sendable () -> UUID) {
        self.exists = exists
        self.saveCue = saveCue
        self.saveGrid = saveGrid
        self.saveTag = saveTag
        self.playlist = playlist
        self.readPlaylist = readPlaylist
        self.savePlaylist = savePlaylist
        self.cue = cue
        self.tag = tag
        self.removeCue = removeCue
        self.removeTag = removeTag
        self.isPlainPath = isPlainPath
        self.newCueID = newCueID
    }
}

extension DraftFiles {
    /// 같은 초안 폴더를 그 출처로 저장하는 포트. `originVariant`가 없는 포트(손으로 만든 포트)는 `origin` 표시만 바뀌고 도장은 그 구현을 따른다
    public func with(origin: DraftOrigin) -> DraftFiles {
        if let originVariant { return originVariant(origin) }
        var copy = self
        copy.origin = origin
        return copy
    }
}

/// 재생 목록 초안 파일을 읽지 못했다(형식 오류·손상). 잠금·저장 오류와 구분한다: CLI는 이것을 `invalid_draft`로, 잠금·저장 오류를 `draft_io_failed`로 알린다
public struct DraftFilesUnreadable: Error, Sendable {
    public init() {}
}

extension DraftFiles {
    /// 지금 파일의 재생 목록 초안이 `expected`와 같을 때만 저장한다. 같은 초안 잠금 안에서 하는 구현이 있으면 그것을 쓴다(`savePlaylistIfUnchanged`)
    public func savePlaylist(_ draft: PlaylistDraft, ifCurrentIs expected: PlaylistDraft) throws -> Bool {
        if let savePlaylistIfUnchanged { return try savePlaylistIfUnchanged(expected, draft) }
        let current: PlaylistDraft
        do { current = try readPlaylist() } catch { throw DraftFilesUnreadable() }
        guard current == expected else { return false }
        try savePlaylist(draft)
        return true
    }
}
