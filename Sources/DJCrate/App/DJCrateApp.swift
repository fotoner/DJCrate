import AppKit
import DJCDomain
import SwiftUI

/// 실행 파일(`DJCrateExecutable/main.swift`)의 진입점. 본체를 라이브러리로 두어 실행 파일과 테스트가 컴파일 결과를 함께 쓴다.
@MainActor
package func runDJCrate() {
    DJCrateApp.main()
}

struct DJCrateApp: App {
    /// 문구 카탈로그(이 타깃 번들)를 가장 먼저 정한다. 하위 모듈의 문구(막힘 이유 등)도 이 카탈로그로 찾는다.
    private let strings: Void = UIStrings.useAppCatalog()
    /// 옛 이름(anicue) 데이터·설정 옮기기. 목록·덱이 설정을 읽기 전에 돌아야 해서 첫 속성으로 둔다.
    private let migrated: Void = AppComposition.migrateLegacyData()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 저장소·덱·창을 한 곳에서 만들어 잇는다(`AppComposition`)
    @State private var app = AppComposition.live()
    private var store: LibraryStore { app.store }
    private var deck: DeckModel { app.deck }
    @State private var windowFrameRestored = false

    private static func makeLibraryStore() -> LibraryStore {
        #if DEBUG
        if CommandLine.arguments.contains("--history-selftest") {
            do {
                _ = try HistorySelfTest.startupDatabase(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
            } catch {
                FileHandle.standardError.write(Data("[히스토리 시험] 미검증: 같은 합성 DB와 임시 DJC_HOME·DJC_REKORDBOX_DIR을 지정하세요\n".utf8))
                exit(2)
            }
        }
        #endif
        return LibraryStore(draftHome: DJCPaths.userData)
    }

    init() {
        // SwiftPM 실행 파일은 번들이 없어서 Dock·메뉴 막대에 올리려면 직접 지정해야 한다.
        NSApplication.shared.setActivationPolicy(.regular)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--key-routing-selftest"),
           KeyRoutingSelfTestMode.requested(arguments: ProcessInfo.processInfo.arguments,
                                            environment: ProcessInfo.processInfo.environment) == nil {
            FileHandle.standardError.write(Data("[키 전달] 미검증: 자가 테스트 인자와 두 격리 환경 변수를 확인하세요 · 종료 코드 2\n".utf8))
            exit(2)
        }
        if ResizePerfSelfTest.isRequested {
            // 측정 창을 띄워도 사용 중인 앱의 포커스를 가져오지 않는다.
            NSApplication.shared.setActivationPolicy(.accessory)
            if let refusal = ResizePerfSelfTest.startupRefusal() {
                ResizePerfSelfTest.log(refusal)
                exit(2)
            }
            ResizePerfSelfTest.saveSettings()
        }
        // 창이 만들어지기 전에 정해야 SwiftUI와 AppKit 목록이 같은 모양새로 시작한다.
        if ProcessInfo.processInfo.arguments.contains("--perf-appearance=light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        if ProcessInfo.processInfo.arguments.contains("--perf-appearance=dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        // USB 자가 테스트의 거부는 라이브러리를 읽기 전에 본다(명시한 사본 없이 띄우면 사용자 스냅샷 폴더를 열기 때문)
        if let refusal = UsbSelfTest.startupRefusal(arguments: ProcessInfo.processInfo.arguments,
                                                    environment: ProcessInfo.processInfo.environment) {
            UsbSelfTest.log(refusal)
            exit(2)
        }
        #endif
    }

    var body: some Scene {
        // 단일 창: ⌘N 새 창이 같은 상태를 공유하며 라이브러리를 다시 읽는 문제를 막는다.
        Window(Text(verbatim: "DJCrate"), id: "main") {
            ContentView(store: store, deck: deck, app: app, windowFrameRestored: windowFrameRestored)
                .modifier(AppTextScale())
                .frame(minWidth: 1100, minHeight: 700)
                .background(MainWindowFrame { windowFrameRestored = true })
                .task {
                    appDelegate.store = store
                    #if DEBUG
                    // 쓰기 시험(`--write-selftest`)도 키 입력 없이 스토어로만 돌아 사용 중인 앱의 포커스를 가져오지 않는다
                    if !ResizePerfSelfTest.isRequested,
                       !ProcessInfo.processInfo.arguments.contains("--playlist-recovery-selftest"),
                       !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--async-guidance-capture=") || $0.hasPrefix("--usb-migrate-capture=") || $0 == "--key-routing-selftest" || $0 == "--write-selftest" }) {
                        NSApplication.shared.activate()
                    }
                    #else
                    NSApplication.shared.activate()
                    #endif
                    await app.start()
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
            SettingsView(store: store, deck: deck, storage: { [app] in app.storageSettings() })
        }
    }
}

/// SwiftUI 장면 복원은 끈 채 창 위치·크기만 AppKit에 맡긴다.
private struct MainWindowFrame: NSViewRepresentable {
    /// 저장된 프레임을 적용한 뒤(저장된 게 없으면 기본 크기로 정해진 뒤) 부른다.
    var onRestore: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView { TrackingView(onRestore: onRestore) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TrackingView: NSView {
        private weak var sizedSearchField: NSSearchField?
        private let onRestore: @MainActor () -> Void

        init(onRestore: @escaping @MainActor () -> Void) {
            self.onRestore = onRestore
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
                guard let self, let window else { return }
                #if DEBUG
                if ResizePerfSelfTest.isRequested || ProcessInfo.processInfo.arguments.contains("--playlist-recovery-selftest") {
                    onRestore()
                    return
                }
                #endif
                if window.frameAutosaveName != "djc.mainWindow" {
                    window.setFrameUsingName("djc.mainWindow")
                    window.setFrameAutosaveName("djc.mainWindow")
                }
                onRestore()
            }
        }
    }
}
