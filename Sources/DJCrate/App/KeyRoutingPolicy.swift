import AppKit
import DJCDomain

/// 창·포커스 상태만으로 덱 단축키를 받아도 되는지 정한다. 덱 키가 무엇인지는 단축키 표(설정)를 따른다.
enum KeyRoutingPolicy {
    enum Focus {
        case deck, trackList, table, sheet, textInput, control
    }

    struct Context {
        var isMainWindow = true
        var hasModalWindow = false
        var hasAttachedSheet = false
        var hasShortcutModifiers = false
        var focus: Focus = .deck
    }

    static func accepts(_ keyCode: UInt16, in context: Context, shortcuts: DeckShortcuts = .standard) -> Bool {
        guard context.isMainWindow, !context.hasModalWindow, !context.hasAttachedSheet,
              !context.hasShortcutModifiers else { return false }
        switch context.focus {
        case .deck:
            return true
        case .trackList:
            // 곡 목록에서는 덱 키를 받고 나머지는 표에 맡긴다. ←→⌫⌦는 목록에서 할 일이 없어 경고음이 나지 않게 받는다.
            return shortcuts.action(for: keyCode) != nil || [123, 124, 51, 117].contains(keyCode)
        case .sheet:
            return keyCode == 49
        case .textInput, .control, .table:
            return false
        }
    }

    /// ⌘→: 고른 곡을 덱에 올린다(#93). 곡 목록·태그 시트는 표가 직접 받고, 여기서는 덱을 보고 있을 때만 맡는다.
    /// 글자 칸의 ⌘→(줄 끝으로)와 사이드바 등 다른 컨트롤은 건드리지 않는다.
    static func loadsSelection(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, focus: Focus) -> Bool {
        keyCode == 124 && modifiers.intersection([.command, .shift, .control, .option]) == .command && focus == .deck
    }

    /// ⌘=(Shift 없이 누른 ⌘+)도 보기 › 글자 크게로 본다. 메뉴 항목은 '+' 글자에 걸려 ⌘=에는 반응하지 않는다.
    static func isTextBiggerAlias(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 24 && modifiers.intersection([.command, .shift, .control, .option]) == .command
    }
}
