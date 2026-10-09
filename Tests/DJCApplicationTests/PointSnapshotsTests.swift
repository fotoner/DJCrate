import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Synchronization
import Testing

@MainActor
@Suite("시점 스냅샷 유스케이스")
struct PointSnapshotsTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    func points(_ files: MemoryPointSnapshotFiles, backups: [RekordboxWriteBackup] = []) -> PointSnapshots {
        var port = MemoryBackups().port
        port.list = { _ in backups }
        return PointSnapshots(database: URL(filePath: "/copy/master.db"), shareRoot: nil, directory: URL(filePath: "/points"),
                              backupDirectory: URL(filePath: "/backups"), files: files.port, backups: port)
    }

    /// 확인 창 가짜: 답을 정하고 본 창을 기억한다
    @MainActor final class Prompts {
        var answer = true
        var shown: [ReflectionPrompt] = []
        var port: UserConfirmation {
            UserConfirmation(confirm: { self.shown.append($0); return self.answer }, choose: { self.shown.append($0); return self.answer ? .confirm : .cancel })
        }
    }

    @Test func 목록은_시점_스냅샷과_쓰기_전_백업을_최근_것부터_한데_보이고_복원_직전은_무엇으로_되돌리기_전인지_적는다() {
        let files = MemoryPointSnapshotFiles()
        files.add("정리 전", at: now.addingTimeInterval(-300))
        files.add("", at: now, kind: .beforeRestore, restoredFrom: "정리 전")
        let report = RekordboxWriteReport(outcomes: [], dryRun: false, createdAt: "",
                                          gridOutcomes: [.init(trackUUID: "1", title: "그리드 곡", status: .written, removed: 0, added: 1)])
        let backups = [RekordboxWriteBackup(url: URL(filePath: "/backups/a-write"), createdAt: now.addingTimeInterval(-100), isWrite: true, report: report),
                       RekordboxWriteBackup(url: URL(filePath: "/backups/b-before-restore"), createdAt: now.addingTimeInterval(-600), isWrite: false)]
        let rows = points(files, backups: backups).rows()
        #expect(rows.map(\.kind) == ["복원 직전", "쓰기 전 백업", "수동", "복원 직전 백업"])
        #expect(rows[0].name == "‘정리 전’ 복원 전")
        #expect(rows[1].name == "그리드 곡" && rows[1].entry == nil && !rows[1].pinned)
        #expect(rows[2].id == PointSnapshotRow.pointID(rows[2].entry!))
    }

    @Test func 쓰는_중이면_파일을_보지_않고_거부한다() async {
        let files = MemoryPointSnapshotFiles()
        await #expect(throws: PointSnapshotRefusal.busy("쓰는 중")) {
            try await points(files).create(name: "전", autoDays: 7, now: now, blockReason: "쓰는 중")
        }
        #expect(files.calls.isEmpty)
        let entry = try? await points(files).create(name: "전", autoDays: 7, now: now)
        #expect(entry?.metadata.name == "전" && files.calls == ["create 전"])
    }

    @Test func 고정한_스냅샷은_묻지도_지우지도_않고_그_밖은_한_번_묻고_취소하면_그대로_둔다() async throws {
        let files = MemoryPointSnapshotFiles()
        files.add("고정", at: now, pinned: true)
        files.add("보통", at: now)
        let prompts = Prompts()
        let use = points(files)
        let pinned = try use.find("고정"), plain = try use.find("보통")
        guard case .refused(.pinned) = await use.delete(pinned, confirmation: prompts.port) else { Issue.record("고정 거부"); return }
        #expect(prompts.shown.isEmpty && files.calls.isEmpty)
        prompts.answer = false
        guard case .cancelled = await use.delete(plain, confirmation: prompts.port) else { Issue.record("취소"); return }
        #expect(prompts.shown.count == 1 && prompts.shown[0].destructive && files.calls.isEmpty)
        prompts.answer = true
        var working: [Bool] = []
        guard case .deleted = await use.delete(plain, confirmation: prompts.port, working: { working.append($0) }) else { Issue.record("지움"); return }
        #expect(files.calls == ["delete 보통"] && working == [true, false])
        #expect(use.entries().map(\.metadata.name) == ["고정"])
    }

    @Test func 찾지_못한_ID는_list로_확인하라고_알린다() {
        #expect(throws: DJCError.self) { try points(MemoryPointSnapshotFiles()).find("없는-스냅샷") }
    }

    @Test func 복원은_막힘을_먼저_보고_비교한_뒤_한_번만_묻고_확인하면_바뀌는_곡과_함께_되돌린다() async throws {
        let files = MemoryPointSnapshotFiles()
        files.add("전", at: now)
        var diff = RekordboxPointSnapshotDiff()
        diff.tagsChanged = ["바꾼 제목"]
        diff.changedTrackUUIDs = ["uuid-1"]
        files.state.withLock { $0.diff = diff }
        let use = points(files), entry = try use.find("전"), prompts = Prompts()
        var performed: [Set<String>] = [], shownDiff: RekordboxPointSnapshotDiff?, working: [Bool] = []
        let perform: @MainActor (RekordboxPointSnapshotEntry, Set<String>) async throws -> RekordboxPointRestoreReport = { entry, changed in
            performed.append(changed)
            return RekordboxPointRestoreReport(restored: entry, beforeRestore: entry)
        }

        guard case .refused(.busy("쓰는 중")) = await use.restore(entry, blockReason: "쓰는 중", confirmation: prompts.port, perform: perform) else {
            Issue.record("쓰는 중"); return
        }
        files.state.withLock { $0.liveAndRunning = true }
        guard case .refused(.rekordboxRunning) = await use.restore(entry, confirmation: prompts.port, perform: perform) else {
            Issue.record("rekordbox 켜짐"); return
        }
        #expect(files.calls.isEmpty && prompts.shown.isEmpty, "막히면 비교도 묻지도 않는다")
        files.state.withLock { $0.liveAndRunning = false }

        prompts.answer = false
        guard case .cancelled = await use.restore(entry, confirmation: prompts.port, compared: { shownDiff = $0 }, working: { working.append($0) },
                                                  perform: perform) else { Issue.record("취소"); return }
        #expect(files.calls == ["compare"] && prompts.shown == [PointSnapshots.restoreConfirmation(entry, diff: diff)] && performed.isEmpty)
        #expect(shownDiff == diff && working == [true, false], "비교한 결과를 확인 창 전에 보이고 묻는 동안은 일하지 않는다")

        prompts.answer = true
        working = []
        guard case .restored = await use.restore(entry, confirmation: prompts.port, working: { working.append($0) }, perform: perform) else {
            Issue.record("복원"); return
        }
        #expect(performed == [["uuid-1"]] && prompts.shown.count == 2 && working == [true, false, true, false])
    }

    @Test func 비교하지_못하면_묻지_않는다() async throws {
        let files = MemoryPointSnapshotFiles()
        files.add("전", at: now)
        files.state.withLock { $0.compareFails = true }
        let use = points(files), prompts = Prompts()
        let outcome = await use.restore(try use.find("전"), confirmation: prompts.port) { entry, _ in
            RekordboxPointRestoreReport(restored: entry, beforeRestore: entry)
        }
        guard case .compareFailed = outcome else { Issue.record("비교 실패"); return }
        #expect(prompts.shown.isEmpty)
    }

    @Test func 복원_확인_창은_스냅샷_뒤_클라우드_동기화가_있었을_때만_한_줄_알린다() {
        let entry = RekordboxPointSnapshotEntry(url: URL(filePath: "/tmp/x"),
                                                metadata: .init(name: "전", kind: .manual, createdAt: now, cloudUpdateCount: 100))
        var diff = RekordboxPointSnapshotDiff()
        diff.currentCloudUpdateCount = 100
        let quiet = PointSnapshots.restoreConfirmation(entry, diff: diff)
        #expect(!quiet.text.contains(RekordboxPointSnapshotDiff.cloudSyncNote))
        #expect(quiet.text.contains("초안은 그대로") && quiet.destructive && quiet.confirm == "이 시점으로 복원")
        diff.currentCloudUpdateCount = 120
        let prompt = PointSnapshots.restoreConfirmation(entry, diff: diff)
        #expect(prompt.text.contains(RekordboxPointSnapshotDiff.cloudSyncNote) && prompt.text.contains("다른 곳이 없습니다"))
    }

    // MARK: - 자동 시점 스냅샷(#228)

    final class AutoProbe {
        var busy = false
        var writes = 0
        var failures: [String] = []
        var logs: [String] = []
    }

    func autoRunner(_ files: PointSnapshotFiles, probe: AutoProbe, writeCount: @escaping () -> Int) -> AutoPointSnapshotRunner {
        AutoPointSnapshotRunner(environment: .init(database: { URL(filePath: "/copy/master.db") }, shareRoot: { nil },
                                                   snapshots: URL(filePath: "/points"), enabled: { true }, autoDays: { 7 },
                                                   busy: { probe.busy }, writeCount: writeCount, files: files, now: { now },
                                                   calendar: Calendar(identifier: .gregorian)),
                                errorText: { _ in "이유" }, log: { probe.logs.append($0) }, onFailure: { title, _ in probe.failures.append(title) })
    }

    @Test func 뜨는_동안_rekordbox_쓰기가_끼어들면_그_스냅샷을_버린다() async {
        let memory = MemoryPointSnapshotFiles()
        var files = memory.port
        let entry = RekordboxPointSnapshotEntry(url: URL(filePath: "/points/auto"),
                                                metadata: .init(name: "", kind: .auto, createdAt: now))
        files.takeAutoIfDue = { _, _, _, _, _, _, _ in .took(entry) }
        let discarded = Mutex<[URL]>([])
        files.discard = { url in discarded.withLock { $0.append(url) } }
        let probe = AutoProbe()
        var count = 0
        let runner = autoRunner(files, probe: probe, writeCount: { count += 1; return count })
        #expect(await runner.runIfDue() == nil)
        #expect(discarded.withLock { $0 } == [entry.url] && probe.logs.count == 1 && probe.failures.isEmpty)
        // 쓰기가 끼어들지 않으면 그대로 둔다
        let steady = autoRunner(files, probe: probe, writeCount: { 0 })
        #expect(await steady.runIfDue() == .took(entry))
        #expect(discarded.withLock { $0 }.count == 1)
    }

    @Test func 뜨지_못하면_한_번만_알리고_rekordbox가_켜진_때문이면_알리지_않는다() async {
        let memory = MemoryPointSnapshotFiles()
        var files = memory.port
        files.takeAutoIfDue = { _, _, _, _, _, _, _ in throw DJCError.writeRefused("시험 실패") }
        let probe = AutoProbe()
        let runner = autoRunner(files, probe: probe, writeCount: { 0 })
        #expect(await runner.runIfDue() == nil)
        #expect(await runner.runIfDue() == nil)
        #expect(probe.failures == ["자동 시점 스냅샷을 남기지 못했습니다"] && probe.logs.count == 2)
        files.isRekordboxRunning = { true }
        let quiet = AutoProbe()
        #expect(await autoRunner(files, probe: quiet, writeCount: { 0 }).runIfDue() == nil)
        #expect(quiet.failures.isEmpty)
        probe.busy = true
        #expect(await runner.runIfDue() == nil, "쓰는 중이면 보지 않는다")
        #expect(probe.logs.count == 2)
    }
}
