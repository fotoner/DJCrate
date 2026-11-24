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
    /// 디스크의 재생 목록 초안(없으면 빈 초안, 읽지 못하면 던진다). 바깥(CLI)에서 바꾼 초안을 받을 때 손상 파일을 빈 초안으로 받지 않게 한다
    public var readPlaylistDraft: @Sendable () throws -> PlaylistDraft
    public var savePlaylistDraft: @MainActor (PlaylistDraft) throws -> Void
    /// 재생 목록 초안 파일 잠금(#260): 앱이 rekordbox에 쓰는 동안 들고 있어 CLI가 초안 파일을 고치지 못하게 한다.
    /// 잡으면 푸는 함수, 다른 실행이 `wait`초 넘게 들고 있으면 nil. 잠금이 없는 구현은 늘 잡는다
    public var lockPlaylistDraft: @Sendable (_ wait: TimeInterval) -> (@Sendable () -> Void)? = { _ in {} }
    public var mergeDrafts: @Sendable () -> [DuplicateMergeDraft]
    public var saveMergeDrafts: @MainActor ([DuplicateMergeDraft]) throws -> Void

    // MARK: 새 큐 ID

    /// 초안에 새로 들이는 큐의 ID(rekordbox 큐로 시작하는 초안·채우는 자동 큐·새로 찍은 큐). 핵심부는 ID를 스스로 만들지 않고
    /// 초안 저장소에서 받는다(실제 구현은 무작위 UUID, 메모리 구현은 프로세스 안에서 겹치지 않는 차례 번호)
    public var newCueID: @Sendable () -> UUID

    // MARK: 출처·판(R5·R22). 기본값은 지금 동작이다(도장을 적지 않고, 판 지정 삭제는 아무것도 지우지 않는다). 실제 구현은 W1-B(#400)

    /// 이 포트로 저장하는 초안의 출처. 조립 지점이 정한다(앱 편집 포트는 사람 편집, CLI는 CLI, LINK는 LINK).
    /// 정하지 않은 포트는 모름이라 그 초안은 제안이다(자동 저장하지 않는다)
    public var origin: DraftOrigin = .unknown
    /// 같은 저장 큐·파일을 쓰되 출처만 다른 포트를 만든다(복원이 되살린 초안·LINK). nil이면 `origin`만 바꾼 같은 포트다
    public var originVariant: (@Sendable (DraftOrigin) -> DraftStore)?
    /// 곡 초안의 도장(출처·판·저장한 때의 해시). 초안이 없거나 도장을 모르면 nil. 파일을 읽지 않는다
    public var stamp: @Sendable (DraftKey) -> DraftStamp? = { _ in nil }
    /// 재생 목록 초안 단계의 도장(`playlistDraft().steps`와 같은 차례). 모르면 빈 배열
    public var playlistStamps: @Sendable () -> [DraftStamp] = { [] }
    /// 곡 초안의 판 지정 삭제(쓴 뒤 정리, R22). 견주는 해시는 `WrittenDraft.contentHash`(묶음에 실제로 읽어 넣은 내용)다.
    /// - 판과 지금 내용의 해시가 모두 쓴 것과 같으면 지운다(`removed`).
    /// - 판이 같고 지금 해시가 다르면(바깥에서 고침) 지우지 않고 제안으로 남긴다(`suggested`). 같은 잠금 안에서 그 초안에 새 판을 주고
    ///   출처에 모름(`.unknown`)을 더해 기록한다. 그래서 나중에 파일이 저장 당시(쓴) 내용으로 돌아와도 제안이고, 같은 미정리 목록으로
    ///   정리를 다시 해도(다시 켠 뒤) 판이 달라 지우지 않는다.
    /// - 판이 다르거나 초안이 없으면(쓰는 동안 새로 저장, 이미 지움) 그대로 둔다(`kept`).
    /// 비교와 삭제는 앱·CLI가 같은 초안 잠금 안에서 한다. 앞서 걸린 저장 뒤에 한다
    public var removeWritten: @Sendable ([WrittenDraft]) throws -> DraftRemoval = { DraftRemoval(kept: $0) }
    /// 그 판의 초안을 제안으로 바꾼다("이대로 둔다", R11): 판이 같은 곡 초안과 재생 목록 단계에 새 판을 주고 출처에 모름(`.unknown`)을 더한다.
    /// 지우지 않는다. 새 판이라 미정리 목록을 지우기 전에 멈춰 다시 정리해도 그 초안을 쓴 것으로 보고 지우지 않는다.
    /// 판이 다른 초안(쓰는 동안 새로 저장)은 그대로 둔다. 바꾼 초안의 옛 판 → 새 판을 돌려준다. 같은 초안 잠금 안에서 한다
    public var markSuggestions: @Sendable (_ drafts: [WrittenDraft], _ playlistSteps: Set<DraftRevision>) throws -> [DraftRevision: DraftRevision] =
        { _, _ in [:] }
    /// 쓴 재생 목록 단계의 정리(R22). 판으로 찾은 쓴 단계는 해시가 달라도 뺀다. 다만 지금 해시가 쓴 해시와 다르면 바깥에서 고친 지금 내용을
    /// 실제 목록 ID와 함께 `PlaylistStepCopy`로 `copyFolder`에 남긴 뒤에만 뺀다. 사본을 남기지 못하면 그 단계를 남긴다(`copyFailed`:
    /// 부르는 쪽은 미정리 목록을 지우지 않고 그 대상의 다음 쓰기를 보류한 채 다음 정리 때 다시 한다).
    /// 새 목록의 연결 ID(`new:키` → 실제 ID)는 이 함수가 옮기지 않는다: 쓴 뒤 정리(`EditPlaylists`)가 남은 단계의 대상·목적지에 옮긴다.
    /// 막힌 단계와 쓰는 동안 더한 단계는 남는다. 같은 초안 잠금 안에서 한다
    public var removeWrittenSteps: @Sendable (PlaylistStepCleanup) throws -> PlaylistStepRemoval =
        { PlaylistStepRemoval(notFound: Set($0.written.map(\.revision))) }

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
                readPlaylistDraft: @escaping @Sendable () throws -> PlaylistDraft,
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
        self.readPlaylistDraft = readPlaylistDraft
        self.savePlaylistDraft = savePlaylistDraft
        self.mergeDrafts = mergeDrafts
        self.saveMergeDrafts = saveMergeDrafts
        self.newCueID = newCueID
    }
}

