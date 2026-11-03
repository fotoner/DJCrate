import AppKit
import DJCDomain
import Observation

/// 종료를 기다리는 중인 상태와 [종료 취소]. 쓰기 덮개의 카드가 읽는다(#300).
@MainActor
@Observable
final class QuitWaitModel {
    private(set) var current: QuitWait?
    @ObservationIgnored private var onCancel: (() -> Void)?

    var isWaiting: Bool { current != nil }

    func begin(at start: Date, onCancel: @escaping () -> Void) {
        current = QuitWait(startedAt: start)
        self.onCancel = onCancel
    }

    func finish() {
        current = nil
        onCancel = nil
    }

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
    private var watching = false
    /// 켜진 채 종료 시트가 떠 있다(그동안 온 종료 요청은 시트를 더 띄우지 않는다)
    private var isAsking = false
    /// [그냥 종료] 뒤 다시 한 종료 요청 한 번만 묻지 않는다
    private var skipsConfirmation = false
    /// 기다리는 중 어떻게 답할지(위 설명)
    private enum WaitMode { case nested, deferred }
    private var mode: WaitMode?

    /// - Parameters:
    ///   - activity: 지금 앱이 쓰는 중인 것. 관찰할 수 있는 값에서 읽어야 쓰기가 끝난 것을 안다
    ///   - cancelPreparation: 취소할 수 있는 단계의 쓰기를 취소한다
    ///   - flushDrafts: 쓴 초안의 정리가 저장 큐에 걸린 채 끝나지 않게 큐를 비운다
    ///   - reply: `terminateLater`로 미룬 종료에 답한다(true면 종료)
    ///   - terminate: 미루지 않고 취소로 답한 종료를 쓰기가 끝난 뒤 다시 요청한다
    ///   - inform: 끄지 않는 이유를 알린다(USB)
    ///   - terminationCancelled: 종료를 취소로 끝냈다(Mac을 끄는 중이었다면 그 일도 멈췄다)
    ///   - bringForward: 확인할 경고창이 떠 있어 끄지 않을 때 그 창을 앞으로 가져온다(켜진 채 종료 시트를 띄울 때도 부른다)
    ///   - runState: rekordbox 실행 판정. 읽기 전·읽지 못함이면 시트를 띄우지 않는다(기본은 모름)
    ///   - pending: 아직 rekordbox에 쓰지 않은 편집 수. 상태 줄 칩과 같은 수다
    ///   - present: 켜진 채 종료 시트를 띄운다. 답은 true면 [그냥 종료], false면 [취소]다. 지금 이벤트 처리가 끝난 뒤에 불러야 한다
    init(model: QuitWaitModel, activity: @escaping @MainActor () -> AppWriteActivity,
         cancelPreparation: @escaping @MainActor () -> Void, flushDrafts: @escaping @MainActor () -> Void,
         reply: @escaping @MainActor (Bool) -> Void, terminate: @escaping @MainActor () -> Void,
         inform: @escaping @MainActor (String) -> Void, terminationCancelled: @escaping @MainActor () -> Void = {},
         bringForward: @escaping @MainActor () -> Void,
         runState: @escaping @MainActor () -> RekordboxRunState? = { nil },
         pending: @escaping @MainActor () -> PendingWriteCount = { PendingWriteCount(items: 0, playlistEdits: 0) },
         present: @escaping @MainActor (QuitConfirmation, @escaping @MainActor (Bool) -> Void) -> Void = { _, answer in answer(false) },
         now: @escaping @MainActor () -> Date = { Date() }) {
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
    }

