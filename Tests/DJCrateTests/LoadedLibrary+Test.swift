import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit

extension LoadedLibrary {
    /// 옛 `LoadedLibrary.load`(앱)와 같은 읽기: 유스케이스 `LoadLibrary`에 실제 포트(사본 DB·분석 파일·Music 사본)를 붙여 부른다.
    /// Music 순서는 앱과 같은 프로세스 하나(`ITunesRefreshCoordinator.shared`)다.
    static func load(snapshot: URL, commentPreset: CommentPreset = .none, refreshITunes: Bool = false,
                     previousITunesSnapshot: ITunesFallback? = nil,
                     fallbackDirectory: URL,
                     refreshTicket: ITunesRefreshCoordinator.Ticket? = nil,
                     sourceDatabase: URL? = nil,
                     drafts: DraftStore,
                     shareRoot: URL? = nil,
                     progress: @Sendable (Stage) -> Void = { _ in },
                     source: LibrarySource = .live,
                     captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot = { RekordboxITunesReader.capture() }) throws -> LoadedLibrary {
        try loader(drafts: drafts, source: source).read(
            LoadLibrary.Request(snapshot: snapshot, commentPreset: commentPreset, refreshMusic: refreshITunes,
                                previousMusic: previousITunesSnapshot, fallbackDirectory: fallbackDirectory, ticket: refreshTicket,
                                sourceDatabase: sourceDatabase, shareRoot: shareRoot),
            progress: progress, capture: captureITunes)
    }

    /// 옛 `LoadedLibrary.loadITunes`와 같은 Music 결과 채택
    static func loadITunes(snapshot: URL, refreshITunes: Bool = false, captured: ITunesLibrarySnapshot? = nil,
                           previousITunesSnapshot: ITunesFallback? = nil, fallbackDirectory: URL,
                           refreshTicket: ITunesRefreshCoordinator.Ticket? = nil, sourceDatabase: URL? = nil,
                           captureITunes: @escaping @Sendable () -> ITunesLibrarySnapshot = { RekordboxITunesReader.capture() }) -> ITunesLibrarySnapshot {
        loader(drafts: .dataFolder()).readMusic(snapshot: snapshot, refreshMusic: refreshITunes, captured: captured,
                                                previous: previousITunesSnapshot, fallbackDirectory: fallbackDirectory,
                                                ticket: refreshTicket, sourceDatabase: sourceDatabase, capture: captureITunes)
    }

    private static func loader(drafts: DraftStore, source: LibrarySource = .live) -> LoadLibrary {
        LoadLibrary(source: source, music: .live(rekordboxDirectory: LibrarySnapshot.rekordboxDirectory), drafts: drafts, order: .shared,
                    snapshots: SnapshotTaker { _ in throw DJCError.snapshotNotFound }, usbSnapshots: .live)
    }
}

extension LibrarySource {
    /// 사본 DB를 열지 않는 실제 원본(시험): 사본 파일이 있으면 빈 라이브러리를 돌려준다. 스냅샷 폴더·원본 변경·rekordbox 실행 확인은 실제 구현 그대로다.
    /// 사본 옆 파일(iTunes 목록 사본·`playlists3.sync`)만 보는 시험이 쓴다(앱 시험이 암호화 DB를 덜 열게, adv4 T3).
    static var withoutDatabase: LibrarySource {
        var source = LibrarySource.live
        source.library = { snapshot in
            guard FileManager.default.fileExists(atPath: snapshot.path) else { throw DJCError.snapshotNotFound }
            return RekordboxLibrary(allTracks: [], cues: [], playCounts: [:])
        }
        source.tempoChanges = { tracks, _ in tracks.map { _ in [] } }
        source.grid = { _, _ in nil }
        source.log = { _ in }
        return source
    }
}

extension TemporaryFolder {
    var database: URL { url.appending(path: "master.db") }
    var backups: URL { url.appending(path: "backups") }

    /// 빈 `master.db`가 든 임시 폴더. `.withoutDatabase`처럼 DB를 열지 않고 경로·사본 옆 파일만 쓰는 시험이 쓴다.
    static func withEmptyDatabase() throws -> TemporaryFolder {
        let folder = try TemporaryFolder()
        try Data().write(to: folder.database)
        return folder
    }
}
