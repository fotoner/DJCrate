#if DEBUG
import AppKit
import DJCDomain
import DJCStorage
import Foundation

extension DevSelfTests {
    static func setKeyRoutingSheetMode(_ value: Bool, settings: SettingsStore) {
        // 자가 테스트의 persist=false와 별개인 AppStorage 보기만 바꾸고 실행 뒤 원래 값으로 복원한다.
        settings.defaults.set(value, forKey: SettingKeys.sheetMode.name)
    }

    /// 앱 큐에만 키를 넣는다. active 모드는 사용자 직접 클릭을 기다리며 OS 키 입력은 보내지 않는다.
    static func runKeyRoutingSelfTestIfRequested(store: LibraryStore, deck: DeckModel, windows: AppWindows) {
        guard ProcessInfo.processInfo.arguments.contains("--key-routing-selftest"),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        guard let mode = KeyRoutingSelfTestMode.requested(arguments: ProcessInfo.processInfo.arguments,
                                                        environment: ProcessInfo.processInfo.environment) else { exit(2) }
        Task {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var checks = 0, failures = 0
            var captureCount = 0, captureFailures = 0
            @MainActor func check(_ condition: Bool, _ name: String) {
                checks += 1
                if !condition { failures += 1 }
                FileHandle.standardError.write(Data("[키 전달] \(name): \(condition ? "통과" : "실패")\n".utf8))
            }
            @MainActor func waitUntil(_ condition: () -> Bool) async {
                for _ in 0..<100 {
                    if condition() { return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            @MainActor func send(_ window: NSWindow, code: UInt16, text: String) async {
                if mode == .active {
                    guard NSApp.isActive, window.isKeyWindow,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                        FileHandle.standardError.write(Data("[키 전달] 미검증: 입력 대상의 키 창·활성 상태가 바뀌어 중단 · 종료 코드 2\n".utf8))
                        exit(2)
                    }
                }
                for type: NSEvent.EventType in [.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: text, charactersIgnoringModifiers: text,
                                                    isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            @MainActor func find<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
                guard let root else { return nil }
                if let found = root as? T { return found }
                for child in root.subviews {
                    if let found = find(type, in: child) { return found }
                }
                return nil
            }
            await waitUntil { if case .loaded = store.phase { true } else { false } }
            guard store.rows.count == 2, store.rows.allSatisfy({ $0.title.hasPrefix("합성 곡 ·") }),
                  let row = store.rowsByID["1"],
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { exit(2) }
            if mode == .inactive { guard !NSApp.isActive else { exit(2) } }
            deck.shortcuts = .standard
            setKeyRoutingSheetMode(false, settings: store.settings)
            store.loadToDeck(row)
            await deck.loadTask?.value
            deck.gridDraft = GridDraft(trackUUID: row.track.uuid, base: [], segments: [.init(start: 0, bpm: 120, firstBeatNumber: 1)])
            deck.refreshGrid()
            if mode == .active {
                var clicked = false
                let clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    if event.window === window { clicked = true }
                    return event
                }
                window.orderFront(nil)
                FileHandle.standardError.write(Data("[키 전달] 사용자 클릭 대기: \(window.title) · 최대 10분 · 키 이벤트 전송 전\n".utf8))
                let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(600))
                while !(clicked && NSApp.isActive && window.isKeyWindow && NSApp.mainWindow === window), clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
                guard clicked else {
                    FileHandle.standardError.write(Data("[키 전달] 미검증: 10분 안에 시험 창 직접 클릭을 확인하지 못함 · 종료 코드 2\n".utf8))
                    exit(2)
                }
            } else {
                window.makeMain()
                window.makeKey()
            }
            FileHandle.standardError.write(Data("[키 전달] 내부 상태: key=\(window.isKeyWindow), main=\(NSApp.mainWindow === window), active=\(NSApp.isActive)\n".utf8))
            if mode == .active {
                check(NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                      "허용된 활성 모드의 앱 포커스(시작)")
                check(window.isKeyWindow && NSApp.mainWindow === window && NSApp.isActive, "활성 모드의 내부 키 창")
            } else {
                check(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "외부 앱 포커스 보존(시작)")
                check(window.isKeyWindow && NSApp.mainWindow === window && !NSApp.isActive, "앱 비활성 상태의 내부 키 창")
            }
            guard failures == 0 else {
                FileHandle.standardError.write(Data("[키 전달] 미검증: 내부 키 창을 만들지 못해 키 이벤트를 보내지 않음 · 종료 코드 2\n".utf8))
                exit(2)
            }
            @MainActor func capture(_ target: NSWindow, _ name: String) {
                guard mode == .active, let home = ProcessInfo.processInfo.environment["DJC_HOME"] else { return }
                let directory = URL(filePath: home).appending(path: "key-routing-captures")
                let process = Process()
                process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(target.windowNumber), directory.appending(path: "\(name).jpg").path]
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    target.contentView?.layoutSubtreeIfNeeded()
                    target.displayIfNeeded()
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { captureCount += 1 } else { captureFailures += 1 }
                } catch { captureFailures += 1 }
            }

            // 덱 포커스와 실제 곡 목록의 단축키가 같은 덱에 도착한다.
            deck.zoomSeconds = 10
            window.makeFirstResponder(nil)
            let zoom = deck.zoomSeconds
            capture(window, "deck-before")
            await send(window, code: 24, text: "=")
            check(deck.zoomSeconds < zoom, "덱 확대 키")
            capture(window, "deck-after")
            await waitUntil { find(TrackListTableView.self, in: window.contentView) != nil }
            if let table = find(TrackListTableView.self, in: window.contentView) {
                window.makeFirstResponder(table)
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                capture(window, "list-navigation-before")
                await send(window, code: 125, text: "\u{f701}")
                check(table.selectedRow == 1, "곡 목록 탐색 키")
                capture(window, "list-navigation-after")
                let before = deck.zoomSeconds
                capture(window, "list-zoom-before")
                await send(window, code: 24, text: "=")
                check(deck.zoomSeconds < before, "곡 목록의 덱 확대 키")
                capture(window, "list-zoom-after")
                let returnZoom = deck.zoomSeconds
                capture(window, "list-return-before")
                await send(window, code: 36, text: "\r")
                check(table.coordinator?.isEditing == true && KeyRouter.focus(in: window) == .textInput && deck.zoomSeconds == returnZoom,
                      "곡 목록 Return은 태그 편집으로")
                capture(window, "list-return-after")
                await send(window, code: 53, text: "\u{1b}")
                check(table.coordinator?.isEditing == false && window.firstResponder === table, "곡 목록 Esc는 편집 취소로")
            } else { check(false, "실제 곡 목록 찾기") }

            // 실제 검색칸의 필드 에디터가 글자 키를 받으며 덱은 그대로다.
            let search = window.toolbar?.items.compactMap { ($0 as? NSSearchToolbarItem)?.searchField }.first
                ?? find(NSSearchField.self, in: window.contentView?.superview)
            if let search {
                store.search = ""
                search.stringValue = ""
                window.makeFirstResponder(search)
                let before = deck.memoryCueCount
                capture(window, "search-before")
                await send(window, code: 46, text: "m")
                check(search.currentEditor()?.string == "m" && deck.memoryCueCount == before, "글자 입력은 덱 키를 가로채지 않음")
                capture(window, "search-after")
                window.makeFirstResponder(nil)
                store.search = ""
            } else { check(false, "실제 검색칸 찾기") }

            // 태그 시트의 방향키는 셀로 전달한다.
            setKeyRoutingSheetMode(true, settings: store.settings)
            await waitUntil { find(SheetTableView.self, in: window.contentView) != nil }
            if let sheet = find(SheetTableView.self, in: window.contentView), let coordinator = sheet.coordinator {
                window.makeFirstResponder(sheet)
                coordinator.select(.init(row: 0, column: 1), extend: false)
                let before = deck.playhead
                capture(window, "tag-sheet-before")
                await send(window, code: 124, text: "\u{f703}")
                check(coordinator.cursor == .init(row: 0, column: 2) && deck.playhead == before, "태그 시트 방향키")
                capture(window, "tag-sheet-after")
                let cues = deck.memoryCueCount, zoom = deck.zoomSeconds
                capture(window, "tag-input-before")
                await send(window, code: 46, text: "m")
                check(coordinator.isEditing && (window.firstResponder as? NSTextView)?.string == "m"
                      && deck.memoryCueCount == cues && deck.zoomSeconds == zoom, "태그 글자 입력은 덱으로 가지 않음")
                capture(window, "tag-input-after")
                capture(window, "tag-return-before")
                await send(window, code: 36, text: "\r")
                check(!coordinator.isEditing && window.firstResponder === sheet
                      && coordinator.cursor == .init(row: 1, column: 2)
                      && store.tagCell(coordinator.rows[0], .artist) == "m", "태그 Return은 칸 확정으로")
                capture(window, "tag-return-after")
                coordinator.select(.init(row: 0, column: 2), extend: false)
                await send(window, code: 24, text: "=")
                capture(window, "tag-escape-before")
                await send(window, code: 53, text: "\u{1b}")
                check(!coordinator.isEditing && window.firstResponder === sheet
                      && store.tagCell(coordinator.rows[0], .artist) == "m" && deck.zoomSeconds == zoom,
                      "태그 Esc는 칸 취소로")
                capture(window, "tag-escape-after")
            } else { check(false, "실제 태그 시트 찾기") }

            // AppKit의 실제 부착 시트·모달 세션 안 글자 입력은 덱을 바꾸지 않는다.
            for modal in [false, true] {
                let alert = NSAlert()
                alert.messageText = "합성 키 전달 시험"
                let input = NSTextField(string: "")
                input.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
                alert.accessoryView = input
                alert.addButton(withTitle: "확인")
                alert.layout()
                let before = deck.zoomSeconds
                if modal {
                    let session = NSApp.beginModalSession(for: alert.window)
                    _ = NSApp.runModalSession(session)
                    alert.window.makeFirstResponder(input)
                    capture(alert.window, "modal-before")
                    await send(alert.window, code: 24, text: "=")
                    check(NSApp.modalWindow === alert.window && input.currentEditor()?.string == "=" && deck.zoomSeconds == before, "모달의 글자 키")
                    capture(alert.window, "modal-after")
                    NSApp.endModalSession(session)
                    alert.window.orderOut(nil)
                } else {
                    window.beginSheet(alert.window, completionHandler: { _ in })
                    alert.window.makeFirstResponder(input)
                    capture(alert.window, "attached-sheet-before")
                    await send(alert.window, code: 24, text: "=")
                    check(window.attachedSheet === alert.window && input.currentEditor()?.string == "=" && deck.zoomSeconds == before, "부착 시트의 글자 키")
                    capture(alert.window, "attached-sheet-after")
                    window.endSheet(alert.window)
                    alert.window.orderOut(nil)
                }
            }

            // 확인·취소 키도 실제 AppKit 시트와 모달의 버튼으로 전달한다.
            for modal in [false, true] {
                for escape in [false, true] {
                    let alert = NSAlert()
                    alert.messageText = "합성 키 전달 시험"
                    alert.addButton(withTitle: "확인")
                    alert.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
                    alert.layout()
                    let before = deck.zoomSeconds, cues = deck.memoryCueCount
                    let name = "\(modal ? "modal" : "attached-sheet")-\(escape ? "escape" : "return")"
                    let expected: NSApplication.ModalResponse = escape ? .alertSecondButtonReturn : .alertFirstButtonReturn
                    var response: NSApplication.ModalResponse?
                    let session: NSApplication.ModalSession?
                    if modal {
                        session = NSApp.beginModalSession(for: alert.window)
                        _ = NSApp.runModalSession(session!)
                    } else {
                        session = nil
                        window.beginSheet(alert.window) { response = $0 }
                    }
                    alert.window.makeFirstResponder(nil)
                    capture(alert.window, "\(name)-before")
                    await send(alert.window, code: escape ? 53 : 36, text: escape ? "\u{1b}" : "\r")
                    if let session {
                        response = NSApp.runModalSession(session)
                        NSApp.endModalSession(session)
                    } else {
                        await waitUntil { response != nil }
                    }
                    check(response == expected && deck.zoomSeconds == before && deck.memoryCueCount == cues,
                          "\(modal ? "모달" : "부착 시트") \(escape ? "Esc" : "Return")은 해당 창으로")
                    if window.attachedSheet === alert.window { window.endSheet(alert.window) }
                    alert.window.orderOut(nil)
                    window.makeKeyAndOrderFront(nil)
                    capture(window, "\(name)-after")
                }
            }

            // 제품의 곡 편집 창에 온 확대 키는 편집 창만 바꾼다.
            await windows.trackEdit.open()
            if let editWindow = windows.trackEdit.window, let model = windows.trackEdit.model {
                editWindow.makeFirstResponder(nil)
                let before = model.sourceView, deckZoom = deck.zoomSeconds
                capture(editWindow, "edit-before")
                await send(editWindow, code: 24, text: "=")
                check(model.sourceView != before && deck.zoomSeconds == deckZoom, "곡 편집 창 확대 키")
                capture(editWindow, "edit-after")
                editWindow.close()
            } else { check(false, "곡 편집 창 열기") }
            if mode == .active {
                check(NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                      "활성 모드의 앱 포커스(끝)")
                check(captureCount == 32 && captureFailures == 0, "대상 창 전후 캡처 32개")
            } else {
                check(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "외부 앱 포커스 보존")
            }
            FileHandle.standardError.write(Data("[키 전달] 결과: \(checks - failures)/\(checks) 통과 · 앱 안 이벤트 · 소리 재생 없음\n".utf8))
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
