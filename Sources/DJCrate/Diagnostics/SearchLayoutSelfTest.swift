#if DEBUG
import AppKit

extension DevSelfTests {
    /// 메뉴 막대 안에서 키 등가물이 `key`+⌘인 항목과 그 항목이 든 메뉴. 편집 › 찾기가 하나뿐인지(시스템 찾기와 겹치지 않는지) 본다.
    static func commandKeyMenuItems(_ key: String, in menu: NSMenu? = NSApp.mainMenu) -> [(menu: NSMenu, item: NSMenuItem)] {
        guard let menu else { return [] }
        var found: [(NSMenu, NSMenuItem)] = []
        for item in menu.items {
            if item.keyEquivalent.lowercased() == key, item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command {
                found.append((menu, item))
            }
            found += commandKeyMenuItems(key, in: item.submenu)
        }
        return found
    }

    static func findSubview<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let found = root as? T { return found }
        for child in root.subviews {
            if let found = findSubview(type, in: child) { return found }
        }
        return nil
    }

    /// 머리 줄 검색칸(#338)이 툴바 폭과 이웃 단추를 흔들지 않는지 실제 창에서 확인한다.
    /// 툴바에 검색 항목이 없고, 창 폭마다 툴바 단추가 접히지 않고, 머리 줄 검색칸이 포커스 전후 같은 자리·폭인지 본다.
    /// 메뉴 막대에 ⌘F가 하나뿐인지 세고, 포커스는 그 메뉴 항목이 부르는 입구(`LibraryMenuAction.find`)로 옮긴다.
    /// 앞에 다른 앱이 있으면 이 Mac에서는 앱을 활성할 수 없고 그러면 SwiftUI가 메뉴 켜짐 상태를 주지 않는다.
    /// 그래서 메뉴 항목의 켜짐은 앱이 활성일 때만 판정하고, 아니면 "미검증"으로 남긴다(실제 키 입력은 사람이 본다).
    /// 창 아래 상태 줄(#298)이 창 폭 안·도구 막대 아래에 있고 활동 단추가 그 줄 안에 보이는지도 본다.
    static func runSearchLayoutIfRequested(store: LibraryStore, libraryWindow: LibraryWindowModel) {
        guard ProcessInfo.processInfo.arguments.contains("--search-layout-selftest"),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        Task {
            func wait() async { try? await Task.sleep(for: .milliseconds(500)) }
            @MainActor func capture(_ window: NSWindow, name: String) -> Bool {
                guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--search-layout-captures=") }) else { return true }
                let directory = String(argument.dropFirst("--search-layout-captures=".count))
                let command = Process()
                command.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                command.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/\(name).png"]
                do { try command.run() } catch { return false }
                command.waitUntilExit()
                return command.terminationStatus == 0
            }
            @MainActor func searchWindow() -> NSWindow? {
                NSApp.windows.first { $0.toolbar != nil && $0.canBecomeMain && findSubview(NSSearchField.self, in: $0.contentView) != nil }
            }
            // 검색칸은 라이브러리를 읽은 뒤의 목록 위에만 있다. 합성 사본(--db)을 읽을 때까지 기다린다
            for _ in 0..<40 {
                if searchWindow() != nil, case .loaded = store.phase { break }
                await wait()
            }
            guard let window = searchWindow(), let toolbar = window.toolbar else {
                FileHandle.standardError.write(Data("[검색 배치 시험] 미검증: 머리 줄 검색칸을 찾지 못했습니다(합성 사본을 --db로 주세요) · 종료 코드 2\n".utf8))
                exit(2)
            }
            // 앱을 막 띄운 창에서 검색칸이 저절로 포커스를 가져가지 않는지 본다(Space·C 같은 덱 단축키가 검색어로 들어가면 안 된다).
            // 창을 키 창으로 만들기 전의 상태다. 이 Mac은 앱을 활성할 수 없어 AppKit이 키 창이 될 때 고르는 첫 포커스는 볼 수 없다
            let startField = findSubview(NSSearchField.self, in: window.contentView)
            let startEditor = (window.firstResponder as? NSTextView)?.delegate
            let startState = "초기 첫 응답자 \(window.initialFirstResponder.map { String(describing: type(of: $0)) } ?? "없음") · 현재 첫 응답자 \(type(of: window.firstResponder))"
            let startGrabbed = (startField != nil && (window.initialFirstResponder === startField || startEditor === startField))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            await wait()
            // 앞에 다른 앱이 있으면 활성을 양보받지 못한다. 앱 안에서만 키 창·주 창으로 만든다(키 전달 시험과 같은 방식)
            if !window.isKeyWindow { window.makeMain(); window.makeKey() }
            await wait()
            let originalSize = window.contentView?.frame.size ?? NSSize(width: 1440, height: 900)
            var failures = 0
            @MainActor func report(_ name: String, _ passed: Bool, _ detail: String = "") {
                if !passed { failures += 1 }
                FileHandle.standardError.write(Data("[검색 배치 시험] \(name): \(passed ? "통과" : "실패")\(detail.isEmpty ? "" : " · \(detail)")\n".utf8))
            }
            // 사용자화로 저장된 구성이 지운 항목(옛 `reflection`)을 들고 있어도 빈 칸 없이 남은 항목만 보이는지 알 수 있게 항목 목록을 남긴다
            let itemList = toolbar.items.map(\.itemIdentifier.rawValue).joined(separator: ",")
            FileHandle.standardError.write(Data("[검색 배치 시험] 도구 막대 항목: \(itemList)\n".utf8))
            report("시작 직후 검색칸이 포커스를 가져가지 않음", !startGrabbed, startState)
            // 검색칸은 툴바가 아니라 머리 줄에 있다
            report("툴바에 검색 항목 없음", !toolbar.items.contains { $0 is NSSearchToolbarItem })
            // 편집 › 찾기가 메뉴 막대의 ⌘F 전부다
            NSApp.mainMenu?.update()
            let finds = commandKeyMenuItems("f")
            let findLine = finds.map { "\($0.menu.title) › \($0.item.title)(\($0.item.isEnabled ? "켜짐" : "꺼짐"))" }.joined(separator: ", ")
            report("메뉴 막대의 ⌘F 항목 하나", finds.count == 1 && finds[0].item.title == "찾기", findLine)
            if NSApp.isActive {
                report("편집 › 찾기 메뉴 켜짐", finds.first?.item.isEnabled == true)
            } else {
                FileHandle.standardError.write(Data("[검색 배치 시험] 편집 › 찾기 메뉴 켜짐: 미검증(앱이 비활성이라 SwiftUI 메뉴 상태가 없음 · 다른 메뉴 항목도 같음)\n".utf8))
            }
            report("찾기 켜짐 판정(주 창 모델)", LibraryMenuAction.find.isEnabled(in: libraryWindow))
            for width: CGFloat in [1155, 1200, 1440, 1800] {
                window.makeFirstResponder(nil)
                window.setContentSize(NSSize(width: width, height: 700))
                await wait()
                window.contentView?.layoutSubtreeIfNeeded()
                guard let field = findSubview(NSSearchField.self, in: window.contentView) else {
                    report("창 \(Int(width))", false, "머리 줄 검색칸이 없음")
                    continue
                }
                let before = field.convert(field.bounds, to: nil)
                let neighbors = toolbar.items.compactMap(\.view)
                    .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }
                let positions = neighbors.map { $0.convert($0.bounds, to: nil) }
                if !capture(window, name: "\(Int(width))-unfocused") { failures += 1 }
                // 메뉴 항목이 부르는 입구 그대로: 켜짐 판정 → 주 창 모델의 요청 번호 → 검색칸 잎 → 포커스
                LibraryMenuAction.find.perform(in: libraryWindow)
                await wait()
                window.contentView?.layoutSubtreeIfNeeded()
                let after = field.convert(field.bounds, to: nil)
                if !capture(window, name: "\(Int(width))-focused") { failures += 1 }
                let movement = zip(neighbors, positions).map { view, frame in
                    let now = view.convert(view.bounds, to: nil)
                    return max(abs(now.minX - frame.minX), abs(now.width - frame.width))
                }.max() ?? 0
                let focused = (window.firstResponder as? NSTextView)?.delegate === field
                let visibleIDs = Set((toolbar.visibleItems ?? []).map { $0.itemIdentifier.rawValue })
                let hiddenControls = ["viewMode", "addFiles", "tagEditor", "snapshot"].filter { !visibleIDs.contains($0) }
                let controlsVisible = hiddenControls.isEmpty
                // 머리 줄 검색칸은 도구 막대 아래 본문 영역 안에 완전히 들어와야 한다
                let content = window.contentView?.frame.size ?? .zero
                let fieldInside = after.width > 0 && window.contentLayoutRect.insetBy(dx: -0.5, dy: -0.5).contains(after) && after.maxX <= content.width + 0.5
                // 상태 줄 자리는 위 왼쪽 원점의 창 좌표다. 도구 막대 아래 끝은 내용 영역(`contentLayoutRect`)의 위 끝이다
                let toolbarBottom = content.height - window.contentLayoutRect.maxY
                let bar = SelfTestFrames.frames.first { $0.key.hasPrefix("statusBar.") }?.value
                let button = SelfTestFrames.frames["statusBarActivity"]
                let barFits = bar.map { $0.width > 0 && $0.minY >= toolbarBottom && abs($0.maxY - content.height) <= 0.5
                    && $0.minX >= -0.5 && $0.maxX <= content.width + 0.5 } ?? false
                let buttonFits = barFits && button.map { $0.width > 0 && bar?.insetBy(dx: -0.5, dy: -0.5).contains($0) == true } ?? false
                let stable = focused && controlsVisible && !neighbors.isEmpty && before.width > 0
                    && abs(before.width - after.width) <= 0.5 && abs(before.minX - after.minX) <= 0.5 && abs(before.minY - after.minY) <= 0.5
                    && movement <= 0.5 && fieldInside && buttonFits
                if !stable { failures += 1 }
                let line = String(format: "[검색 배치 시험] 창 %.0f(실제 %.0f) · 검색칸 폭 %.2f → %.2f · 이웃 %d개 최대 이동 %.2f · 포커스 %@ · 칸 위치 %@ · 버튼 표시 %@ · 상태 줄 %@(%@) · %@\n",
                                  width, window.contentView?.frame.width ?? 0, before.width, after.width,
                                  neighbors.count, movement,
                                  focused ? "있음" : "없음", fieldInside ? "맞음" : "어긋남",
                                  controlsVisible ? "모두" : "일부(접힘: \(hiddenControls.joined(separator: ",")))", buttonFits ? "맞음" : "어긋남",
                                  bar.map { NSStringFromRect($0) } ?? "없음", stable ? "통과" : "실패")
                FileHandle.standardError.write(Data(line.utf8))
                window.makeFirstResponder(nil)
            }
            window.setContentSize(originalSize)
            FileHandle.standardError.write(Data("[검색 배치 시험] 끝: \(failures == 0 ? "통과" : "실패 \(failures)건")\n".utf8))
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
