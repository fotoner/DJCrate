import AppKit
import DJCApplication
import DJCDomain
import Observation

/// 종료를 기다리는 중인 상태와 [종료 취소]. 쓰기 덮개의 카드가 읽는다(#300).
@MainActor
@Observable
final class QuitWaitModel {
    private(set) var current: QuitWait?
    /// ⌘Q가 엔진의 ⌘Q 저장을 기다린다(R17). 이 기다림 동안은 엔진의 자동 저장만 세션 잠금을 지난다(수동 입구는 `writeRefusal`이 거절한다)
    private(set) var allowsAutoSave = false
    @ObservationIgnored private var onCancel: (() -> Void)?

    var isWaiting: Bool { current != nil }

    /// 기다리는 동안 세션 잠금이 쓰기를 막는지. 엔진의 ⌘Q 저장을 기다리는 동안만 자동 저장을 연다(R17)
    var refusesWrites: Bool { current != nil && !allowsAutoSave }

    func begin(at start: Date, allowsAutoSave: Bool = false, onCancel: @escaping () -> Void) {
        current = QuitWait(startedAt: start)
        self.allowsAutoSave = allowsAutoSave
        self.onCancel = onCancel
    }

    func finish() {
        current = nil
        allowsAutoSave = false
        onCancel = nil
    }

    /// 기다리는 동안 자동 저장의 새 쓰기를 더는 열지 않는다(시스템 종료·업데이트로 바뀜)
    func stopAllowingAutoSave() { allowsAutoSave = false }

    /// [종료 취소]. 종료만 취소하고 쓰기는 끝까지 간다
    func cancel() { onCancel?() }
}

