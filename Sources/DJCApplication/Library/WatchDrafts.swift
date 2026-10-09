import DJCDomain
import Foundation

/// 초안 지켜보기·정리(유스케이스, 옛 `DraftIndex`): 어떤 곡에 큐·그리드·게인·태그·앨범아트 초안이 있는지 초안 파일에서 읽는다.
/// 라이브러리를 읽을 때(`load`)와, 바깥(CLI·다른 창)에서 바꾼 초안 파일을 1초마다 확인할 때(`refresh`) 쓴다.
/// 라이브러리 화면의 초안 폴더 정리(태그 초안 저장·다시 저장, 옮긴 손상 파일 뒤 메모리 입력 다시 저장, 연결되지 않은 초안 버리기)도 여기서 한다.
/// 화면 모델은 초안 저장 큐를 직접 부르지 않고 결과 값을 메인에서 적용한다. 파일 읽기는 메인 스레드 밖이다(`refresh`).
public struct WatchDrafts: Sendable {
    let drafts: DraftStore

    public init(drafts: DraftStore) {
        self.drafts = drafts
    }

    /// 라이브러리를 읽을 때의 초안
    public struct Loaded: Sendable {
        public var tagDrafts: [String: TagDraft] = [:]
        /// 큐 초안 파일이 있는 곡(읽지 못한 파일도 포함)
        public var cueDraftUUIDs: Set<String> = []
        /// 읽은 큐 초안(옛 초안에는 곡의 자동 큐를 채웠다, #145)
        public var cueDrafts: [String: CueDraft] = [:]
        public var gridDraftUUIDs: Set<String> = []
        public var gainDraftUUIDs: Set<String> = []
        public var artworkDrafts: [String: ArtworkDraft] = [:]
        public var playlistDraft = PlaylistDraft()
    }

    /// 라이브러리 읽기 안에서 부른다(이미 메인 밖). `autoCues`: 곡 UUID → rekordbox 큐(자동 큐를 채울 때)
    public func load(autoCues: [String: [Cue]]) -> Loaded {
        var loaded = Loaded()
        for uuid in drafts.tagDraftUUIDs() { loaded.tagDrafts[uuid] = drafts.tagDraft(uuid) }
        loaded.cueDraftUUIDs = drafts.cueDraftUUIDs()
        for uuid in loaded.cueDraftUUIDs {
            loaded.cueDrafts[uuid] = drafts.cueDraft(uuid)?.includingAutoCues(from: autoCues[uuid] ?? [], newID: drafts.newCueID)
        }
        loaded.gridDraftUUIDs = drafts.gridDraftUUIDs()
        loaded.gainDraftUUIDs = drafts.gainDraftUUIDs()
        loaded.artworkDrafts = drafts.artworkDrafts()
        loaded.playlistDraft = drafts.playlistDraft()
        return loaded
    }

    /// 바깥 변경 확인 결과
    public struct Refresh: Sendable {
        /// 읽기 전에 맡은 저장 입력 순번. 적용할 때 달라졌으면 그 사이 앱이 새로 저장한 것이라 버린다
        public var saveRevision: UInt64
        public var failedTagSaves: Set<String>
        public var stamps: [String: Date]
        public var unsaved: UnsavedDrafts
        /// 파일이 바뀌었거나 저장 대기 입력이 있어 다시 읽은 내용. nil이면 화면은 그대로다
        public var contents: Contents?
    }

    public struct Contents: Sendable {
        public var moved: [DamagedDraftFile]
        /// 디스크 초안에 저장 대기 입력을 얹은 큐 초안(자동 큐를 채우기 전, 고친 것이 없는 것도 있다)
        public var cueDrafts: [String: CueDraft]
        /// 고친 것이 있는 태그 초안
        public var tagDrafts: [String: TagDraft]
        public var gridDraftUUIDs: Set<String>
        public var artworkDrafts: [String: ArtworkDraft]
    }

