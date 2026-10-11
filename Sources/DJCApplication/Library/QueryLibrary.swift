import DJCDomain
import Foundation

/// 연 사본 하나에 대한 질의(포트가 연다). 답은 CLI 읽기 명령의 JSON 계약 값(`LibraryRecords`)이다.
public struct LibraryQuery: Sendable {
    public var search: @Sendable (_ query: String, _ bpm: ClosedRange<Double>?, _ key: String?, _ playlistID: String?,
                                  _ filter: LibraryFilter) throws -> LibraryRecords.TrackList
    public var track: @Sendable (_ id: String) throws -> LibraryRecords.TrackInfo
    public var playlists: @Sendable (_ tree: Bool) -> LibraryRecords.PlaylistList
    public var playlist: @Sendable (_ id: String) throws -> LibraryRecords.PlaylistContents
    public var histories: @Sendable () -> LibraryRecords.HistoryList
    public var history: @Sendable (_ id: String) throws -> LibraryRecords.HistoryContents
    public var drafts: @Sendable () -> LibraryRecords.DraftList
    public var duplicates: @Sendable () -> LibraryRecords.DuplicateList
    /// 라이브러리 현황(`checkFiles`면 음원 파일이 있는지도 센다). JSON 계약 값은 `LibraryRecords.Report(_:)`
    public var report: @Sendable (_ checkFiles: Bool) -> LibraryReport
    /// 제목에 검색어가 든 곡의 파일 경로(ID 순서, JSON)
    public var paths: @Sendable (_ query: String) -> LibraryRecords.PathList
    /// 같은 경로를 라이브러리(DB) 순서로(텍스트 `djc path`)
    public var titlePaths: @Sendable (_ query: String) -> [String]
    /// 초안을 만들 곡과 그 rekordbox 큐(곡이 없으면 던진다)
    public var draftSource: @Sendable (_ id: String) throws -> (track: Track, cues: [Cue])
    public var isInPlaylist: @Sendable (_ id: String) -> Bool
    /// rekordbox 곡 색 목록
    public var colors: [TrackColor]

    public init(search: @escaping @Sendable (_ query: String, _ bpm: ClosedRange<Double>?, _ key: String?, _ playlistID: String?,
                                             _ filter: LibraryFilter) throws -> LibraryRecords.TrackList,
                track: @escaping @Sendable (_ id: String) throws -> LibraryRecords.TrackInfo,
                playlists: @escaping @Sendable (_ tree: Bool) -> LibraryRecords.PlaylistList,
                playlist: @escaping @Sendable (_ id: String) throws -> LibraryRecords.PlaylistContents,
                histories: @escaping @Sendable () -> LibraryRecords.HistoryList,
                history: @escaping @Sendable (_ id: String) throws -> LibraryRecords.HistoryContents,
                drafts: @escaping @Sendable () -> LibraryRecords.DraftList,
                duplicates: @escaping @Sendable () -> LibraryRecords.DuplicateList,
                report: @escaping @Sendable (_ checkFiles: Bool) -> LibraryReport,
                paths: @escaping @Sendable (_ query: String) -> LibraryRecords.PathList,
                titlePaths: @escaping @Sendable (_ query: String) -> [String],
                draftSource: @escaping @Sendable (_ id: String) throws -> (track: Track, cues: [Cue]),
                isInPlaylist: @escaping @Sendable (_ id: String) -> Bool,
                colors: [TrackColor]) {
        self.search = search
        self.track = track
        self.playlists = playlists
        self.playlist = playlist
        self.histories = histories
        self.history = history
        self.drafts = drafts
        self.duplicates = duplicates
        self.report = report
        self.paths = paths
        self.titlePaths = titlePaths
        self.draftSource = draftSource
        self.isInPlaylist = isInPlaylist
        self.colors = colors
    }
}

/// 라이브러리 질의(포트): 사본 DB·초안 폴더를 읽어 질의에 답한다. 실제 구현은 DJCAdapters(`LibraryQuerySource.live`).
public struct LibraryQuerySource: Sendable {
    /// 사본을 연다(`shareRoot`: 그리드를 읽을 분석 파일 뿌리, nil이면 사본 옆)
    public var open: @Sendable (_ snapshot: URL, _ shareRoot: URL?, _ commentPreset: CommentPreset) throws -> LibraryQuery
    /// 코멘트 하나를 애니송 프리셋으로 풀어 본다
    public var parse: @Sendable (_ comment: String) -> LibraryRecords.ParsedComment
    /// 설치된 rekordbox와 사본 DB가 쓰기를 확인한 모양인지(읽기만)
    public var compatibility: @Sendable (_ snapshot: URL) throws -> LibraryRecords.Compatibility

    public init(open: @escaping @Sendable (_ snapshot: URL, _ shareRoot: URL?, _ commentPreset: CommentPreset) throws -> LibraryQuery,
                parse: @escaping @Sendable (_ comment: String) -> LibraryRecords.ParsedComment,
                compatibility: @escaping @Sendable (_ snapshot: URL) throws -> LibraryRecords.Compatibility) {
        self.open = open
        self.parse = parse
        self.compatibility = compatibility
    }
}

/// 라이브러리 질의(유스케이스, CLI `search`·`track`·`playlists`·`report`·`path`·`compat`·`draft` …): 명시한 DB(없으면 최신 스냅샷)를
/// 읽을 사본으로 정하고(라이브 master.db는 거부) 연다. 앱의 곡 목록·중복 후보 화면과 같은 값(`LibraryRecords`·`LibraryReport`)을 쓴다.
public struct QueryLibrary: Sendable {
    let source: LibrarySource
    let query: LibraryQuerySource
    /// 사본을 명시하지 않았을 때 그리드를 읽을 분석 파일 뿌리(라이브 rekordbox share)
    let liveShare: URL

    public init(source: LibrarySource, query: LibraryQuerySource, liveShare: URL) {
        self.source = source
        self.query = query
        self.liveShare = liveShare
    }

    /// 읽을 사본을 정해 연다. 명시하지 않았으면 최신 스냅샷과 라이브 share의 분석 파일을 읽는다
    public func open(database: URL?, commentPreset: CommentPreset = .none) throws -> LibraryQuery {
        try openCopy(database: database, commentPreset: commentPreset).query
    }

    /// 읽을 사본을 정한다: 명시한 DB(라이브 master.db는 거부), 없으면 최신 스냅샷
    public func resolveCopy(_ database: URL?) throws -> URL { try source.resolveCopy(database) }

    /// `open`과 같고 정한 사본도 함께 준다(텍스트 `djc report`가 사본 경로를 먼저 보인다)
    public func openCopy(database: URL?, commentPreset: CommentPreset = .none) throws -> (snapshot: URL, query: LibraryQuery) {
        let snapshot = try source.resolveCopy(database)
        return (snapshot, try query.open(snapshot, database == nil ? liveShare : nil, commentPreset))
    }

    /// 쓰기 전 확인(읽기만): 설치된 rekordbox 버전과 사본 DB 구조·카운터
    public func compatibility(database: URL?) throws -> LibraryRecords.Compatibility {
        try query.compatibility(try source.resolveCopy(database))
    }

    public func parse(comment: String) -> LibraryRecords.ParsedComment { query.parse(comment) }
}
