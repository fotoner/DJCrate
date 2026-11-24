import DJCDomain
import Foundation

/// 저장 뒤 ⌘Z가 대기열에 넣는 역편집(R12). 여러 곡에 걸쳐도 한 번의 쓰기로 전부 쓰거나 전부 쓰지 않는다.
/// K행을 넘으면 자동으로 쓰지 않고 ⌘S·저장 단추로 쓴다. 역편집 대상(새 큐 ID 등)을 정하는 일은 W3-F(#405)가 한다.
public struct ReflectionUndoEdit: Equatable, Sendable {
    /// 사용자 동작 하나의 ID(같은 ⌘Z를 두 번 넣지 않는다)
    public var id: String
    /// 되돌릴 값을 담은 초안 묶음
    public var batch: DraftWriteBatch
    /// 이 쓰기가 갱신할 곡 행 수(K와 견준다)
    public var rowCount: Int

    public init(id: String, batch: DraftWriteBatch, rowCount: Int) {
        self.id = id
        self.batch = batch
        self.rowCount = rowCount
    }
}

/// 자동 저장 대기열에 넣는 요청
public enum AutoReflectionRequest: Equatable, Sendable {
    /// ⌘S·저장 단추: 대기 중인 자동 저장을 기다리지 않고 지금 저장한다. 쓰는 중이면 대기열 맨 앞에 넣는다(R3)
    case saveNow
    /// 저장 뒤 ⌘Z의 역편집(R12)
    case undo(ReflectionUndoEdit)
}

