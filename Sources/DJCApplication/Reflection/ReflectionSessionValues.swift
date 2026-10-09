import DJCDomain
import Foundation

/// 반영이 읽는 라이브러리 화면의 초안 상태(메모리 초안·표시). 화면 모델이 들고 있고 세션은 읽기만 한다(`ReflectionLibrary.state`).
public struct ReflectionLibraryState: Sendable {
    /// 곡 UUID → 지금 목록의 곡 행
    public var rows: [String: TrackRow]
    /// 큐·그리드·게인 초안 표시(메모리, 저장 대기 입력 포함)
    public var cueDraftUUIDs: Set<String>
    public var gridDraftUUIDs: Set<String>
    public var gainDraftUUIDs: Set<String>
    public var tagDrafts: [String: TagDraft]
    public var artworkDrafts: [String: ArtworkDraft]
    public var mergeDrafts: [DuplicateMergeDraft]
    public var playlistDraft: PlaylistDraft
    /// 재생 목록 초안 저장에 실패해 메모리 초안이 디스크보다 최신이다(#174)
    public var playlistDraftUnsaved: Bool
    /// 스냅샷에서 읽은 rekordbox 재생 목록(초안을 얹기 전)
    public var rekordboxPlaylists: PlaylistLayout
    /// 재생 목록 연결 기록(메모리)과 그 파일을 읽지 못했는지(그러면 저장하지 않는다)
    public var playlistImports: PlaylistImports
    public var playlistImportsLoadFailed: Bool
    /// 읽지 못해 옮겨 둔 초안의 곡별 종류
    public var unreadableDraftKinds: [String: Set<WritePart>]
    /// 이 화면이 저장을 맡겼다가 실패한 태그 초안 곡
    public var failedTagSaves: Set<String>
    public var staged: [StagedTrack]
    /// 추가한 곡의 그리드를 뒤에서 추정하는 중인지
    public var estimatingGrids: Bool
    /// iTunes 동기화 목록을 보는 중인지(그 곡은 Music에서 뺀다)
    public var iTunesSelection: Bool
    /// 덱에 올린 추가한 곡(넣으면 새 rekordbox 곡으로 바꿔 올린다)
    public var deckStagedUUID: String?
    /// 목록 위 오류 줄(다시 읽기가 실패한 이유)
    public var lastError: String?
    /// rekordbox 쓰기 대기에 오른 USB 재생 기록의 쓰기 입력(#43, 가져온 차례). 곡을 고르지 않아도 쓸 것이 있다
    public var pendingHistories: [HistoryImport]

    public init(rows: [String: TrackRow] = [:], cueDraftUUIDs: Set<String> = [], gridDraftUUIDs: Set<String> = [], gainDraftUUIDs: Set<String> = [],
                tagDrafts: [String: TagDraft] = [:], artworkDrafts: [String: ArtworkDraft] = [:], mergeDrafts: [DuplicateMergeDraft] = [],
                playlistDraft: PlaylistDraft = PlaylistDraft(), playlistDraftUnsaved: Bool = false,
                rekordboxPlaylists: PlaylistLayout = PlaylistLayout(), playlistImports: PlaylistImports = PlaylistImports(),
                playlistImportsLoadFailed: Bool = false, unreadableDraftKinds: [String: Set<WritePart>] = [:], failedTagSaves: Set<String> = [], staged: [StagedTrack] = [],
                estimatingGrids: Bool = false, iTunesSelection: Bool = false, deckStagedUUID: String? = nil, lastError: String? = nil,
                pendingHistories: [HistoryImport] = []) {
        self.rows = rows
        self.cueDraftUUIDs = cueDraftUUIDs
        self.gridDraftUUIDs = gridDraftUUIDs
        self.gainDraftUUIDs = gainDraftUUIDs
        self.tagDrafts = tagDrafts
        self.artworkDrafts = artworkDrafts
        self.mergeDrafts = mergeDrafts
        self.playlistDraft = playlistDraft
        self.playlistDraftUnsaved = playlistDraftUnsaved
        self.rekordboxPlaylists = rekordboxPlaylists
        self.playlistImports = playlistImports
        self.playlistImportsLoadFailed = playlistImportsLoadFailed
        self.unreadableDraftKinds = unreadableDraftKinds
        self.failedTagSaves = failedTagSaves
        self.staged = staged
        self.estimatingGrids = estimatingGrids
        self.iTunesSelection = iTunesSelection
        self.deckStagedUUID = deckStagedUUID
        self.lastError = lastError
        self.pendingHistories = pendingHistories
    }

