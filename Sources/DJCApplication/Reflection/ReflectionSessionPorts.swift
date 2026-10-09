import DJCDomain
import Foundation

// 반영 세션(`ReflectionSession`)의 피동 포트. 실제 구현은 조립 지점(앱 `AppComposition`, CLI `CLIComposition`)이 고른다:
// 관문·백업 폴더·음원 읽기·실행 중인 앱은 DJCAdapters(`.live`), 화면 상태·잠금·다시 읽기·확인·결과는 앱의 화면 쪽이 붙인다.
// 시험은 가짜를 넣는다(DJCApplicationTests `ReflectionFakes`).

/// 반영 세션이 받는 포트 묶음
@MainActor
public struct ReflectionPorts {
    public var gate: RekordboxWriteGate
    public var backups: RekordboxBackups
    public var drafts: DraftStore
    public var snapshots: SnapshotTaker
    public var audio: TrackAudioReader
    public var library: ReflectionLibrary
    public var reload: LibraryReloader
    public var lock: WriteLock
    public var confirmation: UserConfirmation
    public var results: ReflectionResults
    public var runningApps: RunningApps
    /// 재생 목록 연결 기록(쓴 뒤 새 목록 ID 잇기·곡 넣기를 되돌린 뒤 잊기)
    public var playlistImports: PlaylistImportsStore

    public init(gate: RekordboxWriteGate, backups: RekordboxBackups, drafts: DraftStore, snapshots: SnapshotTaker, audio: TrackAudioReader,
                library: ReflectionLibrary, reload: LibraryReloader, lock: WriteLock, confirmation: UserConfirmation,
                results: ReflectionResults, runningApps: RunningApps, playlistImports: PlaylistImportsStore) {
        self.gate = gate
        self.backups = backups
        self.drafts = drafts
        self.snapshots = snapshots
        self.audio = audio
        self.library = library
        self.reload = reload
        self.lock = lock
        self.confirmation = confirmation
        self.results = results
        self.runningApps = runningApps
        self.playlistImports = playlistImports
    }

    /// 라이브러리 화면과 같은 초안 저장 큐·스냅샷 뜨기·연결 기록을 쓰는 포트 묶음(앱 조립 지점). 같은 큐여야 게인 초안처럼 모든 곡이
    /// 파일 하나인 초안의 저장 순서가 지켜진다.
    public init(gate: RekordboxWriteGate, backups: RekordboxBackups, sharing libraryUseCases: LibraryUseCases, audio: TrackAudioReader,
                library: ReflectionLibrary, reload: LibraryReloader, lock: WriteLock, confirmation: UserConfirmation,
                results: ReflectionResults, runningApps: RunningApps) {
        let shared = libraryUseCases.ports
        self.init(gate: gate, backups: backups, drafts: shared.drafts, snapshots: shared.snapshots, audio: audio, library: library,
                  reload: reload, lock: lock, confirmation: confirmation, results: results, runningApps: runningApps,
                  playlistImports: shared.playlistImports)
    }
}

/// 쓰는 동안 잠그고 단계를 알린다(앱: 라이브러리 화면의 쓰기 상태. 덱까지 잠그면 덱이 재생을 멈추고 조작을 막는다).
@MainActor
public struct WriteLock {
    public var isLocked: @MainActor () -> Bool
    /// - Parameter deck: 덱도 잠글지. iTunes 동기화는 덱 초안을 건드리지 않아 다른 쓰기만 막는다(실행 취소 이력·재생 유지)
    public var set: @MainActor (_ locked: Bool, _ deck: Bool) -> Void
    /// 쓰기 단계 안내(nil이면 지운다)
    public var stage: @MainActor @Sendable (WriteStage?) -> Void

    public init(isLocked: @escaping @MainActor () -> Bool, set: @escaping @MainActor (Bool, Bool) -> Void,
                stage: @escaping @MainActor @Sendable (WriteStage?) -> Void) {
        self.isLocked = isLocked
        self.set = set
        self.stage = stage
    }

    /// 잠금이 없는 곳(CLI): 늘 풀려 있고 단계를 알리지 않는다
    public static var none: Self { Self(isLocked: { false }, set: { _, _ in }, stage: { _ in }) }
}

