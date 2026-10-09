import DJCDomain
import DJCEnvironment
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// #182: 시험이 실제 rekordbox 라이브러리를 쓰지 못하게 하는 장치. 실제 폴더는 경로 판단에만 쓰고 절대 쓰지 않는다.
@Suite("시험 프로세스의 실제 라이브러리 보호")
struct RealLibraryProtectionTests {
    let checked = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    @Test func 시험_프로세스를_알아본다() {
        #expect(TestProcess.isRunning)
    }

    @Test func 기본_rekordbox_폴더와_데이터_폴더는_실제_폴더를_가리키지_않는다() {
        let real = LibrarySnapshot.realRekordboxDirectory.standardizedFileURL.path
        #expect(LibrarySnapshot.rekordboxDirectory(in: [:]).standardizedFileURL.path != real)
        #expect(!RekordboxWriter.liveDatabase.standardizedFileURL.path.hasPrefix(real + "/"))
        #expect(!DJCIdentity.supportDirectory.path.hasPrefix(URL.applicationSupportDirectory.path))
    }

    /// 주입한 관문이 라이브가 아니라고 해도 실제 폴더 안의 DB·share는 대상에서 거부한다(경로만 본다).
    @Test func 실제_폴더는_관문을_바꿔도_쓰기_대상에서_거부한다() throws {
        let real = LibrarySnapshot.realRekordboxDirectory
        let copy = try RekordboxFixture()
        #expect(throws: DJCError.self) { _ = try checked.resolveShareRoot(real.appending(path: "master.db"), shareRoot: nil) }
        #expect(throws: DJCError.self) { _ = try checked.resolveShareRoot(copy.database, shareRoot: real.appending(path: "share")) }
        #expect(throws: DJCError.self) { _ = try checked.checkTargets(real.appending(path: "master.db"), shareRoot: nil, dryRun: true) }
    }

    /// 쓰기·복원 입구마다 막히는지는 실제 폴더 대신 보호 폴더로 준 합성 사본으로 본다.
    @Test func 쓰기와_복원_입구는_보호_폴더를_모두_거부한다() throws {
        let fixture = try RekordboxFixture()
        let spec = try fixture.add(TrackSpec())
        let source = try RekordboxFixture()
        try source.add(spec)
        var draft = CueDraft(trackUUID: spec.uuid)
        draft.place(EditableCue(kind: .memory, time: 4))
        _ = try RekordboxWriter.write(drafts: [draft], to: source.database, dryRun: false, backups: source.backups,
                                      shareRoot: source.shareRoot, guard: checked)
        let backup = try #require(RekordboxWriter.backups(in: source.backups).first)

        let protected = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" },
                                            protectedInTests: [fixture.root])
        let before = try Data(contentsOf: fixture.database)
        #expect(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [draft], to: fixture.database, dryRun: false, backups: fixture.backups,
                                      shareRoot: fixture.shareRoot, guard: protected)
        }
        #expect(throws: DJCError.self) {
            try RekordboxWriter.restore(backup.url, to: fixture.database, backups: fixture.backups, guard: protected)
        }
        #expect(throws: DJCError.self) {
            try RekordboxTrackWriter.delete(contentIDs: [spec.id], from: fixture.database, shareRoot: fixture.shareRoot,
                                            dryRun: false, backups: fixture.backups, guard: protected)
        }
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }

    /// 시험 백업이 실제 라이브러리로 되돌려진 사고(#182)는 라이브러리 ID가 달랐다. 다른 라이브러리의 백업은 되돌리지 않는다.
    @Test func 다른_라이브러리의_백업은_되돌리지_않는다() throws {
        let source = try RekordboxFixture()
        let spec = try source.add(TrackSpec())
        var draft = CueDraft(trackUUID: spec.uuid)
        draft.place(EditableCue(kind: .memory, time: 4))
        _ = try RekordboxWriter.write(drafts: [draft], to: source.database, dryRun: false, backups: source.backups,
                                      shareRoot: source.shareRoot, guard: checked)
        let backup = try #require(RekordboxWriter.backups(in: source.backups).first)
        let other = try RekordboxFixture()
        try other.add(spec)
        try other.execute("UPDATE djmdProperty SET DBID = '2'")
        let before = try Data(contentsOf: other.database)
        #expect(throws: DJCError.self) {
            try RekordboxWriter.restore(backup.url, to: other.database, backups: other.backups, guard: checked, shareRoot: other.shareRoot)
        }
        #expect(try Data(contentsOf: other.database) == before)
        #expect(RekordboxWriter.backups(in: other.backups).isEmpty)
        // 같은 라이브러리의 백업은 그대로 되돌린다.
        _ = try RekordboxWriter.restore(backup.url, to: source.database, backups: source.backups, guard: checked, shareRoot: source.shareRoot)
        #expect(try source.rows("SELECT count(*) AS n FROM djmdCue WHERE rb_local_deleted = 0").first?["n"] == "0")
    }
}
