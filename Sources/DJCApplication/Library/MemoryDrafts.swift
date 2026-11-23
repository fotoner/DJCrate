import DJCDomain
import Foundation
import Synchronization

/// 파일 없이 메모리에만 두는 초안 저장소(`DraftStore`의 메모리 구현). 유스케이스·화면 시험이 디스크·저장 큐 없이 쓴다.
/// 실제 구현과 같은 규칙을 따른다(고친 것이 없는 초안 저장은 지우기, 게인 nil은 지우기). 저장은 바로 끝나고 실패하지 않는다.
/// 같은 규칙인지는 DJCAdaptersTests의 계약 시험이 실제 구현과 함께 본다.
///
/// 초안마다 도장(출처·판·해시, R5·R22)을 적는다. 판은 이 저장소 전체에서 늘어나는 번호이고, 출처는 저장한 포트의 출처를 모은다.
/// 바깥에서 고친 초안은 `editOutside`·`editPlaylistOutside`로 흉내 낸다(도장은 그대로, 내용만 바뀐다).
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
        var stamps: [DraftKey: DraftStamp] = [:]
        var playlistStamps: [DraftStamp] = []
        /// 마지막으로 준 판(저장소 전체에서 늘어난다)
        var lastDraftRevision: UInt64 = 0
        /// 남긴 재생 목록 단계 사본(사본 자리 → 사본)
        var playlistCopies: [URL: PlaylistStepCopy] = [:]
        var failsPlaylistCopies = false

        /// 저장한 초안의 도장을 새 판으로 바꾼다(내용이 nil이면 초안이 없어져 도장도 지운다)
        mutating func restamp(_ key: DraftKey, hash: DraftContentHash?, origin: DraftOrigin) {
            guard let hash else {
                stamps[key] = nil
                return
            }
            stamps[key] = newStamp(origins: (stamps[key]?.origins ?? []).union([origin]), hash: hash)
        }

        mutating func newStamp(origins: Set<DraftOrigin>, hash: DraftContentHash) -> DraftStamp {
            lastDraftRevision += 1
            return DraftStamp(revision: DraftRevision(lastDraftRevision), origins: origins, contentHash: hash)
        }

        /// 지금 내용의 해시(초안이 없으면 nil)
        func currentHash(_ key: DraftKey) -> DraftContentHash? {
            switch key.kind {
            case .cue: cues[key.id].flatMap { MemoryDrafts.hash($0) }
            case .grid: grids[key.id].flatMap { MemoryDrafts.hash($0) }
            case .gain: gains[key.id].flatMap { MemoryDrafts.hash($0) }
            case .tag: tags[key.id].flatMap { MemoryDrafts.hash($0) }
            case .artwork: artwork[key.id].flatMap { MemoryDrafts.hash($0) }
            case .merge: merges.first(where: { $0.id == key.id }).flatMap { MemoryDrafts.hash($0) }
            }
        }

        mutating func remove(_ key: DraftKey) {
            switch key.kind {
            case .cue: cues[key.id] = nil
            case .grid: grids[key.id] = nil
            case .gain: gains[key.id] = nil
            case .tag: tags[key.id] = nil
            case .artwork: artwork[key.id] = nil
            case .merge: merges.removeAll { $0.id == key.id }
            }
            stamps[key] = nil
        }
    }
    private let state = Mutex(State())

    public init() {}

    /// 그림 초안의 해시 재료(초안과 그림 바이트)
    private struct ArtworkContent: Encodable {
        var draft: ArtworkDraft
        var image: Data?
    }

    static func hash(_ value: some Encodable) -> DraftContentHash? { try? DraftContentHash(of: value) }
    static func hash(_ edit: ArtworkEdit) -> DraftContentHash? { hash(ArtworkContent(draft: edit.draft, image: edit.image)) }

    public func cue(_ uuid: String) -> CueDraft? { state.withLock { $0.cues[uuid] } }
    public func grid(_ uuid: String) -> GridDraft? { state.withLock { $0.grids[uuid] } }
    public func gain(_ uuid: String) -> Double? { state.withLock { $0.gains[uuid] } }
    public func tag(_ uuid: String) -> TagDraft? { state.withLock { $0.tags[uuid] } }
    /// 초안의 도장(없으면 nil)
    public func stamp(_ key: DraftKey) -> DraftStamp? { state.withLock { $0.stamps[key] } }
    public var playlistStamps: [DraftStamp] { state.withLock { $0.playlistStamps } }

    public func save(_ draft: CueDraft, origin: DraftOrigin = .human) {
        state.withLock {
            $0.revision += 1
            $0.cues[draft.trackUUID] = draft.hasChanges ? draft : nil
            $0.restamp(DraftKey(.cue, draft.trackUUID), hash: draft.hasChanges ? Self.hash(draft) : nil, origin: origin)
        }
    }
    public func save(_ draft: GridDraft, origin: DraftOrigin = .human) {
        state.withLock {
            $0.revision += 1
            $0.grids[draft.trackUUID] = draft.hasChanges ? draft : nil
            $0.restamp(DraftKey(.grid, draft.trackUUID), hash: draft.hasChanges ? Self.hash(draft) : nil, origin: origin)
        }
    }
    public func save(gain: Double?, _ uuid: String, origin: DraftOrigin = .human) {
        state.withLock {
            $0.revision += 1
            $0.gains[uuid] = gain
            $0.restamp(DraftKey(.gain, uuid), hash: gain.flatMap { Self.hash($0) }, origin: origin)
        }
    }
    public func save(_ draft: TagDraft, origin: DraftOrigin = .human) {
        state.withLock {
            $0.tags[draft.trackUUID] = draft.hasChanges ? draft : nil
            $0.restamp(DraftKey(.tag, draft.trackUUID), hash: draft.hasChanges ? Self.hash(draft) : nil, origin: origin)
        }
    }
    public func removeGrid(_ uuid: String) { save(GridDraft(trackUUID: uuid, base: [], segments: [])) }

    /// 바깥(다른 프로세스)이 초안 파일만 고친 것처럼 한다: 내용만 바뀌고 도장은 그대로다(해시가 기록과 어긋난다)
    public func editOutside(_ draft: CueDraft) { state.withLock { $0.cues[draft.trackUUID] = draft } }
    public func editOutside(_ draft: GridDraft) { state.withLock { $0.grids[draft.trackUUID] = draft } }
    public func editOutside(_ draft: TagDraft) { state.withLock { $0.tags[draft.trackUUID] = draft } }

    private func saveArtwork(_ edit: ArtworkEdit, origin: DraftOrigin) {
        state.withLock {
            $0.artwork[edit.trackUUID] = edit
            $0.restamp(DraftKey(.artwork, edit.trackUUID), hash: Self.hash(edit), origin: origin)
        }
    }

    private func removeArtwork(_ uuid: String) {
        state.withLock {
            $0.artwork[uuid] = nil
            $0.stamps[DraftKey(.artwork, uuid)] = nil
        }
    }

    /// 합치기 초안 목록을 통째로 저장한다: 내용이 같은 초안은 도장을 그대로 두고, 바뀌거나 새로 든 초안만 새 판을 받는다
    private func saveMerges(_ drafts: [DuplicateMergeDraft], origin: DraftOrigin) {
        state.withLock { state in
            let ids = Set(drafts.map(\.id))
            for key in state.stamps.keys where key.kind == .merge && !ids.contains(key.id) { state.stamps[key] = nil }
            for draft in drafts {
                let key = DraftKey(.merge, draft.id), hash = Self.hash(draft)
                if let old = state.stamps[key], old.contentHash == hash { continue }
                state.restamp(key, hash: hash, origin: origin)
            }
            state.merges = drafts
        }
    }

    /// 그 판의 초안을 제안으로 바꾼다(`DraftStore.markSuggestions`의 규칙)
    public func markSuggestions(_ drafts: [WrittenDraft], playlistSteps: Set<DraftRevision>) -> Set<DraftRevision> {
        state.withLock { state in
            var marked = Set<DraftRevision>()
            for item in drafts where state.stamps[item.key]?.revision == item.revision {
                state.stamps[item.key]?.origins.insert(.unknown)
                marked.insert(item.revision)
            }
            for index in state.playlistStamps.indices where playlistSteps.contains(state.playlistStamps[index].revision) {
                state.playlistStamps[index].origins.insert(.unknown)
                marked.insert(state.playlistStamps[index].revision)
            }
            return marked
        }
    }

    /// 재생 목록 단계의 해시(단계와 그 단계가 기대는 base, 실제 저장소와 같은 함수)
    static func stepHash(_ step: PlaylistDraft.Step, in draft: PlaylistDraft) -> DraftContentHash {
        (try? DraftContentHash(step: step, in: draft)) ?? DraftContentHash(hex: "")
    }

    /// 재생 목록 초안을 통째로 저장한다: 앞 도장 가운데 내용이 같은 단계의 도장을 차례로 이어 쓰고, 나머지 단계만 새 판을 받는다
    private func savePlaylist(_ draft: PlaylistDraft, origin: DraftOrigin) {
        state.withLock { state in
            var previous = state.playlistStamps
            var stamps: [DraftStamp] = []
            for step in draft.steps {
                let hash = Self.stepHash(step, in: draft)
                if let index = previous.firstIndex(where: { $0.contentHash == hash }) {
                    stamps.append(previous.remove(at: index))
                } else {
                    stamps.append(state.newStamp(origins: [origin], hash: hash))
                }
            }
            state.playlist = draft
            state.playlistStamps = stamps
        }
    }

    /// 바깥(다른 프로세스)이 재생 목록 초안 파일만 고친 것처럼 한다: 단계 수가 같으면 도장은 그대로 두고 내용만 바꾼다
    public func editPlaylistOutside(_ draft: PlaylistDraft) {
        state.withLock { state in
            precondition(draft.steps.count == state.playlistStamps.count, "바깥 수정 흉내는 단계 수를 바꾸지 않는다")
            state.playlist = draft
        }
    }

    /// 남긴 재생 목록 단계 사본(사본 자리 → 사본). 실제 구현은 백업 폴더의 파일이다
    public var playlistCopies: [URL: PlaylistStepCopy] { state.withLock { $0.playlistCopies } }
    /// 재생 목록 단계 사본 남기기를 실패하게 한다(R22 실패 주입)
    public func failPlaylistCopies(_ fails: Bool = true) { state.withLock { $0.failsPlaylistCopies = fails } }

    /// 판 지정 삭제(`DraftStore.removeWritten`의 규칙)
    public func removeWritten(_ written: [WrittenDraft]) -> DraftRemoval {
        state.withLock { state in
            var result = DraftRemoval()
            for item in written {
                guard let stamp = state.stamps[item.key], stamp.revision == item.revision, let current = state.currentHash(item.key) else {
                    result.kept.append(item)
                    continue
                }
                if current == item.contentHash {
                    state.remove(item.key)
                    result.removed.append(item)
                } else {
                    // 바깥에서 고친 초안: 같은 잠금 안에서 제안으로 기록한다(내용이 저장 당시로 돌아와도 제안이다)
                    state.stamps[item.key]?.origins.insert(.unknown)
                    result.suggested.append(item)
                }
            }
            return result
        }
    }

    /// 쓴 재생 목록 단계 정리(`DraftStore.removeWrittenSteps`의 규칙). 연결 ID 옮기기는 하지 않는다(규칙은 W2-G2의 `PlaylistDraft`가 정한다)
    public func removeWrittenSteps(_ cleanup: PlaylistStepCleanup) -> PlaylistStepRemoval {
        state.withLock { state in
            var result = PlaylistStepRemoval()
            var offsets: [Int] = []
            for written in cleanup.written {
                guard let offset = state.playlistStamps.firstIndex(where: { $0.revision == written.revision }) else {
                    result.notFound.insert(written.revision)
                    continue
                }
                let step = state.playlist.steps[offset]
                let current = Self.stepHash(step, in: state.playlist)
                if current != written.contentHash {
                    // 바깥에서 고친 단계: 사본을 남긴 뒤에만 뺀다
                    guard !state.failsPlaylistCopies else {
                        result.copyFailed.insert(written.revision)
                        continue
                    }
                    let playlistID: String? = switch step.edit.playlist {
                    case let .id(id): id
                    case .new: cleanup.newPlaylistIDs[step.edit.playlist.description]
                    case .root: nil
                    }
                    let depends = Set(step.depends)
                    let url = PlaylistStepCopy.url(folder: cleanup.copyFolder, revision: written.revision)
                    state.playlistCopies[url] = PlaylistStepCopy(revision: written.revision, playlistID: playlistID, step: step,
                                                                 base: state.playlist.base.filter { depends.contains($0.key) },
                                                                 writtenHash: written.contentHash, currentHash: current)
                    result.copied[written.revision] = url
                }
                offsets.append(offset)
                result.removed.insert(written.revision)
            }
            let removing = Set(offsets)
            state.playlist.removeSteps(at: offsets.sorted())
            state.playlistStamps = state.playlistStamps.enumerated().filter { !removing.contains($0.offset) }.map(\.element)
            return result
        }
    }

    /// 이 메모리 초안을 사람 편집으로 읽고 쓰는 포트(앱의 편집 포트와 같다)
    public var store: DraftStore { store(origin: .human) }

    /// 이 메모리 초안을 그 출처로 읽고 쓰는 포트
    public func store(origin: DraftOrigin) -> DraftStore {
        var store = DraftStore(
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
            saveCue: { draft, completion in self.save(draft, origin: origin); completion(nil) },
            gridDraftUUIDs: { Set(self.state.withLock { $0.grids.keys }) },
            gridDraft: { self.grid($0) },
            pendingGrid: { _ in nil },
            saveGrid: { draft, completion in self.save(draft, origin: origin); completion(nil) },
            gainDraftUUIDs: { Set(self.state.withLock { $0.gains.keys }) },
            gainDrafts: { self.state.withLock { $0.gains } },
            pendingGain: { _ in nil },
            saveGain: { gain, uuid, completion in self.save(gain: gain, uuid, origin: origin); completion(nil) },
            tagDraftUUIDs: { Set(self.state.withLock { $0.tags.keys }) },
            tagDraft: { self.tag($0) },
            saveTags: { drafts in for draft in drafts { self.save(draft, origin: origin) } },
            artworkDraftUUIDs: { Set(self.state.withLock { $0.artwork.keys }) },
            artworkDrafts: { self.state.withLock { $0.artwork.mapValues(\.draft) } },
            artworkEdit: { uuid in self.state.withLock { $0.artwork[uuid] } },
            saveArtwork: { edit in self.saveArtwork(edit, origin: origin) },
            removeArtwork: { uuid in self.removeArtwork(uuid) },
            playlistDraft: { self.state.withLock { $0.playlist } },
            readPlaylistDraft: { self.state.withLock { $0.playlist } },
            savePlaylistDraft: { draft in self.savePlaylist(draft, origin: origin) },
            mergeDrafts: { self.state.withLock { $0.merges } },
            saveMergeDrafts: { drafts in self.saveMerges(drafts, origin: origin) },
            newCueID: { MemoryCueIDs.next() })
        store.origin = origin
        store.originVariant = { self.store(origin: $0) }
        store.stamp = { self.stamp($0) }
        store.playlistStamps = { self.playlistStamps }
        store.removeWritten = { self.removeWritten($0) }
        store.removeWrittenSteps = { self.removeWrittenSteps($0) }
        store.markSuggestions = { self.markSuggestions($0, playlistSteps: $1) }
        return store
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