/// 쓰기·복원 뒤 라이브러리 다시 읽기(앱: 새 스냅샷을 조용히 읽는다)
@MainActor
public struct LibraryReloader {
    /// 새 스냅샷을 실제로 읽었는지 돌려준다(거절·실패·밀린 읽기는 거짓).
    /// - Parameters:
    ///   - written: 읽은 뒤 덱에 알릴 쓰거나 되돌린 곡. 읽지 못하면 다음에 읽을 때 알린다(옛 스냅샷을 새것으로 보지 않게)
    ///   - playlistEdits: 읽은 뒤 되돌린 rekordbox 상태에 다시 쌓을 재생 목록 편집(복원). 읽지 못하면 다음 읽기 뒤에 쌓는다
    public var reload: @MainActor (_ written: Set<String>, _ playlistEdits: [PlaylistEdit]) async -> Bool

    public init(reload: @escaping @MainActor (Set<String>, [PlaylistEdit]) async -> Bool) {
        self.reload = reload
    }

    /// 다시 읽을 라이브러리가 없는 곳(CLI)
    public static var none: Self { Self { _, _ in false } }
}

/// 사용자에게 묻기(앱: 확인 창). 물을지는 세션이 정하고, 이 포트는 답만 한다.
@MainActor
public struct UserConfirmation {
    /// 확인을 누르면 true
    public var confirm: @MainActor (ReflectionPrompt) -> Bool
    /// 확인·둘째 동작·취소 가운데 누른 것
    public var choose: @MainActor (ReflectionPrompt) -> ReflectionChoice

    public init(confirm: @escaping @MainActor (ReflectionPrompt) -> Bool, choose: @escaping @MainActor (ReflectionPrompt) -> ReflectionChoice) {
        self.confirm = confirm
        self.choose = choose
    }

    /// 묻지 않고 동의한다(CLI: 플래그가 곧 동의다)
    public static var agreeing: Self { Self(confirm: { _ in true }, choose: { _ in .confirm }) }
}

/// rekordbox가 켜져 있는지(켜져 있으면 미리 보지도 않는다. 쓰기 관문도 다시 확인한다)
public struct RunningApps: Sendable {
    public var isRekordboxRunning: @Sendable () -> Bool

    public init(isRekordboxRunning: @escaping @Sendable () -> Bool) {
        self.isRekordboxRunning = isRekordboxRunning
    }
}

/// 결과 알리기·기록(앱: 토스트·결과 기록·심각 경고). 세션이 흐름 안의 알릴 자리에서 부른다.
@MainActor
public struct ReflectionResults {
    public var publish: @MainActor (ReflectionOutcome) -> Void

    public init(publish: @escaping @MainActor (ReflectionOutcome) -> Void) {
        self.publish = publish
    }

    /// 알릴 곳이 없는 곳(CLI는 결과를 직접 찍는다)
    public static var none: Self { Self { _ in } }
}

/// 반영이 보는 라이브러리 화면의 초안 상태(앱: 라이브러리 화면 모델이 든 메모리 초안·표시).
/// 세션은 상태를 읽고(`state`) 쓰거나 되돌린 결과를 알려(`apply`) 화면이 메모리 초안·표시를 맞추게 한다. 무엇을 바꿀지는 세션이 정한다.
@MainActor
public struct ReflectionLibrary {
    public var state: @MainActor () -> ReflectionLibraryState
    public var apply: @MainActor (ReflectionLibraryChange) -> Void
    /// 쓰기 전에: 저장에 실패한 태그 초안을 다시 저장한다(실패한 지우기도)
    public var retryTagSaves: @MainActor () -> Void
    /// 쓰기 전에: 읽지 못하는 초안 파일을 옮겨 보관하고(화면의 메모리 초안은 다시 저장한다) 옮긴 목록을 돌려준다(#174)
    public var preserveDamagedDrafts: @MainActor () -> [DamagedDraftFile]
    /// 쓰기 전에: 저장하지 못한 재생 목록 초안을 다시 저장해 본다. 됐으면(또는 저장할 것이 없으면) true
    public var savePlaylistDraft: @MainActor () -> Bool
    /// 미리 보기·쓰기 뒤에: rekordbox에 쓴(또는 최신 대상에 이미 있던) USB 재생 기록의 보존본에 rekordbox 기록 ID를 남긴다(#43).
    /// 보존본의 저장은 USB 가져오기와 한 줄로 서야 해서(같은 파일을 겹쳐 쓰지 않게) 보존본을 든 화면 쪽이 그 줄에 세운다.
    /// 표시를 저장하지 못하면 알릴 문장을 돌려준다(rekordbox 쓰기는 끝났다)
    public var recordHistories: @MainActor ([RekordboxHistoryOutcome]) async -> String?

