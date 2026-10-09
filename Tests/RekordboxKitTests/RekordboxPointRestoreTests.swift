import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 시점 스냅샷으로 복원(#225)과 차이 요약. 합성 사본(`RekordboxFixture`·`AnlzBuilder`)으로만 한다.
/// 두 번 이상 쓴 뒤 가운데 시점으로 되돌려 DB·분석 파일·앨범아트가 같은 시점을 가리키는지 본다.
@Suite("시점 스냅샷 복원")
struct RekordboxPointRestoreTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    /// 128 BPM 분석 파일(.DAT·.EXT)이 있는 곡
    func gridTrack(_ fixture: RekordboxFixture, title: String) throws -> TrackSpec {
        let uuid = UUID().uuidString.lowercased()
        var track = TrackSpec(uuid: uuid)
        track.title = title
        track.fileType = 11
        track.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio, name: "\(uuid).wav").path
        track.analysisDataPath = "/PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))/ANLZ0000.DAT"
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 128, first: 500.3, count: 126)
        let dat = AnlzBuilder.dat(beats: beats)
        try fixture.putAnalysis(for: track, dat: dat, ext: AnlzBuilder.ext(beats: beats))
        try fixture.addContentFile(for: track, hash: Insecure.MD5.hash(data: dat).map { String(format: "%02x", $0) }.joined(), size: dat.count)
        return track
    }

    func writeBPM(_ fixture: RekordboxFixture, _ track: TrackSpec, _ bpm: Double, at time: Date) throws -> URL {
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
        grid.setBPM(bpm, at: 0)
        let report = try RekordboxWriter.write(drafts: [], grids: [grid], to: fixture.database, dryRun: false, now: time,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        return URL(filePath: try #require(report.backup))
    }

    var snapshots: (RekordboxFixture) -> URL { { $0.root.appending(path: "point-snapshots") } }

    func snapshot(_ fixture: RekordboxFixture, _ name: String, at time: Date) throws -> RekordboxPointSnapshot.Entry {
        try RekordboxPointSnapshot.create(name: name, database: fixture.database, shareRoot: nil, in: snapshots(fixture), autoDays: 7,
                                          now: time, guard: Self.copyGuard)
    }

    func restore(_ fixture: RekordboxFixture, _ entry: RekordboxPointSnapshot.Entry, at time: Date,
                 guard writeGuard: RekordboxWriteGuard = copyGuard) throws -> RekordboxWriter.PointRestoreReport {
        try RekordboxWriter.restore(pointSnapshot: entry.url, to: fixture.database, shareRoot: nil, snapshots: snapshots(fixture),
                                    backups: fixture.backups, autoDays: 7, now: time, guard: writeGuard)
    }

    /// 분석·앨범아트 폴더 전체(상대 경로 → 내용)
    func shareFiles(_ fixture: RekordboxFixture) -> [String: Data] {
        var files: [String: Data] = [:]
        let root = fixture.shareRoot.standardizedFileURL.resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            files[String(path.dropFirst(root.path.count))] = try? Data(contentsOf: url)
        }
        return files
    }

    func bpm(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> String? {
        try fixture.rows("SELECT BPM FROM djmdContent WHERE ID = ?", [.text(track.id)]).first?["BPM"]
    }

    func artwork(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> URL {
        let folder = fixture.shareRoot.appending(path: "PIONEER/Artwork/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "artwork.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: file)
        return file
    }

    @Test func 두_번_쓴_뒤_가운데_시점으로_복원하면_DB·분석_파일·앨범아트가_그_시점이고_복원_직전으로_다시_돌아간다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try gridTrack(fixture, title: "곡 X"), y = try gridTrack(fixture, title: "곡 Y")
        try Data("<xml 0/>".utf8).write(to: fixture.root.appending(path: "masterPlaylists6.xml"))
        _ = try writeBPM(fixture, x, 131, at: now)
        let middle = try snapshot(fixture, "가운데", at: now.addingTimeInterval(10))
        let middleFiles = shareFiles(fixture), middleDB = try Data(contentsOf: fixture.database)
        let middleBPM = (try bpm(fixture, x), try bpm(fixture, y))
        // 가운데 시점 뒤: 다른 곡 그리드, 앨범아트, 재생 목록 파일
        _ = try writeBPM(fixture, y, 140, at: now.addingTimeInterval(20))
        _ = try artwork(fixture, x)
        try Data("<xml 2/>".utf8).write(to: fixture.root.appending(path: "masterPlaylists6.xml"))
        let afterFiles = shareFiles(fixture), afterDB = try Data(contentsOf: fixture.database)
        #expect(afterFiles != middleFiles)

        let report = try restore(fixture, middle, at: now.addingTimeInterval(30))
        #expect(shareFiles(fixture) == middleFiles, "분석·앨범아트가 가운데 시점으로(나중에 넣은 그림은 지움)")
        #expect(try Data(contentsOf: fixture.database) == middleDB)
        #expect(try (bpm(fixture, x), bpm(fixture, y)) == middleBPM)
        #expect(try String(contentsOf: fixture.root.appending(path: "masterPlaylists6.xml"), encoding: .utf8) == "<xml 0/>")
        #expect(report.beforeRestore.metadata.kind == .beforeRestore)
        #expect(report.beforeRestore.metadata.restoredFrom == "가운데")
        // 그 시점에 없던 앨범아트 폴더는 없어지고, 옆에 남긴 임시 폴더도 없다
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.shareRoot.appending(path: "PIONEER").path)
        #expect(leftovers.sorted() == ["USBANLZ"])

        // 복원 직전 스냅샷으로 다시 복원하면 두 번째 쓰기 뒤로
        _ = try restore(fixture, report.beforeRestore, at: now.addingTimeInterval(40))
        #expect(shareFiles(fixture) == afterFiles)
        #expect(try Data(contentsOf: fixture.database) == afterDB)
        #expect(try String(contentsOf: fixture.root.appending(path: "masterPlaylists6.xml"), encoding: .utf8) == "<xml 2/>")
    }

    @Test func rekordbox가_켜져_있으면_아무것도_바꾸지_않고_복원_직전_스냅샷도_남기지_않는다() throws {
        let fixture = try RekordboxFixture()
        let x = try gridTrack(fixture, title: "곡 X")
        let entry = try snapshot(fixture, "전", at: now)
        _ = try writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        let files = shareFiles(fixture), db = try Data(contentsOf: fixture.database)
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        #expect(throws: DJCError.self) { try restore(fixture, entry, at: now.addingTimeInterval(20), guard: running) }
        #expect(try shareFiles(fixture) == files && Data(contentsOf: fixture.database) == db)
        #expect(RekordboxPointSnapshot.list(in: snapshots(fixture)).count == 1)
    }

    @Test func 다른_라이브러리의_스냅샷은_거부한다() throws {
        let fixture = try RekordboxFixture()
        let entry = try snapshot(fixture, "전", at: now)
        try fixture.execute("UPDATE djmdProperty SET DBID = '999'")
        let db = try Data(contentsOf: fixture.database)
        #expect(throws: DJCError.self) { try restore(fixture, entry, at: now.addingTimeInterval(10)) }
        #expect(try Data(contentsOf: fixture.database) == db)
        #expect(RekordboxPointSnapshot.list(in: snapshots(fixture)).count == 1)
    }

    @Test func 망가진_스냅샷은_바꾸기_전에_거부한다() throws {
        let fixture = try RekordboxFixture()
        let x = try gridTrack(fixture, title: "곡 X")
        let damagedDB = try snapshot(fixture, "DB 망가짐", at: now)
        try Data("not a database".utf8).write(to: damagedDB.url.appending(path: "master.db"))
        let missingFolder = try snapshot(fixture, "폴더 없음", at: now.addingTimeInterval(1))
        try FileManager.default.removeItem(at: missingFolder.url.appending(path: "share/PIONEER/USBANLZ"))
        let linked = try snapshot(fixture, "링크", at: now.addingTimeInterval(2))
        let anlz = linked.url.appending(path: "share/PIONEER/USBANLZ/\(x.uuid.prefix(3))/\(x.uuid.dropFirst(3))/ANLZ0000.2EX")
        try FileManager.default.createSymbolicLink(at: anlz, withDestinationURL: URL(filePath: "/etc/hosts"))
        let noInfo = try snapshot(fixture, "정보 없음", at: now.addingTimeInterval(3))
        try FileManager.default.removeItem(at: noInfo.url.appending(path: "snapshot.json"))
        let files = shareFiles(fixture), db = try Data(contentsOf: fixture.database)
        for entry in [damagedDB, missingFolder, linked, noInfo] {
            #expect(throws: DJCError.self, "\(entry.metadata.name)") { try restore(fixture, entry, at: now.addingTimeInterval(10)) }
        }
        #expect(try shareFiles(fixture) == files && Data(contentsOf: fixture.database) == db)
        #expect(!RekordboxPointSnapshot.list(in: snapshots(fixture)).contains { $0.metadata.kind == .beforeRestore })
    }

    @Test func 검증이_실패하면_DB·폴더·재생_목록_파일을_복원_전으로_돌리고_표시를_지운다() throws {
        let fixture = try RekordboxFixture()
        let x = try gridTrack(fixture, title: "곡 X")
        try Data("<xml 0/>".utf8).write(to: fixture.root.appending(path: "masterPlaylists6.xml"))
        let entry = try snapshot(fixture, "전", at: now)
        _ = try writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        _ = try artwork(fixture, x)
        try Data("<xml 1/>".utf8).write(to: fixture.root.appending(path: "masterPlaylists6.xml"))
        // 정보의 라이브러리 ID를 어긋나게 해 바꾼 뒤 검증에서 실패시킨다
        var metadata = try #require(RekordboxPointSnapshot.metadata(in: entry.url))
        metadata.libraryID = "다른 라이브러리"
        try RekordboxPointSnapshot.save(metadata, in: entry.url)
        let files = shareFiles(fixture), db = try Data(contentsOf: fixture.database)
        #expect(throws: DJCError.self) { try restore(fixture, entry, at: now.addingTimeInterval(20)) }
        #expect(shareFiles(fixture) == files)
        #expect(try Data(contentsOf: fixture.database) == db)
        #expect(try String(contentsOf: fixture.root.appending(path: "masterPlaylists6.xml"), encoding: .utf8) == "<xml 1/>")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.shareRoot.appending(path: "PIONEER").path)
        #expect(leftovers.sorted() == ["Artwork", "USBANLZ"])
        let markers = try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path).filter { $0.contains("point-restore") }
        #expect(markers.isEmpty)
    }

    @Test func 시점_복원_뒤에는_그_전_쓰기_전_백업으로_되돌리지_않고_그_뒤_백업은_되돌린다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try gridTrack(fixture, title: "곡 X"), y = try gridTrack(fixture, title: "곡 Y")
        let entry = try snapshot(fixture, "처음", at: now)
        let first = try writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        _ = try restore(fixture, entry, at: now.addingTimeInterval(20))
        let files = shareFiles(fixture), db = try Data(contentsOf: fixture.database)
        #expect(RekordboxWriter.pointRestoreRefusal(after: first, in: fixture.backups) != nil)
        #expect(throws: DJCError.self) { try RekordboxWriter.restore(first, to: fixture.database, now: now.addingTimeInterval(30), backups: fixture.backups) }
        #expect(try shareFiles(fixture) == files && Data(contentsOf: fixture.database) == db, "거부하면 아무것도 바꾸지 않는다")
        #expect(!RekordboxWriter.backups(in: fixture.backups).contains { !$0.isWrite }, "복원 직전 백업도 만들지 않는다")

        // 시점 복원 뒤의 쓰기는 평소처럼 되돌린다
        let originalY = shareFiles(fixture)
        let later = try writeBPM(fixture, y, 140, at: now.addingTimeInterval(40))
        #expect(RekordboxWriter.pointRestoreRefusal(after: later, in: fixture.backups) == nil)
        _ = try RekordboxWriter.restore(later, to: fixture.database, now: now.addingTimeInterval(50), backups: fixture.backups)
        #expect(shareFiles(fixture) == originalY)
    }

    @Test func 복원_직전_스냅샷은_세_개만_남기고_수동_스냅샷은_밀어내지_않는다() throws {
        let fixture = try RekordboxFixture()
        let manual = try snapshot(fixture, "수동", at: now)
        for index in 1...5 { _ = try restore(fixture, manual, at: now.addingTimeInterval(Double(index) * 10)) }
        let list = RekordboxPointSnapshot.list(in: snapshots(fixture))
        #expect(list.filter { $0.metadata.kind == .beforeRestore }.count == 3)
        #expect(list.contains { $0.id == manual.id })
    }

    @Test func 시험_프로세스는_실제_rekordbox_라이브러리로_복원하지_않는다() throws {
        let fixture = try RekordboxFixture()
        let entry = try snapshot(fixture, "전", at: now)
        let real = LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")
        #expect(throws: DJCError.self) {
            try RekordboxWriter.restore(pointSnapshot: entry.url, to: real, shareRoot: nil, snapshots: snapshots(fixture), backups: fixture.backups,
                                        autoDays: 7, now: now, guard: Self.copyGuard)
        }
        #expect(throws: DJCError.self) {
            try RekordboxPointSnapshotDiff.compare(entry, database: real, shareRoot: nil, guard: Self.copyGuard)
        }
    }

    @Test func 차이_요약은_곡·큐·그리드·태그·재생_목록·파일을_복원_방향으로_센다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try gridTrack(fixture, title: "곡 X"), gone = try gridTrack(fixture, title: "뺄 곡")
        try fixture.add(PlaylistSpec(id: "1001", name: "목록 A", seq: 1, contentIDs: [x.id]))
        let entry = try snapshot(fixture, "전", at: now)
        #expect(try RekordboxPointSnapshotDiff.compare(entry, database: fixture.database, shareRoot: nil, guard: Self.copyGuard).isEmpty)

        _ = try writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        try fixture.execute("UPDATE djmdContent SET Title = '곡 X 고침' WHERE ID = ?", [.text(x.id)])
        var added = TrackSpec()
        added.title = "새 곡"
        try fixture.add(added)
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = ?", [.text(gone.id)])
        try FileManager.default.removeItem(at: fixture.analysisURL(for: gone, ext: "EXT"))
        try fixture.add(PlaylistSpec(id: "1002", name: "목록 B", seq: 2, contentIDs: []))
        try fixture.execute("UPDATE djmdPlaylist SET Name = '목록 A2' WHERE ID = '1001'")
        _ = try artwork(fixture, x)

        let diff = try RekordboxPointSnapshotDiff.compare(entry, database: fixture.database, shareRoot: nil, guard: Self.copyGuard)
        #expect(diff.tracksRemoved == ["새 곡"])
        #expect(diff.tracksRestored == ["뺄 곡"])
        #expect(diff.gridsChanged == ["곡 X 고침"])
        #expect(diff.tagsChanged == ["곡 X 고침"])
        #expect(diff.playlistsRemoved == ["목록 B"] && diff.playlistsChanged == ["목록 A2"] && diff.playlistsRestored.isEmpty)
        #expect(diff.analysisFiles.changed == 2, "곡 X의 .DAT·.EXT")
        #expect(diff.analysisFiles.restored == 1, "뺄 곡의 .EXT")
        #expect(diff.artworkFiles.removed == 1)
        #expect(diff.changedTrackUUIDs.isSuperset(of: [x.uuid, gone.uuid, added.uuid]))
        #expect(diff.summary.count == 7)
        #expect(!diff.cloudSyncedSince(entry))
        // 읽기만 했다: 스냅샷 폴더에 곁 파일이 생기지 않는다
        #expect(!FileManager.default.fileExists(atPath: entry.url.appending(path: "master.db-shm").path))
    }

    @Test func 스냅샷_뒤_클라우드_동기화_카운터가_늘었으면_알린다() throws {
        let fixture = try RekordboxFixture()
        try fixture.execute("INSERT INTO agentRegistry (registry_id, int_1, created_at, updated_at) VALUES ('lastUpdateCount', 100, ?, ?)",
                            [.text("2026-01-01 00:00:00.000 +00:00"), .text("2026-01-01 00:00:00.000 +00:00")])
        let entry = try snapshot(fixture, "전", at: now)
        #expect(entry.metadata.cloudUpdateCount == 100)
        try fixture.execute("UPDATE agentRegistry SET int_1 = 150 WHERE registry_id = 'lastUpdateCount'")
        let diff = try RekordboxPointSnapshotDiff.compare(entry, database: fixture.database, shareRoot: nil, guard: Self.copyGuard)
        #expect(diff.cloudSyncedSince(entry))
    }
}