    /// 바깥에서 바꾼 초안 파일을 확인한다. 파일 수정 시각이 `stamps`와 같고 저장 대기 입력이 없으면 내용을 읽지 않는다.
    /// - Parameter preservingDamaged: 읽지 못하는 파일을 옮겨 보관할지(앱 데이터 폴더를 정한 저장소만)
    @concurrent
    public func refresh(since stamps: [String: Date]?, preservingDamaged: Bool) async -> Refresh {
        let revision = drafts.saveRevision()
        drafts.flush()
        let unsaved = drafts.unsaved()
        var result = Refresh(saveRevision: revision, failedTagSaves: drafts.failedTagSaves(),
                             stamps: drafts.fileStamps(), unsaved: unsaved)
        guard result.stamps != stamps || !unsaved.isEmpty else { return result }
        let moved = preservingDamaged ? drafts.preserveDamaged() : []
        var cues: [String: CueDraft] = [:]
        for uuid in drafts.cueDraftUUIDs().union(unsaved.cues.keys) {
            if let draft = unsaved.cues[uuid] ?? drafts.cueDraft(uuid) { cues[uuid] = draft }
        }
        var tags: [String: TagDraft] = [:]
        for uuid in drafts.tagDraftUUIDs() {
            if let draft = drafts.tagDraft(uuid), draft.hasChanges { tags[uuid] = draft }
        }
        result.contents = Contents(moved: moved, cueDrafts: cues, tagDrafts: tags,
                                   gridDraftUUIDs: drafts.gridDraftUUIDs(), artworkDrafts: drafts.artworkDrafts())
        return result
    }

    // MARK: - 저장 큐

    /// 걸린 초안 저장을 끝낸다
    public func flush() { drafts.flush() }

    /// 맡은 저장 입력의 순번(바깥 변경 확인이 읽는 사이 앱이 새로 저장했는지 견준다)
    public func saveRevision() -> UInt64 { drafts.saveRevision() }

    /// 저장을 맡았지만 아직 디스크에 없는 큐·그리드·게인 입력(디스크보다 최신이라 표시는 이것을 따른다)
    public func unsaved() -> UnsavedDrafts { drafts.unsaved() }

    /// 저장 대기·실패 입력이 있는 곡(쓰기 대상 판정이 포함한다)
    public func unsavedUUIDs() -> Set<String> { drafts.unsavedUUIDs() }

    /// 이 화면이 저장을 맡긴 태그 초안 가운데(`attempted`) 저장에 실패한 곡
    public func failedTagSaves(attempted: Set<String>) -> Set<String> { drafts.failedTagSaves().intersection(attempted) }

    /// 태그 초안을 저장한다(고친 것이 없는 초안은 파일째 지운다). 실패는 `failedTagSaves`로 본다
    @MainActor
    public func saveTags(_ tags: [TagDraft]) { drafts.saveTags(tags) }

    /// 저장을 끝낸 뒤 이 화면이 맡긴 태그 저장 가운데 실패한 곡을 메모리 입력으로 다시 저장한다. 메모리에 없는 곡은 실패한 지우기를 다시 한다
    /// (디스크에 남은 옛 초안으로 입력을 되살리지 않는다).
    /// - Returns: 다시 저장한 초안
    @MainActor
    public func retryFailedTags(attempted: Set<String>, memory: [String: TagDraft]) -> [TagDraft] {
        drafts.flush()
        let failed = failedTagSaves(attempted: attempted)
        guard !failed.isEmpty else { return [] }
        let tags = failed.map { memory[$0] ?? TagDraft(trackUUID: $0, base: TagFields()) }
        drafts.saveTags(tags)
        drafts.flush()
        return tags
    }

    /// 저장이 손상된 옛 파일을 옮겨 둔 기록을 가져온다(가져가면 비운다)
    public func takeMovedFiles() -> [DamagedDraftFile] { drafts.takeMovedFiles() }

    /// 읽지 못하는 초안 파일을 `damaged-drafts`에 옮긴다(#174). 옮긴 파일을 돌려준다
    public func preserveDamaged() -> [DamagedDraftFile] { drafts.preserveDamaged() }

    /// 게인 초안이 있는 곡: 디스크에 저장 대기 입력을 얹는다(지우기 입력은 뺀다)
    public func gainDraftUUIDs() -> Set<String> {
        var uuids = drafts.gainDraftUUIDs()
        for (uuid, pending) in drafts.unsaved().gains {
            if pending == nil { uuids.remove(uuid) } else { uuids.insert(uuid) }
        }
        return uuids
    }

    /// 목록에 보일 큐 초안(새 큐 ID는 이 저장소에서 받는다, `visibleCueDrafts(_:newID:autoCues:)`)
    public func visibleCueDrafts(_ cues: [String: CueDraft], autoCues: (String) -> [Cue]) -> [String: CueDraft] {
        Self.visibleCueDrafts(cues, newID: drafts.newCueID, autoCues: autoCues)
    }