    public init(state: @escaping @MainActor () -> ReflectionLibraryState, apply: @escaping @MainActor (ReflectionLibraryChange) -> Void,
                retryTagSaves: @escaping @MainActor () -> Void, preserveDamagedDrafts: @escaping @MainActor () -> [DamagedDraftFile],
                savePlaylistDraft: @escaping @MainActor () -> Bool,
                recordHistories: @escaping @MainActor ([RekordboxHistoryOutcome]) async -> String? = { _ in nil }) {
        self.state = state
        self.apply = apply
        self.retryTagSaves = retryTagSaves
        self.preserveDamagedDrafts = preserveDamagedDrafts
        self.savePlaylistDraft = savePlaylistDraft
        self.recordHistories = recordHistories
    }

    /// 화면이 없는 곳(CLI): 메모리 초안이 없고 바꿀 표시도 없다
    public static var none: Self {
        Self(state: { ReflectionLibraryState() }, apply: { _ in }, retryTagSaves: {}, preserveDamagedDrafts: { [] }, savePlaylistDraft: { true })
    }
}

/// 쓰기 전 백업 폴더 읽기·쓰기(RekordboxKit의 백업 모양). 실제 구현은 DJCAdapters(`RekordboxBackups.live`).
public struct RekordboxBackups: Sendable {
    /// 백업 폴더의 백업(최근 것부터)
    public var list: @Sendable (_ folder: URL) -> [RekordboxWriteBackup]
    /// 이 백업 뒤에 뜬 백업 수(복원하면 그 쓰기·복원도 함께 되돌린다, #222). 모르면 0
    public var laterCount: @Sendable (_ backup: URL, _ folder: URL) -> Int
    /// 이 백업 뒤에 시점 스냅샷으로 복원해 이 백업으로는 되돌릴 수 없으면 그 이유(#225)
    public var pointRestoreRefusal: @Sendable (_ backup: URL, _ folder: URL) -> String?
    /// 백업에 남은 초안(복원이 되살린다)
    public var drafts: @Sendable (_ backup: URL) -> RekordboxBackupDrafts
    /// rekordbox DB 사본의 변경 카운터(백업 뒤 rekordbox에서 바뀌었는지 견준다)
    public var updateCount: @Sendable (_ database: URL) throws -> Int
    /// 백업 폴더(없으면 가장 가까운 있는 상위 폴더)에 쓸 수 있는지
    public var canWrite: @Sendable (_ folder: URL) -> Bool
    /// 곡 넣기 백업에 남긴 추가 목록(되돌리면 추가 목록으로 돌아온다). 옛 백업이거나 읽지 못하면 nil
    public var stagedTracks: @Sendable (_ backup: URL) -> [StagedTrack]?
    /// 곡 넣기 백업에 추가 목록을 남긴다
    public var saveStagedTracks: @Sendable ([StagedTrack], _ backup: URL) throws -> Void
    /// 곡 넣기 백업에 추가한 곡의 초안 사본을 남긴다(복원이 같은 모양으로 되살린다, #202)
    public var saveDraft: @Sendable (RekordboxBackupDraft, _ backup: URL) throws -> Void
    /// 백업에 남은 참고 경고(경로가 예상과 달라 남긴 분석 파일, 복원 결과에 적는다). 없으면 nil
    public var fileWarning: @Sendable (_ backup: URL) -> String?

