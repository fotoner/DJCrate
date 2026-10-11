import DJCDomain
import Foundation

/// 초안 폴더 하나의 초안 저장소(포트): 큐·그리드·게인·태그·앨범아트·재생 목록·합치기 초안의 읽기·쓰기·지우기(추가 목록은 `StagingStore`),
/// 저장 큐(기다리기·저장 순번·저장 실패·저장 대기 입력·다시 저장), 손상 파일 옮기기.
/// 실제 구현(`DraftStore.live(writer:home:)`)은 DJCAdapters가 주고 조립 지점이 고른다. 메모리 구현은 `MemoryDrafts`.
///
/// 큐·그리드·게인·태그 저장은 직렬 큐에 맡기고 바로 돌아온다(메인 스레드 밖에서 차례로 쓴다). 읽기는 메인 밖에서 불린다.
/// 화면이 들고 있는 메모리 초안(재생 목록·합치기)은 메인 액터에서 바로 저장한다.
public struct DraftStore: Sendable {
    // MARK: 저장 큐

    /// 걸려 있는 저장을 모두 끝낸다(디스크의 초안을 읽기 전에)
    public var flush: @Sendable () -> Void
    /// 이 폴더에 맡은 마지막 저장 입력 순번. 읽는 사이 새 입력이 들어왔는지 본다(파일을 읽지 않는다, 다른 폴더의 저장은 세지 않는다)
    public var saveRevision: @Sendable () -> UInt64
    /// 이 폴더의 큐·그리드·게인 저장 실패(파일을 읽지 않는다)
    public var failures: @Sendable () -> [DraftSaveFailure]
    /// 아직 저장하지 못했거나 저장 중인 곡(큐·그리드·게인, 파일을 읽지 않는다)
    public var unsavedUUIDs: @Sendable () -> Set<String>
    /// 아직 저장하지 못했거나 저장 중인 입력(디스크보다 최신, 파일을 읽지 않는다)
    public var unsaved: @Sendable () -> UnsavedDrafts
    /// 저장에 실패한 태그 초안 곡(파일을 읽지 않는다)
    public var failedTagSaves: @Sendable () -> Set<String>
    /// 그 종류의 마지막 입력(저장이든 지우기든)을 다시 저장한다. 다시 저장할 기록이 없으면 false
    public var retry: @Sendable (DraftSaveKind, String, @escaping @Sendable (DraftSaveFailure?) -> Void) -> Bool
    /// 그 실패가 뒤의 저장으로 해소됐는지
    public var isResolved: @Sendable (DraftSaveFailure) -> Bool

    // MARK: 파일

    /// 큐·태그·그리드·앨범아트 초안 파일의 수정 시각(경로별). 바뀌지 않았으면 다시 읽지 않는다
    public var fileStamps: @Sendable () -> [String: Date]
    /// 읽지 못하는 초안 파일을 옮겨 보관하고 옮긴 목록을 받는다(#174). 저장과 같은 큐에서 차례를 기다린다
    public var preserveDamaged: @Sendable () -> [DamagedDraftFile]
    /// 저장하다 옮긴 손상 파일 목록을 꺼낸다(꺼낸 것은 다시 나오지 않는다)
    public var takeMovedFiles: @Sendable () -> [DamagedDraftFile]

    // MARK: 큐·그리드·게인(저장 큐)

    public var cueDraftUUIDs: @Sendable () -> Set<String>
    /// 디스크의 큐 초안(저장 대기 입력은 `pendingCue`)
    public var cueDraft: @Sendable (String) -> CueDraft?
    /// 아직 저장하지 못한 큐 입력
    public var pendingCue: @Sendable (String) -> CueDraft?
    /// 큐 초안 저장(고친 것이 없으면 지우기). 끝나면(실패면 그 실패와) `completion`을 부른다
    public var saveCue: @Sendable (CueDraft, @escaping @Sendable (DraftSaveFailure?) -> Void) -> Void
    public var gridDraftUUIDs: @Sendable () -> Set<String>
    public var gridDraft: @Sendable (String) -> GridDraft?
    public var pendingGrid: @Sendable (String) -> GridDraft?
    public var saveGrid: @Sendable (GridDraft, @escaping @Sendable (DraftSaveFailure?) -> Void) -> Void
    public var gainDraftUUIDs: @Sendable () -> Set<String>
    /// 디스크의 게인 초안 전부. 파일을 읽지 못하면 던진다(쓰기 전 확인)
    public var gainDrafts: @Sendable () throws -> [String: Double]
    /// 저장하지 못한 게인 입력(바깥 nil은 기록 없음, 안쪽 nil은 초안 지우기)
    public var pendingGain: @Sendable (String) -> Double??
    /// 게인 초안(nil이면 지우기)
    public var saveGain: @Sendable (Double?, String, @escaping @Sendable (DraftSaveFailure?) -> Void) -> Void

    // MARK: 태그·앨범아트