/// 앱 종료 요청을 받아 쓰기 단계에 따라 답한다(#300). 판정표는 DJCDomain `AppQuitPolicy`가 정하고 여기서는 그 판정을 따른다.
/// 기다리는 동안은 쓰기 상태가 바뀔 때마다 같은 판정을 다시 하고, 끝나면 한 번만 종료로 답한다.
///
/// 켜진 채 종료 시트(#326): 쓰는 중이 아닐 때 쓰기 대기가 있고 rekordbox(또는 rekordboxAgent)가 켜져 있으며 사용자가 고른 종료면
/// 종료를 취소로 답하고 시트를 한 번 띄운다(`AppQuitPolicy.confirmation`). [그냥 종료]는 종료를 다시 요청하되 그 요청 한 번만 묻지 않는다.
/// [취소]는 종료를 취소한 채 둔다. 시트는 쓰기 허용과 관계없다: 쓸지 말지는 늘 쓰기 관문이 정한다.
///
/// 기다리는 방식은 둘이다.
/// - 미루지 않는 기본(`deferred`): 이번 요청은 취소로 답하고(`terminateCancel`) 쓰기가 끝나면 앱이 종료를 다시 요청한다.
///   `terminateLater`로 미루면 AppKit은 `terminate:` 안에서 이벤트 순환을 안쪽에서 다시 도는데, 그 `terminate:`가 메인 큐 블록 안에서 불렸으면
///   (메인 액터 작업, 업데이트 도구의 완료 처리) 안쪽 순환이 메인 큐를 처리하지 못해 메인 액터에서 도는 쓰기가 끝나지 못하고 종료도 영영 답하지 못한다
///   (자가 테스트에서 확인). 미루지 않으면 어디서 불려도 안전하고, 기다리는 중 다시 눌린 ⌘Q도 그냥 새 요청으로 들어와 종료만 취소한다.
/// - 미루는 방식(`nested`): 로그아웃·재시작·전원 끔은 취소로 답하면 그 일이 통째로 취소되므로 `terminateLater`로 미루고 `reply`로 답한다.
///   이 요청은 시스템 Apple 이벤트에서 온다.
/// 쓰기를 중간에 끊는 길은 없다: 취소하는 것은 아직 아무것도 쓰지 않은 단계(미리 보기)뿐이다.
///
/// ⌘Q 저장(R17): 자동 저장하는 실행의 사용자가 고른 종료는 입력 칸을 확정하고 초안 저장 큐를 비운 뒤 엔진의 ⌘Q 저장(`prepareToQuit`)을
/// 지금의 종료 대기 화면으로 기다린다. 무엇을 쓸지는 엔진이 최신 초안으로 다시 판정한다(조용함·관문·실행 판정은 그대로). 엔진의 자동 저장은
/// 미리 보기도 취소하지 않는다. [종료 취소]·두 번째 ⌘Q는 엔진의 종료 대기를 푼다(쓰는 중인 쓰기는 끝까지 간다).
/// 로그아웃·재시작·전원 끔과 업데이트 다시 켜기는 자동 저장을 기다리지 않고 엔진이 새 쓰기를 시작하지 않게 한다(이미 시작한 쓰기만 마친다).
@MainActor
final class AppQuitController {
    private let model: QuitWaitModel
    private let activity: @MainActor () -> AppWriteActivity
    private let cancelPreparation: @MainActor () -> Void
    private let flushDrafts: @MainActor () -> Void
    private let reply: @MainActor (Bool) -> Void
    private let terminate: @MainActor () -> Void
    private let inform: @MainActor (String) -> Void
    private let terminationCancelled: @MainActor () -> Void
    private let bringForward: @MainActor () -> Void
    private let runState: @MainActor () -> RekordboxRunState?
    private let pending: @MainActor () -> PendingWriteCount
    private let present: @MainActor (QuitConfirmation, @escaping @MainActor (Bool) -> Void) -> Void
    private let now: @MainActor () -> Date
    private let pendingRecordSave: @MainActor () -> Task<Void, Never>?
    private let autoSave: QuitAutoSaveLink
    private var watching = false
    /// 기록 저장을 기다리는 종료(#404 S18). 기다림을 취소하거나 끝내면 비운다: 그 뒤 끝난 저장은 종료를 다시 요청하지 않는다
    private var recordWait: UUID?
    /// 켜진 채 종료 시트가 떠 있다(그동안 온 종료 요청은 시트를 더 띄우지 않는다)
    private var isAsking = false
    /// 이 종료 대기가 엔진의 ⌘Q 저장을 기다리는지(사용자가 고른 종료, 자동 저장하는 실행)
    private var savesFirst = false
    /// 도는 엔진의 ⌘Q 저장
    private var preparing: Task<Void, Never>?
    /// 지금 종료 대기의 저장 준비 표식(컨실 2라운드 D). 대기가 끝나거나 바뀌면 비운다: 그 뒤 돌아온 옛 준비는 엔진에 넘기지 않고 결과도 버린다
    private var preparingTicket: UUID?
    /// 끝난 엔진의 ⌘Q 저장 결과(이 대기의 끝을 정할 때 쓴다)
    private var prepared: QuitPreparation?
    /// 새 자동 저장을 막아 두었다(시스템 종료·업데이트). 그 종료가 취소되면 다시 연다
    private var autoSaveStopped = false
    /// ⌘Q 저장을 기다리는 중 시스템 종료·업데이트 다시 켜기가 합류했다: 대기를 마치고 다시 한 요청은 시트 없이 끈다(컨실 2라운드 G)
    private var systemJoined = false
    /// 대기를 마치고 다시 요청한 종료 한 번(`terminate()` 안에서 곧바로 들어온다): 다시 저장하지 않고, 시트는 이 값대로 판정한다
    private var reentry: Reentry?
    private enum Reentry {
        /// 시트도 묻지 않는다([그냥 종료]·기록 저장 대기 뒤)
        case skipConfirmation
        /// 시트를 평소대로 판정한다
        case confirmNormally
        /// 엔진이 본 실행 상태로 시트를 판정한다(S6)
        case confirm(RekordboxRunState)
    }
    /// 기다리는 중 어떻게 답할지(위 설명)
    private enum WaitMode { case nested, deferred }
    private var mode: WaitMode?

