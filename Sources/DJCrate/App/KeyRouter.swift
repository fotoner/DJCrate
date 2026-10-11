import AppKit
import DJCApplication
import DJCDomain

/// 창 전체 단축키와 검색창 포커스 정리.
///
/// SwiftUI `onKeyPress`는 그 뷰에 포커스가 있어야 동작해서, 파형(제스처가 클릭을 먹는다)이나 목록을
/// 누른 뒤에는 스페이스·CUE가 먹히지 않았다. 덱·곡 목록에서만 덱 단축키를 받고,
/// 다른 창(설정 창 포함)이나 글자 입력·컨트롤 포커스에는 끼어들지 않는다.
/// 어떤 키가 어떤 동작인지는 덱의 단축키 표(`DeckShortcuts`, 설정 › 단축키)를 따른다.
/// 검색창은 Esc·Return, 또는 글자 칸이 아닌 곳을 클릭하면 빠져나온다.
@MainActor
@Observable
final class KeyRouter {
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored weak var deck: DeckModel?
    @ObservationIgnored private weak var store: LibraryStore?
    /// 덱 단축키를 받지 않는 곡 편집·Flip 창
    @ObservationIgnored private weak var windows: AppWindows?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    /// 미리 듣기를 시작한 CUE 키(떼면 미리 듣기를 끝낸다)
    @ObservationIgnored private var heldCueKey: UInt16?

