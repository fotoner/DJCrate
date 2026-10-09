import DJCApplication
import DJCDomain
import Foundation

/// 쓰기 잠금에서 허용하는 시스템 동작과 막는 라이브러리 조작을 구분한다.
struct WriteLockPolicy {
    var isWriting: Bool
    var canCancelPreparation = false

    var allowsLibraryInteraction: Bool { !isWriting }
    var allowsTermination: Bool { !isWriting }
    static var terminationMessage: String { String(ui: "rekordbox에 쓰는 중입니다. 끝난 뒤 종료하세요") }

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
}