    /// 반영 대기 초안이 있는 곡(큐·그리드·게인·태그·앨범아트 초안, 합치기 초안에 묶인 곡)
    public var pendingUUIDs: Set<String> {
        cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys).union(artworkDrafts.keys)
            .union(mergeDrafts.flatMap { $0.members.map(\.trackUUID) })
    }
}

/// 세션이 쓰거나 되돌린 결과로 화면의 메모리 초안·표시를 맞추라는 알림(`ReflectionLibrary.apply`). 무엇을 바꿀지는 세션이 정했다.
/// 쓴 뒤·복원 뒤 초안 파일 저장(큐·그리드·게인·그림·태그·합치기·재생 목록·연결 기록)은 모두 세션이 끝냈고, 화면은 메모리와 표시만 맞춘다.
public enum ReflectionLibraryChange: Sendable {
    /// 큐·그리드·게인 초안을 지웠다(초안 파일은 세션이 지웠다): 표시를 끈다. `cueCounts`면 큐 개수 표시도 지운다
    case draftsCleared(DraftSaveKind, [String], cueCounts: Bool)
    /// 태그 초안을 통째로 바꿨다(쓴 뒤 비운 초안·되살린 초안, 세션이 저장했다). 변경이 없는 초안은 메모리에서 지운다.
    /// 저장 실패는 화면이 맡긴 저장으로 센다(`failedTagSaves`)
    case tagDrafts([TagDraft])
    /// 합치기 초안을 이것으로 바꿨다(세션이 저장했다). 쓰기·복원은 이미 끝났으니 저장 실패(`failure`)는 경고로만 알린다.
    /// `moved`는 저장이 옮긴 손상된 옛 파일(데이터 폴더를 정한 저장소만)
    case mergeDrafts([DuplicateMergeDraft], failure: (any Error)?, moved: [DamagedDraftFile])
    /// 쓴 재생 목록 편집을 초안에서 빼 저장했고(막힌 편집은 남긴다), 새로 만든 목록의 새 rekordbox ID를 연결 기록에 이어 저장했다
    case playlistWritten(EditPlaylists.WriteCleanup)
    /// 쓴 곡의 앨범아트 초안 파일을 지웠다(`failed`곡은 지우지 못했다): 메모리 초안을 지우고 그 곡의 그림을 새로 읽게 한다
    case artworkCleared([String], failed: Int)
    /// 백업의 앨범아트 초안을 되살렸다(파일은 세션이 저장했다). `touched`는 그 백업이 그림을 쓴 곡(새로 읽게 한다)
    case artworkRestored([String: ArtworkDraft], touched: [String])
    /// 넣은 곡을 추가 목록에서 뺀다(초안은 남긴다)
    case unstaged(Set<String>)
    /// 되돌린 곡을 추가 목록에 다시 넣는다(이미 있는 곡은 건너뛴다)
    case restaged([StagedTrack])
    /// 덱에 올린 추가한 곡을 rekordbox에 넣었다: 다시 읽으면 이 곡(ContentID)으로 바꿔 올린다
    case deckTrackMoved(String)
    /// 되돌린 곡(ContentID)의 재생 목록 연결 기록과 초안의 그 곡 편집을 잊어 저장했다
    case playlistImportsReset(EditPlaylists.ImportsReset)
    /// 연결되지 않은 초안을 다시 센다
    case unlinkedDraftsChanged
    /// 목록 위 오류 줄에 알린다
    case libraryError(String)
    /// 넣은 곡(ContentID)을 전체 목록에서 고른다
    case showAdded(String)
    /// 뺀 곡(ContentID)을 선택에서 뺀다
    case deselected(Set<String>)
    /// 이번 실행의 마지막 쓰기 백업(툴바·토스트의 되돌리기)
    case lastWriteBackup(URL?)
    /// 쓰기·복원은 끝났지만 뒤따른 일(초안 정리·다시 읽기·복원 충돌)에 남은 경고(#175)
    case followUp([String])
    /// 쓰기 전 백업 목록이 바뀌었다
    case writeBackupsChanged
    /// 최신 사본에 이미 있던 재생 기록의 보존본 연결을 저장하지 못했다(미리 보기 뒤, #43): 경고로 알린다
    case historyMarkFailed(String)
}

