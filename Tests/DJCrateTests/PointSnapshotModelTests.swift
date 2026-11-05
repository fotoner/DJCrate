import DJCApplication
import DJCDomain
import Foundation
@testable import DJCrate
import DJCAdapters
import RekordboxFixtures
import RekordboxKit
import Testing

/// 시점 스냅샷 창(#224): 합성 사본으로 만들기·목록(쓰기 전 백업과 함께)·고정·지우기. 사용자 데이터 폴더는 쓰지 않는다.
@MainActor
@Suite("시점 스냅샷 창")
struct PointSnapshotModelTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    func model(_ fixture: RekordboxFixture, prompter: ScriptedPrompter = ScriptedPrompter(), busy: String? = nil,
               guard writeGuard: RekordboxWriteGuard = copyGuard, clock: Date? = nil) -> PointSnapshotModel {
        let points = PointSnapshots(database: fixture.database, shareRoot: fixture.shareRoot, directory: fixture.root.appending(path: "point-snapshots"),
                                    backupDirectory: fixture.backups, files: .live(guard: writeGuard), backups: .live())
        return PointSnapshotModel(points: points, busyReason: { busy }, prompter: prompter, now: { clock ?? now },
                           restore: { entry, _ in
                               // 저장소 없이 연 창: 같은 쓰기 관문으로 사본을 되돌린다(앱은 반영 세션이 잠금·다시 읽기까지 한다).
                               try RekordboxWriteGate.live(guard: writeGuard).restorePointSnapshot(
                                   entry.url, .init(database: fixture.database, shareRoot: fixture.shareRoot, backups: fixture.backups),
                                   fixture.root.appending(path: "point-snapshots"), Int(SettingKeys.pointSnapshotAutoDays.defaultValue), clock ?? now)
                           })
    }

    @Test func 이름을_붙여_남기면_목록_맨_위에_고른_채로_보이고_이름_칸을_비운다() async throws {
        let fixture = try RekordboxFixture()
        let model = model(fixture)
        model.newName = "큰 정리 전"
        await model.create()
        #expect(model.isError == false, "\(model.message ?? "")")
        let first = try #require(model.rows.first)
        #expect(first.name == "큰 정리 전" && first.kind == RekordboxPointSnapshot.Kind.manual.title)
        #expect(model.selection == first.id)
        #expect(model.newName.isEmpty)
        #expect((first.bytes ?? 0) > 0)
    }

    @Test func 쓰기_전_백업도_같은_목록에_보이지만_고정할_수_없다() async throws {
        let fixture = try RekordboxFixture()
        try makeBackup(fixture, "2026-09-01T000000-write")
        try makeBackup(fixture, "2026-09-02T000000-before-restore")
        // 백업 목록의 시각은 폴더를 만든 때라 스냅샷은 그 뒤 시각으로 뜬다(소수 초는 ms까지만 적는다)
        let model = model(fixture, clock: Date().addingTimeInterval(1))
        await model.create()
        await model.refresh()
        #expect(model.rows.map(\.kind) == [RekordboxPointSnapshot.Kind.manual.title, "복원 직전 백업", "쓰기 전 백업"],
                "\(model.rows.map { ($0.kind, $0.date.timeIntervalSince1970) })")
        let backupRow = try #require(model.rows.first { $0.entry == nil })
        await model.setPinned(true, backupRow)
        #expect(!model.rows.contains { $0.pinned && $0.entry == nil })
    }

    /// 쓰기 전 백업 하나(합성: 사본 DB를 백업 폴더에 둔다)
    @discardableResult
    func makeBackup(_ fixture: RekordboxFixture, _ name: String) throws -> URL {
        let folder = fixture.backups.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.database, to: folder.appending(path: "master.db"))
        return folder
    }

    @Test func 고정하고_풀_수_있고_고정한_것은_지우지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let prompter = ScriptedPrompter()
        let model = model(fixture, prompter: prompter)
        await model.create()
        let row = try #require(model.rows.first)
        await model.setPinned(true, row)
        #expect(model.rows.first?.pinned == true)
        await model.delete(try #require(model.rows.first))
        #expect(prompter.shown.isEmpty, "고정한 것은 묻지도 않는다")
        #expect(model.rows.count == 1)
        await model.setPinned(false, try #require(model.rows.first))
        #expect(model.rows.first?.pinned == false)
    }

    @Test func 지우기는_한_번_묻고_취소하면_그대로_둔다() async throws {
        let fixture = try RekordboxFixture()
        let prompter = ScriptedPrompter()
        let model = model(fixture, prompter: prompter)
        await model.create()
        prompter.answer = false
        await model.delete(try #require(model.rows.first))
        #expect(model.rows.count == 1 && prompter.shown.count == 1)
        prompter.answer = true
        await model.delete(try #require(model.rows.first))
        #expect(model.rows.isEmpty && prompter.shown.count == 2)
        #expect(prompter.shown.last?.destructive == true)
    }

    // MARK: - 창의 단추(#244): 뷰는 동기 메서드만 부르고, 일과 그 손잡이는 모델이 든다

    @Test func 단추가_시작한_일은_모델이_들고_끝나면_같은_결과를_남긴다() async throws {
        let fixture = try RekordboxFixture()
        let prompter = ScriptedPrompter()
        let model = model(fixture, prompter: prompter)
        model.newName = "단추로"
        model.startCreate()
        await model.task?.value
        let row = try #require(model.rows.first)
        #expect(row.name == "단추로" && model.selection == row.id && model.newName.isEmpty)
        model.startTogglePin(row)
        await model.task?.value
        #expect(model.rows.first?.pinned == true)
        model.startTogglePin(try #require(model.rows.first))
        await model.task?.value
        #expect(model.rows.first?.pinned == false)
        model.startCompare()
        await model.task?.value
        #expect(model.comparedID == row.id && model.comparison != nil)
        prompter.answer = false
        model.startRestore()
        await model.task?.value
        #expect(prompter.shown.count == 1 && prompter.shown.last?.destructive == true)
        model.startDelete()
        await model.task?.value
        #expect(prompter.shown.count == 2 && model.rows.count == 1, "취소하면 그대로 둔다")
        // 창을 다시 앞에 두면 다른 곳에서 남긴 스냅샷까지 다시 읽는다
        let other = self.model(fixture)
        other.startRefresh()
        await other.task?.value
        #expect(other.rows.map(\.id) == model.rows.map(\.id))
    }

    @Test func 고른_줄이_없으면_비교·복원·지우기_단추는_일을_시작하지_않는다() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "point-\(UUID().uuidString)")
        // 일을 시작하지 않으므로 아무 파일도 열지 않는다
        let points = PointSnapshots(database: folder.appending(path: "master.db"), shareRoot: nil, directory: folder,
                                    backupDirectory: folder, files: .live(guard: Self.copyGuard), backups: .live())
        let prompter = ScriptedPrompter()
        let model = PointSnapshotModel(points: points, prompter: prompter, restore: { _, _ in throw CancellationError() })
        model.startCompare()
        model.startRestore()
        model.startDelete()
        #expect(model.task == nil && prompter.shown.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func rekordbox가_켜져_있으면_이유를_알리고_남기지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        let model = model(fixture, guard: running)
        await model.create()
        #expect(model.isError)
        // 안내는 시점 스냅샷 만들기가 거부한 이유 그대로다
        let refusal = #expect(throws: (any Error).self) {
            try RekordboxPointSnapshot.create(name: "", database: fixture.database, shareRoot: fixture.shareRoot,
                                              in: fixture.root.appending(path: "point-snapshots"), autoDays: 7, now: now, guard: running)
        }
        #expect(model.message == refusal.map { AppErrorMessage.message(for: $0) }, "\(model.message ?? "")")
        #expect(model.rows.isEmpty)
    }

    @Test func 쓰는_중에는_막는다() async throws {
        let fixture = try RekordboxFixture()
        let model = model(fixture, busy: "rekordbox에 쓰는 중입니다")
        await model.create()
        #expect(model.isError && model.rows.isEmpty)
    }

    /// 복원까지 실패한 경고창(#300): 그 창을 확인하기 전에는 앱을 끄지 않는다. 창을 띄우는 동안 확인 중으로 표시한다.
    @MainActor final class AckProbe: HeadlessReflectionPrompter {
        var insideAcknowledgement: () -> Bool = { false }
        var shownInside: [Bool] = []
        func show(_ prompt: ReflectionPrompt) -> Bool {
            shownInside.append(insideAcknowledgement())
            return true
        }
    }

    @Test func 복원까지_실패하면_경고창이_떠_있는_동안_확인_중으로_표시한다() async throws {
        let fixture = try RekordboxFixture()
        let creator = model(fixture)
        creator.newName = "복원 시험"
        await creator.create()
        let row = try #require(creator.rows.first { $0.entry != nil })
        let points = PointSnapshots(database: fixture.database, shareRoot: fixture.shareRoot, directory: fixture.root.appending(path: "point-snapshots"),
                                    backupDirectory: fixture.backups, files: .live(guard: Self.copyGuard), backups: .live())
        let probe = AckProbe()
        var acknowledging = false
        probe.insideAcknowledgement = { acknowledging }
        let failing = PointSnapshotModel(points: points, prompter: probe, now: { now },
                                         whileAcknowledging: { ask in acknowledging = true; defer { acknowledging = false }; return ask() },
                                         restore: { _, _ in
            throw DJCError.pointRestoreFailed(reason: "무결성 검사 실패", restoreError: "권한 없음", snapshot: "s", database: nil)
        })
        await failing.refresh()
        let target = try #require(failing.rows.first { $0.id == row.id })
        await failing.restore(target)
        // 비교 뒤 묻는 확인 창은 `ScriptedPrompter`가 아닌 이 프롬프터가 받는다: 확인(true) 뒤 복원이 실패하고 경고창이 한 번 더 뜬다
        #expect(probe.shownInside.last == true, "경고창은 확인 중 표시 안에서 떠야 한다: \(probe.shownInside)")
        #expect(!acknowledging)
    }

    @Test func 종료를_기다리거나_Mac을_끄는_중에는_저장소로_연_창이_복원을_막는다() throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        store.isPoweringOff = true
        let folder = FileManager.default.temporaryDirectory.appending(path: "point-\(UUID().uuidString)")
        let points = PointSnapshots(database: folder.appending(path: "master.db"), shareRoot: nil, directory: folder,
                                    backupDirectory: folder, files: .live(guard: Self.copyGuard), backups: .live())
        let model = PointSnapshotModel(store: store, reflection: ReflectionCoordinator.test(store: store), points: points)
        #expect(model.blockReason == "Mac을 끄는 중이라 rekordbox에 쓰지 않았습니다. 다시 켠 뒤 쓰세요")
        store.isPoweringOff = false
        #expect(model.blockReason == nil)
    }

    // MARK: - 비교·복원(#225)

    func title(_ fixture: RekordboxFixture, _ id: String) throws -> String? {
        try fixture.rows("SELECT Title FROM djmdContent WHERE ID = ?", [.text(id)]).first?["Title"]
    }

    @Test func 복원은_비교한_뒤_한_번만_묻고_취소하면_그대로_두고_확인하면_되돌린다() async throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "501")
        track.title = "원래 제목"
        try fixture.add(track)
        let prompter = ScriptedPrompter()
        let model = model(fixture, prompter: prompter, clock: Date())
        model.newName = "정리 전"
        await model.create()
        try fixture.execute("UPDATE djmdContent SET Title = '바꾼 제목' WHERE ID = '501'")
        let row = try #require(model.rows.first { $0.entry != nil })

        prompter.answer = false
        await model.restore(row)
        #expect(prompter.shown.count == 1)
        #expect(try title(fixture, "501") == "바꾼 제목")
        let prompt = try #require(prompter.shown.first)
        // 확인 창은 비교한 결과로 만든 그 창이다(문구는 아래 클라우드 시험과 `restoreConfirmation`이 정한다)
        let comparison = try #require(model.comparison, "비교 결과도 창에 남는다")
        #expect(prompt == PointSnapshotModel.restoreConfirmation(try #require(row.entry), diff: comparison) && prompt.destructive)
        #expect(prompt.details.starts(with: comparison.summary) && !comparison.summary.isEmpty)
        #expect(comparison.tagsChanged == ["바꾼 제목"])

        prompter.answer = true
        await model.restore(row)
        #expect(prompter.shown.count == 2)
        #expect(try title(fixture, "501") == "원래 제목")
        #expect(model.isError == false, "\(model.message ?? "")")
        #expect(model.rows.contains { $0.entry?.metadata.kind == .beforeRestore && $0.name == "‘정리 전’ 복원 전" })
    }

    /// 시점 스냅샷 창은 주 창과 따로 떠서 주 창의 진행 카드가 가려질 수 있다. 확인 창에서 뺀 "끝날 때까지 rekordbox를 켜지 마세요"는
    /// 이 창이 되돌리는 동안만 직접 보인다(비교·취소·확인 창 동안은 아니다, #310).
    @Test func 복원하는_동안에만_진행_안내를_켠다() async throws {
        final class Probe { var model: PointSnapshotModel?; var restoring: [Bool] = [] }
        let fixture = try RekordboxFixture()
        let probe = Probe()
        let prompter = ScriptedPrompter()
        let points = PointSnapshots(database: fixture.database, shareRoot: fixture.shareRoot, directory: fixture.root.appending(path: "point-snapshots"),
                                    backupDirectory: fixture.backups, files: .live(guard: Self.copyGuard), backups: .live())
        let clock = Date()
        let model = PointSnapshotModel(points: points, busyReason: { nil }, prompter: prompter, now: { clock }, restore: { entry, _ in
            probe.restoring.append(probe.model?.isRestoring == true)
            return try RekordboxWriteGate.live(guard: Self.copyGuard).restorePointSnapshot(
                entry.url, .init(database: fixture.database, shareRoot: fixture.shareRoot, backups: fixture.backups),
                fixture.root.appending(path: "point-snapshots"), Int(SettingKeys.pointSnapshotAutoDays.defaultValue), clock)
        })
        probe.model = model
        await model.create()
        let row = try #require(model.rows.first { $0.entry != nil })
        #expect(!model.isRestoring)

        prompter.answer = false
        await model.restore(row)
        #expect(probe.restoring.isEmpty && !model.isRestoring, "취소하면 되돌리지 않아 안내도 켜지 않는다")

        prompter.answer = true
        await model.restore(row)
        #expect(probe.restoring == [true], "되돌리는 동안 안내가 켜져 있다")
        #expect(!model.isRestoring && !model.isWorking, "끝나면 꺼진다")
    }

    @Test func rekordbox가_켜져_있으면_묻지_않고_이유를_알린다() async throws {
        let fixture = try RekordboxFixture()
        let prompter = ScriptedPrompter()
        _ = try RekordboxPointSnapshot.create(name: "전", database: fixture.database, shareRoot: nil, in: fixture.root.appending(path: "point-snapshots"),
                                             autoDays: 7, now: now, guard: Self.copyGuard)
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        let model = model(fixture, prompter: prompter, guard: running)
        await model.refresh()
        await model.restore(try #require(model.rows.first))
        #expect(prompter.shown.isEmpty && model.isError)
        #expect(model.message?.contains("rekordbox를 완전히 종료") == true)
    }

    @Test func 스냅샷_뒤_클라우드_동기화가_있었으면_확인_창에_한_줄_알린다() throws {
        let entry = RekordboxPointSnapshot.Entry(url: URL(filePath: "/tmp/x"),
                                                 metadata: .init(name: "전", kind: .manual, createdAt: now, cloudUpdateCount: 100))
        var diff = RekordboxPointSnapshotDiff()
        diff.currentCloudUpdateCount = 100
        let quiet = PointSnapshotModel.restoreConfirmation(entry, diff: diff)
        #expect(!quiet.text.contains(RekordboxPointSnapshotDiff.cloudSyncNote))
        // 되돌려도 초안은 남는다는 약속과 파괴 확인 단추(창 원문)
        #expect(quiet.text.contains("초안은 그대로") && quiet.destructive && quiet.confirm == "이 시점으로 복원")
        diff.currentCloudUpdateCount = 120
        let prompt = PointSnapshotModel.restoreConfirmation(entry, diff: diff)
        #expect(prompt.text.contains(RekordboxPointSnapshotDiff.cloudSyncNote))
        #expect(prompt.text.contains("다른 곳이 없습니다"))
    }
}