    /// 고른 곡 가운데 쓰기·XML에서 빠지는 초안의 줄(규칙은 `DraftExclusions`, 반영 세션과 같다). `state`는 화면의 메모리 초안
    /// - Parameter blockedOnly: 쓰기 확인 목록용. 초안을 읽지 못해 막힌 줄만 남긴다(#211)
    public func exclusionReasons(for rows: [TrackRow], state: ReflectionLibraryState, xml: Bool, blockedOnly: Bool) -> [String] {
        DraftExclusions.reasons(for: rows, state: state, drafts: drafts, xml: xml, blockedOnly: blockedOnly)
    }

    // MARK: - 옮긴 손상 파일 뒤(#174)

    /// 옮긴 파일마다 화면이 맞출 것(옮긴 차례)
    public enum MovedStep: Sendable, Equatable {
        /// 태그 파일을 옮겼지만 메모리 초안이 있어 다시 저장했다(화면 메모리에 남긴다)
        case keepTag(TagDraft)
        /// 큐·그리드 초안 파일을 옮겼고 저장 대기 입력도 없다: 표시를 거둔다
        case clearCue(String), clearGrid(String)
        /// 그림 초안은 사본과 함께 옮겼다(메모리에 그림 바이트가 없어 다시 저장하지 못한다): 그림을 다시 고르게 한다
        case clearArtwork(String)
    }

    /// 다시 저장한 재생 목록 초안과 저장하지 못한 이유
    public struct PlaylistResave: Sendable {
        public var draft: PlaylistDraft
        public var error: (any Error)?
    }

    public struct MovedRecovery: Sendable {
        public var steps: [MovedStep] = []
        /// 게인 초안 파일을 옮겼으면 다시 센 게인 초안 곡(저장 대기 입력을 얹었다)
        public var gainDraftUUIDs: Set<String>?
        /// 재생 목록 초안 파일을 옮겼고 메모리 초안이 있으면 다시 저장한 결과
        public var playlist: PlaylistResave?

        /// 다시 저장한 태그 초안
        public var resavedTags: [TagDraft] { steps.compactMap { if case let .keepTag(draft) = $0 { draft } else { nil } } }
    }

    /// 손상돼 옮긴 초안 파일 뒤: 메모리에 남은 입력(태그·재생 목록)은 다시 저장해 잃지 않고, 옮긴 큐·그리드·그림 초안의 표시를 거둘 곡을 정한다.
    /// 게인 초안 파일을 옮겼으면 게인 초안 곡을 다시 센다.
    /// - Parameters:
    ///   - memoryTags: 화면의 태그 초안(고친 것이 있는 것만 다시 저장한다)
    ///   - memoryPlaylist: 화면의 재생 목록 초안(비어 있으면 저장하지 않는다)
    @MainActor
    public func recoverMoved(_ moved: [DamagedDraftFile], memoryTags: [String: TagDraft], memoryPlaylist: PlaylistDraft) -> MovedRecovery {
        var recovery = MovedRecovery()
        guard !moved.isEmpty else { return recovery }
        // 옮긴 파일은 이 저장소의 초안 폴더 것이다. 저장 대기 입력도 같은 폴더에서 본다.
        let unsaved = drafts.unsaved()
        for entry in moved {
            guard let uuid = entry.trackUUID else { continue }
            switch entry.kind {
            case .tag:
                if let draft = memoryTags[uuid], draft.hasChanges { recovery.steps.append(.keepTag(draft)) }
            case .cue where unsaved.cues[uuid]?.hasChanges != true: recovery.steps.append(.clearCue(uuid))
            case .grid where unsaved.grids[uuid]?.hasChanges != true: recovery.steps.append(.clearGrid(uuid))
            case .artwork: recovery.steps.append(.clearArtwork(uuid))
            default: break
            }
        }
        let resave = recovery.resavedTags
        if !resave.isEmpty {
            drafts.saveTags(resave)
            drafts.flush()
        }
        if moved.contains(where: { $0.kind == .gain }) { recovery.gainDraftUUIDs = gainDraftUUIDs() }
        if moved.contains(where: { $0.kind == .playlist }), !memoryPlaylist.isEmpty {
            do {
                try drafts.savePlaylistDraft(memoryPlaylist)
                recovery.playlist = PlaylistResave(draft: memoryPlaylist)
            } catch {
                recovery.playlist = PlaylistResave(draft: memoryPlaylist, error: error)
            }
        }
        return recovery
    }

