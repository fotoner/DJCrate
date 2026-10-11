import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// `djc snapshot-point`(#224): 합성 사본(`--db`) 옆 `point-snapshots/`에만 만든다.
@Suite("djc snapshot-point")
@MainActor
struct PointSnapshotCommandTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })
    /// 사본만 보는 가드로 만든 시점 스냅샷 파일·관문(실제 구현)
    static let files = PointSnapshotFiles.live(guard: copyGuard)
    static let gate = RekordboxWriteGate.live(guard: copyGuard)

    func run(_ fixture: RekordboxFixture, _ args: String...) async throws -> String {
        try await PointSnapshotCommand.run(["snapshot-point"] + args + ["--db", fixture.database.path], now: now, files: Self.files, gate: Self.gate)
    }

    @Test func 만들고_목록에서_보고_고정·풀기·지우기를_한다() async throws {
        let fixture = try RekordboxFixture()
        let created = try await run(fixture, "create", "--name", "정리 전")
        #expect(created.contains("2026-09-25T120000Z-manual"), "\(created)")
        let folder = fixture.root.appending(path: "point-snapshots")
        #expect(RekordboxPointSnapshot.list(in: folder).first?.metadata.name == "정리 전")

        let list = try await run(fixture, "list")
        #expect(list.contains("시점 스냅샷 1개") && list.contains("‘정리 전’") && list.contains("수동"), "\(list)")
        #expect(list.contains("쓰기 전 백업 0개"))

        await #expect(try await run(fixture, "pin", "정리 전").contains("고정했습니다"))
        await #expect(try await run(fixture, "list").contains("고정"))
        await #expect(throws: DJCError.self) { try await run(fixture, "delete", "2026-09-25T120000Z-manual") }
        await #expect(try await run(fixture, "unpin", "2026-09-25T120000Z-manual").contains("고정을 풀었습니다"))
        await #expect(try await run(fixture, "delete", "2026-09-25T120000Z-manual").contains("지웠습니다"))
        #expect(RekordboxPointSnapshot.list(in: folder).isEmpty)
    }

    @Test func 비교하고_복원하면_복원_전으로_돌리는_명령을_알린다() async throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "601")
        track.title = "원래 제목"
        try fixture.add(track)
        _ = try await run(fixture, "create", "--name", "전")
        await #expect(try await run(fixture, "diff", "전").contains("같습니다"))
        try fixture.execute("UPDATE djmdContent SET Title = '바꾼 제목' WHERE ID = '601'")
        let diff = try await run(fixture, "diff", "전")
        #expect(diff.contains("곡 정보가 바뀌는 곡 1") && diff.contains("• 바꾼 제목"), "\(diff)")
        let restored = try await run(fixture, "restore", "전")
        #expect(restored.contains("djc snapshot-point restore") && restored.contains("--db"), "\(restored)")
        #expect(try fixture.rows("SELECT Title FROM djmdContent WHERE ID = '601'").first?["Title"] == "원래 제목")
    }

    @Test func 대상이나_ID가_없으면_사용법이나_이유를_알린다() async throws {
        let fixture = try RekordboxFixture()
        await #expect(throws: UsageError.self) { try await PointSnapshotCommand.run(["snapshot-point", "create"], files: Self.files, gate: Self.gate) }
        await #expect(throws: UsageError.self) { try await PointSnapshotCommand.run(["snapshot-point"], files: Self.files, gate: Self.gate) }
        await #expect(throws: UsageError.self) { try await run(fixture, "pin") }
        await #expect(throws: UsageError.self) { try await run(fixture, "rename") }
        await #expect(throws: UsageError.self) {
            try await PointSnapshotCommand.run(["snapshot-point", "list", "--live", "--db", fixture.database.path], files: Self.files, gate: Self.gate)
        }
        await #expect(throws: DJCError.self) { try await run(fixture, "pin", "없는-스냅샷") }
    }

    @Test func 보관_일수는_앱이_공유_파일에_적은_설정을_따른다() async throws {
        let fixture = try RekordboxFixture()
        let folder = fixture.root.appending(path: "point-snapshots")
        let shared = fixture.root.appending(path: "shared-settings.json")
        let old = try RekordboxPointSnapshot.create(name: "", kind: .auto, database: fixture.database, shareRoot: nil, in: folder,
                                                    autoDays: 90, now: now.addingTimeInterval(-3 * 86_400), guard: Self.copyGuard)
        let older = try RekordboxPointSnapshot.create(name: "", kind: .auto, database: fixture.database, shareRoot: nil, in: folder,
                                                      autoDays: 90, now: now.addingTimeInterval(-4 * 86_400), guard: Self.copyGuard)
        // 공유 파일이 없으면 기본 7일: 사흘 전 자동 스냅샷은 남는다
        _ = try await PointSnapshotCommand.run(["snapshot-point", "create", "--db", fixture.database.path], now: now, files: Self.files, gate: Self.gate,
                                         sharedSettings: shared)
        #expect(FileManager.default.fileExists(atPath: old.url.path) && FileManager.default.fileExists(atPath: older.url.path))
        // 앱에서 2일로 줄이면 CLI도 그 값으로 정리한다
        try SharedSettingsFile.set(2.0, for: SettingKeys.pointSnapshotAutoDays.name, in: shared)
        _ = try await PointSnapshotCommand.run(["snapshot-point", "create", "--db", fixture.database.path], now: now, files: Self.files, gate: Self.gate,
                                         sharedSettings: shared)
        // 2일보다 옛 자동 중 가장 최근(사흘 전)은 남기고 더 옛 것(나흘 전)은 지운다(#236)
        #expect(FileManager.default.fileExists(atPath: old.url.path) && !FileManager.default.fileExists(atPath: older.url.path))
    }

    @Test func 명령_목록에_있고_읽기_사본_snapshot과_이름이_다르다() {
        let names = MainCommands.all.map(\.name)
        #expect(names.contains("snapshot-point") && names.contains("snapshot"))
    }
}
