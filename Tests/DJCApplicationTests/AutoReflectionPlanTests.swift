import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Synchronization
import Testing

/// 자동 저장의 판정(값만 보는 규칙): 실행 조건(R18), 재생 목록 단위와 K행 나누기(R14), 목록 지우기 손실 확인(R4),
/// 자동 저장 앞의 시점 스냅샷 관문(R13)
@MainActor
@Suite("자동 저장 판정")
struct AutoReflectionPlanTests {
    // MARK: - R18 실행 조건

    static let places = AutoReflectionRun.SelfTestPlaces(target: URL(filePath: "/private/var/tmp/run/rekordbox"),
                                                         database: URL(filePath: "/private/var/tmp/run/rekordbox/master.db"),
                                                         analysisRoot: URL(filePath: "/private/var/tmp/run/rekordbox/share"),
                                                         home: URL(filePath: "/private/var/tmp/run/home"),
                                                         temporaryRoot: URL(filePath: "/private/var/tmp"),
                                                         liveRekordbox: URL(filePath: "/Users/me/Library/Pioneer/rekordbox"),
                                                         userData: URL(filePath: "/Users/me/Library/Application Support/DJCrate"), analysisIsLink: false)

    func decide(release: Bool, _ arguments: [String] = [], copy: Bool = false, diagnostic: Bool = false,
                places: AutoReflectionRun.SelfTestPlaces? = Self.places) -> AutoReflectionRun {
        AutoReflectionRun.decide(.init(isReleaseBuild: release, arguments: ["djcrate"] + arguments, opensExplicitCopy: copy, isDiagnosticRun: diagnostic,
                                       selfTestPlaces: places))
    }

    @Test func 릴리스_빌드의_라이브_라이브러리만_자동_저장한다() {
        #expect(decide(release: true) == .live)
        #expect(decide(release: false) == .off(.debugBuild))
        #expect(decide(release: true, ["--db=/copy/master.db"], copy: true) == .off(.explicitCopy))
        #expect(decide(release: false, copy: true) == .off(.explicitCopy))
        #expect(decide(release: true, ["--write-selftest"], diagnostic: true) == .off(.diagnostic))
        #expect(decide(release: false, ["--ui-perf"], diagnostic: true) == .off(.diagnostic))
    }

    @Test func 자가_테스트_인자는_릴리스에서_진단이고_디버그는_자리를_모두_확인할_때만_쓴다() {
        #expect(decide(release: true, ["--auto-reflect-selftest=save"]) == .off(.diagnostic))
        #expect(decide(release: false, ["--auto-reflect-selftest=save"]) == .selfTest(.save))
        #expect(decide(release: false, ["--auto-reflect-selftest=kill-detect"]) == .selfTest(.killDetect))
        // 빈 값·모르는 값·인자 둘
        for arguments in [["--auto-reflect-selftest="], ["--auto-reflect-selftest=copy"], ["--auto-reflect-selftest"],
                          ["--auto-reflect-selftest=save", "--auto-reflect-selftest=save"]] {
            #expect(decide(release: false, arguments) == .off(.unsafeSelfTest))
            #expect(decide(release: true, arguments) == .off(.diagnostic))
        }
        // 명시한 사본과 함께 주면(쓰기 대상이 사본이 아니다) 쓰지 않는다
        #expect(decide(release: false, ["--auto-reflect-selftest=save"], copy: true) == .off(.unsafeSelfTest))
        #expect(decide(release: false, ["--auto-reflect-selftest=save"], places: nil) == .off(.unsafeSelfTest))
    }