/// 반영 흐름 하나의 결과. 세션이 알릴 자리에서 `ReflectionResults.publish`로 알리고(`busy`·`declined`는 알리지 않는다) 그대로 돌려준다.
public enum ReflectionOutcome: Sendable {
    /// 이미 쓰는 중이라 시작하지 않았다
    case busy
    /// 확인 창에서 취소했다(아무것도 쓰지 않았다)
    case declined
    /// 아무것도 하지 않은 안내(지금은 못 함·할 것 없음). 이유 줄은 앞 둘과 남은 수만 보인다
    case notice(title: String, text: String, lines: [String])
    /// 미리 보기 단계에서 취소했다(아무것도 쓰지 않았다)
    case cancelled
    case written(RekordboxWriteReport, preview: RekordboxWriteReport, followUp: [String])
    /// 미리 보니 쓸 것이 없다(막혔거나 제외). 고른 곡(`targets`)의 막힌 초안은 화면이 복구 시트로 고치게 한다(#232)
    case nothingWritable(WritePreview, targets: [TrackRow])
    case added(RekordboxTrackWriteReport, preview: TrackAddPreview, followUp: [String])
    case nothingAdded(TrackAddPreview)
    case deleted(RekordboxTrackWriteReport, preview: TrackDeletePreview)
    case nothingDeleted(TrackDeletePreview)
    /// `fileWarning`은 복원 직전 백업에 남은 참고 경고(복원은 끝났다)
    case restored(RekordboxWriteBackup, saved: URL, fileWarning: String?, followUp: [String])
    /// 쓰기·넣기·빼기 실패. `exclusions`는 미리 보기에서 제외한 초안(따로 창을 띄우지 않고 실패 알림에 합친다, #230)
    case failed(title: String, error: any Error, exclusions: [String])
    case restoreFailed(RekordboxWriteBackup, error: any Error)
}

/// 복원이 되살릴 백업 초안과 지금 초안이 다른 곳(#175). 지금 초안은 쓴 뒤 새로 만든 편집이다.
public struct RestoreDraftConflict: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case cue, grid, gain, tag, artwork, merge }
    public var kind: Kind
    /// 곡 UUID(합치기는 합치기 초안 ID)
    public var uuid: String

    public init(kind: Kind, uuid: String) {
        self.kind = kind
        self.uuid = uuid
    }

    public var label: String {
        switch kind {
        case .cue: String(ui: "큐")
        case .grid: String(ui: "그리드")
        case .gain: String(ui: "게인")
        case .tag: String(ui: "태그")
        case .artwork: String(ui: "앨범아트")
        case .merge: String(ui: "합치기")
        }
    }
}

/// iTunes 동기화로 rekordbox에 쓸 선택(선택 창을 열 때의 동기화 파일 원문, 그때의 Music 목록, 고른 것)
public struct ITunesSyncWrite: Sendable {
    public var base: Data
    public var source: [ITunesSyncSelection.Node]
    public var selection: ITunesSyncSelection

    public init(base: Data, source: [ITunesSyncSelection.Node], selection: ITunesSyncSelection) {
        self.base = base
        self.source = source
        self.selection = selection
    }
}
