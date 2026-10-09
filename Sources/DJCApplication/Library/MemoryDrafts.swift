import DJCDomain
import Foundation
import Synchronization

/// 파일 없이 메모리에만 두는 초안 저장소(`DraftStore`의 메모리 구현). 유스케이스·화면 시험이 디스크·저장 큐 없이 쓴다.
/// 실제 구현과 같은 규칙을 따른다(고친 것이 없는 초안 저장은 지우기, 게인 nil은 지우기). 저장은 바로 끝나고 실패하지 않는다.
/// 같은 규칙인지는 DJCAdaptersTests의 계약 시험이 실제 구현과 함께 본다.
public final class MemoryDrafts: Sendable {
    private struct State {
        var cues: [String: CueDraft] = [:]
        var grids: [String: GridDraft] = [:]
        var gains: [String: Double] = [:]
        var tags: [String: TagDraft] = [:]
        var artwork: [String: ArtworkEdit] = [:]
        var playlist = PlaylistDraft()
        var merges: [DuplicateMergeDraft] = []
        var revision: UInt64 = 0
    }
    private let state = Mutex(State())

    public init() {}

    public func cue(_ uuid: String) -> CueDraft? { state.withLock { $0.cues[uuid] } }
    public func grid(_ uuid: String) -> GridDraft? { state.withLock { $0.grids[uuid] } }
    public func gain(_ uuid: String) -> Double? { state.withLock { $0.gains[uuid] } }
    public func tag(_ uuid: String) -> TagDraft? { state.withLock { $0.tags[uuid] } }

    public func save(_ draft: CueDraft) {
        state.withLock { $0.revision += 1; $0.cues[draft.trackUUID] = draft.hasChanges ? draft : nil }
    }
    public func save(_ draft: GridDraft) {
        state.withLock { $0.revision += 1; $0.grids[draft.trackUUID] = draft.hasChanges ? draft : nil }
    }
    public func save(gain: Double?, _ uuid: String) {
        state.withLock { $0.revision += 1; $0.gains[uuid] = gain }
    }
    public func save(_ draft: TagDraft) {
        state.withLock { $0.tags[draft.trackUUID] = draft.hasChanges ? draft : nil }
    }
    public func removeGrid(_ uuid: String) { save(GridDraft(trackUUID: uuid, base: [], segments: [])) }

    /// 이 메모리 초안을 읽고 쓰는 포트
    public var store: DraftStore {
        DraftStore(
            flush: {},
            saveRevision: { self.state.withLock { $0.revision } },
            failures: { [] },
            unsavedUUIDs: { [] },
            unsaved: { UnsavedDrafts() },
            failedTagSaves: { [] },
            retry: { _, _, _ in false },
            isResolved: { _ in false },
            fileStamps: { [:] },
            preserveDamaged: { [] },
            takeMovedFiles: { [] },
            cueDraftUUIDs: { Set(self.state.withLock { $0.cues.keys }) },
            cueDraft: { self.cue($0) },
            pendingCue: { _ in nil },
            saveCue: { draft, completion in self.save(draft); completion(nil) },
            gridDraftUUIDs: { Set(self.state.withLock { $0.grids.keys }) },
            gridDraft: { self.grid($0) },
            pendingGrid: { _ in nil },
            saveGrid: { draft, completion in self.save(draft); completion(nil) },
            gainDraftUUIDs: { Set(self.state.withLock { $0.gains.keys }) },
            gainDrafts: { self.state.withLock { $0.gains } },
            pendingGain: { _ in nil },
            saveGain: { gain, uuid, completion in self.save(gain: gain, uuid); completion(nil) },
            tagDraftUUIDs: { Set(self.state.withLock { $0.tags.keys }) },
            tagDraft: { self.tag($0) },
            saveTags: { drafts in for draft in drafts { self.save(draft) } },
            artworkDraftUUIDs: { Set(self.state.withLock { $0.artwork.keys }) },
            artworkDrafts: { self.state.withLock { $0.artwork.mapValues(\.draft) } },
            artworkEdit: { uuid in self.state.withLock { $0.artwork[uuid] } },
            saveArtwork: { edit in self.state.withLock { $0.artwork[edit.trackUUID] = edit } },
            removeArtwork: { uuid in self.state.withLock { $0.artwork[uuid] = nil } },
            playlistDraft: { self.state.withLock { $0.playlist } },
            savePlaylistDraft: { draft in self.state.withLock { $0.playlist = draft } },
            mergeDrafts: { self.state.withLock { $0.merges } },
            saveMergeDrafts: { drafts in self.state.withLock { $0.merges = drafts } },
            newCueID: { MemoryCueIDs.next() })
    }
}

/// 메모리 구현(시험·덱 하네스)이 주는 새 큐 ID: 프로세스 안에서 차례로 늘어 겹치지 않는다(메모리 저장소 여럿 사이로 초안을 옮겨도
/// 같은 ID가 생기지 않게). 핵심부라 무작위 `UUID()` 대신 차례 번호로 만든다.
enum MemoryCueIDs {
    private static let counter = Mutex<UInt64>(0)

    static func next() -> UUID {
        let number = counter.withLock { value in
            value += 1
            return value
        }
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llX", number))!
    }
}
