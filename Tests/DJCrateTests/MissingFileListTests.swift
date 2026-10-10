@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import Testing

/// 파일이 없는 곡 모아 보기(#126): 라이브러리를 읽은 뒤 메인 스레드 밖에서 파일을 확인해 필터·개수·행에 반영한다.
/// 확인은 곡 행을 바꾸는 라이브러리 전체의 일이라 핵심이 한다. 목록 아래 막대 화면 모델이 없는 저장소도 읽은 뒤 확인한다(#254).
@Suite("파일이 없는 곡 목록")
@MainActor
struct MissingFileListTests {
    /// 파일 확인이 어느 스레드에서 불렸는지 적는다(메인 스레드를 막지 않는지 본다).
    final class ThreadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var main = 0, total = 0
        func record() { lock.lock(); total += 1; if Thread.isMainThread { main += 1 }; lock.unlock() }
        var counts: (main: Int, total: Int) { lock.lock(); defer { lock.unlock() }; return (main, total) }
    }

    /// 101 있음, 102 지운 음원, 103 스트리밍, 104 연결되지 않은 외장 디스크
    func fixture() throws -> (RekordboxFixture, deleted: URL, volume: String) {
        let fixture = try RekordboxFixture()
        let deleted = fixture.audio.appending(path: "deleted.mp3")
        let volume = "/Volumes/DJC 시험 디스크 \(UUID().uuidString)"
        try fixture.add(TrackSpec(id: "101"))
        var gone = TrackSpec(id: "102"); gone.folderPath = deleted.path
        try fixture.add(gone)
        var streaming = TrackSpec(id: "103"); streaming.folderPath = "apple-music:103"
        try fixture.add(streaming)
        var external = TrackSpec(id: "104"); external.folderPath = "\(volume)/Music/external.mp3"
        try fixture.add(external)
        return (fixture, deleted, volume)
    }

    func store(_ fixture: RekordboxFixture, log: ThreadLog) -> LibraryStore {
        LibraryStore.test(resultHistory: WriteResultHistory(url: fixture.root.appending(path: "result.json")), saveTagDrafts: { _ in },
                          ports: { ports in
                              ports.files.exists = { path in
                                  log.record()
                                  return FileManager.default.fileExists(atPath: path)
                              }
                          })
    }

    @Test func 읽은_뒤_메인_스레드_밖에서_확인해_필터와_행에_반영한다() async throws {
        let (fixture, _, volume) = try fixture()
        let log = ThreadLog()
        let store = store(fixture, log: log)
        await store.load(snapshot: fixture.database)
        await store.missingFileTask?.value
        #expect(store.count(.missingFile) == 2)
        #expect(Set(store.rows.filter(\.fileMissing).map(\.track.id)) == ["102", "104"])
        #expect(store.missingFiles.unmountedVolumes == [.init(path: volume, trackCount: 1)])
        #expect(!store.isCheckingFiles)
        #expect(log.counts.total > 0 && log.counts.main == 0)
        store.sidebar = .filter(.missingFile)
        #expect(Set(store.displayRows.map(\.track.id)) == ["102", "104"])
        #expect(store.rowsByID["102"]?.fileMissing == true)
    }

    @Test func 다시_읽는_동안에는_지난_결과를_보이고_확인이_끝나면_바꾼다() async throws {
        let (fixture, deleted, _) = try fixture()
        let store = store(fixture, log: ThreadLog())
        await store.load(snapshot: fixture.database)
        await store.missingFileTask?.value
        store.sidebar = .filter(.missingFile)
        // 음원을 되돌려 놓고 다시 읽는다. 확인은 메인 액터를 놓은 뒤에 반영되므로 지금은 지난 결과(캐시)가 보인다.
        try Data("x".utf8).write(to: deleted)
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(store.isCheckingFiles)
        #expect(store.count(.missingFile) == 2)
        #expect(Set(store.displayRows.map(\.track.id)) == ["102", "104"])
        await store.missingFileTask?.value
        #expect(!store.isCheckingFiles)
        #expect(store.count(.missingFile) == 1)
        #expect(store.displayRows.map(\.track.id) == ["104"])
        // 다시 확인(디스크 연결·빼기, 작업 줄 버튼)도 같은 길로 반영한다.
        try FileManager.default.removeItem(at: deleted)
        store.checkMissingFiles()
        await store.missingFileTask?.value
        #expect(store.count(.missingFile) == 2)
    }

    @Test func 새로_읽기_시작하면_늦게_끝난_확인은_버린다() async throws {
        let (fixture, _, _) = try fixture()
        let store = store(fixture, log: ThreadLog())
        await store.load(snapshot: fixture.database)
        let stale = store.missingFileTask
        store.invalidatePendingLoads()
        await stale?.value
        #expect(store.count(.missingFile) == 0)
        #expect(store.rows.filter(\.fileMissing).isEmpty)
    }

    @Test func 파일이_없는_곡은_제목_앞에_경고_아이콘을_붙인다() throws {
        var missing = TrackListTagEditTests.row("2")
        missing.fileMissing = true
        let (coordinator, table) = TrackListPolishTests.table(columns: ["title"], rows: [TrackListTagEditTests.row("1"), missing])
        let column = try #require(table.tableColumns.first)
        let present = try #require(coordinator.tableView(table, viewFor: column, row: 0) as? TrackTextCell)
        #expect(present.leadingSymbol == nil)
        let cell = try #require(coordinator.tableView(table, viewFor: column, row: 1) as? TrackTextCell)
        #expect(cell.leadingSymbol == WarningMark.symbol)
        #expect(cell.label.textColor == .secondaryLabelColor)
        #expect(cell.text == "곡 2")
        #expect(cell.symbolTint == UIColors.warning.nsColor)
    }
}