    /// - Parameters:
    ///   - activity: 지금 앱이 쓰는 중인 것. 관찰할 수 있는 값에서 읽어야 쓰기가 끝난 것을 안다
    ///   - cancelPreparation: 취소할 수 있는 단계의 쓰기를 취소한다
    ///   - flushDrafts: 초안 저장 큐를 비운다. 끄기 전과 엔진의 ⌘Q 저장 전에 늘 부른다(편집 직후 큐에 걸린 초안을 잃지 않게)
    ///   - reply: `terminateLater`로 미룬 종료에 답한다(true면 종료)
    ///   - terminate: 미루지 않고 취소로 답한 종료를 쓰기가 끝난 뒤 다시 요청한다
    ///   - inform: 끄지 않는 이유를 알린다(USB)
    ///   - terminationCancelled: 종료를 취소로 끝냈다(Mac을 끄는 중이었다면 그 일도 멈췄다)
    ///   - bringForward: 확인할 경고창이 떠 있어 끄지 않을 때 그 창을 앞으로 가져온다(켜진 채 종료 시트를 띄울 때도 부른다)
    ///   - runState: rekordbox 실행 판정. 읽기 전·읽지 못함이면 시트를 띄우지 않는다(기본은 모름)
    ///   - pending: 아직 rekordbox에 쓰지 않은 편집 수. 상태 줄 칩과 같은 수다
    ///   - present: 켜진 채 종료 시트를 띄운다. 답은 true면 [그냥 종료], false면 [취소]다. 지금 이벤트 처리가 끝난 뒤에 불러야 한다
    ///   - pendingRecordSave: 자동 저장 엔진이 아직 디스크에 남기지 못한 기록 저장(사용자가 취소한 판). 있으면 그 저장이 끝난 뒤 종료를 승인한다
    ///   - autoSave: 자동 저장 엔진과의 연결(R17). 기본은 자동 저장하지 않는 실행이다
    init(model: QuitWaitModel, activity: @escaping @MainActor () -> AppWriteActivity,
         cancelPreparation: @escaping @MainActor () -> Void, flushDrafts: @escaping @MainActor () -> Void,
         reply: @escaping @MainActor (Bool) -> Void, terminate: @escaping @MainActor () -> Void,
         inform: @escaping @MainActor (String) -> Void, terminationCancelled: @escaping @MainActor () -> Void = {},
         bringForward: @escaping @MainActor () -> Void,
         runState: @escaping @MainActor () -> RekordboxRunState? = { nil },
         pending: @escaping @MainActor () -> PendingWriteCount = { PendingWriteCount(items: 0, playlistEdits: 0) },
         present: @escaping @MainActor (QuitConfirmation, @escaping @MainActor (Bool) -> Void) -> Void = { _, answer in answer(false) },
         now: @escaping @MainActor () -> Date = { Date() },
         pendingRecordSave: @escaping @MainActor () -> Task<Void, Never>? = { nil },
         autoSave: QuitAutoSaveLink = QuitAutoSaveLink()) {
        self.model = model
        self.activity = activity
        self.cancelPreparation = cancelPreparation
        self.flushDrafts = flushDrafts
        self.reply = reply
        self.terminate = terminate
        self.inform = inform
        self.terminationCancelled = terminationCancelled
        self.bringForward = bringForward
        self.runState = runState
        self.pending = pending
        self.present = present
        self.now = now
        self.pendingRecordSave = pendingRecordSave
        self.autoSave = autoSave
    }

    /// - Parameters:
    ///   - nested: 종료를 미루고 `reply`로 답할지(시스템이 끄는 중일 때). 아니면 취소로 답하고 쓰기가 끝나면 다시 요청한다.
    ///   - cause: 누가 고른 종료인가. 사용자가 고른 종료(기본)만 켜진 채 종료 시트를 띄우고, 자동 저장을 먼저 한다
    func requestTermination(nested: Bool = false, cause: AppQuitCause = .user) -> NSApplication.TerminateReply {
        // 로그아웃·재시작·전원 끔·업데이트 다시 켜기는 새 쓰기를 시작하지 않는다(R17)
        let system = nested || cause == .systemShutdown || cause == .updateRelaunch
        if model.isWaiting {
            if system, mode == .deferred {
                // ⌘Q로 기다리는 중 Mac을 끄는 요청·업데이트가 오면 그 일은 취소하지 않는다. 새 자동 저장은 막고 곧바로 다시 판정한다.
                // 다시 한 요청은 사용자 종료로 들어와도 그 사유를 잃지 않는다(시트가 업데이트·로그아웃을 막지 않게)
                systemJoined = true
                stopSavingFirst()
                if nested { mode = .nested }
                Task { @MainActor [weak self] in self?.activityChanged() }
                return nested ? .terminateLater : .terminateCancel
            }
            // 기다리는 중 다시 종료를 요청하면(⌘Q를 한 번 더) 종료만 취소한다
            cancelWaiting()
            return .terminateCancel
        }
        // 시트가 떠 있는 동안 다시 눌린 사용자 종료는 시트를 더 띄우지 않고 취소로만 답한다(시트에서 고른다).
        // 로그아웃·재시작·전원 끔·업데이트 다시 켜기는 취소로 답하면 그 일이 통째로 멈추므로 시트가 떠 있어도 기존 판정을 따른다
        if isAsking, !nested, cause.isUserChosen { return .terminateCancel }
        let entered = reentry
        reentry = nil
        let current = activity()
        if let confirmation = confirmationBeforeQuit(current, nested: nested, cause: cause, reentry: entered) {
            ask(confirmation)
            return .terminateCancel
        }
        if system { stopAutoSave() }
        // 다시 요청한 종료(저장을 마쳤거나 시트·기록 저장을 거침)와 사용자가 고르지 않은 종료(시스템 종료·업데이트·알 수 없는 사유)는
        // 먼저 저장하지 않는다(시트 판정과 같다)
        let userChosen = !system && cause.isUserChosen
        let saving: QuitAutoSave = !userChosen || entered != nil || !autoSave.autoSaves() ? .off : (autoSave.autoWriting() ? .autoWriting : .saveFirst)
        let decision = AppQuitPolicy.decision(for: current, autoSave: saving)
        switch decision {
        case .terminateNow:
            flushDrafts()
            return approveTermination(nested: nested)
        case .cancelPreparationThenTerminate:
            cancelPreparation()
            flushDrafts()
            return approveTermination(nested: nested)
        case .cancelPreparationThenAutoSave:
            cancelPreparation()
            beginWait(nested: nested, savesFirst: true)
            startPreparing()
            watch()
            return nested ? .terminateLater : .terminateCancel
        case .waitForRekordboxWrite, .waitForAutoSave:
            beginWait(nested: nested, savesFirst: saving != .off)
            if decision == .waitForAutoSave { startPreparing() }
            watch()
            return nested ? .terminateLater : .terminateCancel
        case .keepOpenForAcknowledgement:
            bringForward()
            cancelled()
            return .terminateCancel
        default:
            if let message = decision.message { inform(message) }
            cancelled()
            return .terminateCancel
        }
    }

