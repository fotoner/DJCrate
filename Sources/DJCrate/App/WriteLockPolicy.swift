import DJCApplication
import DJCDomain
import Foundation

/// 쓰기 잠금에서 허용하는 시스템 동작과 막는 라이브러리 조작을 구분한다.
struct WriteLockPolicy {
    var isWriting: Bool
    var canCancelPreparation = false

    var allowsLibraryInteraction: Bool { !isWriting }
    /// 앱 끄기는 USB 쓰기도 함께 본다(`AppWriteActivity.quitBlockedReason`)
    var allowsTermination: Bool { !isWriting }

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
    var writeLockPolicy: WriteLockPolicy {
        WriteLockPolicy(isWriting: isWritingRekordbox, canCancelPreparation: writeStage?.cancellable == true)
    }

    /// 앱이 쓰는 중인 것: rekordbox 쓰기·복원(쓰기 잠금)과 USB 쓰기(진행 중·볼륨을 붙잡은 작업). 관찰할 수 있는 값에서 읽는다.
    var writeActivity: AppWriteActivity {
        AppWriteActivity(writingRekordbox: isWritingRekordbox,
                         writingUsb: usb.map { $0.activeWrite != nil || !$0.busyVolumes.isEmpty } ?? false)
    }
}
