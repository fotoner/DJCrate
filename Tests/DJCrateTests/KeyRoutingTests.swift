@testable import DJCrate
import Testing
import AppKit

@Suite("키 전달 규칙")
struct KeyRoutingTests {
    // Return·Enter·Esc·Space·←→↑↓
    static let controlKeys: [UInt16] = [36, 76, 53, 49, 123, 124, 126, 125]
    static let deckKeys: [UInt16] = [49, 8, 18, 19, 20, 21, 23, 22, 26, 28,
                                   83, 84, 85, 86, 87, 88, 89, 91,
                                   46, 50, 12, 14, 123, 124, 51, 117, 1, 0, 37, 33, 30, 17, 24, 27, 69, 78]

    @Test(arguments: controlKeys)
    func 경고창은_키를_받는다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(hasModalWindow: true)))
    }

    @Test(arguments: controlKeys)
    func 팝오버와_다른_창은_키를_받는다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(isMainWindow: false)))
    }

    @Test(arguments: controlKeys)
    func 시트가_열리면_주_창도_단축키를_받지_않는다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(hasAttachedSheet: true)))
    }

    @Test(arguments: controlKeys)
    func 텍스트_입력은_키를_받는다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(focus: .textInput)))
    }

    @Test(arguments: controlKeys)
    func 버튼과_슬라이더는_키를_받는다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(focus: .control)))
    }

    @Test(arguments: controlKeys)
    func 일반_표는_키를_받는다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(focus: .table)))
    }

    @Test(arguments: deckKeys)
    func 덱의_기존_단축키는_유지한다(_ key: UInt16) {
        #expect(KeyRoutingPolicy.accepts(key, in: .init()))
    }

    @Test(arguments: deckKeys)
    func 컨트롤에_포커스가_있으면_글자_덱_키도_전달한다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(focus: .control)))
    }

    @Test(arguments: deckKeys)
    func 명령_조합은_덱_단축키로_쓰지_않는다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(hasShortcutModifiers: true)))
    }

    @Test(arguments: deckKeys)
    func 곡_목록의_기존_덱_키는_유지한다(_ key: UInt16) {
        #expect(KeyRoutingPolicy.accepts(key, in: .init(focus: .trackList)))
    }

    @Test(arguments: [36, 76, 53, 126, 125, 48, 115, 119, 116, 121] as [UInt16])
    func 곡_목록의_확정_취소_탐색은_표에_전달한다(_ key: UInt16) {
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(focus: .trackList)))
    }

    @Test(arguments: controlKeys + deckKeys)
    func 태그_표는_기존처럼_스페이스만_덱에서_받는다(_ key: UInt16) {
        #expect(KeyRoutingPolicy.accepts(key, in: .init(focus: .sheet)) == (key == 49))
    }

    @MainActor @Test
    func 창_이외의_응답자는_덱으로_간주하지_않는다() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeFirstResponder(nil)
        #expect(KeyRouter.focus(in: window) == .deck)
        let control = FocusableView()
        window.contentView?.addSubview(control)
        window.makeFirstResponder(control)
        #expect(KeyRouter.focus(in: window) == .control)
        let table = NSTableView(frame: .init(x: 0, y: 0, width: 300, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        window.contentView?.addSubview(table)
        #expect(window.makeFirstResponder(table))
        #expect(KeyRouter.focus(in: window) == .table)
        table.identifier = KeyRouter.trackListID
        #expect(KeyRouter.focus(in: window) == .trackList)
        let editor = NSTextView()
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        #expect(KeyRouter.focus(in: window) == .textInput)
    }
}

@MainActor
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