    public init(list: @escaping @Sendable (URL) -> [RekordboxWriteBackup], laterCount: @escaping @Sendable (URL, URL) -> Int,
                pointRestoreRefusal: @escaping @Sendable (URL, URL) -> String?, drafts: @escaping @Sendable (URL) -> RekordboxBackupDrafts,
                updateCount: @escaping @Sendable (URL) throws -> Int, canWrite: @escaping @Sendable (URL) -> Bool,
                stagedTracks: @escaping @Sendable (URL) -> [StagedTrack]?, saveStagedTracks: @escaping @Sendable ([StagedTrack], URL) throws -> Void,
                saveDraft: @escaping @Sendable (RekordboxBackupDraft, URL) throws -> Void,
                fileWarning: @escaping @Sendable (URL) -> String?) {
        self.list = list
        self.laterCount = laterCount
        self.pointRestoreRefusal = pointRestoreRefusal
        self.drafts = drafts
        self.updateCount = updateCount
        self.canWrite = canWrite
        self.stagedTracks = stagedTracks
        self.saveStagedTracks = saveStagedTracks
        self.saveDraft = saveDraft
        self.fileWarning = fileWarning
    }
}

/// 백업에 남은 초안(쓰기가 백업 폴더에 남긴 것)
public struct RekordboxBackupDrafts: Sendable {
    public var cues: [CueDraft]
    public var grids: [GridDraft]
    public var gains: [String: Double]
    public var tags: [TagDraft]
    public var artworks: [ArtworkEdit]
    public var merges: [DuplicateMergeDraft]
    public var playlistEdits: [PlaylistEdit]

    public init(cues: [CueDraft] = [], grids: [GridDraft] = [], gains: [String: Double] = [:], tags: [TagDraft] = [], artworks: [ArtworkEdit] = [],
                merges: [DuplicateMergeDraft] = [], playlistEdits: [PlaylistEdit] = []) {
        self.cues = cues
        self.grids = grids
        self.gains = gains
        self.tags = tags
        self.artworks = artworks
        self.merges = merges
        self.playlistEdits = playlistEdits
    }
}

/// 곡 넣기 백업에 남기는 추가한 곡의 초안 하나
public enum RekordboxBackupDraft: Sendable {
    case cue(CueDraft), grid(GridDraft), tag(TagDraft)

    public var trackUUID: String {
        switch self {
        case let .cue(draft): draft.trackUUID
        case let .grid(draft): draft.trackUUID
        case let .tag(draft): draft.trackUUID
        }
    }
}

/// 음원 읽기(곡 넣기 계획·분석 붙이기). 실제 구현은 DJCAdapters(`TrackAudioReader.live`), 음량 캐시는 앱이 준다.
public struct TrackAudioReader: Sendable {
    /// 분석 파일이 없는 곡인지(분석 파일 경로가 비었으면 분석 전 곡이다)
    public var needsAnalysis: @Sendable (_ analysisDataPath: String?) -> Bool
    /// 길이·태그·내장 그림(AVFoundation)
    public var tags: @Sendable (URL) async throws -> AudioTags
    /// 전에 잰 음량, 없으면 재서 남긴다(재지 못하면 nil)
    public var loudness: @Sendable (URL) async -> Loudness?
    /// 분석을 붙이지 못하는 음원이면 그 이유(규칙을 확인하지 않은 형식)
    public var unsupported: @Sendable (URL) -> String?
    /// 넣기 계획(파일 태그 → 곡 행 값)
    public var addPlan: @Sendable (URL, AudioTags) throws -> TrackAddPlan

    public init(needsAnalysis: @escaping @Sendable (String?) -> Bool, tags: @escaping @Sendable (URL) async throws -> AudioTags,
                loudness: @escaping @Sendable (URL) async -> Loudness?, unsupported: @escaping @Sendable (URL) -> String?,
                addPlan: @escaping @Sendable (URL, AudioTags) throws -> TrackAddPlan) {
        self.needsAnalysis = needsAnalysis
        self.tags = tags
        self.loudness = loudness
        self.unsupported = unsupported
        self.addPlan = addPlan
    }
}
