import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Synchronization

/// 쓰기 입구 훅 대본(R10·R11 시험). 정한 때(몇 번째인지까지)에 강제 종료 흉내(`RekordboxWriteStop`)나 실패(`Injected`)를 던지고,
/// 정한 때부터 재확인이 켜짐을 보게 한다. 지나간 때·시각 훅을 남기고, 때마다 시험의 일을 부른다(파일 만들기·기록 읽기).
final class WriteHookScript: Sendable {
    struct Injected: Error, Equatable {}

    private struct State {
        var stop: (moment: RekordboxWriteMoment, occurrence: Int)?
        var fail: (moment: RekordboxWriteMoment, occurrence: Int)?
        var runningFrom: RekordboxWriteMoment?
        var runningSteps: Set<RekordboxWriteStep> = []
        var running = false
        var counts: [RekordboxWriteMoment: Int] = [:]
        var moments: [RekordboxWriteMoment] = []
        var timings: [RekordboxWriteMoment] = []
        var actions: [RekordboxWriteMoment: @Sendable () -> Void] = [:]
    }
    private let state = Mutex(State())

    init() {}

    /// 그 때의 `occurrence`번째에 강제 종료를 흉내 낸다
    func stop(at moment: RekordboxWriteMoment, occurrence: Int = 1) { state.withLock { $0.stop = (moment, occurrence) } }
    /// 그 때의 `occurrence`번째에 실패를 던진다
    func fail(at moment: RekordboxWriteMoment, occurrence: Int = 1) { state.withLock { $0.fail = (moment, occurrence) } }
    /// 그 때를 지난 뒤로 모든 재확인이 켜짐을 본다(그 때가 재확인이면 그 재확인부터)
    func startRunning(at moment: RekordboxWriteMoment) { state.withLock { $0.runningFrom = moment } }
    /// 그 단계의 재확인만 켜짐을 본다
    func running(at steps: Set<RekordboxWriteStep>) { state.withLock { $0.runningSteps = steps } }
    /// 그 때에 시험의 일을 한다(던지기 전에)
    func on(_ moment: RekordboxWriteMoment, _ action: @escaping @Sendable () -> Void) { state.withLock { $0.actions[moment] = action } }

    var moments: [RekordboxWriteMoment] { state.withLock { $0.moments } }
    var timings: [RekordboxWriteMoment] { state.withLock { $0.timings } }
    func count(_ moment: RekordboxWriteMoment) -> Int { state.withLock { $0.counts[moment] ?? 0 } }

    var hooks: RekordboxWriteHooks {
        RekordboxWriteHooks(
            checkpoint: { [self] moment in
                let (action, stops, fails) = state.withLock { state -> ((@Sendable () -> Void)?, Bool, Bool) in
                    let count = (state.counts[moment] ?? 0) + 1
                    state.counts[moment] = count
                    state.moments.append(moment)
                    if moment == state.runningFrom { state.running = true }
                    return (state.actions[moment], state.stop.map { $0.moment == moment && $0.occurrence == count } ?? false,
                            state.fail.map { $0.moment == moment && $0.occurrence == count } ?? false)
                }
                action?()
                if stops { throw RekordboxWriteStop() }
                if fails { throw Injected() }
            },
            timing: { [self] moment, _ in state.withLock { $0.timings.append(moment) } },
            isRekordboxRunning: { [self] step in state.withLock { $0.running || $0.runningSteps.contains(step) } })
    }

    /// 사본 대상의 관문(라이브 아님)에 이 대본을 단다
    var writeGuard: RekordboxWriteGuard {
        var writeGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })
        writeGuard.hooks = hooks
        return writeGuard
    }
}

/// 쓰기 기록 시험의 공통 도움
enum JournalTestKit {
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    static func journalURL(_ fixture: RekordboxFixture) throws -> URL {
        RekordboxWriteJournal.url(resolvedDatabase: try RekordboxWriteLocks.resolve(fixture.database))
    }

    static func journal(_ fixture: RekordboxFixture) throws -> RekordboxWriteJournal? {
        try RekordboxWriter.readJournal(at: journalURL(fixture))
    }

    static func judge(_ fixture: RekordboxFixture, backups: URL? = nil) throws -> RekordboxJournalJudgment? {
        try RekordboxWriter.judgeJournal(database: fixture.database, backups: backups ?? fixture.backups, locked: false, guard: copyGuard)
    }

    /// 중단 판정이면 그 기록과 경고 여부·그때 본 DB 크기·시각
    static func interrupted(_ judgment: RekordboxJournalJudgment?) -> (journal: RekordboxWriteJournal, changedSince: Bool, stamp: RekordboxFileStamp?)? {
        guard case let .interrupted(journal, changedSince, stamp)? = judgment else { return nil }
        return (journal, changedSince, stamp)
    }

    /// 판정한 중단 기록으로 복원한다
    static func restore(_ fixture: RekordboxFixture, shareRoot: URL? = nil, guard writeGuard: RekordboxWriteGuard = copyGuard,
                        now: Date = Date(timeIntervalSince1970: 1_790_400_000)) throws -> RekordboxWriter.JournalRequestOutcome<RekordboxWriter.JournalRestoreResult> {
        guard let found = interrupted(try judge(fixture)) else { throw FixtureError("중단 기록이 없다") }
        return try RekordboxWriter.restoreJournal(database: fixture.database, operationID: found.journal.operationID, databaseStamp: found.stamp,
                                                  backups: fixture.backups, shareRoot: shareRoot, now: now, guard: writeGuard)
    }

    /// 쓰기가 건드리는 표
    static func state(_ fixture: RekordboxFixture) throws -> [[String: String]] {
        try ["djmdContent", "djmdCue", "contentCue", "contentFile", "djmdMixerParam", "agentRegistry"]
            .flatMap { try fixture.rows("SELECT * FROM \($0) ORDER BY 1") }
    }

    /// 루트 아래 임시 폴더(준비 폴더·복원 임시 폴더)
    static func leftovers(_ roots: URL...) -> [String] {
        roots.flatMap { root -> [String] in
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            var found: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                let name = url.lastPathComponent
                if name == RekordboxStaging.folderName || name.hasPrefix(".djc-restore") || name.hasPrefix(".djc-old-") || name.hasSuffix(".djc-part") {
                    found.append(url.path)
                }
            }
            return found
        }
    }
}
