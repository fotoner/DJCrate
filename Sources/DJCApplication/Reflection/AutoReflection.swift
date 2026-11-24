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

/// 자동 저장 대기열에 넣는 요청. ⌘S·저장 단추는 여기로 오지 않고 조정자의 저장(`ReflectionCoordinator.startWrite`)이 엔진의 차례(`exclusive`)로 한다
public enum AutoReflectionRequest: Equatable, Sendable {
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
    /// 지금 도는 자동 저장 쓰기 하나(루프와 따로 도는 작업: 루프를 취소하면 자동 저장 전체가 멈추므로 [취소]는 이 작업에만 간다)
    private var autoWriting: Task<ReflectionSession.AutoWriteOutcome, Never>?
    /// 지금 도는 자동 저장 쓰기를 사용자가 [취소]했다(쓰기마다 처음에 푼다)
    private var userCancelledWrite = false
    /// 지금 도는 자동 저장 쓰기가 다루는 판: 묶음의 판과, 사용자가 [취소]하면 함께 멈출 자동으로 쓸 판 전부
    private var writingRevisions: Set<DraftRevision> = []
    /// 아직 끝나지 않은 기록 저장 수
    private var recordSaves = 0
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
    /// 마지막 기록 남기기가 실패했다: 멈춤·[취소]가 디스크에 없어 다시 켜면 풀릴 수 있으니 남길 때까지 자동 저장을 보류하고 판정마다 다시 남겨 본다
    private var recordSaveFailed = false
    /// 같은 원인으로 두 번 난 백업 전 실패의 보류를 사람 편집의 새 판이 생긴 뒤 한 번 풀어 다시 시도한다(R7)
    private var preBackupRetry = false
    /// 백업 전 실패로 보류할 때 저장 대기에 있던 판(여기 없는 판이 생기면 다시 시도한다)
    private var preBackupSeen: Set<DraftRevision>?
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
    /// 여러 곡 역편집 묶음(R12, `enqueue(.undo)`)
    private var undoGroups: [AutoReflectionUndoGroup] = []
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
    /// 쓰기 잠금을 잡지 못해 기록 판정·정리를 미뤘다. 잡을 때까지 판정마다(대기 초안·실행 조건과 상관없이) 다시 한다(R11)
    private var journalPending = false
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
    /// 같은 원인으로 두 번 난 백업 전 실패의 보류는 다시 나눈 저장 대기에 사람 편집의 새 판이 있을 때만 다시 시도한다(R7)
    public func edited() {
        lastEdit = ports.clock.now()
        grace = nil
        wake()
    }

    /// 편집 활동 신호(R1·R19). 편집 중이면 자동 저장을 미룬다. 편집이 끝나면 그때부터 T_edit를 다시 센다
    public func setActivity(_ activity: EditActivity) {
        if self.activity.isEditing, !activity.isEditing { lastEdit = ports.clock.now() }
        self.activity = activity
        wake()
    }

    /// 대기열에 넣는다. 여러 곡 역편집(R12)은 한 묶음으로 보통 자동 저장과 따로, 전부 쓰거나 전부 쓰지 않는다. K행을 넘으면 ⌘S·저장 단추로 쓴다.
    /// 묶음은 앱 수명 동안만 든다(항목별 되돌리기의 영속 기록은 범위 밖: 다시 켜면 그 초안은 보통 편집으로 쓴다)
    public func enqueue(_ request: AutoReflectionRequest) {
        switch request {
        case let .undo(edit):
            undoGroups.removeAll { $0.id == edit.id }
            if edit.batch.draftKeys.count > 1 { undoGroups.append(AutoReflectionUndoGroup(edit)) }
            wake()
        }
    }