    /// - Parameters:
    ///   - nested: 종료를 미루고 `reply`로 답할지(시스템이 끄는 중일 때). 아니면 취소로 답하고 쓰기가 끝나면 다시 요청한다.
    ///   - cause: 누가 고른 종료인가. 사용자가 고른 종료(기본)만 켜진 채 종료 시트를 띄운다
    func requestTermination(nested: Bool = false, cause: AppQuitCause = .user) -> NSApplication.TerminateReply {
        if model.isWaiting {
            // ⌘Q로 기다리는 중 Mac을 끄는 요청이 오면 그 일은 취소하지 않고 같이 기다린다(미루는 방식으로 바꾼다)
            if nested, mode == .deferred {
                mode = .nested
                return .terminateLater
            }
            // 기다리는 중 다시 종료를 요청하면(⌘Q를 한 번 더) 종료만 취소한다
            cancelWaiting()
            return .terminateCancel
        }
        // 시트가 떠 있는 동안 다시 눌린 사용자 종료는 시트를 더 띄우지 않고 취소로만 답한다(시트에서 고른다).
        // 로그아웃·재시작·전원 끔·업데이트 다시 켜기는 취소로 답하면 그 일이 통째로 멈추므로 시트가 떠 있어도 기존 판정을 따른다
        if isAsking, !nested, cause.isUserChosen { return .terminateCancel }
        let current = activity()
        if let confirmation = confirmationBeforeQuit(current, nested: nested, cause: cause) {
            ask(confirmation)
            return .terminateCancel
        }
        switch AppQuitPolicy.decision(for: current) {
        case .terminateNow:
            flushAfterWrite(current)
            return .terminateNow
        case .cancelPreparationThenTerminate:
            cancelPreparation()
            flushAfterWrite(current)
            return .terminateNow
        case .waitForRekordboxWrite:
            model.begin(at: now()) { [weak self] in self?.cancelWaiting() }
            mode = nested ? .nested : .deferred
            watch()
            return nested ? .terminateLater : .terminateCancel
        case .keepOpenForAcknowledgement:
            bringForward()
            terminationCancelled()
            return .terminateCancel
        case let decision:
            if let message = decision.message { inform(message) }
            terminationCancelled()
            return .terminateCancel
        }
    }

    /// 켜진 채 종료 시트를 띄울 때만 내용을 돌려준다. [그냥 종료] 뒤 다시 한 요청 한 번은 묻지 않는다.
    /// 미루는 방식(`nested`)은 시스템이 Mac을 끄는 중이라 이유를 잘못 알려 와도 묻지 않는다(취소로 답하면 그 일이 통째로 멈춘다).
    private func confirmationBeforeQuit(_ current: AppWriteActivity, nested: Bool, cause: AppQuitCause) -> QuitConfirmation? {
        if skipsConfirmation {
            skipsConfirmation = false
            return nil
        }
        guard !nested else { return nil }
        return AppQuitPolicy.confirmation(for: current, cause: cause, run: runState(), pending: pending())
    }

    /// 종료는 취소로 답해 두고 시트를 띄운다. [그냥 종료]는 종료를 다시 요청하고 그 요청 한 번만 묻지 않는다.
    private func ask(_ confirmation: QuitConfirmation) {
        isAsking = true
        bringForward()
        present(confirmation) { [weak self] quitAnyway in
            guard let self else { return }
            isAsking = false
            if quitAnyway {
                skipsConfirmation = true
                terminate()
                // 종료 요청이 바로 처리되지 않았어도 한 번만 건너뛴 것으로 센다(다음 종료는 다시 묻는다)
                skipsConfirmation = false
            } else {
                terminationCancelled()
            }
        }
    }

    /// 기다리는 중 쓰기 상태가 바뀌었다. 끝났으면 종료로, 확인이 필요해졌으면 취소로 답한다.
    func activityChanged() {
        guard model.isWaiting else { return }
        let current = activity()
        switch AppQuitPolicy.decision(for: current) {
        case .waitForRekordboxWrite:
            return
        case .terminateNow:
            flushAfterWrite(current)
            finish(terminating: true)
        case .cancelPreparationThenTerminate:
            cancelPreparation()
            flushAfterWrite(current)
            finish(terminating: true)
        case .keepOpenForAcknowledgement:
            bringForward()
            finish(terminating: false)
        case let decision:
            if let message = decision.message { inform(message) }
            finish(terminating: false)
        }
    }

    /// [종료 취소]나 두 번째 종료 요청. 종료만 취소하고 쓰기는 그대로 끝까지 간다.
    func cancelWaiting() {
        guard model.isWaiting else { return }
        finish(terminating: false)
    }

    private func finish(terminating: Bool) {
        model.finish()
        let finished = mode
        mode = nil
        switch finished {
        case .nested: reply(terminating)
        case .deferred: if terminating { terminate() }
        case nil: break
        }
        if !terminating { terminationCancelled() }
    }

    /// 쓴 초안 정리가 저장 큐에 걸린 채 프로세스가 끝나면 쓴 초안이 디스크에 남는다. 쓰기가 있었으면 큐를 비운 뒤 끈다.
    private func flushAfterWrite(_ current: AppWriteActivity) {
        if current.rekordbox != .idle { flushDrafts() }
    }

    /// 기다리는 동안만 쓰기 상태를 지켜본다(`AppUpdater.watchActivity`와 같은 방식)
    private func watch() {
        guard !watching else { return }
        watching = true
        withObservationTracking { _ = activity() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watching = false
                self.activityChanged()
                if self.model.isWaiting { self.watch() }
            }
        }
    }
}
