import DJCDomain
import Foundation
import Synchronization

/// 파일 없이 메모리에만 두는 곡별 초안 파일(`DraftFiles`의 메모리 구현). 유스케이스 시험이 쓴다.
/// 실제 구현과 같은 규칙을 따른다(곡마다 종류별 파일 하나, 있으면 있는 것, 고친 것이 없는 초안 저장은 지우기). 같은지는 DJCAdaptersTests의 계약 시험이 본다.
public final class MemoryDraftFiles: Sendable {
    private struct State {
        var cues: [String: CueDraft] = [:]
        var grids: [String: GridDraft] = [:]
        var tags: [String: TagDraft] = [:]
        var playlist = PlaylistDraft()
        /// 다음 `playlist` 읽기들에 차례로 돌려줄 값(시험이 계획 도중 바뀐 초안을 만든다)
        var playlistReads: [PlaylistDraft] = []
        /// 다른 실행이 재생 목록 초안 파일 잠금을 들고 있다
        var playlistLocked = false
        /// 곡 초안의 도장(종류·곡별). 파일만 두는 `put`·바깥 수정은 도장을 바꾸지 않는다
        var stamps: [DraftKey: DraftStamp] = [:]
        /// 마지막으로 준 판(이 가짜 전체에서 늘어난다)
        var lastRevision: UInt64 = 0

        /// 저장한 초안의 도장을 새 판으로 바꾼다(실제 구현과 같은 규칙): 출처는 포트의 출처에 앞 도장의 출처를 모으고, 파일이 있었는데
        /// 도장이 없으면(업데이트 전부터 있던 초안) 모름을 모은다. 초안이 없어졌으면(해시 nil) 도장도 지운다
        mutating func restamp(_ key: DraftKey, existed: Bool, origin: DraftOrigin, hash: DraftContentHash?) {
            guard let hash else {
                stamps[key] = nil
                return
            }
            var origins: Set<DraftOrigin> = [origin]
            if existed { origins.formUnion(stamps[key]?.origins ?? [.unknown]) }
            lastRevision += 1
            stamps[key] = DraftStamp(revision: DraftRevision(lastRevision), origins: origins, contentHash: hash)
        }
    }
    private let state = Mutex(State())

    public init() {}

    public func cue(_ uuid: String) -> CueDraft? { state.withLock { $0.cues[uuid] } }
    public func grid(_ uuid: String) -> GridDraft? { state.withLock { $0.grids[uuid] } }
    public func tag(_ uuid: String) -> TagDraft? { state.withLock { $0.tags[uuid] } }
    public var playlist: PlaylistDraft { state.withLock { $0.playlist } }
    /// 초안 파일 하나를 둔다(시험 준비: 고친 것이 없어도 둔다)
    public func put(_ draft: CueDraft) { state.withLock { $0.cues[draft.trackUUID] = draft } }
    public func put(_ draft: GridDraft) { state.withLock { $0.grids[draft.trackUUID] = draft } }
    public func put(_ draft: TagDraft) { state.withLock { $0.tags[draft.trackUUID] = draft } }
    public func setPlaylist(_ draft: PlaylistDraft) { state.withLock { $0.playlist = draft } }
    /// 곡 초안의 도장(없으면 nil)
    public func stamp(_ key: DraftKey) -> DraftStamp? { state.withLock { $0.stamps[key] } }
    /// 다음 재생 목록 초안 읽기들이 차례로 이 값을 돌려준다(다 쓰면 저장된 값)
    public func queuePlaylistReads(_ drafts: [PlaylistDraft]) { state.withLock { $0.playlistReads = drafts } }
    /// 다른 실행(앱의 쓰기)이 재생 목록 초안 파일 잠금을 들고 있는 것처럼 한다
    public func setPlaylistLocked(_ locked: Bool) { state.withLock { $0.playlistLocked = locked } }
    private var isPlaylistLocked: Bool { state.withLock { $0.playlistLocked } }

    /// 이 가짜를 출처를 정하지 않은 포트로 읽고 쓴다(조립이 출처를 정하지 않은 포트와 같다: 모름)
    public var files: DraftFiles { files(origin: .unknown) }

    /// 이 가짜를 그 출처로 읽고 쓰는 포트
    public func files(origin: DraftOrigin) -> DraftFiles {
        var files = DraftFiles(
            exists: { [self] kind, uuid in
                state.withLock {
                    switch kind {
                    case .cue: $0.cues[uuid] != nil
                    case .grid: $0.grids[uuid] != nil
                    case .tag: $0.tags[uuid] != nil
                    case .playlist: false
                    }
                }
            },
            // 실제 구현과 같다: 고친 것이 없는 초안 저장은 지우기(도장도 지운다)
            saveCue: { [self] draft in
                state.withLock {
                    let existed = $0.cues[draft.trackUUID] != nil
                    $0.cues[draft.trackUUID] = draft.hasChanges ? draft : nil
                    $0.restamp(DraftKey(.cue, draft.trackUUID), existed: existed, origin: origin, hash: draft.hasChanges ? MemoryDrafts.hash(draft) : nil)
                }
            },
            saveGrid: { [self] draft in
                state.withLock {
                    let existed = $0.grids[draft.trackUUID] != nil
                    $0.grids[draft.trackUUID] = draft.hasChanges ? draft : nil
                    $0.restamp(DraftKey(.grid, draft.trackUUID), existed: existed, origin: origin, hash: draft.hasChanges ? MemoryDrafts.hash(draft) : nil)
                }
            },
            saveTag: { [self] draft in
                state.withLock {
                    let existed = $0.tags[draft.trackUUID] != nil
                    $0.tags[draft.trackUUID] = draft.hasChanges ? draft : nil
                    $0.restamp(DraftKey(.tag, draft.trackUUID), existed: existed, origin: origin, hash: draft.hasChanges ? MemoryDrafts.hash(draft) : nil)
                }
            },
            playlist: { [self] in
                state.withLock { $0.playlistReads.isEmpty ? $0.playlist : $0.playlistReads.removeFirst() }
            },
            readPlaylist: { [self] in
                state.withLock { $0.playlistReads.isEmpty ? $0.playlist : $0.playlistReads.removeFirst() }
            },
            savePlaylist: { [self] draft in setPlaylist(draft) },
            cue: { [self] uuid in cue(uuid) },
            tag: { [self] uuid in tag(uuid) },
            removeCue: { [self] uuid in
                state.withLock {
                    _ = $0.cues.removeValue(forKey: uuid)
                    $0.stamps[DraftKey(.cue, uuid)] = nil
                }
            },
            removeTag: { [self] uuid in
                state.withLock {
                    _ = $0.tags.removeValue(forKey: uuid)
                    $0.stamps[DraftKey(.tag, uuid)] = nil
                }
            },
            isPlainPath: { _, _ in true },
            newCueID: { MemoryCueIDs.next() })
        let unlock: @Sendable () -> Void = {}
        files.lockPlaylist = { [self] in isPlaylistLocked ? nil : unlock }
        files.origin = origin
        files.stamp = { [self] in stamp($0) }
        files.originVariant = { [self] in self.files(origin: $0) }
        return files
    }
}
