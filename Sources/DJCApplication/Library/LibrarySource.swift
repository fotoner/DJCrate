import DJCDomain
import Foundation

/// rekordbox 라이브러리 읽기(포트): 스냅샷 사본의 DB·분석 파일과 스냅샷 폴더를 읽기만 한다.
/// 실제 구현(`LibrarySource.live`)은 DJCAdapters가 주고 조립 지점이 고른다. 시험은 메모리 구현(`LibrarySource.memory`)을 쓴다.
public struct LibrarySource: Sendable {
    /// 스냅샷 사본을 읽는다(곡·큐·재생 목록·기록·오토게인·그림 파일·곡 색)
    public var library: @Sendable (_ snapshot: URL) throws -> RekordboxLibrary
    /// 곡마다 분석 파일 그리드의 변속 흐름(`tracks`와 같은 순서). 스트리밍·분석 파일이 없는 곡은 빈 값
    public var tempoChanges: @Sendable (_ tracks: [Track], _ shareRoot: URL?) -> [[Double]]
    /// 곡의 분석 파일 그리드(`AnalysisDataPath`, share 뿌리 기준). 없거나 읽지 못하면 nil
    public var grid: @Sendable (_ analysisPath: String?, _ shareRoot: URL?) -> BeatGrid?
    /// 폴더의 가장 최근 스냅샷. 없으면 던진다
    public var latestSnapshot: @Sendable (_ directory: URL) throws -> URL
    /// 폴더의 스냅샷 사본 파일(`.db`, 순서 없음)
    public var snapshots: @Sendable (_ directory: URL) -> [URL]
    /// 스냅샷을 뜬 뒤 원본(master.db·WAL)이 바뀌었는지(스냅샷 이름의 시각과 파일 시각을 견준다)
    public var changed: @Sendable (_ snapshot: URL, _ source: URL) -> Bool
    /// rekordbox·rekordboxAgent가 켜져 있는지
    public var isRekordboxRunning: @Sendable () -> Bool
    /// 읽기 단계 기록(개인 경로·곡 정보 없이 단계와 걸린 시간만)
    public var log: @Sendable (String) -> Void
    /// 명시한 DB(없으면 최신 스냅샷)를 읽을 사본으로 정한다. 라이브 master.db(링크·같은 파일 포함)는 거부한다(`ReadFailure` `live_database`, CLI 읽기 명령)
    public var resolveCopy: @Sendable (_ database: URL?) throws -> URL

    public init(library: @escaping @Sendable (_ snapshot: URL) throws -> RekordboxLibrary,
                tempoChanges: @escaping @Sendable (_ tracks: [Track], _ shareRoot: URL?) -> [[Double]],
                grid: @escaping @Sendable (_ analysisPath: String?, _ shareRoot: URL?) -> BeatGrid?,
                latestSnapshot: @escaping @Sendable (_ directory: URL) throws -> URL,
                snapshots: @escaping @Sendable (_ directory: URL) -> [URL],
                changed: @escaping @Sendable (_ snapshot: URL, _ source: URL) -> Bool,
                isRekordboxRunning: @escaping @Sendable () -> Bool,
                log: @escaping @Sendable (String) -> Void,
                resolveCopy: @escaping @Sendable (_ database: URL?) throws -> URL) {
        self.library = library
        self.tempoChanges = tempoChanges
        self.grid = grid
        self.latestSnapshot = latestSnapshot
        self.snapshots = snapshots
        self.changed = changed
        self.isRekordboxRunning = isRekordboxRunning
        self.log = log
        self.resolveCopy = resolveCopy
    }
}

extension LibrarySource {
    /// 메모리 라이브러리(시험): 사본 경로마다 읽을 라이브러리를 준다. 분석 파일 그리드는 `analysisPath`별로 준다.
    /// 스냅샷 폴더·변경 확인·rekordbox 실행 여부는 주지 않으면 없음·바뀌지 않음·꺼짐이다.
    public static func memory(_ libraries: [URL: RekordboxLibrary], grids: [String: BeatGrid] = [:],
                              latest: URL? = nil, changed: Bool = false, rekordboxRunning: Bool = false) -> LibrarySource {
        LibrarySource(
            library: { snapshot in
                guard let library = libraries[snapshot] else { throw DJCError.snapshotNotFound }
                return library
            },
            tempoChanges: { tracks, _ in
                tracks.map { track in
                    guard !track.isStreaming, let path = track.analysisDataPath, let grid = grids[path] else { return [] }
                    return grid.tempoChanges
                }
            },
            grid: { path, _ in path.flatMap { grids[$0] } },
            latestSnapshot: { _ in
                guard let latest else { throw DJCError.snapshotNotFound }
                return latest
            },
            snapshots: { _ in Array(libraries.keys) },
            changed: { _, _ in changed },
            isRekordboxRunning: { rekordboxRunning },
            log: { _ in },
            resolveCopy: { database in
                guard let copy = database ?? latest else { throw DJCError.snapshotNotFound }
                return copy
            })
    }
}