    public var tagDraftUUIDs: @Sendable () -> Set<String>
    public var tagDraft: @Sendable (String) -> TagDraft?
    /// 태그 초안 저장(고친 것이 없으면 지우기, 메인 액터에서). 실패한 곡은 `failedTagSaves`에 남는다
    public var saveTags: @MainActor ([TagDraft]) -> Void
    public var artworkDraftUUIDs: @Sendable () -> Set<String>
    /// 읽을 수 있는 앨범아트 초안(그림 바이트 없이, 목록 표시용)
    public var artworkDrafts: @Sendable () -> [String: ArtworkDraft]
    /// 앨범아트 초안과 그림. 없으면 nil, 읽지 못하면 던진다
    public var artworkEdit: @Sendable (String) throws -> ArtworkEdit?
    public var saveArtwork: @Sendable (ArtworkEdit) throws -> Void
    public var removeArtwork: @Sendable (String) throws -> Void

    // MARK: 재생 목록·합치기(화면이 들고 있는 메모리 초안). 추가 목록은 `StagingStore`

    public var playlistDraft: @Sendable () -> PlaylistDraft
    public var savePlaylistDraft: @MainActor (PlaylistDraft) throws -> Void
    public var mergeDrafts: @Sendable () -> [DuplicateMergeDraft]
    public var saveMergeDrafts: @MainActor ([DuplicateMergeDraft]) throws -> Void

    // MARK: 새 큐 ID

    /// 초안에 새로 들이는 큐의 ID(rekordbox 큐로 시작하는 초안·채우는 자동 큐·새로 찍은 큐). 핵심부는 ID를 스스로 만들지 않고
    /// 초안 저장소에서 받는다(실제 구현은 무작위 UUID, 메모리 구현은 프로세스 안에서 겹치지 않는 차례 번호)
    public var newCueID: @Sendable () -> UUID

    public init(flush: @escaping @Sendable () -> Void,
                saveRevision: @escaping @Sendable () -> UInt64,
                failures: @escaping @Sendable () -> [DraftSaveFailure],
                unsavedUUIDs: @escaping @Sendable () -> Set<String>,
                unsaved: @escaping @Sendable () -> UnsavedDrafts,
                failedTagSaves: @escaping @Sendable () -> Set<String>,
                retry: @escaping @Sendable (DraftSaveKind, String, @escaping @Sendable (DraftSaveFailure?) -> Void) -> Bool,
                isResolved: @escaping @Sendable (DraftSaveFailure) -> Bool,
                fileStamps: @escaping @Sendable () -> [String: Date],
                preserveDamaged: @escaping @Sendable () -> [DamagedDraftFile],
                takeMovedFiles: @escaping @Sendable () -> [DamagedDraftFile],
                cueDraftUUIDs: @escaping @Sendable () -> Set<String>,
                cueDraft: @escaping @Sendable (String) -> CueDraft?,
                pendingCue: @escaping @Sendable (String) -> CueDraft?,
                saveCue: @escaping @Sendable (CueDraft, @escaping @Sendable (DraftSaveFailure?) -> Void) -> Void,
                gridDraftUUIDs: @escaping @Sendable () -> Set<String>,
                gridDraft: @escaping @Sendable (String) -> GridDraft?,
                pendingGrid: @escaping @Sendable (String) -> GridDraft?,
                saveGrid: @escaping @Sendable (GridDraft, @escaping @Sendable (DraftSaveFailure?) -> Void) -> Void,
                gainDraftUUIDs: @escaping @Sendable () -> Set<String>,
                gainDrafts: @escaping @Sendable () throws -> [String: Double],
                pendingGain: @escaping @Sendable (String) -> Double??,
                saveGain: @escaping @Sendable (Double?, String, @escaping @Sendable (DraftSaveFailure?) -> Void) -> Void,
                tagDraftUUIDs: @escaping @Sendable () -> Set<String>,
                tagDraft: @escaping @Sendable (String) -> TagDraft?,
                saveTags: @escaping @MainActor ([TagDraft]) -> Void,
                artworkDraftUUIDs: @escaping @Sendable () -> Set<String>,
                artworkDrafts: @escaping @Sendable () -> [String: ArtworkDraft],
                artworkEdit: @escaping @Sendable (String) throws -> ArtworkEdit?,
                saveArtwork: @escaping @Sendable (ArtworkEdit) throws -> Void,
                removeArtwork: @escaping @Sendable (String) throws -> Void,
                playlistDraft: @escaping @Sendable () -> PlaylistDraft,
                savePlaylistDraft: @escaping @MainActor (PlaylistDraft) throws -> Void,
                mergeDrafts: @escaping @Sendable () -> [DuplicateMergeDraft],
                saveMergeDrafts: @escaping @MainActor ([DuplicateMergeDraft]) throws -> Void,
                newCueID: @escaping @Sendable () -> UUID) {
        self.flush = flush
        self.saveRevision = saveRevision
        self.failures = failures
        self.unsavedUUIDs = unsavedUUIDs
        self.unsaved = unsaved
        self.failedTagSaves = failedTagSaves
        self.retry = retry
        self.isResolved = isResolved
        self.fileStamps = fileStamps
        self.preserveDamaged = preserveDamaged
        self.takeMovedFiles = takeMovedFiles
        self.cueDraftUUIDs = cueDraftUUIDs
        self.cueDraft = cueDraft
        self.pendingCue = pendingCue
        self.saveCue = saveCue
        self.gridDraftUUIDs = gridDraftUUIDs
        self.gridDraft = gridDraft
        self.pendingGrid = pendingGrid
        self.saveGrid = saveGrid
        self.gainDraftUUIDs = gainDraftUUIDs
        self.gainDrafts = gainDrafts
        self.pendingGain = pendingGain
        self.saveGain = saveGain
        self.tagDraftUUIDs = tagDraftUUIDs
        self.tagDraft = tagDraft
        self.saveTags = saveTags
        self.artworkDraftUUIDs = artworkDraftUUIDs
        self.artworkDrafts = artworkDrafts
        self.artworkEdit = artworkEdit
        self.saveArtwork = saveArtwork
        self.removeArtwork = removeArtwork
        self.playlistDraft = playlistDraft
        self.savePlaylistDraft = savePlaylistDraft
        self.mergeDrafts = mergeDrafts
        self.saveMergeDrafts = saveMergeDrafts
        self.newCueID = newCueID
    }
}