    /// 지금 도는 자동 저장 쓰기 하나만 취소한다(미리 보기 [취소]·Esc). 엔진 루프는 건드리지 않아 다음 판정이 이어진다.
    /// 자동 저장이 쓰는 중이 아니면(수동 쓰기·차례를 기다리는 쓰기·쉬는 중) 아무것도 하지 않고 false
    /// - Parameter byUser: 사용자가 [취소]·Esc로 멈췄다. 그러면 대량 유예의 [취소]처럼(R14) 그 판들의 초안은 남고 새 편집이나 ⌘S 전까지
    ///   자동 저장하지 않는다(기록에 남아 다시 켜도 이어진다). 앱 종료처럼 사용자가 거절한 것이 아닌 취소는 false로 부른다: 판을 남기지 않고 다시 본다
    @discardableResult
    public func cancelAutoWrite(byUser: Bool = true) -> Bool {
        guard let autoWriting else { return false }
        if byUser {
            // 받은 순간 그 판들을 취소한 판으로 남기고 저장을 시작한다: 미리 보기가 어떤 결과로 돌아오든(오류 포함), 그전에 앱을 꺼도 이어진다.
            // 오류 분류(멈춤·백업 전 실패)는 쓰기 결과를 받아 그대로 한다
            userCancelledWrite = true
            record.cancelledRevisions.formUnion(writingRevisions)
            saveRecord()
        }
        autoWriting.cancel()
        return true
    }

    /// 아직 디스크에 남기지 못한 기록 저장(없으면 nil). 앱을 끄는 길이 이 저장이 끝난 뒤에 끈다: 취소한 판이 메모리에만 있으면 다시 켠 뒤 같은 판을 자동으로 쓴다
    public var pendingRecordSave: Task<Void, Never>? { recordSaves > 0 ? recordSave : nil }

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

    /// 앱이 라이브러리를 다시 읽었다(성공). 다음 판정에서 잠금 아래 기록을 다시 판정하고 미정리 목록을 정리한다(엔진이 모르는 사이
    /// 앱의 곡 넣기가 미룬 정리도 풀린다). 새 곡이 없다는 확정은 그 정리가 읽은 사본이 라이브 DB와 같을 때만 한다(`ReflectionSession.resumeCleanups`).
    /// 엔진 시작 전에 온 첫 읽기도 시작 정리가 같은 판정으로 다룬다
    public func libraryReloaded() {
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
            // 저장하지 못한 재생 목록 초안은 먼저 저장해 본다(그대로면 재시작 정리가 재생 목록 몫을 미룬다, R22)
            let library = session.ports.library
            if library.state().playlistDraftUnsaved { _ = library.savePlaylistDraft() }
            // 늘 쓰기 잠금 아래에서 기록을 판정하고 기록이 없을 때만 정리한다(R11·R22: 그 사이 다른 실행이 남긴 중단의 초안을 지우지 않게).
            // 수동 쓰기는 잠금을 기다려(메인 액터 밖) 판정·정리를 마친 뒤 쓴다: 정리하지 않은 채 쓰면 쓴 단계를 또 쓴다
            journalStale = false
            let judged = await judgeAndClean(waits: true)
            // 잠금 아래 판정을 하지 못했으면(rekordbox가 켜져 기록을 판정하지 못함·잠금·기록을 읽다 실패) 이전 보류로 판단해 정리 없이 쓰지 않는다.
            // 알림이 이유를 고르게 실행 상태를 메인 액터 밖에서 보고 함께 넘긴다
            if case .busy = judged, let whenHeld {
                let runState = ports.runState
                var holds: Set<ReflectionHold> = [.lockBusy]
                switch await BlockingWork.run(qos: .userInitiated, { runState() }) {
                case .running, .unknown: holds.insert(.rekordboxRunning)
                case .agentOnly: holds.insert(.agentRunning)
                case .stopped: break
                }
                return whenHeld(holds)
            }
            // 정리를 마치지 못한 목록이 있으면 쓰지 않는다
            if interrupted == nil, !cleanupHolds.isEmpty, let whenHeld { return whenHeld(cleanupHolds) }
        }
        let result: T
        do {
            result = try await work()
        } catch {
            // 실패한 쓰기·복원이 기록을 남겼을 수 있다: 다음 판정에서 다시 본다
            journalStale = true
            throw error
        }
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

