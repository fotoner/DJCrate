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
    /// 저장된 창 프레임을 적용했는지. 그 전의 기본 크기 폭으로는 사이드바를 접지 않는다(#119).
    var windowFrameRestored = true
    @AppStorage(SettingKeys.showTagEditor.name) private var showTagEditor = SettingKeys.showTagEditor.defaultValue
    @AppStorage(SettingKeys.sheetMode.name) private var sheetMode = SettingKeys.sheetMode.defaultValue
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
            Sidebar(store: store)
                .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
                // 본문(덱·목록)에 바로 붙이면 인스펙터를 연 뒤 임시 높이의 본문 사본이 생겨, 창 크기를 바꿀 때마다
                // 크기 측정이 진짜 본문과 번갈아 와서 본문을 두 번씩 다시 계산했다(#138). 상세 열 전체에 붙인다.
                .inspector(isPresented: inspectorPresented) {
                    Group { if inspectorContentShown { TagInspector(store: store) } }
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
                .task(id: showTagEditor) { await InspectorReveal.follow(showTagEditor, shown: $inspectorContentShown) }
                .modifier(LibraryWindowTitle(store: store))
                .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
                // 위쪽 알림 줄(스냅샷 오류·반영·곡 추가)과 겹치지 않게 아래에 띄운다(#122).
                .overlay(alignment: .bottom) {
                    if let toast = store.toast {
                        AppToastView(toast: toast,
                                     onUndo: toast.undoBackup.map { url in { store.toast = nil; app.reflection.startRestore(backupURL: url) } },
                                     onDetails: toast.showsResult ? { store.showingWriteResult = true } : nil,
                                     onAction: toast.action.map { action in { store.performToastAction(action) } },
                                     onClose: { if store.toast?.id == toast.id { store.toast = nil } })
                            .padding(.bottom, 16)
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
                WritingOverlay(stage: stage, onCancel: { store.cancelWritePreparation() }).transition(.opacity)
            } else if let write = store.usb?.activeWrite {
                UsbWritingOverlay(model: UsbWriteProgressModel(write), onCancel: { store.usb?.cancelWrite() }).transition(.opacity)
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
        .sheet(isPresented: $store.showingWriteResult) { WriteResultView(history: store.resultHistory) }
        .sheet(isPresented: $store.showingPlaylistPicker) { PlaylistPickerView(store: store) }
        .sheet(isPresented: $store.showingUnlinkedDrafts) { UnlinkedDraftsView(store: store) }
        .sheet(item: $store.xmlImportPreview) { preview in XMLImportSheet(store: store, preview: preview) }
        .modifier(RecoverySheetHost(store: store, anchor: .library))
        .animation(.easeInOut(duration: 0.15), value: store.writeStage)
        .searchable(text: $store.search, placement: .toolbar, prompt: Text(.ui("제목·아티스트·코멘트")))
        .toolbar(id: "main") { toolbarContent }
        .focusedSceneValue(\.appCommands, AppCommandContext(store: store, deck: deck, windows: app.windows, reflection: app.reflection,
                                                            showTagEditor: $showTagEditor))
        .onAppear { setUp() }
        // 보조 창·목록 메뉴 동작은 조립 지점이 한 번 만든 것을 내려 준다(값이 바뀌지 않아 본문을 다시 계산하지 않는다).
        .environment(\.appWindows, app.windows)
        .environment(\.trackListActions, app.trackListActions)
        .environment(\.reflection, app.reflection)
        .onChange(of: undoManager, initial: true) {
            deck.undoManager = undoManager
            store.undoManager = undoManager
        }
        // CLI·다른 앱이 바꾼 초안 파일을 1초마다 다시 읽는다
        .task { await app.watchExternalDrafts() }
        // 하루 한 번 자동 시점 스냅샷(#228): rekordbox가 꺼져 있고 라이브러리가 바뀌었으면 뒤에서 조용히 남긴다
        .task { await app.runAutoPointSnapshots() }
        // rekordbox에서 곡을 지우거나 고치고 돌아오면 새로 읽는다(옛 목록에 지워진 곡이 남지 않게)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.startRefreshIfRekordboxChanged()
        }
    }

    @ViewBuilder private var detail: some View {
            switch store.phase {
            case .loaded:
                LibraryDetail(store: store, deck: deck, windowFrameRestored: windowFrameRestored, sidebarVisible: sidebarVisible)
            case .idle:
                ContentUnavailableView {
                    Label(.ui("스냅샷이 없습니다"), systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text(.ui("rekordbox를 종료한 뒤 master.db 사본을 떠 주세요. 원본은 읽기만 합니다."))
                } actions: {
                    Button(.ui("스냅샷 뜨기")) { store.startTakeSnapshot() }
                }
            case let .loading(message):
                ProgressView(message)
            case let .failed(message):
                ContentUnavailableView {
                    Label(.ui("불러오지 못했습니다"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(.ui("다시 시도")) { store.startLoadInitial() }
                    Button(.ui("실행 중이어도 읽기용 스냅샷 뜨기")) { store.startTakeSnapshot(force: true) }
                }
            }
    }

    @ToolbarContentBuilder private var toolbarContent: some CustomizableToolbarContent {
            ToolbarItem(id: "relatedTracks") {
                RelatedTracksButton(store: store, deck: deck)
            }
            ToolbarItem(id: "volume", placement: .principal) {
                VolumeControl(deck: deck)
                    .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
            }
            ToolbarItem(id: "viewMode", placement: .principal) {
                Picker(.ui("보기"), selection: $sheetMode) {
                    Label(.ui("목록"), systemImage: "list.bullet").tag(false)
                        .help(.ui("곡 목록을 봅니다(⌘1)."))
                    Label(.ui("태그 시트"), systemImage: "tablecells").tag(true)
                        .help(.ui("태그를 표에서 편집합니다(⌘2)."))
                }
                .pickerStyle(.segmented)
                .disabled(!store.writeLockPolicy.allowsLibraryInteraction || store.sidebar == .duplicates || store.isUsbSelection)
                .help(!store.writeLockPolicy.allowsLibraryInteraction ? String(ui: "rekordbox 쓰기가 끝난 뒤 다시 시도하세요")
                      : store.isUsbSelection ? String(ui: "USB 곡은 읽기 전용이니 로컬 라이브러리에서 태그를 편집하세요")
                      : store.sidebar == .duplicates ? String(ui: "중복 후보에서는 태그 시트를 열 수 없으니 전체 목록에서 곡을 고르세요")
                      : String(ui: "태그 시트에서 태그 칸을 고르고 입력하세요"))
            }
            ToolbarItem(id: "attributeFilter") {
                AttributeFilterMenu(store: store)
            }
            ToolbarItem(id: "addFiles") {
                Button {
                    StagingPanels.chooseFiles(store: store)
                } label: {
                    Label(.ui("곡 추가"), systemImage: "plus")
                }
                .disabled(!LibraryMenuAction.addFiles.isEnabled(in: store))
                .help(.ui("음원 파일·폴더를 추가합니다. 창에 끌어다 놓아도 됩니다."))
            }
            ToolbarItem(id: "tagEditor") {
                Button {
                    showTagEditor.toggle()
                } label: {
                    Label(.ui("태그 편집"), systemImage: "tag")
                }
                .help(.ui("선택한 곡의 태그를 편집합니다 (⌘I). 여러 곡을 한꺼번에 편집할 수 있습니다."))
                .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
            }
            ToolbarItem(id: "snapshot") {
                Button {
                    // rekordbox가 켜져 있어도 읽기용 사본을 뜬다(최근 변경이 담긴 WAL까지 사본 안에서 합친다).
                    store.startSynchronizeLibrary()
                } label: {
                    Label(.ui("rekordbox와 동기화"), systemImage: "arrow.clockwise")
                }
                .disabled(!LibraryMenuAction.snapshot.isEnabled(in: store))
                .help(LibraryMenuAction.snapshot.disabledReason(in: store) ?? String(ui: "rekordbox 내용을 새로 읽고 편집 중인 초안을 보존합니다(⌘R)."))
            }
            ToolbarItem(id: "reflection", placement: .primaryAction) {
                ReflectionMenu(store: store)
            }
    }

    private func setUp() {
        app.connect()
        if ProcessInfo.processInfo.arguments.contains("--inspector") { showTagEditor = true }
        if ProcessInfo.processInfo.arguments.contains("--sheet") { sheetMode = true }
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

    @ViewBuilder private var message: some View {
        if !store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: store.search)
        } else if let summary = store.selectedSmartPlaylistResult?.unsupportedSummary {
            ContentUnavailableView {
                Label(.ui("조건을 계산하지 못했습니다"), systemImage: WarningMark.symbol)
            } description: {
                Text(.ui("\(summary). rekordbox에서 이 목록을 확인하세요."))
            }
        } else if store.isAttributeFiltered {
            ContentUnavailableView {
                Label(.ui("평점·곡 색 조건에 맞는 곡이 없습니다"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(.ui("거르기는 rekordbox 값(초안 전)으로 합니다. 조건을 바꾸거나 거르기를 끄세요."))
            } actions: {
                Button(.ui("평점·곡 색 거르기 끄기")) { store.minimumRating = 0; store.colorFilter = nil }
            }
        } else if store.selectedSmartPlaylistResult != nil, store.streamingHiddenInView == 0 {
            ContentUnavailableView {
                Label(.ui("조건에 맞는 곡이 없습니다"), systemImage: "music.note.list")
            } description: {
                Text(.ui("DJCrate가 계산한 결과입니다. rekordbox 화면과 다를 수 있습니다."))
            }
        } else if store.sidebar == .pending, !store.pendingHistories.isEmpty {
            // 쓰기 대기 재생 기록(#43)은 곡 줄이 아니라 위 쓰기 대기 바에서 함께 쓴다
            ContentUnavailableView {
                Label(.ui("쓸 곡 초안이 없습니다"), systemImage: "clock.arrow.circlepath")
            } description: {
                Text(.ui("USB 재생 기록 \(store.pendingHistories.count)건이 쓰기 대기에 있습니다. 위 ‘rekordbox에 쓰기’로 rekordbox 재생 기록에 넣습니다."))
            }
        } else if store.sidebar == .pending {
            ContentUnavailableView {
                Label(.ui("쓸 초안이 없습니다"), systemImage: "checkmark.circle")
            } description: {
                Text(.ui("곡의 큐·그리드·게인을 고치면 여기에 모입니다."))
            }
        } else if store.isUsbSelection {
            ContentUnavailableView {
                Label(.ui("표시할 USB 곡이 없습니다"), systemImage: "externaldrive")
            } description: {
                Text(.ui("USB를 다시 읽거나 다른 재생 목록을 고르세요."))
            }
        } else if store.sidebar == .staged {
            ContentUnavailableView {
                Label(.ui("추가한 곡이 없습니다"), systemImage: "music.note")
            } description: {
                Text(.ui("음원 파일을 끌어다 놓거나 ‘곡 추가’를 눌러 시작하세요."))
            } actions: {
                Button(.ui("곡 추가…")) { StagingPanels.chooseFiles(store: store) }
            }
        } else if store.streamingHiddenInView > 0 {
            ContentUnavailableView {
                Label(.ui("스트리밍 곡을 숨기고 있습니다"), systemImage: "eye.slash")
            } description: {
                Text(.ui("이 목록의 곡은 모두 스트리밍 곡입니다. 설정 › 일반에서 ‘스트리밍 곡 숨기기’를 끄면 보입니다."))
            }
        } else {
            ContentUnavailableView {
                Label(.ui("표시할 곡이 없습니다"), systemImage: "music.note.list")
            } description: {
                Text(.ui("다른 목록을 선택하거나 rekordbox와 동기화로 라이브러리를 다시 읽어 보세요."))
            }
        }
    }
}

/// 태그 시트 위 안내 줄.
struct SheetHeader: View {
    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(spacing: 14) {
            Text(.ui("더블클릭·Return·타이핑: 편집  ·  ⌘→: 덱에 불러오기  ·  ⌃Tab: 표 밖으로  ·  ⌘C/⌘V: 엑셀·시트와 복사·붙여넣기  ·  ⌘D: 아래로 채우기  ·  Delete: 지우기  ·  ⌘Z/⇧⌘Z: 실행 취소·실행 복귀"))
                .font(.scaled(.caption, textScale)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            // 색이 아니라 칸의 모양(왼쪽 위 모서리 삼각형)으로 알린다.
            Label { Text(.ui("= 초안(파일·rekordbox에 쓰기 전)")) } icon: { DraftCornerSwatch() }
                .font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
                .help(.ui("왼쪽 위 삼각형은 초안입니다. 아직 음원 파일과 rekordbox에 쓰지 않았습니다."))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(.ui("왼쪽 위 모서리 삼각형이 붙은 칸은 초안(파일·rekordbox에 쓰기 전)"))
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, 6)
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
    let store: LibraryStore
    @Binding var highlight: DropHighlight

    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        !providers.isEmpty
            && providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            && !providers.contains { $0.hasItemConformingToTypeIdentifier(DeckDragType.track.identifier)
                || $0.hasItemConformingToTypeIdentifier(PlaylistDragType.tracks.identifier) }
    }

    func validateDrop(info: DropInfo) -> Bool {
        store.writeLockPolicy.allowsLibraryInteraction
            && !store.isITunesSelection
            && !store.isUsbSelection
            && Self.accepts(info.itemProviders(for: [.fileURL, DeckDragType.track, PlaylistDragType.tracks]))
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
        store.addDroppedFiles(info.itemProviders(for: [.fileURL]))
        return true
    }
}
