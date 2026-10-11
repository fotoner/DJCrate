import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 쓰기 백업과 되돌리기: 백업 목록, 백업에 남긴 보고서·초안, 되돌리기 전 확인.
@Suite("rekordbox 백업·되돌리기")
struct RekordboxBackupTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    /// 확인 없이 바로 쓰므로(#210) 되돌릴 수 있는 쓰기 전 백업을 최근 20개까지 남긴다(사용자 결정 2026-10-07, #209).
    @Test func 쓰기_전_백업은_최근_20개를_남긴다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-prune-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 1...22 {
            let backup = folder.appending(path: String(format: "2026-10-07T00-00-%02d-write", index))
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try Data().write(to: backup.appending(path: "master.db"))
        }
        RekordboxWriter.prune(folder)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left.count == 20)
        #expect(left.first == "2026-10-07T00-00-03-write" && left.last == "2026-10-07T00-00-22-write")
    }

    /// 큐·그리드·게인을 한 번에 쓴다
    func writeAll(_ fixture: RekordboxFixture) throws -> (report: RekordboxWriter.Report, cue: CueDraft, grid: GridDraft, gain: String) {
        let (gridTrack, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = GridDraft(trackUUID: gridTrack.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: gridTrack)))
        grid.shift(by: 0.010)
        var cueTrack = TrackSpec()
        cueTrack.gain = (high: 16256, low: 0)   // 선형 1.0
        try fixture.add(cueTrack)
        var cue = CueDraft(trackUUID: cueTrack.uuid)
        cue.place(EditableCue(kind: .memory, time: 30))
        let report = try RekordboxWriter.write(drafts: [cue], grids: [grid], gains: [cueTrack.uuid: -3], to: fixture.database,
                                               dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot)
        return (report, cue, grid, cueTrack.uuid)
    }

    @Test func 쓰기_백업에는_보고서와_쓴_초안이_남아_되돌릴_때_살린다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 1000)
        let (report, cue, grid, gainUUID) = try writeAll(fixture)
        #expect(report.written.count == 1 && report.gridWritten.count == 1 && report.gainWritten.count == 1)

        let backups = RekordboxWriter.backups(in: fixture.backups)
        let backup = try #require(backups.first)
        let written = URL(filePath: try #require(report.backup)).lastPathComponent
        #expect(backups.count == 1 && backup.isWrite && backup.url.lastPathComponent == written)
        #expect(backup.report?.finalUpdateCount == report.finalUpdateCount && backup.titles == ["시험 곡"])
        #expect(RekordboxWriter.contents(of: backup.url).drafts.map(\.trackUUID) == [cue.trackUUID])
        #expect(RekordboxWriter.gridDrafts(in: backup.url).map(\.segments) == [grid.segments])
        #expect(RekordboxWriter.gainDrafts(in: backup.url) == [gainUUID: -3])
        // 쓴 뒤 rekordbox가 아무것도 안 바꿨으면 카운터가 보고서와 같다(되돌리기 경고 판단)
        #expect(try RekordboxWriter.updateCount(of: fixture.database) == report.finalUpdateCount)
    }

    @Test func 되돌리면_지금_상태를_따로_백업하고_목록_맨_앞에_둔다() throws {
        let fixture = try RekordboxFixture()
        let (report, _, _, _) = try writeAll(fixture)
        let saved = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database,
                                                now: now.addingTimeInterval(60), backups: fixture.backups)
        let list = RekordboxWriter.backups(in: fixture.backups)
        #expect(list.map(\.url.lastPathComponent) == [saved.lastPathComponent, URL(filePath: report.backup!).lastPathComponent])
        #expect(list.first?.isWrite == false, "되돌리기 직전 백업은 쓰기 백업이 아니다")
    }

    @Test func rekordbox가_켜져_있으면_되돌리지_않는다() throws {
        let fixture = try RekordboxFixture()
        let (report, _, _, _) = try writeAll(fixture)
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        let before = try fixture.rows("SELECT * FROM djmdCue")
        #expect(throws: DJCError.self) {
            try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database,
                                        backups: fixture.backups, guard: running)
        }
        #expect(try fixture.rows("SELECT * FROM djmdCue") == before)
        #expect(RekordboxWriter.backups(in: fixture.backups).count == 1, "되돌리기 직전 백업도 만들지 않는다")
    }

    @Test func 오토게인_행이_없거나_여럿이면_게인을_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        let none = try fixture.add(TrackSpec())
        var two = TrackSpec()
        two.gain = (high: 16256, low: 0)
        try fixture.add(two)
        try fixture.insert("djmdMixerParam", ["ID": .text("extra"), "ContentID": .text(two.id), "GainHigh": .int(16256),
                                              "GainLow": .int(0), "rb_local_deleted": .int(0)])
        let report = try RekordboxWriter.write(drafts: [], gains: [none.uuid: -1, two.uuid: -1], to: fixture.database,
                                               dryRun: false, now: now, backups: fixture.backups)
        let reasons = Dictionary(uniqueKeysWithValues: report.gainBlocked.map { ($0.trackUUID, $0.reason ?? "") })
        #expect(reasons[none.uuid]?.contains("분석 전") == true)
        #expect(reasons[two.uuid]?.contains("여럿") == true)
        #expect(report.gainWritten.isEmpty)
    }

    @Test func 설치된_rekordbox_버전은_가장_높은_판의_Info_plist에서() throws {
        let apps = FileManager.default.temporaryDirectory.appending(path: "djc-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: apps) }
        for (folder, version) in [("rekordbox 6", "6.8.5"), ("rekordbox 7", "7.2.18.0311")] {
            let contents = apps.appending(path: folder).appending(path: "rekordbox.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleShortVersionString": version] as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        }
        try FileManager.default.createDirectory(at: apps.appending(path: "Other.app"), withIntermediateDirectories: true)
        #expect(RekordboxCompatibility.installedAppVersion(applications: apps) == "7.2.18.0311")
        #expect(RekordboxCompatibility.installedAppVersion(applications: apps.appending(path: "없음")) == nil)
        #expect(throws: Never.self) { try RekordboxCompatibility.checkApp(version: "7.2.18.0311") }
        #expect(throws: DJCError.self) { try RekordboxCompatibility.checkApp(version: "6.8.5") }
        #expect(throws: DJCError.self) { try RekordboxCompatibility.checkApp(version: "7") }
    }
}
