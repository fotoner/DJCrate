import DJCApplication
import DJCDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A안: 사이드바 | (위) 덱 · (아래) 라이브러리 표
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @Bindable var store: LibraryStore
    @Bindable var deck: DeckModel
    /// 저장소·덱·창을 잇는 조립 지점(처음 나타날 때 한 번 잇는다)
    let app: AppComposition
    /// 주 창 화면 모델(시트와 단추·메뉴 입구). 조립 지점이 한 번 만든다
    private var window: LibraryWindowModel { app.libraryWindow }
    /// 저장된 창 프레임을 적용했는지. 그 전의 기본 크기 폭으로는 사이드바를 접지 않는다(#119).
    var windowFrameRestored = true
    @AppStorage(SettingKeys.showTagEditor.name) private var showTagEditor = SettingKeys.showTagEditor.defaultValue
    /// 이름에 점이 들어 `@AppStorage`로 두면 창 프레임 자동 저장 같은 다른 설정이 바뀔 때마다 본문을 다시 계산한다(#138).
    @State private var sidebarVisible = ObservedSetting(SettingKeys.sidebarVisible)
    /// 인스펙터 내용을 그릴지. 닫혀 있어도 SwiftUI가 내용을 계속 계산해, 곡을 고를 때마다 입력 칸을 새로 만들고
    /// 덱까지 창 레이아웃을 다시 잡았다(#129). 열려 있을 때만 그린다.
    @State private var inspectorContentShown = false

    /// 인스펙터는 라이브러리를 읽은 뒤에만 연다(읽는 중·실패 화면에는 편집할 곡이 없다).
    private var inspectorPresented: Binding<Bool> {
        Binding {
            guard case .loaded = store.phase else { return false }
            return showTagEditor
        } set: { showTagEditor = $0 }
    }

    /// 사이드바 표시 상태는 저장해 두고 다음 실행을 같은 모양으로 시작한다(#119).
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding { SidebarVisibility.columns(visible: sidebarVisible.value) } set: { sidebarVisible.value = SidebarVisibility.isVisible($0) }
    }

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        NavigationSplitView(columnVisibility: columnVisibility) {
            Sidebar(store: store, playlistSidebar: app.playlistSidebar)
                // 안쪽에 가드가 없는 조작(추가 목록 제거, USB 편집 메뉴)도 이 줄이 막아 준다. 그래서 libraryBusy다.
                // 편집 잠금만 푸는 PR은 그 조작에 가드를 더한 뒤 이 줄을 editsFrozen으로 바꾼다(#301).
                .disabled(store.libraryBusy)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
                // 창 아래 LINK 막대(#272): Pro DJ Link 장치가 보일 때만 높이를 차지한다. 막대만 장치 목록을 읽는다.
                // 분할 화면 전체 아래에 붙이면 열의 화면이 막대 위까지 덮어 플레이어 칸이 끌어다 놓기를 받지 못했다(#274). 상세 열 안에 둔다
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let link = app.link { LinkBar(model: link) }
                }
                // 창 맨 아래 상태 줄(#298). LINK 막대처럼 상세 열 안에 둔다: 사이드바를 접어도 상세 열은 늘 있고,
                // 분할 화면 전체 아래에 붙이면 열의 화면이 막대를 덮었다(#274). 읽지 않은 수는 상태 줄만 읽는다
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: app.statusBar) }
                // 본문(덱·목록)에 바로 붙이면 인스펙터를 연 뒤 임시 높이의 본문 사본이 생겨, 창 크기를 바꿀 때마다
                // 크기 측정이 진짜 본문과 번갈아 와서 본문을 두 번씩 다시 계산했다(#138). 상세 열 전체에 붙인다.
                .inspector(isPresented: inspectorPresented) {
                    Group { if inspectorContentShown { TagInspector(model: app.tagInspector) } }
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
                .task(id: showTagEditor) { await InspectorReveal.follow(showTagEditor, shown: $inspectorContentShown) }
                .modifier(LibraryWindowTitle(store: store))
                // 안쪽 가드가 없는 조작을 막아 주므로 libraryBusy다(사이드바와 같다).
                .disabled(store.libraryBusy)
                // 덱을 가리지 않게 아래에 띄운다(#122). 목록 위 오류·안내 줄도 모두 이 알림으로 옮겼다(#307).
                // 덮개는 아래 덧댄 상태 줄의 자리를 모르므로 그 높이만큼 올린다(#298)
                .overlay(alignment: .bottom) {
                    if let toast = store.toast {
                        AppToastView(toast: toast,
                                     onUndo: toast.undoBackup.map { url in { store.dismissToast(); app.reflection.startRestore(backupURL: url) } },
                                     onDetails: toast.showsResult ? { window.showActivityLog(selecting: toast.activityID) } : nil,
                                     onOpen: toast.opensActivity ? { store.dismissToast(toast.id); app.statusBar.open(toast.activityID) } : nil,
                                     onAction: toast.action.map { action in { window.performToastAction(action) } },
                                     onClose: { store.dismissToast(toast.id) })
                            .padding(.bottom, 16 + StatusBar.height)
                            .padding(.horizontal, 16)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                            .id(toast.id)
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35), value: store.toast?.id)
        }
        // rekordbox·USB에 쓰는 동안은 창 전체를 덮어 다른 조작을 막는다.
        .overlay {
            if let stage = store.writeStage {
                WritingOverlay(stage: stage, quitWait: store.quitWait.current, onCancel: { store.cancelWritePreparation() },
                               onCancelQuit: { store.quitWait.cancel() }).transition(.opacity)
            } else if let write = store.usb?.activeWrite {
                UsbWritingOverlay(model: UsbWriteProgressModel(write), onCancel: { store.usb?.cancelWrite() }).transition(.opacity)
            } else if let wait = store.quitWait.current {
                QuitWaitOverlay(wait: wait, onCancel: { store.quitWait.cancel() }).transition(.opacity)
            }
        }
        .sheet(item: Binding(get: { store.usb?.syncSheet }, set: { store.usb?.syncSheet = $0 })) { request in
            if let usb = store.usb {
                UsbSyncView(store: store, usb: usb, request: request)
                    // 동기화 시트는 쓰는 동안에도 열려 있어 창의 쓰기 덮개를 가린다. 같은 덮개를 시트 위에 띄운다
                    .overlay {
                        if let write = usb.activeWrite {
                            UsbWritingOverlay(model: UsbWriteProgressModel(write), onCancel: { usb.cancelWrite() }).transition(.opacity)
                        }
                    }
            }
        }
        .sheet(item: Binding(get: { store.usb?.exportSheet }, set: { store.usb?.exportSheet = $0 })) { request in
            if let usb = store.usb {
                UsbExportSheet(store: store, usb: usb, request: request)
            }
        }
        .sheet(item: Binding(get: { store.usb?.pointSnapshotSheet }, set: { store.usb?.pointSnapshotSheet = $0 })) { model in
            UsbPointSnapshotsView(model: model)
        }
        // 주 창만 쓰는 시트는 주 창 모델이, 다른 화면이 여는 시트(재생 목록 고르기·USB·복구)는 그 주인이 든다
        .sheet(item: Binding(get: { window.activityLog }, set: { window.activityLog = $0 })) { ActivityLogView(model: $0) }
        .sheet(item: Binding(get: { store.playlists.playlistPicker }, set: { store.playlists.playlistPicker = $0 })) { PlaylistPickerView(model: $0) }
        .sheet(item: Binding(get: { window.unlinkedDrafts }, set: { window.unlinkedDrafts = $0 })) { UnlinkedDraftsView(model: $0) }
        .sheet(item: Binding(get: { window.xmlImport.preview }, set: { window.xmlImport.preview = $0 })) { preview in
            XMLImportSheet(model: window.xmlImport, preview: preview)
        }
        .modifier(RecoverySheetHost(store: store, anchor: .library))
        .animation(.easeInOut(duration: 0.15), value: store.writeStage)
        .toolbar(id: "main") { toolbarContent }
        .focusedSceneValue(\.appCommands, AppCommandContext(window: window, windows: app.windows, reflection: app.reflection,
                                                            showTagEditor: $showTagEditor))
        .onAppear { setUp() }
        // 보조 창·목록 메뉴 동작은 조립 지점이 한 번 만든 것을 내려 준다(값이 바뀌지 않아 본문을 다시 계산하지 않는다).
        .environment(\.appWindows, app.windows)
        .environment(\.trackListActions, app.trackListActions)
        .environment(\.reflection, app.reflection)
        .environment(\.libraryWindow, window)
        .onChange(of: undoManager, initial: true) {
            deck.undoManager = undoManager
            store.undoManager = undoManager
        }
        // CLI·다른 앱이 바꾼 초안 파일을 1초마다 다시 읽는다
        .task { await app.watchExternalDrafts() }
        // 하루 한 번 자동 시점 스냅샷(#228): rekordbox가 꺼져 있고 라이브러리가 바뀌었으면 뒤에서 조용히 남긴다
        .task { await app.runAutoPointSnapshots() }
        // Pro DJ Link 장치 알림을 받기만 한다(#272). 화면 시험·자가 테스트 조립에는 없다
        .task { await app.link?.watch() }
        // rekordbox에서 곡을 지우거나 고치고 돌아오면 새로 읽는다(옛 목록에 지워진 곡이 남지 않게)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            window.startRefreshIfRekordboxChanged()
        }
    }

    @ViewBuilder private var detail: some View {
            switch store.phase {
            case .loaded:
                LibraryDetail(store: store, deck: deck, windowFrameRestored: windowFrameRestored, sidebarVisible: sidebarVisible,
                              listActionBar: app.listActionBar, window: window)
            case .idle:
                // 첫 실행은 단추 없이 바로 읽는다(`LibraryReadFlow.readsOnFirstRun`). 여기는 자가 테스트·캡처 실행이나 읽기 전 잠깐만 보인다.
                ContentUnavailableView {
                    Label(.ui("라이브러리를 읽지 않았습니다"), systemImage: "externaldrive")
                } description: {
                    Text(.ui("‘rekordbox와 동기화’(⌘R)로 라이브러리를 읽어 오세요"))
                }
            case let .loading(message):
                // 상세 열을 다 채운다. 제 크기만 차지하면 아래에 붙는 LINK 막대가 열 가운데로 올라왔다
                ProgressView(message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                if let failure = store.lastReadFailure {
                    LibraryReadFailureView(title: failure.title, guidance: failure.guidance,
                                           detail: failure.offersDetail ? failure.detail : nil) { window.startRetryLoad() }
                } else {
                    // 사본을 뜨지 않은 이유(명시한 사본 모드 등)처럼 원인 분류가 없는 실패
                    LibraryReadFailureView(title: String(ui: "라이브러리를 읽지 못했습니다"), guidance: message, detail: nil) {
                        window.startRetryLoad()
                    }
                }
            }
    }

    @ToolbarContentBuilder private var toolbarContent: some CustomizableToolbarContent {
            ToolbarItem(id: "volume", placement: .principal) {
                VolumeControl(deck: deck)
                    .disabled(store.editsFrozen)
            }
            ToolbarItem(id: "addFiles") {
                Button {
                    StagingPanels.chooseFiles(store: store)
                } label: {
                    Label(.ui("곡 추가"), systemImage: "plus")
                }
                .disabled(!LibraryMenuAction.addFiles.isEnabled(in: window))
                .help(LibraryMenuAction.addFiles.disabledReason(in: window) ?? String(ui: "곡 추가 (⌘O)"))
            }
            ToolbarItem(id: "tagEditor") {
                Button {
                    showTagEditor.toggle()
                } label: {
                    Label(.ui("태그 편집"), systemImage: "tag")
                }
                .help(store.editsFrozen ? String(ui: "rekordbox 저장이 끝난 뒤 다시 시도하세요") : String(ui: "태그 편집 (⌘I)"))
                .disabled(store.editsFrozen)
            }
            ToolbarItem(id: "snapshot") {
                Button {
                    // rekordbox가 켜져 있어도 읽기용 사본을 뜬다(최근 변경이 담긴 WAL까지 사본 안에서 합친다).
                    window.startSynchronizeLibrary()
                } label: {
                    Label(.ui("rekordbox와 동기화"), systemImage: "arrow.clockwise")
                }
                // 아이콘만 보이면 USB·iTunes 다시 확인의 ⟳와 구분되지 않는다
                .labelStyle(.titleAndIcon)
                .disabled(!LibraryMenuAction.snapshot.isEnabled(in: window))
                // 라벨이 보이는 단추라 막힐 때의 이유만 알린다(STR-19)
                .help(LibraryMenuAction.snapshot.disabledReason(in: window) ?? "")
            }
    }

    private func setUp() {
        app.connect()
        if ProcessInfo.processInfo.arguments.contains("--inspector") { showTagEditor = true }
        // 보기 모드는 머리 줄·본문 잎이 읽는다. 여기서 읽으면 보기를 바꿀 때마다 이 본문이 다시 계산되므로 값만 쓴다
        if ProcessInfo.processInfo.arguments.contains("--sheet") { UserDefaults.standard.set(true, forKey: SettingKeys.sheetMode.name) }
    }
}

