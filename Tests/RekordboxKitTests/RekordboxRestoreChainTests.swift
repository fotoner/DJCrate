import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 가장 최근이 아닌 백업으로 복원(#222): 그 뒤 쓰기들이 바꾼 분석 파일도 고른 백업 시점으로 맞춘다.
/// 백업은 그 쓰기가 바꾸는 파일만 담으므로, 뒤 백업들을 최신부터 차례로 되돌린 결과와 같아야 한다.
@Suite("rekordbox 연쇄 복원")
struct RekordboxRestoreChainTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    /// 128 BPM 분석 파일(.DAT·.EXT)이 있는 곡
    func gridTrack(_ fixture: RekordboxFixture, title: String, dataStatus: Int = 256) throws -> TrackSpec {
        let uuid = UUID().uuidString.lowercased()
        var track = TrackSpec(uuid: uuid)
        track.title = title
        track.dataStatus = dataStatus
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

    /// 곡의 분석 파일 두 개(없으면 nil)
    func files(_ fixture: RekordboxFixture, _ track: TrackSpec) -> [Data?] {
        ["DAT", "EXT"].map { try? Data(contentsOf: fixture.analysisURL(for: track, ext: $0)) }
    }

    func bpm(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> String? {
        try fixture.rows("SELECT BPM FROM djmdContent WHERE ID = ?", [.text(track.id)]).first?["BPM"]
    }

    @Test func 첫_백업으로_복원하면_두_번째_쓰기가_바꾼_다른_곡의_분석_파일도_돌아온다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try gridTrack(fixture, title: "곡 X"), y = try gridTrack(fixture, title: "곡 Y")
        let originalX = files(fixture, x), originalY = files(fixture, y)
        let bpmY = try bpm(fixture, y)
        let first = try writeBPM(fixture, x, 131, at: now)
        _ = try writeBPM(fixture, y, 132, at: now.addingTimeInterval(10))
        #expect(files(fixture, y) != originalY)

        let saved = try RekordboxWriter.restore(first, to: fixture.database, now: now.addingTimeInterval(20), backups: fixture.backups)
        #expect(files(fixture, x) == originalX)
        #expect(files(fixture, y) == originalY, "두 번째 쓰기가 바꾼 곡도 첫 백업 시점으로")
        #expect(try bpm(fixture, y) == bpmY)

        // 복원 직전 백업으로 되돌리면 두 쓰기 뒤 상태로
        _ = try RekordboxWriter.restore(saved, to: fixture.database, now: now.addingTimeInterval(30), backups: fixture.backups)
        #expect(files(fixture, x) != originalX && files(fixture, y) != originalY)
    }

    @Test func 곡을_뺀_뒤_그_전_백업으로_복원하면_뺀_곡의_분석_파일도_돌아오고_되돌리면_다시_빠진다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        // 곡 빼기는 클라우드 동기화 전 곡(rb_data_status 0)으로만 확인했다(#196).
        let x = try gridTrack(fixture, title: "곡 X"), gone = try gridTrack(fixture, title: "뺄 곡", dataStatus: 0)
        let originalGone = files(fixture, gone)
        // 같은 초에 쓰고 빼도(이름 끝 -write·-delete) 뜬 순서대로 되돌린다.
        let first = try writeBPM(fixture, x, 131, at: now)
        let deleted = try RekordboxTrackWriter.delete(contentIDs: [gone.id], from: fixture.database, shareRoot: fixture.shareRoot,
                                                      dryRun: false, now: now, backups: fixture.backups)
        #expect(deleted.deleted.first?.written == true && files(fixture, gone) == [nil, nil])

        let saved = try RekordboxWriter.restore(first, to: fixture.database, now: now.addingTimeInterval(20), backups: fixture.backups)
        #expect(try fixture.rows("SELECT ID FROM djmdContent WHERE ID = ?", [.text(gone.id)]).count == 1)
        #expect(files(fixture, gone) == originalGone, "DB에 돌아온 곡의 분석 파일도 돌아온다")

        _ = try RekordboxWriter.restore(saved, to: fixture.database, now: now.addingTimeInterval(30), backups: fixture.backups)
        #expect(try fixture.rows("SELECT ID FROM djmdContent WHERE ID = ?", [.text(gone.id)]).isEmpty)
        #expect(files(fixture, gone) == [nil, nil], "복원이 되살린 파일은 복원을 되돌리면 지운다")
    }

    @Test func 복원한_뒤_그보다_옛_백업으로_복원해도_시점이_맞는다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try gridTrack(fixture, title: "곡 X"), y = try gridTrack(fixture, title: "곡 Y"), z = try gridTrack(fixture, title: "곡 Z")
        let originalY = files(fixture, y), originalZ = files(fixture, z)
        let first = try writeBPM(fixture, x, 131, at: now)
        let afterFirstX = files(fixture, x)
        let second = try writeBPM(fixture, y, 132, at: now.addingTimeInterval(10))
        _ = try writeBPM(fixture, z, 133, at: now.addingTimeInterval(20))
        // 첫 쓰기 전으로 → 복원 직전 백업이 생긴다. 그 뒤 두 번째 백업(첫 쓰기 뒤 상태)으로 복원한다.
        _ = try RekordboxWriter.restore(first, to: fixture.database, now: now.addingTimeInterval(30), backups: fixture.backups)
        _ = try RekordboxWriter.restore(second, to: fixture.database, now: now.addingTimeInterval(40), backups: fixture.backups)
        #expect(files(fixture, x) == afterFirstX, "첫 쓰기만 한 시점")
        #expect(files(fixture, y) == originalY && files(fixture, z) == originalZ)
    }

    @Test func 뒤_백업을_되돌릴_수_없으면_아무것도_바꾸지_않고_그_백업을_알린다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try gridTrack(fixture, title: "곡 X"), y = try gridTrack(fixture, title: "곡 Y")
        let first = try writeBPM(fixture, x, 131, at: now)
        let second = try writeBPM(fixture, y, 132, at: now.addingTimeInterval(10))
        try Data("{".utf8).write(to: second.appending(path: "anlz/manifest.json"))
        let before = (files(fixture, x), files(fixture, y), try fixture.rows("SELECT ID, BPM FROM djmdContent ORDER BY ID"))
        let count = try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path).count

        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.restore(first, to: fixture.database, now: now.addingTimeInterval(20), backups: fixture.backups)
        }
        #expect(error.description.contains(second.lastPathComponent))
        #expect((files(fixture, x), files(fixture, y)) == (before.0, before.1))
        #expect(try fixture.rows("SELECT ID, BPM FROM djmdContent ORDER BY ID") == before.2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path).count == count, "복원 직전 백업도 만들지 않는다")
    }

    @Test func 되돌리다_실패하면_복원_전_상태로_돌린다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try gridTrack(fixture, title: "곡 X"), y = try gridTrack(fixture, title: "곡 Y")
        let first = try writeBPM(fixture, x, 131, at: now)
        _ = try writeBPM(fixture, y, 132, at: now.addingTimeInterval(10))
        let before = (files(fixture, x), files(fixture, y), try fixture.rows("SELECT ID, BPM FROM djmdContent ORDER BY ID"))
        // 곡 X 폴더를 잠가 마지막 단계(첫 백업의 X 파일)에서 실패하게 한다. 앞 단계는 곡 Y를 이미 되돌렸다.
        let folder = fixture.analysisURL(for: x).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        #expect(throws: (any Error).self) {
            try RekordboxWriter.restore(first, to: fixture.database, now: now.addingTimeInterval(20), backups: fixture.backups)
        }
        #expect((files(fixture, x), files(fixture, y)) == (before.0, before.1), "곡 Y도 두 쓰기 뒤 상태로 돌아온다")
        #expect(try fixture.rows("SELECT ID, BPM FROM djmdContent ORDER BY ID") == before.2)
    }

    @Test func 뒤에_뜬_백업을_최신부터_센다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try gridTrack(fixture, title: "곡 X"), y = try gridTrack(fixture, title: "곡 Y")
        let first = try writeBPM(fixture, x, 131, at: now)
        let second = try writeBPM(fixture, y, 132, at: now)
        #expect(try RekordboxWriter.laterBackups(than: first, in: fixture.backups).map(\.lastPathComponent) == [second.lastPathComponent])
        #expect(try RekordboxWriter.laterBackups(than: second, in: fixture.backups).isEmpty)
    }
}