    /// 종료 대기를 시작한다. 엔진의 ⌘Q 저장을 기다리면 그 자동 저장만 세션 잠금을 지난다(수동 입구는 지금처럼 거절한다)
    private func beginWait(nested: Bool, savesFirst: Bool) {
        self.savesFirst = savesFirst
        prepared = nil
        model.begin(at: now(), allowsAutoSave: savesFirst) { [weak self] in self?.cancelWaiting() }
        mode = nested ? .nested : .deferred
    }

    /// 엔진의 ⌘Q 저장: 입력 칸을 확정하고(⌘S와 같다) 초안 저장 큐를 비운 뒤 엔진이 최신 초안으로 다시 판정해 쓰기를 기다린다.
    /// 입력 확정 직후와 엔진이 돌아온 직후에 같은 종료 대기인지 표식으로 본다(컨실 2라운드 D): 그사이 [종료 취소]·두 번째 ⌘Q·시스템 종료로
    /// 대기가 끝났거나 바뀌었으면 엔진에 넘기지 않고(엔진이 T_edit를 건너뛴 종료 대기에 들지 않게), 돌아온 옛 결과로 새 대기를 끝내지 않는다
    private func startPreparing() {
        guard preparing == nil, prepared == nil else { return }
        let ticket = UUID()
        preparingTicket = ticket
        preparing = Task { @MainActor [weak self] in
            guard let self else { return }
            await autoSave.commitInput()
            guard isCurrent(ticket) else { return }
            flushDrafts()
            let result = await autoSave.prepare()
            guard isCurrent(ticket) else { return }
            preparing = nil
            preparingTicket = nil
            prepared = result
            activityChanged()
        }
    }

    /// 이 표식의 저장 준비가 지금 종료 대기의 것인지(대기 중이고 엔진의 ⌘Q 저장을 기다린다)
    private func isCurrent(_ ticket: UUID) -> Bool {
        preparingTicket == ticket && model.isWaiting && savesFirst
    }

    /// 엔진의 ⌘Q 저장 준비를 끝낸다. 아직 돌아오지 않았으면 엔진의 종료 대기를 풀고, 그 준비가 늦게 돌아와도 버린다
    private func stopPreparing() {
        if savesFirst, prepared == nil { autoSave.cancel() }
        preparing = nil
        preparingTicket = nil
        prepared = nil
    }

    /// 새 자동 저장을 막는다(엔진이 이미 시작한 쓰기만 마친다)
    private func stopAutoSave() {
        guard !autoSaveStopped else { return }
        autoSaveStopped = true
        autoSave.shutdown(true)
    }

    /// 기다리던 ⌘Q 저장을 풀고 새 자동 저장을 막는다(시스템 종료·업데이트로 바뀜)
    private func stopSavingFirst() {
        stopPreparing()
        savesFirst = false
        model.stopAllowingAutoSave()
        stopAutoSave()
    }