/// 창 제목·부제(목록 이름·곡 수·선택 수). ContentView 본문이 선택·표시 줄을 읽으면 곡을 고를 때마다
/// 덱·툴바까지 창 전체를 다시 계산하므로 여기서만 읽는다(#129).
private struct LibraryWindowTitle: ViewModifier {
    let store: LibraryStore

    func body(content: Content) -> some View {
        content
            .navigationTitle(store.sidebarTitle)
            .navigationSubtitle(store.sidebar == .duplicates
                ? String(ui: "\(store.displayDuplicateGroups.count)묶음 · \(store.displayRows.count)곡")
                : store.selection.count > 1
                ? String(ui: "\(store.displayRows.count)곡 · \(store.selection.count)곡 선택")
                : String(ui: "\(store.displayRows.count)곡"))
    }
}

/// 목록이 비었을 때 안내. 검색·정렬로 줄이 바뀔 때 ContentView 전체가 아니라 이것만 다시 계산한다(#129).
struct EmptyLibraryOverlay: View {
    let store: LibraryStore

    var body: some View {
        if store.displayRows.isEmpty { message }
    }

    private func noResults(_ guide: NoResultsGuide) -> some View {
        NoResultsView(guide: guide, clearSearch: { store.search = "" }, clearFilter: { store.clearAttributeFilters() })
    }