    /// 대상의 쓰기 잠금을 쥔 채 기록을 판정하고, 기록이 없으면 같은 잠금 아래에서 미정리 목록을 정리한다(R11·R22).
    /// 다른 프로세스가 잠금을 쥐었으면 판정·정리를 미루고 잡을 때까지 판정마다 다시 한다
    /// - Parameter waits: 잠금을 기다린다(수동 쓰기). 판정 줄은 기다리지 않는다
    @discardableResult
    private func judgeAndClean(waits: Bool = false) async -> ReflectionSession.JournalCleanup {
        lastJudged = ports.clock.now()
        let judged = await session.judgeAndResumeCleanups(lock: ports.writeLock, waits: waits)
        switch judged {
        case .busy:
            journalPending = true
        case let .interrupted(finding):
            interrupted = finding
            journalPending = false
        case let .cleaned(resumed):
            interrupted = nil
            journalPending = false
            cleanupHolds = resumed.holds
        }
        return judged
    }

    /// 쓰기 잠금을 비차단으로 잡고 그 아래에서 기록만 판정한다(실패 분류). 잡지 못하면 진행 중이다
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
        let rowLimit = timing.rowLimit, idle = timing.idleInterval, poll = timing.pollInterval
        if inventoryStale || inventory == nil {
            inventoryStale = false
            let next = await session.autoInventory(cancelled: record.cancelledRevisions, needsConfirmation: needsConfirmation)
            inventory = next
            prune(next)
            notePreBackupRetry(next.autoRevisions(rowLimit: rowLimit))
        }
        guard var inventory, !dirty else { return nil }
        // 여러 곡 역편집 묶음은 보통 자동 저장에서 빼고 따로 전부 아니면 전무로 쓴다(R12)
        let undo = inventory.applyingUndo(undoGroups, rowLimit: rowLimit)
        undoGroups = undo.groups
        let hasAuto = inventory.hasAuto(rowLimit: rowLimit) || undo.chunk != nil, leftoverCount = inventory.leftoverCount(rowLimit: rowLimit)
        var base = ReflectionConditions(leftovers: inventory.leftovers(rowLimit: rowLimit), hasPending: hasAuto || leftoverCount > 0,
                                        editingField: activity.contains(.fieldEditing), autoSaves: run.autoSaves)
        func hold(_ reason: ReflectionHold, status: AutoReflectionStatus? = nil, waiting: Bool = true, pause: Duration?) -> Duration? {
            base.holds.insert(reason)
            base.waiting = waiting
            publish(status: status ?? (reason.kind == .stop ? .stopped(reason) : .held(reason)), conditions: base)
            return pause
        }
        // 미룬 판정(잠금을 못 잡음)·다시 보라는 요청·가끔 다시 보는 중단은 대기 초안·실행 조건과 상관없이 판정한다
        if startupDone, journalStale || journalPending || (interrupted != nil && lastJudged.map { ports.clock.now().timeIntervalSince($0) >= 60 } ?? true) {
            journalStale = false
            await judgeAndClean()
        }
        // 지금 걸린 사유를 모두 조건에 모은다(상태 줄이 R3 표의 겹친 줄을 가린다). 칩은 아래 갈래가 고른 첫 사유만 보인다
        let appHolds = ports.appHolds()
        let editing = activity.isEditing || appHolds.contains(.editing)
        let preBackupHeld = record.preBackupFailure.map { $0.count >= 2 } == true && !preBackupRetry
        base.holds.formUnion(appHolds)
        if editing { base.holds.insert(.editing) }
        if journalPending { base.holds.insert(.lockBusy) }
        if let interrupted {
            base.holds.insert(.interrupted(recoveryFailed: interrupted.journal.marks.contains(.recoveryFailed)))
            // 다시 판정할 때마다 실린다: 상태 줄이 [이대로 두기…]를 먼저 보일지 정한다(#404)
            base.interruptedChangedSince = interrupted.changedSince
        }
        if recordUnreadable || recordSaveFailed || record.stop == .afterFailure { base.holds.insert(.stoppedAfterFailure) }
        if record.stop == .afterRestore { base.holds.insert(.stoppedAfterRestore) }
        if shuttingDown { base.holds.insert(.shuttingDown) }
        if case let .off(reason) = run { base.holds.insert(.notAutoRun(reason)) }
        if preBackupHeld { base.holds.insert(.preBackupFailure) }
        func interruptedHold(_ finding: RekordboxJournalFinding) -> Duration? {
            let failed = finding.journal.marks.contains(.recoveryFailed)
            return hold(.interrupted(recoveryFailed: failed), status: .interrupted(recoveryFailed: failed), waiting: false, pause: poll)
        }
        // 확인한 중단은 실행 조건보다 먼저 알린다(자동 저장하지 않는 실행도 복원 안내를 띄운다)
        if case .off = run, let interrupted { return interruptedHold(interrupted) }
        if case let .off(reason) = run {
            // 자동 저장하지 않는 실행도 rekordbox 켜짐을 조건에 싣는다(상태 줄 R3 3번 줄이 6번 줄보다 앞선다). 쓰지는 않는다
            let runState = ports.runState
            switch await BlockingWork.run(qos: .utility, { runState() }) {
            case .running, .unknown: base.holds.insert(.rekordboxRunning)
            case .agentOnly: base.holds.insert(.agentRunning)
            case .stopped: break
            }
            guard !dirty else { return nil }
            return hold(.notAutoRun(reason), status: base.hasPending ? .held(.notAutoRun(reason)) : .saved, waiting: false,
                        pause: journalPending || interrupted != nil || base.hasPending ? poll : idle)
        }
        guard startupDone else { return hold(.starting, pause: poll) }
        // 멈춤·중단 동안에도 지켜본다: ⌘S·복원으로 풀리면 조용함을 처음부터 다시 세지 않는다
        let watch = await observeLibrary()
        guard !dirty else { return nil }
        switch watch.run {
        case .running, .unknown: base.holds.insert(.rekordboxRunning)
        case .agentOnly: base.holds.insert(.agentRunning)
        case .stopped: break
        }
        if let wal = watch.stamps.walSize, wal > 0 { base.holds.insert(.walRemains) }
        if watch.stamps.shmExists { base.holds.insert(.shmRemains) }
        if let interrupted { return interruptedHold(interrupted) }
        if recordSaveFailed {
            // 남기지 못한 기록을 다시 남겨 본다(되면 깨워 이어 간다)
            saveRecord()
            return hold(.stoppedAfterFailure, waiting: false, pause: poll)
        }
        if recordUnreadable || record.stop == .afterFailure { return hold(.stoppedAfterFailure, waiting: false, pause: poll) }
        if record.stop == .afterRestore { return hold(.stoppedAfterRestore, waiting: false, pause: poll) }
        if shuttingDown { return hold(.shuttingDown, waiting: false, pause: idle) }
        guard hasAuto else {
            grace = nil
            publish(status: leftoverCount > 0 ? .leftover(count: leftoverCount) : .saved, conditions: base)
            return poll
        }
        if preBackupHeld { return hold(.preBackupFailure, waiting: false, pause: poll) }
        let now = ports.clock.now()
        if editing {
            lastEdit = now
            grace = nil
            return hold(.editing, status: .pending, pause: poll)
        }
        if let lastEdit, now < lastEdit + Self.seconds(timing.editDelay) {
            base.waiting = true
            publish(status: .pending, conditions: base)
            return .seconds(min((lastEdit + Self.seconds(timing.editDelay)).timeIntervalSince(now), Self.seconds(poll)))
        }
        // 앱 보류 사유·rekordbox 켜짐은 대량 유예보다 먼저 본다. 그동안은 유예를 세지 않는다(풀린 뒤 처음부터 다시 센다, R14·R16)
        if let reason = Self.firstHold(appHolds.subtracting([.editing])) {
            grace = nil
            return hold(reason, pause: poll)
        }
        // rekordbox·Agent가 둘 다 꺼진 뒤 조용함 다섯 조건(R2). 5번(새로 읽은 사본으로 base 확인)은 쓰기의 미리 보기가 한다
        switch watch.run {
        case .running, .unknown:
            grace = nil
            return hold(.rekordboxRunning, status: .rekordboxRunning(agentOnly: false), pause: poll)
        case .agentOnly:
            grace = nil
            return hold(.agentRunning, status: .rekordboxRunning(agentOnly: true), pause: poll)
        case .stopped: break
        }
        // 대량 유예(R14): 유예 동안 「N초 뒤 저장 · [취소]」. ⌘Q·창 전환으로 앞당기지 않는다
        let autoRevisions = inventory.autoRevisions(rowLimit: rowLimit).union(undo.chunk?.revisions ?? [])
        // 여러 곡 역편집도 M곡 이상이거나 여러 곡의 값을 지우면 대량 유예를 거친다(R14)
        let undoBulk = undo.chunk.map { $0.rows >= timing.bulkTracks || inventory.clearing.intersection($0.tracks.keys).count >= 2 } ?? false
        if inventory.isBulk(timing: timing) || undoBulk, !autoRevisions.isSubset(of: graceAccepted) {
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
        // 다른 프로세스가 쓰는 중이면(쓰기 잠금) 잡을 수 있을 때까지 보류하고, 잡으면 그 아래에서 기록을 판정하고 남은 미정리 목록을 정리한다
        // (R9·R11·R22). 마치지 못한 목록이 있으면 그 대상의 다음 쓰기를 보류한다(쓴 단계를 다시 쓰지 않게)
        switch await judgeAndClean() {
        case .busy: return hold(.lockBusy, pause: poll)
        case let .interrupted(finding): return interruptedHold(finding)
        case let .cleaned(resumed):
            if let reason = Self.firstHold(cleanupHolds) { return hold(reason, pause: poll) }
            // 정리로 초안이 바뀌었으면 저장 대기를 다시 나눈다
            if resumed.finished > 0 {
                inventoryStale = true
                return nil
            }
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
        guard let chunk = undo.chunk ?? inventory.chunk(rowLimit: rowLimit) else { return poll }
        return await write(chunk)
    }

    /// 세션이 쓰기 잠금을 걸기 직전(같은 메인 액터 구간)에 다시 보는 조건(R1·R16): 준비하는 동안 편집을 시작했거나 앱 보류 사유가 생겼거나
    /// 새 신호(편집·요청)가 왔으면 쓰지 않고 다시 판정한다
    private func mayStartWrite() -> Bool {
        !activity.isEditing && ports.appHolds().isEmpty && !shuttingDown && !stopped && !dirty && manualWaiting == 0
    }

    /// 같은 원인으로 두 번 난 백업 전 실패의 보류는 사람 편집의 새 판이 생겼을 때만 한 번 풀어 다시 시도한다(R7).
    /// 다시 읽기처럼 판이 그대로인 변경으로는 풀지 않는다
    private func notePreBackupRetry(_ revisions: Set<DraftRevision>) {
        guard let failure = record.preBackupFailure, failure.count >= 2, !preBackupRetry else { return }
        guard let seen = preBackupSeen else {
            preBackupSeen = revisions
            return
        }
        if !revisions.isSubset(of: seen) { preBackupRetry = true }
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
    /// 마지막으로 지켜본 때는 그대로 둔다: 쓰고 다시 읽느라 지켜보지 못한 틈이 길면(3초 넘게) 다음 관찰이 조용함을 처음부터 다시 센다(R2)
    private func wroteLibrary() {
        guard quiet != nil else { return }
        rebaselineQuiet = true
    }

    /// 고른 묶음을 자동으로 쓰고 결과로 다음 판정을 정한다(R6·R7)
    private func write(_ chunk: AutoReflectionChunk) async -> Duration? {
        isWriting = true
        publish(status: .writing, conditions: conditions(writing: true))
        userCancelledWrite = false
        writingRevisions = chunk.revisions.union(inventory?.autoRevisions(rowLimit: timing.rowLimit) ?? [])
        let writing = Task { await session.autoWrite(chunk, mayWrite: { [unowned self] in mayStartWrite() }) }
        autoWriting = writing
        // 루프의 취소(앱 종료)는 그대로 쓰기에 전한다
        let outcome = await withTaskCancellationHandler { await writing.value } onCancel: { writing.cancel() }
        autoWriting = nil
        writingRevisions = []
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
            preBackupSeen = nil
            if record.preBackupFailure != nil {
                record.preBackupFailure = nil
                saveRecord()
            }
            return nil
        case .held:
            // 준비하는 동안 보류 사유·편집·새 신호가 생겼다: 곧바로 다시 판정해 알린다
            return nil
        case let .nothingWritten(unwritten):
            needsConfirmation.formUnion(unwritten)
            return timing.pollInterval
        case .lockBusy:
            // 판정 뒤 쓰기 입구가 잡기 전에 다른 프로세스가 잠금을 잡았다: 기다리지 않고 잠금 보류로 알린 뒤 다시 본다(R9)
            var held = conditions(writing: false)
            held.holds.insert(.lockBusy)
            publish(status: .held(.lockBusy), conditions: held)
            return timing.pollInterval
        case .busy:
            return timing.pollInterval
        case .cancelled:
            // 사용자가 멈춘 쓰기는 받은 순간 기록했다(`cancelAutoWrite`). 곧바로 다시 판정해 남은 편집 줄을 알린다
            return userCancelledWrite ? nil : timing.pollInterval
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
            // 보류하면 지금 저장 대기의 판을 적어 둔다(사람 편집의 새 판이 생기면 다시 시도한다)
            preBackupSeen = count >= 2 ? inventory?.autoRevisions(rowLimit: timing.rowLimit) : nil
            saveRecord()
            // 두 번째면 곧바로 다시 판정해 보류를 알린다
            return count < 2
        }
    }

    /// 수동 쓰기의 결과: 저장에 성공하면 멈춤·백업 전 실패 보류·[취소]·확인 필요를 푼다(R7·R14), 복원했으면 멈춘다(R8), 실패하면 기록을 다시 판정한다
    private func noteManual(_ outcome: ReflectionOutcome) async {
        switch outcome {
        case .written:
            // 멈춤·백업 전 실패 보류·읽지 못한 기록만 푼다. [취소]한 판은 실제로 사라졌을 때만 솎는다(일부만 쓴 저장이 다른 곡의 [취소]를 풀지 않게, R14)
            needsConfirmation = []
            recordUnreadable = false
            record.stop = nil
            record.preBackupFailure = nil
            preBackupSeen = nil
            saveRecord()
        case .restored:
            record.stop = .afterRestore
            saveRecord()
            journalStale = true
        case let .failed(_, error, _):
            // 수동 저장도 백업을 뜬 뒤 실패했으면 자동 저장이 멈춘다(같은 묶음을 자동으로 다시 쓰지 않게, R7).
            // 관문이 백업 뒤 표시(`AfterBackupFailure`)를 실은 오류와 쓰기·검증에 실패해 되돌린 오류다
            switch error as? DJCError {
            case .writeVerificationFailed?, .writeRolledBack?, .restoreFailed?:
                record.stop = .afterFailure
                saveRecord()
            default:
                if error is RekordboxWriteGate.AfterBackupFailure {
                    record.stop = .afterFailure
                    saveRecord()
                }
            }
            await judgeAndClean()
        case .restoreFailed:
            await judgeAndClean()
        case .added:
            // 곡 넣기는 앱이 정리를 미뤘을 수 있다(넣은 뒤 다시 읽기 실패): 다음 판정에서 잠금 아래 다시 본다
            journalStale = true
        default:
            break
        }
    }

    // MARK: - 도움

    /// 새 판을 받은(다음 편집) 초안의 [취소]·확인 필요는 저절로 풀린다. 재생 목록 초안을 판정할 수 없는 동안(디스크 ≠ 메모리·저장 실패)은
    /// 판이 사라졌는지 모르므로 솎지 않는다
    private func prune(_ inventory: AutoReflectionInventory) {
        guard !inventory.playlistUndetermined else { return }
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

    /// 기록을 남긴다. 남기기는 메인 액터 밖에서 차례대로 한다(앞 남기기가 끝난 뒤 다음 것을 남겨 옛 기록이 새 기록을 덮지 않게).
    /// 실패하면 남길 때까지 자동 저장을 보류한다(R7·R8·R14: 멈춤·[취소]를 남기지 못한 채 쓰지 않는다)
    private func saveRecord() {
        let records = ports.records, record = record, previous = recordSave
        recordSaves += 1
        recordSave = Task { [weak self] in
            await previous?.value
            let saved = await BlockingWork.run(qos: .utility) { (try? records.save(record)) != nil }
            self?.noteRecordSave(saved)
        }
    }

    private func noteRecordSave(_ saved: Bool) {
        recordSaves -= 1
        guard recordSaveFailed == saved else { return }
        recordSaveFailed = !saved
        wake()
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