    /// 시스템 종료·업데이트 다시 켜기로 새 자동 저장을 막았는데 그 종료가 취소돼 앱이 살아 있다(앱이 다시 활성화됨, 컨실 2라운드 H).
    /// 종료를 기다리는 중이 아니면 막아 둔 자동 저장을 다시 연다. Mac을 끄는 중 표시를 풀었으면(`poweringOffCancelled`) 그 알림이 막은 것도 연다
    func reopenAutoSaveAfterCancelledShutdown(poweringOffCancelled: Bool) {
        guard !model.isWaiting, autoSaveStopped || poweringOffCancelled else { return }
        autoSaveStopped = false
        autoSave.shutdown(false)
    }

    /// 종료를 취소로 끝냈다: 막아 둔 자동 저장을 다시 연다
    private func cancelled() {
        if autoSaveStopped {
            autoSaveStopped = false
            autoSave.shutdown(false)
        }
        terminationCancelled()
    }

    /// 종료를 승인한다. 자동 저장 엔진이 사용자가 취소한 판의 기록을 아직 디스크에 남기지 못했으면 그 저장이 끝난 뒤에 승인한다:
    /// 기록 없이 끄면 다시 켠 뒤 같은 판을 자동으로 쓴다. 미루는 방식(`nested`)은 미뤘다가 `reply`로, 아니면 취소로 답해 두고 다시 요청한다
    /// 기록 저장 대기도 종료 대기 상태로 든다(#404 S18): 기다리는 중 다시 누른 ⌘Q·[종료 취소]는 기다림을 취소하고, 그 뒤 끝난 저장은 종료를 다시 요청하지 않는다
    private func approveTermination(nested: Bool) -> NSApplication.TerminateReply {
        guard let saving = pendingRecordSave() else { return .terminateNow }
        let ticket = UUID()
        recordWait = ticket
        model.begin(at: now()) { [weak self] in self?.cancelWaiting() }
        mode = nested ? .nested : .deferred
        Task { @MainActor [weak self] in
            await saving.value
            guard let self, recordWait == ticket, model.isWaiting else { return }
            // 이미 확인을 거친 종료다: 다시 요청해도 시트를 또 띄우지 않는다
            finish(terminating: true, reentry: .skipConfirmation)
        }
        return nested ? .terminateLater : .terminateCancel
    }

    /// 켜진 채 종료 시트를 띄울 때만 내용을 돌려준다. [그냥 종료]·기록 저장 대기 뒤 다시 한 요청은 묻지 않는다.
    /// 엔진의 ⌘Q 저장이 rekordbox 켜짐을 보고 돌아왔으면 그 실행 상태로 판정한다(감시 모델보다 늦지 않다, S6).
    /// 미루는 방식(`nested`)은 시스템이 Mac을 끄는 중이라 이유를 잘못 알려 와도 묻지 않는다(취소로 답하면 그 일이 통째로 멈춘다).
    private func confirmationBeforeQuit(_ current: AppWriteActivity, nested: Bool, cause: AppQuitCause, reentry: Reentry?) -> QuitConfirmation? {
        guard !nested else { return nil }
        switch reentry {
        case .skipConfirmation?: return nil
        case let .confirm(run)?: return AppQuitPolicy.confirmation(for: current, cause: cause, run: run, pending: pending())
        case .confirmNormally?, nil: return AppQuitPolicy.confirmation(for: current, cause: cause, run: runState(), pending: pending())
        }
    }

    /// 종료는 취소로 답해 두고 시트를 띄운다. [그냥 종료]는 종료를 다시 요청하고 그 요청 한 번만 묻지 않는다.
    private func ask(_ confirmation: QuitConfirmation) {
        isAsking = true
        bringForward()
        present(confirmation) { [weak self] quitAnyway in
            guard let self else { return }
            isAsking = false
            if quitAnyway {
                // 종료 요청이 바로 처리되지 않았어도 한 번만 건너뛴 것으로 센다(다음 종료는 다시 묻는다)
                reentry = .skipConfirmation
                terminate()
                reentry = nil
            } else {
                cancelled()
            }
        }
    }