    // MARK: - 적용 규칙(순수)

    /// 목록에 보일 큐 초안: 옛 초안에는 곡의 자동 큐를 채우고(#145, 채우는 큐의 ID는 `newID`) 고친 것이 있는 것만 남긴다.
    public static func visibleCueDrafts(_ drafts: [String: CueDraft], newID: () -> UUID, autoCues: (String) -> [Cue]) -> [String: CueDraft] {
        var visible: [String: CueDraft] = [:]
        for (uuid, draft) in drafts {
            let filled = draft.includingAutoCues(from: autoCues(uuid), newID: newID)
            if filled.hasChanges { visible[uuid] = filled }
        }
        return visible
    }

    /// 바깥 변경 뒤 태그 초안. 저장에 실패한 곡은 메모리 입력이 디스크보다 최신이라 그대로 둔다.
    /// - Returns: 메모리와 칸이 달라졌으면 새 초안 전체, 같으면 nil(되돌리기 이력을 그대로 둔다)
    public static func externalTags(disk: [String: TagDraft], memory: [String: TagDraft],
                                    failed: Set<String>) -> [String: TagDraft]? {
        var tags = disk
        for uuid in failed { tags[uuid] = memory[uuid] }
        let same = memory.mapValues(\.fields) == tags.mapValues(\.fields) && memory.mapValues(\.base) == tags.mapValues(\.base)
        return same ? nil : tags
    }

    /// 라이브러리를 다시 읽은 뒤의 태그 초안
    public struct TagReload: Sendable, Equatable {
        public var tags: [String: TagDraft]
        /// 새 rekordbox 값에 맞춰 base를 옮긴 초안(다시 저장한다)
        public var rebased: [TagDraft]
        /// 같은 칸이 rekordbox에서도 바뀌어 옮기지 못한 곡 수
        public var conflicts: Int
    }

    /// 다시 읽은 태그 초안을 고른다. 읽는 동안 편집했으면(`editedDuringRead`) 디스크의 옛 값 대신 메모리를,
    /// 저장에 실패한 곡은 메모리 입력을 쓴다. 동기화(`synchronizing`)면 충돌하지 않는 초안의 base를 새 rekordbox 값으로 옮긴다.
    /// - Parameter currentFields: 곡 UUID → 지금 rekordbox 값(라이브러리에 없는 곡은 nil: 추가한 곡·연결이 끊긴 초안, #175)
    public static func reloadedTags(loaded: [String: TagDraft], memory: [String: TagDraft], editedDuringRead: Bool,
                                    failed: Set<String>, synchronizing: Bool,
                                    currentFields: (String) -> TagFields?) -> TagReload {
        var tags = editedDuringRead ? memory : loaded
        for uuid in failed { tags[uuid] = memory[uuid] }
        var reload = TagReload(tags: tags, rebased: [], conflicts: 0)
        guard synchronizing else { return reload }
        for (uuid, draft) in tags.sorted(by: { $0.key < $1.key }) where !failed.contains(uuid) {
            guard let fields = currentFields(uuid) else { continue }
            guard let updated = draft.rebased(onto: fields) else {
                reload.conflicts += 1
                continue
            }
            if updated != draft {
                reload.tags[uuid] = updated.hasChanges ? updated : nil
                reload.rebased.append(updated)
            }
        }
        return reload
    }

    // MARK: - 연결되지 않은 초안(#175)

    /// 초안 파일(저장하지 못한 입력 포함)이 있는 곡과 그 종류
    public func draftKinds() -> [String: [UnlinkedDraft.Kind]] {
        let sources: [(UnlinkedDraft.Kind, Set<String>)] = [
            (.cue, drafts.cueDraftUUIDs()),
            (.grid, drafts.gridDraftUUIDs()),
            (.gain, drafts.gainDraftUUIDs()),
            (.tag, drafts.tagDraftUUIDs()),
            (.artwork, drafts.artworkDraftUUIDs()),
        ]
        var kinds: [String: [UnlinkedDraft.Kind]] = [:]
        for (kind, uuids) in sources { for uuid in uuids { kinds[uuid, default: []].append(kind) } }
        return kinds
    }

    /// 스냅샷의 곡·추가한 곡 어디에도 이어지지 않는 초안이 있는 곡(파일 이름만 본다)
    public func unlinked(linked: Set<String>) -> Set<String> {
        Set(draftKinds().keys).subtracting(linked)
    }

