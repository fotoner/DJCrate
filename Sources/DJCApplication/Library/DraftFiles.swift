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
    public var savePlaylist: @Sendable (PlaylistDraft) throws -> Void
    /// 큐·태그 초안 파일을 읽는다. 없으면 nil, 읽지 못하면 던진다
    public var cue: @Sendable (_ trackUUID: String) throws -> CueDraft?
    public var tag: @Sendable (_ trackUUID: String) throws -> TagDraft?
    public var removeCue: @Sendable (_ trackUUID: String) throws -> Void
    public var removeTag: @Sendable (_ trackUUID: String) throws -> Void
    /// 그 종류의 초안 폴더와 곡 파일 자리가 심볼릭 링크가 아닌지(링크를 따라 초안 폴더 밖을 고치지 않게)
    public var isPlainPath: @Sendable (_ kind: XMLImportDrafts.Kind, _ trackUUID: String) -> Bool
    /// 초안에 새로 들이는 큐의 ID(`DraftStore.newCueID`와 같은 규칙)
    public var newCueID: @Sendable () -> UUID

    public init(exists: @escaping @Sendable (_ kind: XMLImportDrafts.Kind, _ trackUUID: String) -> Bool,
                saveCue: @escaping @Sendable (CueDraft) throws -> Void,
                saveGrid: @escaping @Sendable (GridDraft) throws -> Void,
                saveTag: @escaping @Sendable (TagDraft) throws -> Void,
                playlist: @escaping @Sendable () -> PlaylistDraft,
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
        self.savePlaylist = savePlaylist
        self.cue = cue
        self.tag = tag
        self.removeCue = removeCue
        self.removeTag = removeTag
        self.isPlainPath = isPlainPath
        self.newCueID = newCueID
    }
}
