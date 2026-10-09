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
    /// 다음 재생 목록 초안 읽기들이 차례로 이 값을 돌려준다(다 쓰면 저장된 값)
    public func queuePlaylistReads(_ drafts: [PlaylistDraft]) { state.withLock { $0.playlistReads = drafts } }

    public var files: DraftFiles {
        DraftFiles(
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
            // 실제 구현과 같다: 고친 것이 없는 초안 저장은 지우기
            saveCue: { [self] draft in state.withLock { $0.cues[draft.trackUUID] = draft.hasChanges ? draft : nil } },
            saveGrid: { [self] draft in state.withLock { $0.grids[draft.trackUUID] = draft.hasChanges ? draft : nil } },
            saveTag: { [self] draft in state.withLock { $0.tags[draft.trackUUID] = draft.hasChanges ? draft : nil } },
            playlist: { [self] in
                state.withLock { $0.playlistReads.isEmpty ? $0.playlist : $0.playlistReads.removeFirst() }
            },
            savePlaylist: { [self] draft in setPlaylist(draft) },
            cue: { [self] uuid in cue(uuid) },
            tag: { [self] uuid in tag(uuid) },
            removeCue: { [self] uuid in state.withLock { _ = $0.cues.removeValue(forKey: uuid) } },
            removeTag: { [self] uuid in state.withLock { _ = $0.tags.removeValue(forKey: uuid) } },
            isPlainPath: { _, _ in true },
            newCueID: { MemoryCueIDs.next() })
    }
}