    /// 연결되지 않은 초안을 버린 결과
    public struct UnlinkedDiscard: Sendable {
        /// 빈 초안으로 저장한(지운) 태그 초안 곡
        public var clearedTags: [String] = []
        /// 사본과 함께 지운 그림 초안 곡
        public var removedArtwork: [String] = []
        /// 저장이 손상된 옛 파일을 옮겼으면 그 파일
        public var moved: [DamagedDraftFile] = []
        /// 버리지 못한 곡(저장 실패·그림 지우기 실패)
        public var failed: Set<String> = []
    }

    /// 고른 곡의 초안(큐·그리드·게인·태그·그림)을 버린다. 저장 실패 기록까지 함께 비우려고 저장 큐로 지운다(손상된 파일은 지우지 않고 옮겨 둔다).
    /// - Parameter attemptedTags: 이 화면이 앞서 저장을 맡긴 태그 초안 곡(버리지 못한 곡을 셀 때 이 화면 것만 본다)
    @MainActor
    public func discardUnlinked(_ targets: Set<String>, attemptedTags: Set<String>) -> UnlinkedDiscard {
        var result = UnlinkedDiscard()
        let kinds = draftKinds()
        var failedArtwork: Set<String> = []
        for uuid in targets.sorted() {
            let present = kinds[uuid] ?? []
            if present.contains(.cue) { drafts.removeCue(uuid) }
            if present.contains(.grid) { drafts.removeGrid(uuid) }
            if present.contains(.gain) { drafts.removeGain(uuid) }
            if present.contains(.tag) { result.clearedTags.append(uuid) }
            if present.contains(.artwork) {
                do {
                    try drafts.removeArtwork(uuid)
                    result.removedArtwork.append(uuid)
                } catch { failedArtwork.insert(uuid) }
            }
        }
        if !result.clearedTags.isEmpty { drafts.saveTags(result.clearedTags.map { TagDraft(trackUUID: $0, base: TagFields()) }) }
        drafts.flush()
        result.moved = drafts.takeMovedFiles()
        result.failed = Set(drafts.failures().map(\.trackUUID))
            .union(failedTagSaves(attempted: attemptedTags.union(result.clearedTags))).union(failedArtwork).intersection(targets)
        return result
    }

    /// 연결되지 않은 초안의 자세한 목록(최근에 고친 것부터): 종류, 태그 초안에 남은 제목, 초안 파일을 마지막으로 고친 때
    public func unlinkedDetails(_ uuids: Set<String>) -> [UnlinkedDraft] {
        let kinds = draftKinds()
        var modified: [String: Date] = [:]
        for (path, date) in drafts.fileStamps() {
            let name = (path as NSString).lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            let uuid = String(name.dropLast(".json".count))
            guard uuids.contains(uuid) else { continue }
            modified[uuid] = max(modified[uuid] ?? date, date)
        }
        return uuids.map { uuid in
            let tag = drafts.tagDraft(uuid)
            let title = [tag?.fields.title, tag?.base.title].compactMap { $0 }.first { !$0.isEmpty }
            return UnlinkedDraft(uuid: uuid, kinds: kinds[uuid] ?? [], title: title, modified: modified[uuid])
        }
        .sorted { ($0.modified ?? .distantPast, $1.uuid) > ($1.modified ?? .distantPast, $0.uuid) }
    }
}

/// 스냅샷의 곡·추가한 곡 어디에도 이어지지 않는 초안(#175). 어디서 왔는지 모르므로 자동으로 지우지 않고,
/// 쓰기 대기 목록에서 보여 주고 사용자가 고른 것만 버린다.
public struct UnlinkedDraft: Identifiable, Hashable, Sendable {
    public enum Kind: CaseIterable, Hashable, Sendable {
        case cue, grid, gain, tag, artwork
        public var label: String {
            switch self {
            case .cue: String(ui: "큐")
            case .grid: String(ui: "그리드")
            case .gain: String(ui: "게인")
            case .tag: String(ui: "태그")
            case .artwork: String(ui: "앨범아트")
            }
        }
    }
    public var id: String { uuid }
    public var uuid: String
    public var kinds: [Kind]
    /// 태그 초안에 남은 제목(없으면 nil)
    public var title: String?
    public var modified: Date?

    public init(uuid: String, kinds: [Kind], title: String?, modified: Date?) {
        self.uuid = uuid
        self.kinds = kinds
        self.title = title
        self.modified = modified
    }
}