    @ViewBuilder private var message: some View {
        switch EmptyListNotice.resolve(store: store) {
        case let .noResults(guide):
            noResults(guide)
        case let .message(notice):
            ContentUnavailableView {
                Label(notice.title, systemImage: notice.systemImage)
            } description: {
                if let description = notice.description { Text(description) }
            } actions: {
                if let action = notice.action { Button(action.title) { action.perform(store: store) } }
            }
        }
    }
}

/// 덱과 목록 사이 핸들: 끌어서 파형 높이를 조절한다.
struct SplitHandle: View {
    @Binding var height: Double
    var displayedHeight: Double
    var maximumHeight: Double
    var minimumHeight = DeckLayout.minimumWaveformHeight
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if start == nil { start = displayedHeight }
                    height = draggedHeight(from: start ?? displayedHeight, translation: value.translation.height)
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { height = DeckLayout.defaultWaveformHeight }
            .accessibilityLabel(.ui("파형 높이 조절"))
            .accessibilityValue(.ui("\(Int(displayedHeight))포인트"))
            .accessibilityHint(.ui("위아래로 조절하거나 두 번 클릭하면 기본 높이로 돌아갑니다"))
            .accessibilityAdjustableAction { direction in
                // 메뉴 '파형 크게·작게'와 같은 한 칸
                switch direction {
                case .increment: height = DeckLayout.steppedWaveformHeight(displayed: displayedHeight, direction: 1, maximum: maximumHeight, minimum: minimumHeight)
                case .decrement: height = DeckLayout.steppedWaveformHeight(displayed: displayedHeight, direction: -1, maximum: maximumHeight, minimum: minimumHeight)
                @unknown default: break
                }
            }
    }

    func draggedHeight(from start: Double, translation: Double) -> Double {
        let value = start + translation
        return min(max(value, minimumHeight), max(maximumHeight, minimumHeight))
    }
}

