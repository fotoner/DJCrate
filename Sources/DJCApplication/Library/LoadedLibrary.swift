import DJCDomain
import Foundation

/// 라이브러리 읽기 결과(메인 밖에서 만들어 화면 모델이 한 번에 적용한다, `LoadLibrary.read`).
public struct LoadedLibrary: Sendable {
    /// 읽기 단계(화면 안내와 걸린 시간 기록)
    public enum Stage: String, Sendable {
        case database, music, iTunes, tracks

        public var message: String {
            switch self {
            case .database: String(ui: "rekordbox 라이브러리를 읽는 중…")
            case .music: String(ui: "Music 보관함을 읽는 중…")
            case .iTunes: String(ui: "iTunes 목록 사본을 읽는 중…")
            case .tracks: String(ui: "곡 목록을 준비하는 중…")
            }
        }

        func measure<Value>(progress: (Stage) -> Void, log: (String) -> Void, _ operation: () throws -> Value) rethrows -> Value {
            progress(self)
            let started = ContinuousClock.now
            defer { logElapsed(since: started, log: log) }
            return try operation()
        }

        func logElapsed(since started: ContinuousClock.Instant, log: (String) -> Void) {
            // 개인 경로·곡·목록 정보 없이 DB와 Music 대기 시간을 구분한다.
            log("라이브러리 단계 \(rawValue) · \(ContinuousClock.now - started)")
        }
    }

    /// 이전 읽기의 iTunes 목록(새 사본이 Music을 읽지 못했을 때 이어 쓸 값)
    public struct ITunesFallback: Sendable {
        public let source: URL
        public let contents: ITunesLibrarySnapshot
        public var preferOverCurrent = false
        public var sourceDatabase: URL? = nil

        public init(source: URL, contents: ITunesLibrarySnapshot, preferOverCurrent: Bool = false, sourceDatabase: URL? = nil) {
            self.source = source
            self.contents = contents
            self.preferOverCurrent = preferOverCurrent
            self.sourceDatabase = sourceDatabase
        }
    }

    public var rows: [TrackRow]
    public var report: LibraryReport
    public var filterCounts: [LibraryFilter: Int]
    public var tagDrafts: [String: TagDraft]
    public var cueDraftUUIDs: Set<String>
    public var gridDraftUUIDs: Set<String>
    public var gainDraftUUIDs: Set<String> = []
    public var playlists: PlaylistLayout
    /// 인텔리전트 재생 목록 ID → 읽은 조건 칸(#68). 보이는 것은 실험실 설정이 켜 있을 때뿐이다.
    public var smartPlaylists: [String: SmartPlaylistSource] = [:]
    public var playlistDraft: PlaylistDraft
    public var histories: [RekordboxHistory]
    public var draftCueCounts: [String: CueCounts] = [:]
    public var draftPreviewCues: [String: [PreviewCueMark]] = [:]
    public var duplicateGroups: [LibraryRecords.DuplicateGroup] = []
    public var iTunesLibrary = SyncedITunesLibrary()
    public var iTunesSnapshot = ITunesLibrarySnapshot(status: .notCaptured)
    /// 그림 초안(그림 바이트 없이)과 곡의 살아 있는 그림 파일 행(ContentID별, 초안 base)
    public var artworkDrafts: [String: ArtworkDraft] = [:]
    public var artworkFiles: [String: [ArtworkFileRow]] = [:]
    /// rekordbox 곡 색 목록(`djmdColor`, 비었으면 화면은 rekordbox 기본 여덟 색)
    public var colors: [TrackColor] = []

    public init(rows: [TrackRow], report: LibraryReport, filterCounts: [LibraryFilter: Int], tagDrafts: [String: TagDraft],
                cueDraftUUIDs: Set<String>, gridDraftUUIDs: Set<String>, gainDraftUUIDs: Set<String> = [], playlists: PlaylistLayout,
                playlistDraft: PlaylistDraft, histories: [RekordboxHistory], draftCueCounts: [String: CueCounts] = [:],
                draftPreviewCues: [String: [PreviewCueMark]] = [:], duplicateGroups: [LibraryRecords.DuplicateGroup] = [],
                iTunesLibrary: SyncedITunesLibrary = SyncedITunesLibrary(),
                iTunesSnapshot: ITunesLibrarySnapshot = ITunesLibrarySnapshot(status: .notCaptured)) {
        self.rows = rows
        self.report = report
        self.filterCounts = filterCounts
        self.tagDrafts = tagDrafts
        self.cueDraftUUIDs = cueDraftUUIDs
        self.gridDraftUUIDs = gridDraftUUIDs
        self.gainDraftUUIDs = gainDraftUUIDs
        self.playlists = playlists
        self.playlistDraft = playlistDraft
        self.histories = histories
        self.draftCueCounts = draftCueCounts
        self.draftPreviewCues = draftPreviewCues
        self.duplicateGroups = duplicateGroups
        self.iTunesLibrary = iTunesLibrary
        self.iTunesSnapshot = iTunesSnapshot
    }
}