extension DraftStore {
    /// 같은 저장소를 다른 출처로 저장하는 포트. 구현이 출처 포트를 새로 만들므로(`originVariant`) 이 포트에 바꿔 넣은 클로저
    /// (시험의 실패 주입 등)는 따라가지 않는다: 실패를 주입하려면 출처 포트를 만든 뒤 그 포트에 바꿔 넣는다.
    /// `originVariant`가 없는 포트(손으로 만든 포트)는 `origin` 표시만 바뀌고 도장은 그 구현을 따른다
    public func with(origin: DraftOrigin) -> DraftStore {
        if let originVariant { return originVariant(origin) }
        var copy = self
        copy.origin = origin
        return copy
    }

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

/// 쓴 재생 목록 단계 하나(R22)
public struct WrittenPlaylistStep: Hashable, Sendable {
    public var revision: DraftRevision
    /// 묶음에 실제로 읽어 넣은(쓴) 단계의 해시(`DraftContentHash(step:in:)`)
    public var contentHash: DraftContentHash

    public init(revision: DraftRevision, contentHash: DraftContentHash) {
        self.revision = revision
        self.contentHash = contentHash
    }
}

/// 쓴 재생 목록 단계 정리 요청(R22)
public struct PlaylistStepCleanup: Equatable, Sendable {
    /// 쓴 단계(결과가 `written`인 단계만)
    public var written: [WrittenPlaylistStep]
    /// 새 목록의 연결 ID(`new:키` → 실제 ID)
    public var newPlaylistIDs: [String: String]
    /// 백업 루트(대상의 백업 폴더)
    public var backups: URL
    /// 그 쓰기의 백업 폴더(백업 루트 기준 상대 경로, 미정리 목록의 `backupFolder`). 다시 켠 뒤 정리도 같은 폴더를 찾는다
    public var backupFolder: String

    public init(written: [WrittenPlaylistStep], newPlaylistIDs: [String: String], backups: URL, backupFolder: String) {
        self.written = written
        self.newPlaylistIDs = newPlaylistIDs
        self.backups = backups
        self.backupFolder = backupFolder
    }

    /// 미정리 목록으로 다시 하는 정리(다시 켠 뒤): 쓴 단계·연결 ID·백업 폴더를 목록에서 읽는다
    public init(list: DraftCleanupList, backups: URL) {
        self.init(written: list.playlistSteps.filter { $0.outcome == .written }
                    .map { WrittenPlaylistStep(revision: $0.revision, contentHash: $0.contentHash) },
                  newPlaylistIDs: list.newPlaylistIDs, backups: backups, backupFolder: list.backupFolder)
    }

    /// 바깥에서 고친 단계의 사본을 남길 폴더(그 쓰기의 백업 폴더). 사본 자리는 `PlaylistStepCopy.url(folder:revision:)`
    public var copyFolder: URL { backups.appending(path: backupFolder, directoryHint: .isDirectory) }
}

/// 쓴 재생 목록 단계 정리의 결과(R22)
public struct PlaylistStepRemoval: Equatable, Sendable {
    /// 뺀 단계(해시가 같았거나, 사본을 남긴 뒤 뺐다)
    public var removed: Set<DraftRevision>
    /// 해시가 달라 사본을 남기고 뺀 단계 → 사본 파일
    public var copied: [DraftRevision: URL]
    /// 해시가 달랐는데 사본을 남기지 못해 남긴 단계
    public var copyFailed: Set<DraftRevision>
    /// 판을 찾지 못한 단계(이미 빠졌다). 그대로 둔다
    public var notFound: Set<DraftRevision>

    public init(removed: Set<DraftRevision> = [], copied: [DraftRevision: URL] = [:], copyFailed: Set<DraftRevision> = [],
                notFound: Set<DraftRevision> = []) {
        self.removed = removed
        self.copied = copied
        self.copyFailed = copyFailed
        self.notFound = notFound
    }
}

/// 곡 초안 판 지정 삭제의 결과(R22)
public struct DraftRemoval: Equatable, Sendable {
    /// 판과 해시가 같아 지운 초안
    public var removed: [WrittenDraft]
    /// 판은 같은데 지금 해시가 달라(바깥에서 고침) 지우지 않고 제안으로 남긴 초안
    public var suggested: [WrittenDraft]
    /// 판이 달라(쓰는 동안 새로 저장했거나 이미 없음) 그대로 둔 초안
    public var kept: [WrittenDraft]

    public init(removed: [WrittenDraft] = [], suggested: [WrittenDraft] = [], kept: [WrittenDraft] = []) {
        self.removed = removed
        self.suggested = suggested
        self.kept = kept
    }
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