    @Test func 자가_테스트_자리가_하나라도_어긋나면_쓰지_않는다() {
        func run(_ change: (inout AutoReflectionRun.SelfTestPlaces) -> Void) -> AutoReflectionRun {
            var places = Self.places
            change(&places)
            return decide(release: false, ["--auto-reflect-selftest=save"], places: places)
        }
        #expect(run { _ in } == .selfTest(.save))
        // 대상·DJC_HOME이 임시 폴더 밖
        #expect(run { $0.target = URL(filePath: "/Users/me/copy/rekordbox") } == .off(.unsafeSelfTest))
        #expect(run { $0.home = URL(filePath: "/Users/me/djc-home") } == .off(.unsafeSelfTest))
        #expect(run { $0.target = URL(filePath: "/private/var/tmpx/rekordbox") } == .off(.unsafeSelfTest), "이름이 비슷한 폴더는 아래가 아니다")
        // 실제 rekordbox 폴더와 겹침(링크를 푼 경로가 그 폴더이거나 그 안·밖)
        #expect(run { $0.liveRekordbox = $0.target } == .off(.unsafeSelfTest))
        #expect(run { $0.liveRekordbox = URL(filePath: "/private/var/tmp/run") } == .off(.unsafeSelfTest))
        #expect(run { $0.liveRekordbox = URL(filePath: "/PRIVATE/var/tmp/run/rekordbox/sub") } == .off(.unsafeSelfTest), "대소문자를 가리지 않는다")
        // 사본 안 USBANLZ가 링크(SAFE-8)
        #expect(run { $0.analysisIsLink = true } == .off(.unsafeSelfTest))
        // 쓰기 대상 DB 파일·분석 루트가 링크로 실제 rekordbox 폴더나 임시 폴더 밖을 가리킨다(파일 단위로 링크를 푼 경로)
        #expect(run { $0.database = $0.liveRekordbox.appending(path: "master.db") } == .off(.unsafeSelfTest))
        #expect(run { $0.analysisRoot = $0.liveRekordbox.appending(path: "share") } == .off(.unsafeSelfTest))
        #expect(run { $0.database = URL(filePath: "/Users/me/copy/master.db") } == .off(.unsafeSelfTest))
        // 링크를 풀지 못한 자리가 있다
        #expect(run { $0.resolved = false } == .off(.unsafeSelfTest))
        // DJC_HOME이 실제 rekordbox 폴더와 겹침
        #expect(run { $0.liveRekordbox = $0.home } == .off(.unsafeSelfTest))
        // DJC_HOME이 사용자 폴더와 겹침
        #expect(run { $0.userData = URL(filePath: "/private/var/tmp/run") } == .off(.unsafeSelfTest))
    }

    // MARK: - R14 재생 목록 단위와 K행

    func step(_ playlist: String, rows: Int, revision: UInt64, leftover: ReflectionLeftover? = nil) -> AutoReflectionInventory.Step {
        AutoReflectionInventory.Step(playlist: playlist, rows: rows, revision: DraftRevision(revision), leftover: leftover)
    }

    @Test func 같은_목록에_닿는_단계는_사이에_낀_단계까지_한_단위다() {
        #expect(AutoReflectionInventory.units(["A", "B", "A"]) == [0..<3])
        #expect(AutoReflectionInventory.units(["A", "B", "C"]) == [0..<1, 1..<2, 2..<3])
        #expect(AutoReflectionInventory.units(["new:a", "A", "new:a", "B"]) == [0..<3, 3..<4])
        #expect(AutoReflectionInventory.units(["A", "B", "A", "C", "B"]) == [0..<5])
        #expect(AutoReflectionInventory.units([]) == [])
    }

    @Test func K행을_넘는_한_단위는_나누지_않고_자동으로_쓰지_않는다() {
        // 「A에 120곡 → B에 1곡 → A에 80곡」은 한 단위라 201행: 자동 쓰기 0회, ⌘S·단추로 쓴다
        let inventory = AutoReflectionInventory(steps: [step("A", rows: 120, revision: 1), step("B", rows: 1, revision: 2), step("A", rows: 80, revision: 3)])
        #expect(inventory.autoUnits(rowLimit: 200).units.isEmpty)
        #expect(inventory.leftovers(rowLimit: 200) == [.overRowLimit])
        #expect(inventory.chunk(rowLimit: 200) == nil && inventory.leftoverCount(rowLimit: 200) == 3)
    }

