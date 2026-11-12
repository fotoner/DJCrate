#if DEBUG
import AppKit
import DJCDomain

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

    /// 메뉴 항목의 켜짐을 지금 상태로 다시 매긴다. `NSMenu.update()`는 그 메뉴의 항목만 매기므로 하위 메뉴까지 내려간다.
    /// SwiftUI 명령 메뉴는 열리기 직전(`menuNeedsUpdate`)에 항목을 채우므로 그것도 부른다
    static func updateMenus(_ menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items { updateMenus(item.submenu) }
    }

    static func findSubview<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let found = root as? T { return found }
        for child in root.subviews {
            if let found = findSubview(type, in: child) { return found }
        }
        return nil
    }

    /// 툴바에 남아야 하는 앱 단위 항목(#339). 창 폭마다 접히지 않고 보여야 한다
    static let toolbarItemIDs = ["volume", "addFiles", "tagEditor", "snapshot"]
    /// 머리 줄로 옮기며 툴바에서 지운 항목. 툴바 구성에 남아 있으면 안 된다
    static let retiredToolbarItemIDs = ["viewMode", "attributeFilter"]

    /// 머리 줄 검색칸(#338)이 툴바 폭과 이웃 단추를 흔들지 않는지 실제 창에서 확인한다.
    /// 툴바에 검색 항목이 없고, 창 폭마다 툴바 단추가 접히지 않고, 머리 줄 검색칸이 포커스 전후 같은 자리·폭인지 본다.
    /// 메뉴 막대에 ⌘F가 하나뿐인지 세고, 포커스는 그 메뉴 항목이 부르는 입구(`LibraryMenuAction.find`)로 옮긴다.
    /// 앞에 다른 앱이 있으면 이 Mac에서는 앱을 활성할 수 없고 그러면 SwiftUI가 메뉴 켜짐 상태를 주지 않는다.
    /// 그래서 메뉴 항목의 켜짐은 앱이 활성일 때만 판정하고, 아니면 "미검증"으로 남긴다(실제 키 입력은 사람이 본다).
    /// 창 아래 상태 줄(#298)이 창 폭 안·도구 막대 아래에 있고 활동 단추가 그 줄 안에 보이는지도 본다.
    static func runSearchLayoutIfRequested(store: LibraryStore, libraryWindow: LibraryWindowModel) {
        guard ProcessInfo.processInfo.arguments.contains("--search-layout-selftest"),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        // 모든 작업 폴더가 같은 UserDefaults 영역을 쓴다. 이 시험이 바꾸는 창 프레임·분할 뷰·보기 모드·인스펙터·사이드바·글자 배율은
        // 끝나면 처음 저장돼 있던 값으로 되돌린다(`UIPerfSelfTest`와 같다). 실행 인자로 준 값이 아니라 저장된 값을 읽는다
        let storedDefaults = UserDefaults.standard.persistentDomain(forName: ProcessInfo.processInfo.processName) ?? [:]
        let restoredKeys = UIPerfSelfTest.restoredKeys + [SettingKeys.textScale.name]
        let savedDefaults = restoredKeys.map { ($0, storedDefaults[$0]) }
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
            // 옛 항목(보기 전환·필터)을 지웠다. 사용자화로 저장된 구성이 옛 식별자를 들고 있어도 남은 항목만 보이고 빈 칸이 없어야 한다
            let retired = Self.retiredToolbarItemIDs.filter { id in toolbar.items.contains { $0.itemIdentifier.rawValue == id } }
            report("툴바에 옛 항목(viewMode·attributeFilter) 없음", retired.isEmpty, retired.joined(separator: ","))
            // 편집 › 찾기가 메뉴 막대의 ⌘F 전부다
            updateMenus()
            let finds = commandKeyMenuItems("f")
            let findLine = finds.map { "\($0.menu.title) › \($0.item.title)(\($0.item.isEnabled ? "켜짐" : "꺼짐"))" }.joined(separator: ", ")
            report("메뉴 막대의 ⌘F 항목 하나", finds.count == 1 && finds[0].item.title == "찾기", findLine)
            // SwiftUI 메뉴 상태(focusedSceneValue)는 앱이 활성이고 주 창이 키 창일 때만 온다. 그때는 켜짐을 판정한다.
            // 다른 메뉴 항목이 켜졌는지로 대신 보면 메뉴 배선이 끊긴 회귀(모두 꺼짐)를 미검증으로 놓친다
            if NSApp.isActive, window.isKeyWindow {
                let addFiles = commandKeyMenuItems("o").first?.item.isEnabled == true
                report("편집 › 찾기 메뉴 켜짐", finds.first?.item.isEnabled == true, "곡 추가(⌘O) \(addFiles ? "켜짐" : "꺼짐")")
            } else {
                FileHandle.standardError.write(Data("[검색 배치 시험] 편집 › 찾기 메뉴 켜짐: 미검증(SwiftUI 메뉴 상태가 없음 · 앱 활성 \(NSApp.isActive ? "예" : "아니오") · 키 창 \(window.isKeyWindow ? "예" : "아니오"))\n".utf8))
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
                // 툴바에는 앱 단위 항목만 남는다(음량·곡 추가·태그 편집·rekordbox와 동기화). 보기 전환·필터는 머리 줄로 옮겼다(#339)
                let hiddenControls = Self.toolbarItemIDs.filter { !visibleIDs.contains($0) }
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
            failures += await runHeaderScenes(window: window, toolbar: toolbar, store: store, capture: { capture($0, name: $1) }, report: { report($0, $1, $2) }, wait: wait)
            window.setContentSize(originalSize)
            for (key, value) in savedDefaults {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            FileHandle.standardError.write(Data("[검색 배치 시험] 끝: \(failures == 0 ? "통과" : "실패 \(failures)건")\n".utf8))
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// 켠 조건 셋(BPM 범위·어울리는 키·장르). 줄인 칩 「BPM 120–130 외 2」가 가장 긴 첫 조건 글이다
    static let threeConditions = TrackFilter(bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("8A", mode: .compatible), genre: "House")

    /// 머리 줄(#339)의 필터 단추·칩·보기 전환이 창 폭과 글자 배율마다 겹치거나 잘리지 않는지 실제 창에서 본다.
    /// 장면: 칩 0·1·2·3·6개, 태그 시트(ⓘ가 보인다), 인스펙터를 열고 글자를 키워 본문 폭이 모자랄 때(칩이 첫 조건 글을 남긴 「BPM 120–130 외 2」 하나로 줄어든다).
    /// 칩이 줄어도 켠 조건이 하나 이상 글자로 보여야 한다(#351, 툴팁이 아니다).
    /// 바꾸는 설정(보기 모드·인스펙터·사이드바·글자 배율)은 처음 값으로 되돌린다. 모든 작업 폴더가 같은 UserDefaults 영역을 쓰기 때문이다.
    /// 장면의 통과·실패는 `report`가 세고, 반환값은 캡처를 못 남긴 횟수다.
    @MainActor
    static func runHeaderScenes(window: NSWindow, toolbar: NSToolbar, store: LibraryStore,
                                capture: (NSWindow, String) -> Bool, report: (String, Bool, String) -> Void,
                                wait: () async -> Void) async -> Int {
        struct Scene {
            var name: String
            var width: CGFloat
            var filter = TrackFilter()
            var sheet = false
            var inspector = false
            var scale = 1.0
            /// 곡 색 2의 이름을 긴 이름으로 바꿔 칩 폭을 키운다(rekordbox에서 이름을 바꿔 쓰는 경우). 본문이 모자라 칩이 하나로 줄어야 한다
            var longColorName = false
        }
        let longColorName = "Deep house opener set"
        // 조건 하나·둘·셋(#351: BPM·어울리는 키·장르)·여섯(평점·곡 색 둘까지 모두)
        let one = TrackFilter(minimumRating: 3)
        let two = TrackFilter(minimumRating: 3, colorIDs: ["2"])
        let three = Self.threeConditions
        let six = TrackFilter(minimumRating: 3, colorIDs: ["2", "7"], bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("8A", mode: .compatible), genre: "House")
        var scenes: [Scene] = []
        for width: CGFloat in [1155, 1200, 1440, 1800] {
            scenes += [Scene(name: "none", width: width), Scene(name: "chip1", width: width, filter: one),
                       Scene(name: "chip2", width: width, filter: two), Scene(name: "chip3", width: width, filter: three),
                       Scene(name: "chip6", width: width, filter: six),
                       Scene(name: "sheet-chip3", width: width, filter: three, sheet: true)]
        }
        scenes += [Scene(name: "inspector-big-chip2", width: 1155, filter: two, inspector: true, scale: 1.5),
                   Scene(name: "inspector-big-chip3", width: 1155, filter: three, inspector: true, scale: 1.5),
                   Scene(name: "inspector-big-sheet-chip3", width: 1155, filter: three, sheet: true, inspector: true, scale: 1.5),
                   Scene(name: "inspector-longname-collapsed", width: 1155, filter: two, inspector: true, scale: 1.5, longColorName: true),
                   Scene(name: "inspector-longname-sheet-collapsed", width: 1155, filter: two, sheet: true, inspector: true,
                         scale: 1.5, longColorName: true)]
        let keys = [SettingKeys.sheetMode.name, SettingKeys.showTagEditor.name, SettingKeys.sidebarVisible.name, SettingKeys.textScale.name]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let selection = store.sidebar
        let colors = store.trackColors
        store.sidebar = .filter(.all)
        var failures = 0
        for scene in scenes {
            store.trackColors = scene.longColorName ? colors.map { $0.id == "2" ? TrackColor(id: "2", name: longColorName) : $0 } : colors
            store.filter = scene.filter
            UserDefaults.standard.set(scene.sheet, forKey: SettingKeys.sheetMode.name)
            UserDefaults.standard.set(scene.inspector, forKey: SettingKeys.showTagEditor.name)
            UserDefaults.standard.set(scene.scale, forKey: SettingKeys.textScale.name)
            window.makeFirstResponder(nil)
            window.setContentSize(NSSize(width: scene.width, height: 700))
            await wait()
            window.contentView?.layoutSubtreeIfNeeded()
            await wait()
            let frames = SelfTestFrames.frames
            let content = window.contentView?.frame.size ?? .zero
            // 칩 자리는 `ViewThatFits`가 고른 한 모양만 보인다. 줄어든 칩이 있으면 그것이 보이는 칩이고, 다 들어간 모양에서 줄어든 모양으로
            // 바뀔 때 사라진 칩의 늦은 배치 알림이 남긴 자리는 버린다
            let chipValues = store.attributeFilterChips
            let allChips = frames.filter { $0.key.hasPrefix("listHeader.chip.") }.sorted { $0.value.minX < $1.value.minX }
            let expected = chipValues.chips.count
            let collapsedKey = "listHeader.chip.\(chipValues.collapsedTitle)"
            let chips = allChips.contains { $0.key == collapsedKey } ? allChips.filter { $0.key == collapsedKey } : allChips
            // 조건이 하나면 줄인 칩도 그 조건 하나라 전부 보인 모양과 같다
            let isCollapsed = expected > 1 && chips.count == 1 && chips[0].key == collapsedKey
            let isFull = chips.count == expected && !chips.contains { $0.key == collapsedKey && expected > 1 }
            // 긴 곡 색 이름 장면은 칩이 하나로 줄어든 모양이어야 한다(줄어듦이 실제 창에서 일어나는지 본다)
            // 켠 조건이 하나 이상 글자로 보여야 한다(툴팁 아님): 보이는 칩 가운데 첫 조건 글로 시작하는 칩이 있다. 숨기면 실패다
            let firstTitle = chipValues.chips.first?.title ?? ""
            let conditionVisible = expected == 0 || chips.contains { ($0.key == collapsedKey || $0.key == "listHeader.chip.\(firstTitle)") && $0.value.width > 24 }
            let chipsOK = expected == 0 ? chips.isEmpty : (scene.longColorName ? isCollapsed : (isCollapsed || isFull)) && conditionVisible
            var parts: [(String, CGRect)] = []
            for name in ["listHeader.search", "listHeader.filter"] { if let frame = frames[name] { parts.append((name, frame)) } }
            parts += chips.map { ($0.key, $0.value) }
            if let frame = frames["listHeader.info"] { parts.append(("listHeader.info", frame)) }
            if let frame = frames["listHeader.viewMode"] { parts.append(("listHeader.viewMode", frame)) }
            let required = frames["listHeader.search"] != nil && frames["listHeader.filter"] != nil && frames["listHeader.viewMode"] != nil
            // 왼쪽에서 오른쪽으로 검색칸·필터·칩·ⓘ·전환 순서로 겹침 없이 놓이고 창 안에 들어온다
            var ordered = required
            for (previous, next) in zip(parts, parts.dropFirst()) where previous.1.maxX > next.1.minX + 0.5 { ordered = false }
            let inside = parts.allSatisfy { $0.1.width > 0 && $0.1.minX >= -0.5 && $0.1.maxX <= content.width + 0.5 && $0.1.height <= ListHeaderBar.height + 0.5 }
            let infoOK = (frames["listHeader.info"] != nil) == scene.sheet
            let visibleIDs = Set((toolbar.visibleItems ?? []).map { $0.itemIdentifier.rawValue })
            let hidden = toolbarItemIDs.filter { !visibleIDs.contains($0) }
            let passed = required && ordered && inside && chipsOK && infoOK && hidden.isEmpty
            let mode = expected == 0 ? "칩 없음" : isCollapsed ? "하나로 줄임(\(chips[0].key.dropFirst("listHeader.chip.".count)))" : isFull ? "칩 \(chips.count)개" : "알 수 없음(\(chips.count)개)"
            let shown = conditionVisible ? "켠 조건 글자로 보임" : "켠 조건이 안 보임"
            let line = parts.map { "\($0.0.dropFirst("listHeader.".count)) \(Int($0.1.minX))–\(Int($0.1.maxX))" }.joined(separator: " · ")
            report("머리 줄 \(scene.name) 창 \(Int(scene.width))", passed,
                   "실제 \(Int(content.width)) · \(mode) · 순서·겹침 \(ordered ? "맞음" : "어긋남") · 창 안 \(inside ? "맞음" : "어긋남") · ⓘ \(infoOK ? "맞음" : "어긋남") · 툴바 \(hidden.isEmpty ? "모두 보임" : "접힘 \(hidden.joined(separator: ","))") · \(shown) · \(line)")
            if !capture(window, "header-\(Int(scene.width))-\(scene.name)") { failures += 1 }
        }
        // 머리 줄 오른쪽 구성(#340): 모드마다 가장 긴 이름을 값으로 넣어 실제 창에서 폭을 잰다. 조건 셋을 켠 가장 좁은 상태다
        // 앞 장면이 남긴 긴 곡 색 이름을 되돌린 뒤 기본 글자 크기에서 잰다
        store.trackColors = colors
        failures += await runActionScenes(window: window, toolbar: toolbar, store: store, capture: capture, report: report, wait: wait)
        // 필터 칩 하나를 눌러 끄는 길: 칩 값이 같은 입구로 그 조건만 끈다(눌러 보기는 사람이 한다)
        store.filter = TrackFilter()
        store.trackColors = colors
        store.sidebar = selection
        // 인스펙터를 먼저 닫고 가라앉힌 뒤 사이드바를 되돌린다. 인스펙터가 열린 채 사이드바를 열면 폭이 모자라 다시 접히면서 접힌 값이 남는다
        func restore(_ names: [String]) {
            for (key, value) in saved where names.contains(key) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        restore([SettingKeys.sheetMode.name, SettingKeys.showTagEditor.name, SettingKeys.textScale.name])
        await wait()
        await wait()
        restore([SettingKeys.sidebarVisible.name])
        await wait()
        return failures
    }

    /// 머리 줄 오른쪽 구성(#340)이 모드마다 겹치거나 잘리지 않는지 실제 창에서 본다. 저장소 상태를 만들기 어려운 가장 긴 이름
    /// (세 자리 곡 수, 함께 쓰는 재생 목록·재생 기록 건수, 연결되지 않은 초안)을 `ListHeaderActionsDebugOverride`로 값 그대로 넣는다.
    /// 조건 셋을 켠 채 창 1155의 사이드바 열림(본문 약 925)과 인스펙터 열림(본문 약 815)에서 잰다. 파일 없음·BPM 없음은 저장소 상태 그대로 본다.
    /// 반환값은 캡처를 못 남긴 횟수다. 통과·실패는 `report`가 센다.
    @MainActor
    static func runActionScenes(window: NSWindow, toolbar: NSToolbar, store: LibraryStore,
                                capture: (NSWindow, String) -> Bool, report: (String, Bool, String) -> Void,
                                wait: () async -> Void) async -> Int {
        typealias A = ListHeaderActions
        let locks = A.Locks()
        let restore = A.Restore(isEnabled: true, help: "라이브러리 전체를 마지막 쓰기 전 백업으로 복원합니다.")
        let histories = [A.HistoryMenu.Entry(id: "h1", name: "HISTORY 2026-10-05"), .init(id: "h2", name: "HISTORY 2026-10-06")]
        // (이름, 값). 값이 nil이면 저장소 상태 그대로(사이드바만 그 목록으로)
        let modes: [(String, A?, SidebarItem)] = [
            ("staged", A.staged(selected: true, count: 123, canRemove: true, canExportXML: true, importedCount: 12, locks: locks), .filter(.all)),
            ("pending", A.pending(selected: true, tracks: 123, playlistEdits: 12, histories: histories, unlinkedDrafts: 0, restore: restore, locks: locks), .filter(.all)),
            ("pending-unlinked", A.pending(selected: false, tracks: 123, playlistEdits: 12, histories: histories, unlinkedDrafts: 14, restore: restore, locks: locks), .filter(.all)),
            ("music", A.music(unavailable: 12), .filter(.all)),
            ("smart", A.smartPlaylist(unsupported: false), .filter(.all)),
            ("playlist-draft", A.playlist(id: "P", isDraft: true, blockedReason: "곡이 rekordbox에서 사라졌습니다", hiddenStreaming: nil, canCompare: true, locks: locks), .filter(.all)),
            ("hidden-streaming", A.playlist(id: "P", isDraft: false, blockedReason: nil, hiddenStreaming: 123, canCompare: true, locks: locks), .filter(.all)),
            ("usb", A.usb(volumeKey: "V", editing: (updatable: 123, blockReason: nil, draftCount: 45), playlistMismatch: true), .filter(.all)),
            ("missing-injected", A.missingFiles(volumes: [.init(name: "공연용 SSD", trackCount: 12)], checking: false, hasMissing: true, canFindInFolder: true), .filter(.all)),
            ("missing", nil, .filter(.missingFile)),
            ("no-bpm", nil, .filter(.noBPM)),
        ]
        let keys = [SettingKeys.showTagEditor.name, SettingKeys.sheetMode.name]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let selection = store.sidebar
        let savedFilter = store.filter
        UserDefaults.standard.set(false, forKey: SettingKeys.sheetMode.name)
        // 글자 배율은 호출한 쪽이 끝에서 되돌린다(`runHeaderScenes`)
        UserDefaults.standard.set(1.0, forKey: SettingKeys.textScale.name)
        var failures = 0
        defer {
            ListHeaderActionsDebugOverride.shared.value = nil
            store.sidebar = selection
            store.filter = savedFilter
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for inspector in [false, true] {
            for (name, actions, sidebar) in modes {
                ListHeaderActionsDebugOverride.shared.value = actions
                store.sidebar = sidebar
                // 파일 없음·BPM 없음 목록은 필터가 걸리지 않게 두면 칩이 없다. 그 밖은 조건 셋을 켠 가장 좁은 상태로 잰다
                store.filter = actions == nil ? TrackFilter() : Self.threeConditions
                UserDefaults.standard.set(inspector, forKey: SettingKeys.showTagEditor.name)
                window.makeFirstResponder(nil)
                // 사이드바·인스펙터를 바꾸면 창이 본문 폭을 지키려고 넓어지고, 사이드바는 늦게 열린다.
                // 창이 1155이고 (인스펙터 장면이 아니면) 검색칸이 사이드바 오른쪽으로 밀려날 때까지 다시 맞춘다
                func settled() -> Bool {
                    Int(window.contentView?.frame.width ?? 0) == 1155
                        && (inspector || (SelfTestFrames.frames["listHeader.search"]?.minX ?? 0) > 100)
                }
                for _ in 0..<5 {
                    // 앞 장면(인스펙터+글자 키움)이 접은 사이드바를 연다. 인스펙터가 닫히는 중에 열면 폭이 모자라 다시 접히므로 매번 다시 연다.
                    // 사이드바는 호출한 쪽이 끝에서 되돌린다(`runHeaderScenes`)
                    if !inspector { UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name) }
                    window.setContentSize(NSSize(width: 1155, height: 700))
                    await wait()
                    window.contentView?.layoutSubtreeIfNeeded()
                    await wait()
                    if settled() { break }
                }
                let atWidth = settled()
                let frames = SelfTestFrames.frames
                let content = window.contentView?.frame.size ?? .zero
                // 칩 자리는 ViewThatFits가 고른 한 모양만 보인다(전부, 「필터 2」 하나, 숨김). 앞 장면에서 사라진 칩의 늦은 배치 알림이 남긴 자리는 뺀다
                let chipValues = store.attributeFilterChips
                let collapsedKey = "listHeader.chip.\(chipValues.collapsedTitle)"
                let expectedChips = actions == nil ? [] : [collapsedKey] + chipValues.chips.map { "listHeader.chip.\($0.title)" }
                let shown = frames.filter { expectedChips.contains($0.key) }
                let allChips = (shown[collapsedKey] != nil ? shown.filter { $0.key == collapsedKey } : shown).sorted { $0.value.minX < $1.value.minX }
                var parts: [(String, CGRect)] = []
                for key in ["search", "filter"] { if let frame = frames["listHeader.\(key)"] { parts.append((key, frame)) } }
                parts += allChips.map { (String($0.key.dropFirst("listHeader.".count)), $0.value) }
                for key in ["status", "primary", "menu", "info", "viewMode"] { if let frame = frames["listHeader.\(key)"] { parts.append((key, frame)) } }
                var ordered = true
                for (previous, next) in zip(parts, parts.dropFirst()) where previous.1.maxX > next.1.minX + 0.5 { ordered = false }
                let inside = parts.allSatisfy { $0.1.width > 0 && $0.1.minX >= -0.5 && $0.1.maxX <= content.width + 0.5 && $0.1.height <= ListHeaderBar.height + 0.5 }
                // 값을 넣은 장면은 주 단추·메뉴가 늘 남아야 한다. 저장소 상태 장면은 단추가 있거나(파일 없음·BPM 없음) 곡이 없어 막혀도 자리는 있다
                let expectedPrimary = actions.map { $0.primary != nil } ?? true
                let expectedMenu = actions.map { !$0.menu.isEmpty } ?? (sidebar == .filter(.missingFile))
                let present = (frames["listHeader.primary"] != nil) == expectedPrimary && (frames["listHeader.menu"] != nil) == expectedMenu
                    && frames["listHeader.viewMode"] != nil
                let visibleIDs = Set((toolbar.visibleItems ?? []).map { $0.itemIdentifier.rawValue })
                let hidden = toolbarItemIDs.filter { !visibleIDs.contains($0) }
                let line = parts.map { "\($0.0) \(Int($0.1.minX))–\(Int($0.1.maxX))" }.joined(separator: " · ")
                // 다른 폭이나 사이드바가 닫힌 채 잰 통과는 그 장면의 증거가 아니다
                report("머리 줄 오른쪽 \(name) 창 1155\(inspector ? " 인스펙터" : "")", atWidth && ordered && inside && present && hidden.isEmpty,
                       "실제 \(Int(content.width)) · 폭·사이드바 \(atWidth ? "맞음" : "어긋남") · 순서·겹침 \(ordered ? "맞음" : "어긋남") · 창 안 \(inside ? "맞음" : "어긋남") · 단추·메뉴 \(present ? "맞음" : "어긋남") · 툴바 \(hidden.isEmpty ? "모두 보임" : "접힘 \(hidden.joined(separator: ","))") · \(line)")
                if !capture(window, "actions-1155\(inspector ? "-inspector" : "")-\(name)") { failures += 1 }
            }
        }
        return failures
    }
}
#endif