/// 파일 URL과 내부 곡 ID를 함께 싣는 드래그를 구별해야 하므로 형식을 검사할 수 있는 delegate를 쓴다.
struct LibraryFileDropDelegate: DropDelegate {
    /// 주 창 화면 모델(받을지 판정과 곡 추가 입구)
    let window: LibraryWindowModel
    @Binding var highlight: DropHighlight

    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        !providers.isEmpty
            && providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            && !providers.contains { $0.hasItemConformingToTypeIdentifier(DeckDragType.track.identifier)
                || $0.hasItemConformingToTypeIdentifier(PlaylistDragType.tracks.identifier) }
    }

    func validateDrop(info: DropInfo) -> Bool {
        window.acceptsFileDrop && Self.accepts(info.itemProviders(for: [.fileURL, DeckDragType.track, PlaylistDragType.tracks]))
    }

    func dropEntered(info: DropInfo) { highlight.enter(accepted: validateDrop(info: info)) }
    func dropExited(info: DropInfo) { highlight.exit() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let accepted = validateDrop(info: info)
        highlight.update(accepted: accepted)
        return DropProposal(operation: accepted ? .copy : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        highlight.drop()
        guard validateDrop(info: info) else { return false }
        window.addDroppedFiles(info.itemProviders(for: [.fileURL]))
        return true
    }
}

extension EnvironmentValues {
    /// 주 창 화면 모델. 사이드바 줄처럼 부모 본문에 클로저를 넣으면 다시 계산이 늘어나는 잎 뷰가 받는다.
    /// 조립 지점이 붙이지 않은 화면(시험·미리 보기)에서는 nil이다.
    @Entry var libraryWindow: LibraryWindowModel? = nil
}