    func install(deck: DeckModel, store: LibraryStore? = nil, windows: AppWindows? = nil) {
        self.deck = deck
        self.store = store
        self.windows = windows
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { [weak self] event in
            // `self?.route(event) ?? event`로 쓰면 처리했다는 nil까지 원래 이벤트로 바뀌어 새어 나간다.
            guard let self else { return event }
            return self.route(event)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.releaseFocusIfNeeded(event)
            return event
        }) { monitors.append(monitor) }
        // CUE를 누른 채 다른 앱으로 넘어가면 keyUp이 오지 않는다. 미리 듣기를 끝낸다.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deck?.cueUp()
                self?.heldCueKey = nil
            }
        }
    }

    // MARK: - 키

    /// nil을 돌려주면 이벤트를 삼킨다(다른 곳으로 가지 않는다).
    private func route(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, let bigger = Self.textBiggerEvent(from: event) { return bigger }
#if DEBUG
        ScrubHotCueTrace.recordKey(event)
#endif
        guard let deck else { return event }
        // CUE를 누른 뒤 포커스가 바뀌어도 이미 시작한 미리 듣기는 끝내되, 키는 새 대상에 넘긴다.
        if event.type == .keyUp { handleKeyUp(event.keyCode) }
        guard let window = event.window else { return event }
        let responder = window.firstResponder
        let focus = Self.focus(in: window)
        let context = KeyRoutingPolicy.Context(
            isMainWindow: isDeckWindow(window),
            hasModalWindow: NSApp.modalWindow != nil,
            hasAttachedSheet: window.attachedSheet != nil,
            hasShortcutModifiers: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            focus: focus)
        guard context.isMainWindow, !context.hasModalWindow, !context.hasAttachedSheet else { return event }
        if event.type == .keyDown, KeyRoutingPolicy.loadsSelection(event.keyCode, modifiers: event.modifierFlags, focus: focus) {
            store?.loadSelectionToDeck()
            return nil
        }
        // 표준 시스템 단축키는 AppKit에 맡긴다. 종료는 앱 델리게이트가 별도로 거절한다.
        if context.hasShortcutModifiers { return event }
        let lock = WriteLockPolicy(isWriting: deck.isWriteLocked, canCancelPreparation: store?.writeStage?.cancellable == true)
        if lock.blocksKey(event.keyCode, in: context) { return nil }
        if lock.isWriting, lock.canCancelPreparation, event.keyCode == Self.escape { return event }
        if let editor = responder as? NSTextView {
            return routeWhileTyping(event, editor: editor, window: window)
        }
        if focus == .control || focus == .table || focus == .textInput { return event }
        guard KeyRoutingPolicy.accepts(event.keyCode, in: context, shortcuts: deck.shortcuts) else { return event }

        if event.type == .keyUp {
            return deck.shortcuts.action(for: event.keyCode) == .cue ? nil : event
        }
        if handleKeyDown(event.keyCode, shift: event.modifierFlags.contains(.shift), isRepeat: event.isARepeat, focus: focus) {
            return nil
        }
        if focus == .sheet { return event }

        if focus == .deck {
            switch event.specialKey {
            case .upArrow?, .downArrow?, .pageUp?, .pageDown?, .home?, .end?:
                // 파형을 누른 뒤에도 ↑↓로 곡을 고를 수 있게 목록으로 넘긴다.
                if let list = focusList(in: window) {
                    list.keyDown(with: event)
                    return nil
                }
            case .tab?, .backTab?:
                return event  // 키보드로 컨트롤 사이를 옮겨 다니는 키
            default:
                break
            }
            // 덱을 보고 있을 때 처리하지 않은 키는 받을 곳이 없어 경고음(뚱)이 난다. 삼킨다.
            return nil
        }
        if focus == .trackList, let store, store.playlists.editablePlaylistID != nil,
           [.delete, .deleteForward, .backspace].contains(event.specialKey) {
            // 재생 목록을 볼 때 ⌫는 이 목록에서만 뺀다(초안). 컬렉션에서 빼기는 메뉴의 확인 창을 거친다.
            store.playlists.removeSelectedFromPlaylist()
            return nil
        }
        if !(responder is NSOutlineView) {
            // 곡 목록에서 ←→·Delete는 할 일이 없고, 넘기면 경고음이 난다(사이드바는 ←→로 폴더를 접는다).
            switch event.specialKey {
            case .leftArrow?, .rightArrow?, .delete?, .deleteForward?, .backspace?: return nil
            default: break
            }
        }
        return event
    }

    /// ⌘=를 메뉴 '글자 크게'(⌘+)에 걸리는 ⌘⇧= 이벤트로 바꾼다. 처리는 그대로 메뉴가 한다.
    static func textBiggerEvent(from event: NSEvent) -> NSEvent? {
        guard KeyRoutingPolicy.isTextBiggerAlias(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return nil }
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
                                modifierFlags: event.modifierFlags.union(.shift), timestamp: event.timestamp,
                                windowNumber: event.windowNumber, context: nil, characters: "+",
                                charactersIgnoringModifiers: "+", isARepeat: event.isARepeat, keyCode: event.keyCode)
    }

    /// 글자 입력 중에는 단축키를 쓰지 않는다. 대신 입력을 끝내는 키(Return·Esc)에서 포커스를 놓아 준다.
    /// 놓지 않으면 BPM·큐 이름 칸에 Return을 친 뒤에도 스페이스·C가 계속 칸으로 들어가 재생이 안 된다.
    private func routeWhileTyping(_ event: NSEvent, editor: NSTextView, window: NSWindow) -> NSEvent? {
        // 한글 조합 중에는 입력기에 맡긴다.
        guard event.type == .keyDown, !editor.hasMarkedText() else { return event }
        let isReturn = event.keyCode == Self.returnKey || event.keyCode == Self.enter
        let isEscape = event.keyCode == Self.escape
        guard isReturn || isEscape else { return event }
        if editor.delegate is NSSearchField {
            // Esc의 검색어 지우기·Return의 확정을 먼저 처리한 뒤 목록으로 옮긴다.
            Task { @MainActor [weak self] in
                if window.firstResponder === editor { self?.focusList(in: window) }
            }
            return event
        }
        // 태그 시트 셀·곡 목록 칸 편집은 확정·취소 뒤 표로 포커스를 돌리는 규칙이 따로 있다.
        guard let field = editor.delegate as? NSTextField, !Self.editsInTable(field) else { return event }
        // 확정·취소는 칸에 먼저 보내고 포커스를 놓는다.
        Task { @MainActor in
            if window.firstResponder === editor { window.makeFirstResponder(nil) }
        }
        return event
    }

    /// 태그 시트나 곡 목록(#88) 칸에서 고치는 글자 칸인가. 그 표가 Return·Tab·Esc를 처리하고 표로 포커스를 돌린다.
    static func editsInTable(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate is SheetTableView { return true }
            if let table = candidate as? NSTableView, table.identifier == trackListID { return true }
            current = candidate.superview
        }
        return false
    }

    /// 덱 단축키. 글자가 아니라 키 위치로 본다(한글 입력기가 켜져 있으면 C 키가 "ㅊ"으로 들어와 글자로는 못 알아본다).
    /// 처리했으면 true. NSEvent 없이 시험할 수 있게 창·포커스 판단(`route`)과 나눴다.
    func handleKeyDown(_ keyCode: UInt16, shift: Bool = false, isRepeat: Bool = false, focus: KeyRoutingPolicy.Focus) -> Bool {
        guard let deck, deck.row != nil else { return false }
        // Esc(예약 키)는 덱에서 큐 선택만 푼다. 그 뒤 ←→는 재생 위치를 옮긴다. 목록·검색창·시트의 Esc는 그대로 둔다.
        if keyCode == Self.escape {
            guard focus == .deck, deck.selectedCueID != nil else { return false }
            deck.selectedCueID = nil
            return true
        }
        guard let action = deck.shortcuts.action(for: keyCode) else { return false }
        if action == .playPause {
            if !isRepeat { deck.togglePlay() }
            return true
        }
        // 태그 표에서는 재생/정지만 덱으로 보낸다(나머지는 칸 입력).
        guard focus != .sheet else { return false }
        let deckFocused = focus == .deck
        // 핫큐 A~H: 버튼을 누른 것과 같다(있으면 이동, 없으면 플레이헤드에 찍기). Shift를 함께 누르면 지우기.
        if let slot = action.hotCueSlot {
            if !isRepeat {
                if shift { deck.deleteHotCue(slot: slot) } else { deck.pressHotCue(slot: slot) }
            }
            return true
        }
        switch action {
        case .cue:
            if !isRepeat { deck.cueDown(); heldCueKey = keyCode }
        case .previousCue: if !isRepeat { deck.jumpToCue(forward: false) }
        case .nextCue: if !isRepeat { deck.jumpToCue(forward: true) }
        case .memoryCue:
            // Shift를 함께 누르면 이 자리 메모리 큐 지우기
            if !isRepeat {
                if shift { deck.deleteMemoryCue(at: deck.currentTime) } else { deck.addMemoryCue() }
            }
        case .nudgeBack, .nudgeForward:
            // 선택한 큐가 있으면 그 큐를, 없으면 재생 위치를 1박(Shift: 1마디) 옮긴다.
            guard deckFocused else { return false }
            deck.step(beats: (action == .nudgeBack ? -1 : 1) * (shift ? BeatJump.beatsPerBar : 1))
        case .deleteCue: return deckFocused && deck.deleteSelectedCue()
        case .nextSuggestion: if !isRepeat { deck.jumpToSuggestion(forward: !shift) }
        case .acceptSuggestion: if !isRepeat { deck.acceptNearestSuggestion() }
        case .tapTempo: if !isRepeat { deck.tapTempo() }
        case .loop: if !isRepeat { deck.toggleLoop() }
        case .loopHalve: deck.resizeLoop(-1)
        case .loopDouble: deck.resizeLoop(1)
        case .zoomIn: deck.zoom(by: 0.8)
        case .zoomOut: deck.zoom(by: 1.25)
        case .playPause, .hotCueA, .hotCueB, .hotCueC, .hotCueD, .hotCueE, .hotCueF, .hotCueG, .hotCueH:
            return false   // 위에서 처리
        }
        return true
    }

    /// CUE 키를 떼면 미리 듣기를 끝낸다. 끝냈으면 true.
    @discardableResult
    func handleKeyUp(_ keyCode: UInt16) -> Bool {
        guard keyCode == heldCueKey else { return false }
        deck?.cueUp()
        heldCueKey = nil
        return true
    }

    /// 덱 단축키를 받는 창: 설정·단축키 안내 창과 곡 편집·Flip 창(자체 재생기·단축키가 있다)을 제외한 주 창.
    private func isDeckWindow(_ window: NSWindow) -> Bool {
        window === NSApp.mainWindow && window !== SettingsWindow.current && window !== ShortcutsWindow.current
            && window !== windows?.trackEdit.window && window !== windows?.flip.window
    }

    // MARK: - 목록 포커스

    static let trackListID = NSUserInterfaceItemIdentifier("djc.trackList")
    private weak var list: NSTableView?

    static func focus(in window: NSWindow) -> KeyRoutingPolicy.Focus {
        let responder = window.firstResponder
        if responder is NSTextView || responder is NSTextField { return .textInput }
        if responder is SheetTableView { return .sheet }
        if let table = responder as? NSTableView {
            return table.identifier == trackListID ? .trackList : .table
        }
        // 파형 클릭은 창으로 포커스를 돌린다. SwiftUI의 내부 컨트롤도 기본적으로 보호한다.
        return responder === window ? .deck : .control
    }

    /// 곡 목록(태그 시트 모드면 시트)에 포커스를 준다. 없으면 창 자신에게.
    @discardableResult
    private func focusList(in window: NSWindow) -> NSTableView? {
        let table = (list?.window === window ? list : nil) ?? findList(in: window.contentView)
        list = table
        window.makeFirstResponder(table)
        return table
    }

    private func findList(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table is SheetTableView || table.identifier == Self.trackListID {
            return table
        }
        for subview in view.subviews {
            if let found = findList(in: subview) { return found }
        }
        return nil
    }

    // MARK: - 클릭

    /// 글자 칸·표가 아닌 곳(파형·덱 버튼·빈 곳)을 누르면 포커스를 창으로 돌려 단축키가 덱으로 가게 한다.
    /// 검색창에 포커스가 박혀 스페이스가 검색어로 들어가던 문제를 여기서 푼다.
    private func releaseFocusIfNeeded(_ event: NSEvent) {
        guard NSApp.modalWindow == nil, let window = event.window, isDeckWindow(window),
              window.attachedSheet == nil,
              let root = window.contentView?.superview,
              let hit = root.hitTest(event.locationInWindow) else { return }
        var view: NSView? = hit
        while let current = view {
            if current is NSTextView || current is NSControl {
                return
            }
            view = current.superview
        }
        if window.firstResponder !== window { window.makeFirstResponder(nil) }
    }

    private static let escape: UInt16 = 53
    private static let returnKey: UInt16 = 36
    private static let enter: UInt16 = 76
}
