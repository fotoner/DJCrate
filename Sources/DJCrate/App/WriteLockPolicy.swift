import DJCApplication
import DJCDomain
import Foundation

/// 쓰기 잠금에서 허용하는 시스템 동작과 막는 라이브러리 조작을 구분한다.
struct WriteLockPolicy {
    /// 쓰는 중인지. 키 입력 차단은 편집 잠금(덱 쪽 복사본 `DeckModel.editsFrozen`)을 넣고, 종료 판단은 이 구조체를 쓰지 않는다(`writeActivity`).
    var isWriting: Bool
    var canCancelPreparation = false

    func blocksKey(_ keyCode: UInt16, in context: KeyRoutingPolicy.Context) -> Bool {
        guard isWriting, context.isMainWindow, !context.hasModalWindow, !context.hasAttachedSheet,
              !context.hasShortcutModifiers else { return false }
        if keyCode == 53, canCancelPreparation { return false }
        switch context.focus {
        case .deck, .trackList, .sheet: return true
        case .textInput, .control, .table: return false
        }
    }
}

extension LibraryStore {
    /// 앱이 쓰는 중인 것: rekordbox 쓰기·복원(쓰기 잠금의 단계)과 USB 쓰기(진행 중·볼륨을 붙잡은 작업). 관찰할 수 있는 값에서 읽는다.
    /// 앱 종료(#300)와 업데이트 설치 미루기(#59)가 이 값 하나로 판단한다(`AppQuitPolicy`·`UpdateInstallPolicy`).
    var writeActivity: AppWriteActivity {
        AppWriteActivity(rekordbox: rekordboxWritePhase,
                         writingUsb: usb.map { $0.activeWrite != nil || !$0.busyVolumes.isEmpty } ?? false)
    }

    /// rekordbox 쓰기가 어느 단계인가. 진행 안내(`writeStage`)가 단계를 알리고, 진행 안내가 없는 때는 창이 떠 있는지로 가른다.
    /// 진행 안내가 없는 쓰기(iTunes 동기화 등)와 결과를 알리는 짧은 때는 끊지 않는 쓰기로 본다(기다린다).
    var rekordboxWritePhase: RekordboxWritePhase {
        // 확인할 경고창은 잠금이 풀린 뒤(시점 복원 실패)에도 뜬다. 확인하기 전에는 끄지 않는다
        if isAwaitingAcknowledgement { return .acknowledging }
        guard quitBlocked else { return .idle }
        if isAwaitingConfirmation { return .confirming }
        return writeStage?.phase ?? .writing
    }

    /// 새 rekordbox 쓰기를 시작하지 않을 이유(Mac을 끄는 중·종료를 기다리는 중). 없으면 nil
    var writeRefusal: String? {
        if isPoweringOff { return String(ui: "Mac을 끄는 중이라 rekordbox에 쓰지 않았습니다. 다시 켠 뒤 쓰세요") }
        if quitWait.isWaiting { return String(ui: "종료하는 중이라 rekordbox에 쓰지 않았습니다. 종료를 취소한 뒤 다시 쓰세요") }
        return nil
    }

    /// 쓰기·복원 확인 창을 띄워 답을 기다리는 동안 표시를 켠다(아직 아무것도 쓰지 않았다)
    func whileAwaitingConfirmation<T>(_ ask: () -> T) -> T {
        isAwaitingConfirmation = true
        defer { isAwaitingConfirmation = false }
        return ask()
    }

    /// 복원까지 실패했다는 경고창을 띄워 확인을 기다리는 동안 표시를 켠다
    func whileAwaitingAcknowledgement<T>(_ ask: () -> T) -> T {
        isAwaitingAcknowledgement = true
        defer { isAwaitingAcknowledgement = false }
        return ask()
    }
}