extension DraftStore {
    /// 지금의 큐 초안: 저장하지 못한 입력이 디스크보다 최신이다(지우기였으면 nil)
    public func currentCue(_ uuid: String) -> CueDraft? {
        if let pending = pendingCue(uuid) { return pending.hasChanges ? pending : nil }
        return cueDraft(uuid)
    }

    /// 지금의 그리드 초안: 저장하지 못한 입력이 디스크보다 최신이다(지우기였으면 nil)
    public func currentGrid(_ uuid: String) -> GridDraft? {
        if let pending = pendingGrid(uuid) { return pending.hasChanges ? pending : nil }
        return gridDraft(uuid)
    }

    /// 지금의 게인 초안: 저장하지 못한 입력이 디스크보다 최신이다(지우기였으면 nil). 파일을 읽지 못하면 없음
    public func currentGain(_ uuid: String) -> Double? {
        if let pending = pendingGain(uuid) { return pending }
        return (try? gainDrafts())?[uuid]
    }

    /// 큐 초안을 지운다(앞서 걸린 저장 뒤에). 저장 실패 기록도 함께 비운다
    public func removeCue(_ uuid: String) { saveCue(CueDraft(trackUUID: uuid), { _ in }) }
    public func removeGrid(_ uuid: String, completion: @escaping @Sendable (DraftSaveFailure?) -> Void = { _ in }) {
        saveGrid(GridDraft(trackUUID: uuid, base: [], segments: []), completion)
    }
    public func removeGain(_ uuid: String) { saveGain(nil, uuid, { _ in }) }
    public func saveCue(_ draft: CueDraft) { saveCue(draft, { _ in }) }
    public func saveGrid(_ draft: GridDraft) { saveGrid(draft, { _ in }) }
    public func saveGain(_ gain: Double?, trackUUID: String) { saveGain(gain, trackUUID, { _ in }) }
}

/// 저장을 맡았지만 아직 디스크에 없는 입력(저장 중이거나 실패). 디스크보다 최신이라 표시는 이것을 따른다.
public struct UnsavedDrafts: Sendable, Equatable {
    public var cues: [String: CueDraft]
    public var grids: [String: GridDraft]
    /// 값이 nil이면 게인 초안 지우기
    public var gains: [String: Double?]

    public init(cues: [String: CueDraft] = [:], grids: [String: GridDraft] = [:], gains: [String: Double?] = [:]) {
        self.cues = cues
        self.grids = grids
        self.gains = gains
    }

    public var isEmpty: Bool { cues.isEmpty && grids.isEmpty && gains.isEmpty }

    /// 초안이 있는 곡 표시(큐·그리드·게인)에 저장 대기 입력을 얹는다.
    /// - Returns: 목록 숫자를 다시 맞출 큐 초안(저장 대기 입력)
    public func overlay(cue: inout Set<String>, grid: inout Set<String>, gain: inout Set<String>) -> [CueDraft] {
        for (uuid, value) in gains {
            if value != nil { gain.insert(uuid) } else { gain.remove(uuid) }
        }
        for (uuid, draft) in grids {
            if draft.hasChanges { grid.insert(uuid) } else { grid.remove(uuid) }
        }
        for (uuid, draft) in cues {
            if draft.hasChanges { cue.insert(uuid) } else { cue.remove(uuid) }
        }
        return cues.keys.sorted().compactMap { cues[$0] }
    }
}