    @Test func 단위_안의_단계가_막히면_그_단위는_자동으로_쓰지_않고_막히지_않으면_한_번에_쓴다() {
        // 「A에 50곡 → B에 1곡 → A에 50곡」에서 B가 막히면 A도 0회
        let blocked = AutoReflectionInventory(steps: [step("A", rows: 50, revision: 1), step("B", rows: 1, revision: 2, leftover: .needsConfirmation),
                                                      step("A", rows: 50, revision: 3)])
        #expect(blocked.chunk(rowLimit: 200) == nil && blocked.leftovers(rowLimit: 200) == [.needsConfirmation])
        let open = AutoReflectionInventory(steps: [step("A", rows: 50, revision: 1), step("B", rows: 1, revision: 2), step("A", rows: 50, revision: 3)])
        #expect(open.chunk(rowLimit: 200) == AutoReflectionChunk(tracks: [:], playlistSteps: 3, stepRevisions: [1, 2, 3].map(DraftRevision.init),
                                                                  rows: 101))
        // 앞 단위가 막히면 그 뒤 단위도 자동으로 쓰지 않는다(AR-9)
        let later = AutoReflectionInventory(steps: [step("A", rows: 1, revision: 1, leftover: .suggestion), step("B", rows: 1, revision: 2)])
        #expect(later.chunk(rowLimit: 200) == nil && later.leftoverCount(rowLimit: 200) == 2)
    }

    @Test func 곡_빼기·옮기기는_그_목록의_번호를_다시_매기는_행까지_센다() {
        let entries = [PlaylistEntry(trackNo: 1, contentID: "1")]
        #expect(AutoReflectionInventory.Step.rows(of: .removeTracks(playlist: .id("A"), entries: entries), playlistSize: 300) == 300)
        #expect(AutoReflectionInventory.Step.rows(of: .moveTracks(playlist: .id("A"), entries: entries, to: 1), playlistSize: 300) == 300)
        #expect(AutoReflectionInventory.Step.rows(of: .addTracks(playlist: .id("A"), contentIDs: ["1", "2"]), playlistSize: 300) == 2)
        #expect(AutoReflectionInventory.Step.rows(of: .rename(playlist: .id("A"), name: "가"), playlistSize: 300) == 1)
    }

    @Test func 자동_저장_한_번은_K행까지_재생_목록_단위를_먼저_넣고_남은_행을_곡으로_채운다() {
        let tracks = Dictionary(uniqueKeysWithValues: (0..<5).map { index in
            ("t\(index)", [DraftKey(.cue, "t\(index)"): DraftRevision(UInt64(10 + index))])
        })
        let inventory = AutoReflectionInventory(tracks: tracks, steps: [step("A", rows: 2, revision: 1), step("B", rows: 2, revision: 2)])
        let first = inventory.chunk(rowLimit: 5)
        #expect(first?.playlistSteps == 2 && first?.tracks.keys.sorted() == ["t0"] && first?.rows == 5)
        // 곡만이면 K+1곡이 두 번에 나뉜다
        let only = AutoReflectionInventory(tracks: tracks)
        #expect(only.chunk(rowLimit: 4)?.tracks.keys.sorted() == ["t0", "t1", "t2", "t3"])
        #expect(only.isBulk(timing: AutoReflectionTiming(editDelay: .zero, quietDelay: .zero, bulkDelay: .zero, bulkTracks: 5, rowLimit: 200)))
        #expect(!only.isBulk(timing: .standard))
    }

    // MARK: - R4 목록 지우기는 손실

    @Test func 재생_목록_지우기는_수동_저장에서도_손실로_확인을_거친다() {
        var report = ReflectionHarness.report()
        report.playlistOutcomes = [PlaylistOutcome(edit: .delete(playlist: .id("A")), playlistID: "A", name: "가", status: .written, reason: nil)]
        #expect(WriteConfirmPolicy.reasons(report, exclusions: [], canBackUp: true) == [.loss])
        let prompt = ReflectionPrompts.confirmation(report)
        #expect(prompt.destructive && prompt.details.contains { $0.contains("가") })
        // 막힌 지우기는 지우지 않으니 손실이 아니다
        report.playlistOutcomes?[0].status = .blocked
        #expect(!WriteConfirmPolicy.reasons(report, exclusions: [], canBackUp: true).contains(.loss))
    }

    // MARK: - R13 자동 저장 앞의 시점 스냅샷

    func runner(_ files: PointSnapshotFiles) -> AutoPointSnapshotRunner {
        AutoPointSnapshotRunner(environment: .init(database: { URL(filePath: "/copy/master.db") }, shareRoot: { nil },
                                                   snapshots: URL(filePath: "/points"), enabled: { true }, autoDays: { 7 }, busy: { false },
                                                   files: files, now: { Date(timeIntervalSince1970: 1_764_000_000) },
                                                   calendar: Calendar(identifier: .gregorian)))
    }

    @Test func 스냅샷은_쓰기_잠금을_잡고_중단_기록이_없을_때만_뜬다() async throws {
        let taken = Mutex(0)
        var files = MemoryPointSnapshotFiles().port
        files.takeAutoIfDue = { _, _, _, _, _, _, _ in
            taken.withLock { $0 += 1 }
            return .skipped(.alreadyToday)
        }
        let target = RekordboxWriteTarget.copy(database: URL(filePath: "/copy/master.db"), shareRoot: nil)
        let locks = MemoryWriteLocks()
        let key = MemoryWriteLocks.key(for: target.database)
        let none: @Sendable (RekordboxWriteTarget, RekordboxWriteLock.Hold?) throws -> RekordboxJournalVerdict = { _, hold in
            #expect(hold?.key == key, "잡은 잠금을 넘겨 그 아래에서 판정한다")
            return .none
        }
        // 다른 프로세스가 잠금을 쥐었으면 뜨지 않고 보류
        locks.holdElsewhere(key)
        #expect(await runner(files).gate(lock: locks.port, journal: none, target: target) == .held(.lockBusy))
        locks.holdElsewhere(key, false)
        // 중단 기록이 있으면 뜨지 않고 보류
        let finding = RekordboxJournalFinding(journal: RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts), changedSince: false,
                                              database: nil)
        #expect(await runner(files).gate(lock: locks.port, journal: { _, _ in .interrupted(finding) }, target: target)
            == .held(.interrupted(recoveryFailed: false)))
        #expect(taken.withLock { $0 } == 0)
        // 오늘 이미 떴거나·바뀐 것 없음·클론 안 됨은 채운 것으로 본다. 켜짐·남은 -wal은 보류
        for (skip, expected) in [(RekordboxPointSnapshotAutoSkip.alreadyToday, AutoSnapshotGate.satisfied), (.unchanged, .satisfied),
                                 (.noClone, .satisfied), (.rekordboxRunning, .held(.rekordboxRunning)), (.walPending, .held(.walRemains))] {
            files.takeAutoIfDue = { _, _, _, _, _, _, _ in
                taken.withLock { $0 += 1 }
                return .skipped(skip)
            }
            #expect(await runner(files).gate(lock: locks.port, journal: none, target: target) == expected)
        }
        // 뜨기에 실패해도 기다리지 않는다
        files.takeAutoIfDue = { _, _, _, _, _, _, _ in throw DJCError.writeRefused("실패") }
        #expect(await runner(files).gate(lock: locks.port, journal: none, target: target) == .satisfied)
        #expect(locks.heldKeys.isEmpty, "뜬 뒤 잠금을 푼다")
    }

    // MARK: - 2라운드 S9

    @Test func 곡_빼기는_직전_목록의_모든_행을_옮기기는_자리가_바뀐_구간을_센다() {
        let entries = (1...201).map { PlaylistEntry(trackNo: $0, contentID: "\($0)") }
        // 쓰기는 지운 행과 남은 행 전부의 번호를 다시 적는다(RekordboxWriter+Playlist의 곡 빼기)
        let afterRemove = entries.dropLast().map { $0 }
        #expect(AutoReflectionInventory.Step.rows(of: .removeTracks(playlist: .id("A"), entries: [entries[200]]), before: entries,
                                                  after: afterRemove) == 201)
        // 9번 곡을 2번 자리로: 2~9번 자리의 곡 8개가 번호를 받는다
        let ten = Array(entries.prefix(10))
        var moved = ten
        let picked = moved.remove(at: 8)
        moved.insert(picked, at: 1)
        let renumbered = moved.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element.contentID) }
        #expect(AutoReflectionInventory.Step.rows(of: .moveTracks(playlist: .id("A"), entries: [ten[8]], to: 2), before: ten,
                                                  after: renumbered) == 8)
    }

    // MARK: - 3라운드 S9

    @Test func 같은_곡이_여러_번_든_목록의_옮기기도_쓰기처럼_원래_번호로_센다() {
        // 같은 곡이 201번 든 목록에서 마지막 줄을 맨 앞으로: 쓰기는 원래 번호가 바뀐 줄을 모두 다시 적는다(201행)
        let entries = (1...201).map { PlaylistEntry(trackNo: $0, contentID: "1") }
        let after = (1...201).map { PlaylistEntry(trackNo: $0, contentID: "1") }
        #expect(AutoReflectionInventory.Step.rows(of: .moveTracks(playlist: .id("A"), entries: [entries[200]], to: 1), before: entries,
                                                  after: after) == 201)
    }
    // MARK: - 역편집 묶음(R12, 컨실 S2·G5·G7)

    /// 묶은 뒤 구성원의 판이 바뀌면(다시 고쳤다) 묶음을 풀지 않고 전체를 보류한다(한 곡만 보통 편집으로 쓰지 않는다)
    @Test func 역편집_묶음의_판이_바뀌면_묶음_전체를_보류한다() {
        let a = DraftKey(.tag, "a"), b = DraftKey(.tag, "b")
        var group = AutoReflectionUndoGroup(ReflectionUndoEdit(id: "u", batch: DraftWriteBatch(tags: [TagDraft(trackUUID: "a", base: TagFields()),
                                                                                                    TagDraft(trackUUID: "b", base: TagFields())],
                                                                                             commitPolicy: .allOrNothing), rowCount: 2))
        group.revisions = [a: DraftRevision(1), b: DraftRevision(2)]
        var inventory = AutoReflectionInventory(tracks: ["a": [a: DraftRevision(1)], "b": [b: DraftRevision(9)]])
        let result = inventory.applyingUndo([group], rowLimit: 200)
        #expect(result.chunk == nil && result.groups.count == 1)
        #expect(inventory.tracks.isEmpty && inventory.leftoverKeys[a] == .needsConfirmation && inventory.leftoverKeys[b] == .needsConfirmation)
    }

    func undoGroup(_ uuids: [String]) -> AutoReflectionUndoGroup {
        AutoReflectionUndoGroup(ReflectionUndoEdit(id: "u", batch: DraftWriteBatch(tags: uuids.map { TagDraft(trackUUID: $0, base: TagFields()) },
                                                                                  commitPolicy: .allOrNothing), rowCount: uuids.count))
    }

    /// 처음 볼 때 구성원이 모두 저장 대기에 있지 않으면 판을 기록하지 않고 묶음 전체를 확인 필요로 남긴다(남은 곡만 쓰지 않는다, 컨실 2라운드 C·O11)
    @Test func 처음_볼_때_구성원이_빠진_역편집_묶음은_판을_잡지_않고_전체를_보류한다() {
        let a = DraftKey(.tag, "a")
        var inventory = AutoReflectionInventory(tracks: ["a": [a: DraftRevision(1)]])
        let result = inventory.applyingUndo([undoGroup(["a", "b"])], rowLimit: 200)
        #expect(result.chunk == nil)
        #expect(result.groups.first?.revisions.isEmpty == true)
        #expect(inventory.leftoverKeys[a] == .needsConfirmation && inventory.tracks.isEmpty)
    }

    /// 판을 잡은 뒤에도 구성원 수가 묶음보다 적으면 보류한다(합쳐 판을 비운 묶음 포함, 컨실 2라운드 C·S2)
    @Test func 합쳐_판을_비운_묶음도_구성원이_빠지면_보류한다() {
        let a = DraftKey(.tag, "a"), c = DraftKey(.tag, "c")
        var inventory = AutoReflectionInventory(tracks: ["a": [a: DraftRevision(1)], "c": [c: DraftRevision(3)]])
        var merged = undoGroup(["a", "b", "c"])
        merged.revisions = [:]
        let result = inventory.applyingUndo([merged], rowLimit: 200)
        #expect(result.chunk == nil && inventory.leftoverKeys[a] == .needsConfirmation && inventory.leftoverKeys[c] == .needsConfirmation)
    }

    /// 대기 중인 역편집 묶음 전체의 행·판·곡을 함께 센다(대량 유예와 [취소] 판, 컨실 G7)
    @Test func 대기_중인_역편집_묶음_전체를_함께_센다() {
        func edit(_ id: String, _ uuids: [String]) -> ReflectionUndoEdit {
            ReflectionUndoEdit(id: id, batch: DraftWriteBatch(tags: uuids.map { TagDraft(trackUUID: $0, base: TagFields()) }, commitPolicy: .allOrNothing),
                               rowCount: uuids.count)
        }
        var tracks: [String: [DraftKey: DraftRevision]] = [:]
        for (index, uuid) in ["a", "b", "c", "d"].enumerated() { tracks[uuid] = [DraftKey(.tag, uuid): DraftRevision(UInt64(index + 1))] }
        var inventory = AutoReflectionInventory(tracks: tracks)
        let result = inventory.applyingUndo([AutoReflectionUndoGroup(edit("1", ["a", "b"])), AutoReflectionUndoGroup(edit("2", ["c", "d"]))], rowLimit: 200)
        #expect(result.pendingRows == 4 && result.pendingTracks == ["a", "b", "c", "d"] && result.pendingRevisions.count == 4)
    }
}