/// 자동 저장 엔진(R1~R24의 몸통): 대상 편집을 T_edit 뒤에, rekordbox가 꺼지고 조용해지면, 보류 사유가 없을 때 사용자 조작 없이 저장한다.
/// 저장은 반영 세션(`ReflectionSession`)의 단계로 한다. 쓸지 말지의 마지막 판정은 늘 쓰기 관문이 다시 한다.
/// 앱 수명 동안 조립 지점(`AppComposition`)이 하나 든다. CLI는 쓰지 않는다.
///
/// 한 번에 쓰기 하나만 한다(직렬 큐): 자동 저장과 ⌘S·복원 같은 수동 쓰기는 모두 이 엔진의 차례를 받는다(`exclusive`). 쓰는 중에 들어온 수동 쓰기는
/// 그 쓰기가 끝나면 다음 자동 저장보다 먼저 한다(R3 5번 줄). 판정은 한 줄로 돈다: 판정 → (때가 됐으면) 쓰기 → 다음 판정까지 쉬기.
/// 쉬는 동안 편집·활동·요청 신호가 깨운다. rekordbox 실행·파일 확인·잠금 시도는 메인 액터 밖에서 한다.
@MainActor
public final class AutoReflection {
    public let session: ReflectionSession
    public let ports: AutoReflectionPorts
    public let timing: AutoReflectionTiming
    public let run: AutoReflectionRun
    /// 지금 칩 상태
    public private(set) var status: AutoReflectionStatus = .saved
    /// 상태 줄·⌘S가 보는 지금 조건
    public private(set) var conditions = ReflectionConditions()
    /// rekordbox에 쓰는 중(자동·수동)
    public private(set) var isWriting = false
    /// 판정을 마치고 쉬는 중(시험·자가 테스트가 본다)
    public private(set) var isParked = false
    /// 자동 저장으로 쓴 횟수(시험·자가 테스트가 본다)
    public private(set) var autoWrites = 0

    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    /// 판정 중에 신호가 왔다: 쉬지 않고 다시 판정한다
    private var dirty = false
    private var stopped = false
    private var shuttingDown = false
    /// 첫 읽기 뒤 기록 읽기·쓰기 기록 판정·재시작 정리를 마쳤다
    private var startupDone = false
    /// 마지막 대상 편집(또는 편집 활동이 끝난) 때. T_edit를 여기서 센다
    private var lastEdit: Date?
    private var activity = EditActivity()
    /// 영속 기록(멈춤·[취소]한 판·백업 전 실패). 읽지 못하면 멈춤으로 본다(R7)
    private var record = AutoReflectionRecord()
    private var recordUnreadable = false
    /// 같은 원인으로 두 번 난 백업 전 실패의 보류를 새 편집 뒤 한 번 풀어 다시 시도한다(R7)
    private var preBackupRetry = false
    /// 미리 보기에서 막혀 뺀 판(R6). 새 편집(새 판)이 생길 때만 다시 본다
    private var needsConfirmation: Set<DraftRevision> = []
    /// rekordbox·Agent가 둘 다 꺼진 것을 처음 본 때, 그때부터 바뀌지 않은 파일 상태, 마지막으로 본 때(R2 조건 1·4).
    /// "계속 꺼져 있음"은 끊기지 않고 지켜본 동안만 센다: 지켜보지 못한 틈이 있으면 처음부터 다시 센다
    private var quiet: Quiet?
    private struct Quiet {
        var since: Date
        var stamps: LibraryQuietStamps
        var checked: Date
    }
    /// 이 엔진이 쓴 뒤 처음 보는 파일 상태는 새 기준으로 받는다(자기 쓰기로 바뀐 master.db로 조용함을 다시 세지 않게)
    private var rebaselineQuiet = false
    /// 마지막으로 나눈 저장 대기와, 다시 나눠야 하는지(편집·요청·쓰기 뒤)
    private var inventory: AutoReflectionInventory?
    private var inventoryStale = true
    /// 대량 유예(R14): 끝나는 때와 그때 쓸 판
    private var grace: (until: Date, revisions: Set<DraftRevision>)?
    /// 유예를 마친(취소하지 않은) 판. K행으로 나눠 쓰는 다음 묶음은 다시 유예하지 않는다
    private var graceAccepted: Set<DraftRevision> = []
    /// 판정이 찾은 중단 기록(R11)
    private var interrupted: RekordboxJournalFinding?
    /// 재시작 정리가 남긴 보류(R22)
    private var cleanupHolds: Set<ReflectionHold> = []
    /// 다음 판정에서 쓰기 기록을 다시 판정한다
    private var journalStale = false
    /// 마지막으로 쓰기 기록을 판정한 때(중단 상태는 가끔 다시 본다: CLI·다른 프로세스가 기록을 정리했을 수 있다)
    private var lastJudged: Date?
    /// 첫 읽기 뒤 시작 정리를 기다리는 수동 쓰기
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []
    /// 차례를 기다리는 수동 쓰기 수와 깨울 곳
    private var manualWaiting = 0
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordSave: Task<Void, Never>?

    public init(session: ReflectionSession, ports: AutoReflectionPorts, run: AutoReflectionRun, timing: AutoReflectionTiming = .standard) {
        self.session = session
        self.ports = ports
        self.run = run
        self.timing = timing
    }

    // MARK: - 신호

