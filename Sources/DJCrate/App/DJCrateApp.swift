import AppKit
import DJCDomain
import DJCStorage
import SwiftUI

@MainActor
package func runDJCrate() {
    DJCrateApp.main()
}

struct DJCrateApp: App {
    /// 문구 카탈로그(이 타깃 번들)를 가장 먼저 정한다. 하위 모듈의 문구(막힘 이유 등)도 이 카탈로그로 찾는다.
    private let strings: Void = UIStrings.bundle = .module
    /// 옛 이름(anicue) 데이터·설정 옮기기. 목록·덱이 설정을 읽기 전에 돌아야 해서 첫 속성으로 둔다.
    private let migrated = LegacyMigration.run()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()
    @State private var deck = DeckModel()

    init() {
        // SwiftPM 실행 파일은 번들이 없어서 Dock·메뉴 막대에 올리려면 직접 지정해야 한다.
        NSApplication.shared.setActivationPolicy(.regular)
        #if DEBUG
        // 창이 만들어지기 전에 정해야 SwiftUI와 AppKit 목록이 같은 모양새로 시작한다.
        if ProcessInfo.processInfo.arguments.contains("--perf-appearance=light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        if ProcessInfo.processInfo.arguments.contains("--perf-appearance=dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        #endif
    }

    var body: some Scene {
        // 단일 창: ⌘N 새 창이 같은 상태를 공유하며 라이브러리를 다시 읽는 문제를 막는다.
        Window(Text(verbatim: "DJCrate"), id: "main") {
            ContentView(store: store, deck: deck)
                .modifier(AppTextScale())
                .frame(minWidth: 1100, minHeight: 700)
                .background(MainWindowFrame())
                .task {
                    appDelegate.store = store
                    NSApplication.shared.activate()
                    await store.loadInitial()
                }
        }
        .commands {
            AppCommands()
            CommandGroup(after: .pasteboard) {
                // 표준 편집 명령처럼 현재 응답자가 활성 상태와 실행을 결정한다.
                Button(.ui("아래로 채우기")) {
                    NSApp.sendAction(#selector(SheetTableView.fillDown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!store.canFillDownTags || store.isWritingRekordbox)
            }
        }
        .defaultSize(width: 1440, height: 900)
        // 이전 창 상태 복원이 가끔 500×500 흰 창을 만든다. 항상 새 창으로 시작한다.
        .restorationBehavior(.disabled)

        Window(.ui("단축키"), id: "shortcuts") {
            ScrollView {
                ShortcutsList(shortcuts: deck.shortcuts).padding(20)
            }
            .modifier(AppTextScale())
            .frame(minWidth: 620, minHeight: 420)
            .background(ShortcutsWindow.Tracker())
        }
        .defaultSize(width: 720, height: 660)
        .restorationBehavior(.disabled)

        // Settings가 설정 메뉴와 ⌘,도 등록한다. 주 창에 수동 메뉴를 더하면 중복된다.
        // 덱과 같은 모델에 묶여 바꾸면 바로 반영·저장된다.
        Settings {
            SettingsView(store: store, deck: deck)
        }
    }
}

/// SwiftUI 장면 복원은 끈 채 창 위치·크기만 AppKit에 맡긴다.
private struct MainWindowFrame: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrackingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TrackingView: NSView {
        private weak var sizedSearchField: NSSearchField?

        override func layout() {
            super.layout()
            guard let search = window?.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first,
                  sizedSearchField !== search.searchField else { return }
            // 포커스 때만 240pt로 늘어나 이웃 버튼이 밀리지 않게 평상시에도 같은 폭을 확보한다.
            let width: CGFloat = 240
            search.preferredWidthForSearchField = width
            search.searchField.widthAnchor.constraint(equalToConstant: width).isActive = true
            sizedSearchField = search.searchField
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI가 기본 크기를 잡은 뒤 저장된 프레임을 적용한다.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.frameAutosaveName != "djc.mainWindow" else { return }
                window.setFrameUsingName("djc.mainWindow")
                window.setFrameAutosaveName("djc.mainWindow")
            }
        }
    }
}
