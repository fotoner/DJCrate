import AppKit
import DJCDomain

/// 곡 목록·태그 시트가 함께 쓰는 '덱에 불러오기'(#93): ⌘→ 키와 오른쪽 클릭 메뉴 항목.
@MainActor
enum LoadToDeckCommand {
    /// 목록·메뉴에 보이는 불러오기 키(⌘ 와 함께)
    static let key = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    /// ⌘→(다른 조합 키 없이)인지. 목록에서 ⌘ 조합은 덱 단축키로 가지 않고 표로 온다(→·⇧→는 덱의 박·마디 이동, 시트는 옆 칸).
    static func matches(_ event: NSEvent) -> Bool {
        event.specialKey == .rightArrow && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    }

    /// 오른쪽 클릭 메뉴의 '덱에 불러오기'. 올릴 줄이 없으면 `action`을 nil로 준다(누를 수 없다).
    static func menuItem(action: Selector?, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: String(ui: "덱에 불러오기"), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.target = target
        return item
    }
}