    /// 기다리는 중 쓰기 상태가 바뀌었거나 엔진의 ⌘Q 저장이 돌아왔다. 끝났으면 종료로, 확인이 필요해졌으면 취소로 답한다.
    func activityChanged() {
        // 기록 저장 대기는 그 저장이 끝날 때만 답한다
        guard model.isWaiting, recordWait == nil else { return }
        let current = activity()
        let saving: QuitAutoSave = !savesFirst || prepared != nil ? .off : (autoSave.autoWriting() ? .autoWriting : .saveFirst)
        switch AppQuitPolicy.decision(for: current, autoSave: saving) {
        case .waitForRekordboxWrite:
            return
        case .waitForAutoSave:
            startPreparing()
        case .cancelPreparationThenAutoSave:
            cancelPreparation()
            startPreparing()
        case .terminateNow:
            // 기다린 것은 쓰기였으니 단계와 관계없이 큐를 비운다. 쓴 뒤 다시 읽기를 미룬 길(#305)은 다시 읽는 단계를 거치지 않아
            // 쓰기가 끝났다고 알려 올 때 이미 잠금이 풀려 단계가 idle이다
            flushDrafts()
            finish(terminating: true, reentry: reentryAfterSaving())
        case .cancelPreparationThenTerminate:
            cancelPreparation()
            flushDrafts()
            finish(terminating: true, reentry: reentryAfterSaving())
        case .keepOpenForAcknowledgement:
            bringForward()
            finish(terminating: false)
        case let decision:
            if let message = decision.message { inform(message) }
            finish(terminating: false)
        }
    }

    /// 대기를 마치고 다시 한 요청의 시트 판정. 시스템 종료·업데이트가 합류했으면 묻지 않는다(G).
    /// 엔진의 ⌘Q 저장이 본 실행 상태가 있으면 그 값으로 판정한다: 켜짐으로 쓰지 못했거나, 대상 밖 편집만 남아 다 썼다고 돌아와도 같다(S6·J)
    private func reentryAfterSaving() -> Reentry {
        if systemJoined { return .skipConfirmation }
        switch prepared {
        case .unwritten(.rekordboxRunning)?: return .confirm(.running)
        case .unwritten(.agentRunning)?: return .confirm(.agentOnly)
        case let .finished(run?)?: return .confirm(run)
        default: return .confirmNormally
        }
    }

    /// [종료 취소]나 두 번째 종료 요청. 종료만 취소하고 쓰기는 그대로 끝까지 간다. 엔진의 종료 대기도 푼다
    func cancelWaiting() {
        guard model.isWaiting else { return }
        finish(terminating: false)
    }

    /// 종료 대기를 끝낸다. 어느 갈래로 끝나든(종료·[종료 취소]·두 번째 ⌘Q·확인 경고창·USB 거절) 엔진의 종료 대기를 풀고 저장 준비 표식을 비운다
    private func finish(terminating: Bool, reentry next: Reentry = .confirmNormally) {
        stopPreparing()
        model.finish()
        recordWait = nil
        savesFirst = false
        systemJoined = false
        let finished = mode
        mode = nil
        switch finished {
        case .nested: reply(terminating)
        case .deferred:
            if terminating {
                reentry = next
                terminate()
                reentry = nil
            }
        case nil: break
        }
        if !terminating { cancelled() }
    }

    /// 기다리는 동안만 쓰기 상태를 지켜본다(`AppUpdater.watchActivity`와 같은 방식). 엔진의 ⌘Q 저장은 돌아올 때 알린다
    private func watch() {
        guard !watching else { return }
        watching = true
        withObservationTracking {
            _ = activity()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watching = false
                self.activityChanged()
                if self.model.isWaiting { self.watch() }
            }
        }
    }
}

/// ⌘Q 저장(R17)을 자동 저장 엔진에 잇는 자리. 조립 지점이 엔진으로 채운다. 기본값은 자동 저장하지 않는 실행이다
struct QuitAutoSaveLink {
    /// 이 실행이 자동 저장하는지(엔진이 있고 자동 저장하는 실행)
    var autoSaves: @MainActor () -> Bool = { false }
    /// 지금 쓰는 것이 엔진의 자동 저장인지(수동 저장이 엔진의 차례를 받아 도는 것이 아니다)
    var autoWriting: @MainActor () -> Bool = { false }
    /// 입력 중인 칸을 확정한다(⌘S와 같은 확정)
    var commitInput: @MainActor () async -> Void = {}
    /// 엔진의 ⌘Q 저장을 기다린다
    var prepare: @MainActor () async -> QuitPreparation = { .finished(run: nil) }
    /// 엔진의 종료 대기를 푼다
    var cancel: @MainActor () -> Void = {}
    /// 새 자동 저장을 막거나(true: 시스템 종료·업데이트) 다시 연다(false: 그 종료가 취소됨)
    var shutdown: @MainActor (Bool) -> Void = { _ in }
}