    /// 첫 읽기 뒤 부른다: 기록을 읽고, 쓰기 기록을 판정하고, 미정리 목록을 정리한 뒤(R22) 판정을 시작한다.
    /// 남아 있던 대상 편집은 R1과 같은 조건(T_edit·조용함)으로 저장한다. 자동 저장하지 않는 실행(R18)도 기록 판정·정리는 한다
    public func start() {
        guard loop == nil, !stopped else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    /// 앱을 끌 때 대기와 감시를 멈춘다(쓰는 중인 저장은 끝까지 간다)
    public func stop() {
        stopped = true
        loop?.cancel()
        sleeper?.cancel()
    }

    /// 대상 편집이 생겼다(저장 대기가 바뀔 때마다). 마지막 편집 뒤 T_edit를 다시 센다. 대량 유예는 처음부터 다시 센다.
    /// 같은 원인으로 두 번 난 백업 전 실패의 보류도 새 편집이면 다시 시도한다(R7)
    public func edited() {
        lastEdit = ports.clock.now()
        grace = nil
        preBackupRetry = true
        wake()
    }

    /// 편집 활동 신호(R1·R19). 편집 중이면 자동 저장을 미룬다. 편집이 끝나면 그때부터 T_edit를 다시 센다
    public func setActivity(_ activity: EditActivity) {
        if self.activity.isEditing, !activity.isEditing { lastEdit = ports.clock.now() }
        self.activity = activity
        wake()
    }

    /// 대기열에 넣는다. ⌘S는 수동 저장(`exclusive`)으로 지금 저장한다. 역편집(R12)은 W3-F(#405)가 잇는다
    public func enqueue(_ request: AutoReflectionRequest) {
        switch request {
        case .saveNow:
            Task { [weak self] in
                guard let self else { return }
                _ = await exclusive({ [session] in await session.write(rows: Array(session.ports.library.state().rows.values)) }, whenHeld: { _ in .busy })
            }
        case .undo:
            wake()
        }
    }

    /// 대량 유예의 [취소](R14). 초안은 남고 그 판은 다음 편집이나 ⌘S까지 자동 저장하지 않는다(다시 켜도 이어진다)
    public func cancelGrace() {
        guard let grace else { return }
        record.cancelledRevisions.formUnion(grace.revisions)
        self.grace = nil
        saveRecord()
        wake()
    }

    /// ⌘Q(R17): 대기 중인 대상 편집을 저장하고(미리 보기 단계도 기다린다) 끝나면 돌아온다. 유예·확인 필요 편집은 쓰지 않는다.
    /// 쓰는 중이면 그 쓰기를 기다린다. 조용함 대기·종료 시트는 W3-H(#406)가 잇는다
    public func prepareToQuit() async {
        while isWriting { await waitForTurn() }
    }

    /// 로그아웃·전원 끔(R17): 새 쓰기를 시작하지 않는다. 이미 시작한 쓰기만 마친다
    public func shutdown() {
        shuttingDown = true
        wake()
    }

    /// 쓰기 전 백업·복원 시점·중단 기록으로 복원했다(R8): 자동 저장이 멈춘다. ⌘S·저장 단추로 저장에 성공하면 다시 시작한다.
    /// 중단 기록으로 복원했으면 기록이 지워졌으니 다음 판정에서 기록을 다시 본다
    public func restored() {
        record.stop = .afterRestore
        saveRecord()
        recheckJournal()
    }

    /// 쓰기 기록이 바뀌었을 수 있다("이대로 둔다"·기록으로 복원 뒤): 다음 판정에서 잠금 아래 기록을 다시 판정하고 미정리 목록을 정리한다(R11·R22)
    public func recheckJournal() {
        journalStale = true
        wake()
    }

    /// 수동 쓰기(⌘S·저장 단추·복원·곡 넣기·빼기·시점 복원)를 엔진의 차례로 한다(직렬 큐). 쓰는 중이면 그 쓰기가 끝난 뒤 다음 자동 저장보다 먼저 한다.
    /// 결과가 반영 결과면 그것을 보고 멈춤을 풀거나(저장 성공, R7) 멈춘다(복원, R8·백업 뒤 실패, R7).
    /// 쓰기 전에 시작 정리를 기다리고, 쓰기 기록을 (중단이었으면 다시) 판정하고, 미정리 목록을 정리한다(R11·R22).
    /// - Parameter whenHeld: 정리를 마치지 못해 그 대상의 다음 쓰기를 보류해야 할 때 `work` 대신 부른다(R22: 쓴 재생 목록 단계를 다시 쓰지 않게).
    ///   주지 않으면(복원 등 고치는 쓰기) 그대로 한다
    public func exclusive<T>(_ work: @MainActor () async throws -> T,
                             whenHeld: (@MainActor (Set<ReflectionHold>) -> T)? = nil) async rethrows -> T {
        manualWaiting += 1
        wake()
        while loop != nil, !startupDone, !stopped { await withCheckedContinuation { startupWaiters.append($0) } }
        while isWriting { await waitForTurn() }
        manualWaiting -= 1
        isWriting = true
        publish(status: .writing, conditions: conditions(writing: true))
        var wrote = false
        defer {
            isWriting = false
            // 수동 쓰기 동안은 지켜보지 못했다: 쓴 것으로 바뀐 파일만 새 기준으로 받고, 틈이 길면 조용함을 처음부터 다시 센다
            if wrote { rebaselineQuiet = true }
            inventoryStale = true
            resumeTurn()
            wake()
        }
        if startupDone {
            if interrupted != nil || journalStale {
                journalStale = false
                await judgeAndClean()
            } else {
                cleanupHolds = await session.resumeCleanups().holds
            }
            if interrupted == nil, !cleanupHolds.isEmpty, let whenHeld { return whenHeld(cleanupHolds) }
        }
        let result = try await work()
        if let outcome = result as? ReflectionOutcome {
            wrote = outcome.changedLibrary
            await noteManual(outcome)
        } else {
            wrote = true
        }
        return result
    }

    // MARK: - 한 줄로 도는 판정

    private func runLoop() async {
        await startup()
        while !Task.isCancelled, !stopped {
            dirty = false
            let pause = await step()
            if Task.isCancelled || stopped { break }
            if dirty { continue }
            if let pause { await park(pause) }
        }
    }

    /// 기록 읽기 → 쓰기 기록 판정 → 재시작 정리. 남은 편집도 이때부터 T_edit를 센다
    private func startup() async {
        let records = ports.records
        do { record = try await BlockingWork.run { try records.load() } } catch { recordUnreadable = true }
        await judgeAndClean()
        lastEdit = ports.clock.now()
        startupDone = true
        let waiters = startupWaiters
        startupWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// 대상의 쓰기 기록을 잠금 아래에서 판정하고, 중단이 아니면 미정리 목록을 정리한다(R11·R22).
    /// 다른 프로세스가 잠금을 쥐었으면 판정·정리를 미루고 보류한다
    private func judgeAndClean() async {
        lastJudged = ports.clock.now()
        switch await judgeJournal() {
        case let .interrupted(finding):
            interrupted = finding
        case .inProgress:
            cleanupHolds = [.lockBusy]
        case .none:
            interrupted = nil
            cleanupHolds = await session.resumeCleanups().holds
        }
    }

    /// 쓰기 잠금을 비차단으로 잡고 그 아래에서 기록을 판정한다. 잡지 못하면 진행 중이다
    private func judgeJournal() async -> RekordboxJournalVerdict {
        let lock = ports.writeLock, gate = session.ports.gate, target = session.target
        return (try? await BlockingWork.run { () throws -> RekordboxJournalVerdict in
            guard let hold = try lock.tryLock(try lock.key(target.database)) else { return .inProgress }
            defer { hold.release() }
            return try gate.journal(target, hold)
        }) ?? .inProgress
    }

    /// 판정 한 번. 때가 됐으면 쓰고 nil(곧 다시 판정)을, 기다릴 것이 있으면 쉴 길이를 돌려준다.
    /// 자동 저장하는 실행이면 저장 대기가 없어도 rekordbox 실행·파일 상태를 짧은 간격으로 지켜본다(조용함이 끊기지 않게, R2)
    private func step() async -> Duration? {
        guard manualWaiting == 0, !isWriting else { return timing.idleInterval }
        if inventoryStale || inventory == nil {
            inventoryStale = false
            let next = await session.autoInventory(cancelled: record.cancelledRevisions, needsConfirmation: needsConfirmation)
            inventory = next
            prune(next)
        }
        guard let inventory, !dirty else { return nil }
        let rowLimit = timing.rowLimit, idle = timing.idleInterval, poll = timing.pollInterval
        let hasAuto = inventory.hasAuto(rowLimit: rowLimit), leftoverCount = inventory.leftoverCount(rowLimit: rowLimit)
        var base = ReflectionConditions(leftovers: inventory.leftovers(rowLimit: rowLimit), hasPending: hasAuto || leftoverCount > 0,
                                        editingField: activity.contains(.fieldEditing), autoSaves: run.autoSaves)
        func hold(_ reason: ReflectionHold, status: AutoReflectionStatus? = nil, waiting: Bool = true, pause: Duration?) -> Duration? {
            base.holds.insert(reason)
            base.waiting = waiting
            publish(status: status ?? (reason.kind == .stop ? .stopped(reason) : .held(reason)), conditions: base)
            return pause
        }
        if startupDone, journalStale || (interrupted != nil && lastJudged.map { ports.clock.now().timeIntervalSince($0) >= 60 } ?? true) {
            journalStale = false
            await judgeAndClean()
        }
        if case let .off(reason) = run {
            return hold(.notAutoRun(reason), status: base.hasPending ? .held(.notAutoRun(reason)) : .saved, waiting: false, pause: idle)
        }
        guard startupDone else { return hold(.starting, pause: poll) }
        // 멈춤·중단 동안에도 지켜본다: ⌘S·복원으로 풀리면 조용함을 처음부터 다시 세지 않는다
        let watch = await observeLibrary()
        guard !dirty else { return nil }
        if let interrupted {
            let failed = interrupted.journal.marks.contains(.recoveryFailed)
            return hold(.interrupted(recoveryFailed: failed), status: .interrupted(recoveryFailed: failed), waiting: false, pause: poll)
        }
        if recordUnreadable || record.stop == .afterFailure { return hold(.stoppedAfterFailure, waiting: false, pause: poll) }
        if record.stop == .afterRestore { return hold(.stoppedAfterRestore, waiting: false, pause: poll) }
        if shuttingDown { return hold(.shuttingDown, waiting: false, pause: idle) }
        guard hasAuto else {
            grace = nil
            publish(status: leftoverCount > 0 ? .leftover(count: leftoverCount) : .saved, conditions: base)
            return poll
        }
        if record.preBackupFailure.map({ $0.count >= 2 }) == true, !preBackupRetry {
            return hold(.preBackupFailure, waiting: false, pause: poll)
        }
        let now = ports.clock.now()
        let appHolds = ports.appHolds()
        if activity.isEditing || appHolds.contains(.editing) {
            lastEdit = now
            return hold(.editing, status: .pending, pause: poll)
        }
        if let lastEdit, now < lastEdit + Self.seconds(timing.editDelay) {
            base.waiting = true
            publish(status: .pending, conditions: base)
            return .seconds(min((lastEdit + Self.seconds(timing.editDelay)).timeIntervalSince(now), Self.seconds(poll)))
        }
        // 대량 유예(R14): 유예 동안 「N초 뒤 저장 · [취소]」. ⌘Q·창 전환으로 앞당기지 않는다
        let autoRevisions = inventory.autoRevisions(rowLimit: rowLimit)
        if inventory.isBulk(timing: timing), !autoRevisions.isSubset(of: graceAccepted) {
            let grace = grace ?? (now + Self.seconds(timing.bulkDelay), autoRevisions)
            self.grace = grace
            if now < grace.until {
                base.waiting = true
                let left = grace.until.timeIntervalSince(now)
                publish(status: .grace(secondsLeft: Int(left.rounded(.up))), conditions: base)
                return .seconds(min(left, Self.seconds(poll)))
            }
            graceAccepted = grace.revisions
            self.grace = nil
        }
        if let reason = Self.firstHold(appHolds.subtracting([.editing])) { return hold(reason, pause: poll) }
        // rekordbox·Agent가 둘 다 꺼진 뒤 조용함 다섯 조건(R2). 5번(새로 읽은 사본으로 base 확인)은 쓰기의 미리 보기가 한다
        switch watch.run {
        case .running, .unknown: return hold(.rekordboxRunning, status: .rekordboxRunning(agentOnly: false), pause: poll)
        case .agentOnly: return hold(.agentRunning, status: .rekordboxRunning(agentOnly: true), pause: poll)
        case .stopped: break
        }
        if let wal = watch.stamps.walSize, wal > 0 { return hold(.walRemains, pause: poll) }
        if watch.stamps.shmExists { return hold(.shmRemains, pause: poll) }
        if let quiet, now < quiet.since + Self.seconds(timing.quietDelay) {
            base.waiting = true
            base.holds.insert(.quietWaiting)
            publish(status: .quietWaiting, conditions: base)
            return .seconds(min((quiet.since + Self.seconds(timing.quietDelay)).timeIntervalSince(now), Self.seconds(poll)))
        }
        // 백업 조건(R13): 같은 볼륨이라 클론이 되고 여유 공간이 넉넉하다. 어긋나면 이유를 보이고 보류한다(조건이 풀리면 저절로 다시 시작)
        let backups = session.ports.backups, target = session.target
        switch await BlockingWork.run(qos: .utility, { backups.autoSaveCondition(target.backups, target.database) }) {
        case .ready: break
        case .noClone, .unknown: return hold(.backupNoClone, status: .leftover(count: max(leftoverCount, 1)), waiting: false, pause: poll)
        case .lowSpace: return hold(.lowDiskSpace, status: .leftover(count: max(leftoverCount, 1)), waiting: false, pause: poll)
        }
        // 다른 프로세스가 쓰는 중이면(쓰기 잠금) 잡을 수 있을 때까지 보류하고, 잡으면 그 아래에서 기록을 판정한다(R9·R11)
        switch await judgeJournal() {
        case .inProgress: return hold(.lockBusy, pause: poll)
        case let .interrupted(finding):
            interrupted = finding
            let failed = finding.journal.marks.contains(.recoveryFailed)
            return hold(.interrupted(recoveryFailed: failed), status: .interrupted(recoveryFailed: failed), waiting: false, pause: poll)
        case .none: break
        }
        // 쓰기마다 그 전에 남은 미정리 목록을 정리한다. 마치지 못한 목록이 있으면 그 대상의 다음 쓰기를 보류한다(R22: 쓴 단계를 다시 쓰지 않게)
        let resumed = await session.resumeCleanups()
        cleanupHolds = resumed.holds
        if let reason = Self.firstHold(cleanupHolds) { return hold(reason, pause: poll) }
        // 정리로 초안이 바뀌었으면 저장 대기를 다시 나눈다
        if resumed.finished > 0 {
            inventoryStale = true
            return nil
        }
        // 오늘 뜰 차례면 시점 스냅샷을 먼저 뜬다(R13). 잠금을 못 잡았거나 중단 기록이 있으면 뜨지 않고 보류한다
        base.waiting = true
        publish(status: .held(.pointSnapshot), conditions: base)
        if case let .held(reason) = await ports.pointSnapshot() {
            if case .interrupted = reason { await judgeAndClean() }
            return hold(reason, pause: poll)
        }
        // 스냅샷을 뜨느라 지켜보지 못한 틈이 있으면 처음부터 다시 판정한다(조용함을 다시 본다)
        if ports.clock.now().timeIntervalSince(now) > Self.seconds(poll) { return nil }
        guard !dirty, manualWaiting == 0, !isWriting else { return nil }
        guard let chunk = inventory.chunk(rowLimit: rowLimit) else { return poll }
        return await write(chunk)
    }

    /// rekordbox·Agent 실행 여부와 대상 폴더의 파일 상태를 메인 액터 밖에서 보고 조용함을 센다(R2 조건 1·4).
    /// 켜져 있으면 조용함을 지운다. 지켜보지 못한 틈이 있었거나 master.db·masterPlaylists6.xml이 바뀌었으면 처음부터 다시 센다(자기 쓰기 뒤는 기준만 바꾼다)
    private func observeLibrary() async -> (run: RekordboxRunState, stamps: LibraryQuietStamps) {
        let runState = ports.runState, quietStamps = ports.quietStamps, target = session.target
        let seen = await BlockingWork.run(qos: .utility) { (run: runState(), stamps: quietStamps(target)) }
        let now = ports.clock.now()
        guard seen.run == .stopped else {
            quiet = nil
            rebaselineQuiet = false
            return seen
        }
        let gap = Self.seconds(timing.pollInterval) * 3
        if var current = quiet, now.timeIntervalSince(current.checked) <= gap {
            if current.stamps.database != seen.stamps.database || current.stamps.playlistsXML != seen.stamps.playlistsXML {
                current = rebaselineQuiet ? Quiet(since: current.since, stamps: seen.stamps, checked: now)
                    : Quiet(since: now, stamps: seen.stamps, checked: now)
            }
            current.checked = now
            quiet = current
        } else {
            quiet = Quiet(since: now, stamps: seen.stamps, checked: now)
        }
        rebaselineQuiet = false
        return seen
    }

    /// 이 엔진이 쓰는 동안은 관문이 rekordbox를 다시 본다: 쓴 뒤에는 조용함을 이어 가되 파일 상태는 새 기준으로 받는다
    private func wroteLibrary() {
        guard quiet != nil else { return }
        quiet?.checked = ports.clock.now()
        rebaselineQuiet = true
    }

    /// 고른 묶음을 자동으로 쓰고 결과로 다음 판정을 정한다(R6·R7)
    private func write(_ chunk: AutoReflectionChunk) async -> Duration? {
        isWriting = true
        publish(status: .writing, conditions: conditions(writing: true))
        let outcome = await session.autoWrite(chunk)
        isWriting = false
        inventoryStale = true
        defer {
            resumeTurn()
        }
        switch outcome {
        case let .written(_, unwritten):
            autoWrites += 1
            wroteLibrary()
            needsConfirmation.formUnion(unwritten)
            grace = nil
            if record.preBackupFailure != nil {
                record.preBackupFailure = nil
                saveRecord()
            }
            return nil
        case let .nothingWritten(unwritten):
            needsConfirmation.formUnion(unwritten)
            return timing.pollInterval
        case .busy, .cancelled:
            return timing.pollInterval
        case .rekordboxRunning:
            quiet = nil
            return nil
        case let .failed(error):
            // 백업 전 실패는 잠시 쉬고 다시 본다(같은 원인 두 번이면 보류). 그 밖은 곧바로 다시 판정해 멈춤·중단·조용함을 알린다
            return await classify(error) ? timing.pollInterval : nil
        }
    }

    /// 자동 저장 실패를 나눈다(R7·R10·R11): 쓰기 기록이 남았으면 중단, 커밋 전에 켜짐을 봤으면 조용함부터 다시, 백업 뒤 실패해 복구를 마쳤으면 멈춤,
    /// 백업을 뜨기 전 실패는 같은 원인으로 두 번 나면 보류(새 편집·⌘S 때 다시 시도)
    /// - Returns: 잠시 쉬고 다시 볼지(백업 전 실패를 처음 셌다)
    private func classify(_ error: any Error) async -> Bool {
        if case let .interrupted(finding) = await judgeJournal() {
            interrupted = finding
            return false
        }
        switch error as? DJCError {
        case .rekordboxRunning?, .writeAheadLogPresent?:
            quiet = nil
            return false
        case .writeVerificationFailed?, .writeRolledBack?, .restoreFailed?, .pointRestoreFailed?:
            record.stop = .afterFailure
            saveRecord()
            return false
        default:
            let cause = Self.failureCause(error)
            let count = record.preBackupFailure?.cause == cause ? (record.preBackupFailure?.count ?? 0) + 1 : 1
            record.preBackupFailure = .init(cause: cause, count: count)
            preBackupRetry = false
            saveRecord()
            // 두 번째면 곧바로 다시 판정해 보류를 알린다
            return count < 2
        }
    }

    /// 수동 쓰기의 결과: 저장에 성공하면 멈춤·백업 전 실패 보류·[취소]·확인 필요를 푼다(R7·R14), 복원했으면 멈춘다(R8), 실패하면 기록을 다시 판정한다
    private func noteManual(_ outcome: ReflectionOutcome) async {
        switch outcome {
        case .written:
            needsConfirmation = []
            recordUnreadable = false
            record = AutoReflectionRecord()
            saveRecord()
        case .restored:
            record.stop = .afterRestore
            saveRecord()
            journalStale = true
        case let .failed(_, error, _):
            // 수동 저장도 백업을 뜬 뒤 쓰기·검증에 실패해 되돌렸으면 자동 저장이 멈춘다(같은 묶음을 자동으로 다시 쓰지 않게, R7)
            switch error as? DJCError {
            case .writeVerificationFailed?, .writeRolledBack?, .restoreFailed?:
                record.stop = .afterFailure
                saveRecord()
            default: break
            }
            await judgeAndClean()
        case .restoreFailed:
            await judgeAndClean()
        default:
            break
        }
    }

    // MARK: - 도움

    /// 새 판을 받은(다음 편집) 초안의 [취소]·확인 필요는 저절로 풀린다
    private func prune(_ inventory: AutoReflectionInventory) {
        let known = inventory.known
        needsConfirmation.formIntersection(known)
        let cancelled = record.cancelledRevisions.intersection(known)
        if cancelled != record.cancelledRevisions {
            record.cancelledRevisions = cancelled
            saveRecord()
        }
    }

    /// 백업 전 실패의 원인(같은 원인인지 견준다, R7). 오류 문장에는 경로·시각이 들어 매번 달라지므로 종류로 묶는다:
    /// 앱 오류는 경우 이름, 그 밖은 오류 영역과 번호
    public static func failureCause(_ error: any Error) -> String {
        if let djc = error as? DJCError { return "DJCError." + (Mirror(reflecting: djc).children.first?.label ?? "\(djc)") }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }

    /// 앱 보류 사유 가운데 상태로 보일 하나(겹치면 이 차례)
    static func firstHold(_ holds: Set<ReflectionHold>) -> ReflectionHold? {
        let order: [ReflectionHold] = [.shuttingDown, .usbBusy, .blockedDraftsOpen, .importSheetOpen, .libraryReading, .linkServer,
                                       .lockBusy, .cleanupStoreMissing, .playlistCopyFailed, .cleanupPending, .pointSnapshot, .hardLinkedDatabase,
                                       .stagingUnavailable]
        if let unwritable = holds.first(where: { if case .unwritable = $0 { true } else { false } }) { return unwritable }
        return order.first(where: holds.contains) ?? holds.sorted { "\($0)" < "\($1)" }.first
    }

    private func conditions(writing: Bool) -> ReflectionConditions {
        var next = conditions
        next.writing = writing
        next.waiting = false
        return next
    }

    private func publish(status: AutoReflectionStatus, conditions: ReflectionConditions) {
        guard status != self.status || conditions != self.conditions else { return }
        self.status = status
        self.conditions = conditions
        ports.publish(status, conditions)
    }

    /// 기록을 남긴다. 남기기는 메인 액터 밖에서 차례대로 한다(앞 남기기가 끝난 뒤 다음 것을 남겨 옛 기록이 새 기록을 덮지 않게)
    private func saveRecord() {
        let records = ports.records, record = record, previous = recordSave
        recordSave = Task {
            await previous?.value
            await BlockingWork.run(qos: .utility) { try? records.save(record) }
        }
    }

    /// 마지막으로 맡긴 기록 남기기(시험·자가 테스트가 기다린다)
    public func recordSaved() async { await recordSave?.value }

    private func park(_ duration: Duration) async {
        isParked = true
        defer { isParked = false }
        let clock = ports.clock
        let task = Task { _ = try? await clock.sleep(duration) }
        sleeper = task
        await task.value
        sleeper = nil
    }

    private func wake() {
        dirty = true
        inventoryStale = true
        sleeper?.cancel()
    }

    private func waitForTurn() async {
        await withCheckedContinuation { turnWaiters.append($0) }
    }

    private func resumeTurn() {
        let waiters = turnWaiters
        turnWaiters = []
        waiters.forEach { $0.resume() }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18
    }
}

extension ReflectionOutcome {
    /// 이 흐름이 rekordbox 라이브러리를 바꿨는지(쓰기·넣기·빼기·복원)
    var changedLibrary: Bool {
        switch self {
        case .written, .autoWritten, .added, .deleted, .restored: true
        case .busy, .declined, .notice, .cancelled, .nothingWritable, .nothingAdded, .nothingDeleted, .failed, .restoreFailed: false
        }
    }
}
