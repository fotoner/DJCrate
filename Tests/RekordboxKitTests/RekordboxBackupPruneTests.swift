import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 백업 정리(#221): 백업을 만드는 모든 경로가 끝에 정리하고, 보존 개수는 쓰기 백업(-write·-add·-delete)으로만 센다.
/// 복원 직전 백업은 세지 않고, 남긴 가장 옛 쓰기 백업보다 옛 것만 지운다(연쇄 복원 #222가 사이의 백업을 모두 거쳐야 해서).
@Suite("rekordbox 백업 정리")
struct RekordboxBackupPruneTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    var keep: Int { RekordboxWriter.backupsToKeep }

    /// 옛 백업 폴더(정리는 master.db가 있는지만 본다). 이름의 시각은 2020년부터 분 단위로 늘린다.
    func oldBackups(_ fixture: RekordboxFixture, labels: [String]) throws -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let start = Date(timeIntervalSince1970: 1_577_836_800)
        return try labels.enumerated().map { index, label in
            let name = formatter.string(from: start.addingTimeInterval(Double(index) * 60)) + "-" + label
            let folder = fixture.backups.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "master.db"))
            return name
        }
    }

    func names(_ fixture: RekordboxFixture) -> [String] {
        RekordboxWriter.backups(in: fixture.backups).map(\.url.lastPathComponent)
    }

    func writes(_ fixture: RekordboxFixture) -> [String] {
        RekordboxWriter.backups(in: fixture.backups).filter(\.isWrite).map(\.url.lastPathComponent)
    }

    @Test func 복원_직전_백업은_세지_않고_남긴_가장_옛_쓰기보다_옛_것만_지운다() throws {
        let fixture = try RekordboxFixture()
        // 옛 것부터: 복원 직전 → 쓰기 → 복원 직전 → 쓰기 keep개
        let made = try oldBackups(fixture, labels: ["before-restore", "write", "before-restore"] + Array(repeating: "write", count: keep))
        RekordboxWriter.prune(fixture.backups)
        #expect(writes(fixture).count == keep, "쓰기 백업 keep개")
        #expect(Set(names(fixture)) == Set(made.dropFirst(3)), "남긴 가장 옛 쓰기보다 옛 백업(복원 직전 포함)은 지운다")
    }

    @Test func 쓰기가_보존_개수_안이면_복원_직전_백업이_많아도_지우지_않는다() throws {
        let fixture = try RekordboxFixture()
        let made = try oldBackups(fixture, labels: Array(repeating: "before-restore", count: keep + 2) + Array(repeating: "write", count: keep))
        RekordboxWriter.prune(fixture.backups)
        #expect(Set(names(fixture)) == Set(made))
    }

    @Test func 같은_초에_뜬_쓰기_백업도_쓰기로_센다() throws {
        let fixture = try RekordboxFixture()
        _ = try oldBackups(fixture, labels: ["write-2", "delete-3", "add"])
        #expect(writes(fixture).count == 3)
    }

    @Test func 곡_넣기도_끝에_정리한다() async throws {
        let fixture = try RekordboxFixture()
        var existing = TrackSpec()   // 곡 넣기는 기존 곡에서 기기 정보를 읽는다
        existing.folderPath = "/tmp/djc-prune-existing.mp3"
        try fixture.add(existing)
        _ = try oldBackups(fixture, labels: Array(repeating: "write", count: keep))
        let plan = try await RekordboxTrackWriterTests().plan("mp3-lame-cbr.mp3")
        let report = try RekordboxTrackWriter.add([plan], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        #expect(report.added.first?.written == true)
        let made = URL(filePath: try #require(report.backup)).lastPathComponent
        #expect(writes(fixture).count == keep && writes(fixture).first == made)
    }

    @Test func 곡_빼기도_끝에_정리한다() throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.dataStatus = 0
        let track = try fixture.add(spec)
        _ = try oldBackups(fixture, labels: Array(repeating: "write", count: keep))
        let report = try RekordboxTrackWriter.delete(contentIDs: [track.id], from: fixture.database, dryRun: false, now: now,
                                                     backups: fixture.backups)
        #expect(report.deleted.first?.written == true)
        let made = URL(filePath: try #require(report.backup)).lastPathComponent
        #expect(writes(fixture).count == keep && writes(fixture).first == made)
    }

    @Test func 복원도_끝에_정리하고_복원_직전_백업은_쓰기를_밀어내지_않는다() throws {
        let fixture = try RekordboxFixture()
        let old = try oldBackups(fixture, labels: ["write"] + Array(repeating: "write", count: keep - 1))
        var spec = TrackSpec()
        spec.gain = (high: 16256, low: 0)
        try fixture.add(spec)
        let report = try RekordboxWriter.write(drafts: [], gains: [spec.uuid: -3], to: fixture.database, dryRun: false, now: now,
                                               backups: fixture.backups)
        let backup = URL(filePath: try #require(report.backup))
        #expect(writes(fixture).count == keep && !names(fixture).contains(old[0]), "쓰기는 keep개")
        let saved = try RekordboxWriter.restore(backup, to: fixture.database, now: now.addingTimeInterval(60), backups: fixture.backups)
        #expect(writes(fixture).count == keep, "복원 직전 백업이 쓰기 백업을 밀어내지 않는다")
        #expect(names(fixture).first == saved.lastPathComponent)
        // 보존 개수를 넘긴 채 복원해도 복원이 끝에 정리한다
        _ = try oldBackups(fixture, labels: ["write"])
        _ = try RekordboxWriter.restore(saved, to: fixture.database, now: now.addingTimeInterval(120), backups: fixture.backups)
        #expect(writes(fixture).count == keep)
    }
}
