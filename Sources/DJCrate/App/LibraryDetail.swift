import DJCDomain
import SwiftUI
import UniformTypeIdentifiers

/// 주 창 본문: (위) 덱 · (아래) 라이브러리 표.
/// 덱과 목록이 잰 원시 크기는 `LibraryLayoutMetrics`가 들고, 실제 적용 높이는 작은 뷰만 읽는다.
/// 창 크기 변화가 곡 목록·툴바·사이드바 본문까지 전파되지 않게 한다(#138, #180).
struct LibraryDetail: View {
    @Environment(\.textScale) private var textScale
    @Bindable var store: LibraryStore
    @Bindable var deck: DeckModel
    /// 저장된 창 프레임을 적용했는지. 그 전의 기본 크기 폭으로는 사이드바를 접지 않는다(#119).
    var windowFrameRestored: Bool
    /// 폭이 모자라면 탐색 열을 접는다. 값은 읽지 않고 쓰기만 한다(읽으면 이 뷰가 사이드바를 여닫을 때마다 다시 계산된다).
    let sidebarVisible: ObservedSetting<Bool>
    /// 목록 아래 작업 막대의 화면 모델(조립 지점이 한 번 만든다). 본문은 읽지 않고 막대에 넘긴다
    let listActionBar: ListActionBarModel
    /// 주 창 화면 모델(연결되지 않은 초안 시트·파일 끌어 놓기). 본문은 읽지 않고 넘긴다
    let window: LibraryWindowModel
    @AppStorage(SettingKeys.waveformHeight.name) private var waveformHeight = SettingKeys.waveformHeight.defaultValue
    @AppStorage(SettingKeys.sheetMode.name) private var sheetMode = SettingKeys.sheetMode.defaultValue
    @State private var sidebarAutoCollapse = SidebarVisibility()
    @State private var widthClass = DeckWidthClass(width: 1400)
    @State private var layout = LibraryLayoutMetrics()
    @State private var fileDropHighlight = DropHighlight()

    /// 태그 시트는 편집 화면이라 중복 후보·USB(읽기 전용) 목록에서는 곡 목록으로 보인다.
    private var showsSheet: Bool { sheetMode && store.sidebar != .duplicates && !store.isUsbSelection }

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        // VSplitView(NSSplitView)는 자식 최소 크기가 내용에 따라 바뀌면 레이아웃을 끝없이
        // 다시 잡다가 예외로 죽는다. SwiftUI만으로 나누고, 덱 높이는 핸들로 조절한다.
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let error = store.visibleLastError {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(UIColors.warning.color)
                            .textSelection(.enabled)
                        Spacer()
                        Button(.ui("닫기")) { store.dismissLastError() }.controlSize(.small)
                    }
                    .font(.callout)
                    .padding(.horizontal, Spacing.edge).padding(.vertical, 6)
                }
                if let message = store.draftFileMessage {
                    AppMessageView(message: message, onClose: { store.draftFileMessage = nil })
                }
                if store.sidebar == .pending, !store.unlinkedDraftUUIDs.isEmpty {
                    UnlinkedDraftsBar(store: store, window: window)
                }
                if let message = store.reflectionMessage {
                    AppMessageView(message: message, onClose: { store.reflectionMessage = nil })
                }
                if let message = store.staging.stagingMessage {
                    AppMessageView(message: message, onClose: { store.staging.stagingMessage = nil })
                }
                if let message = store.playlists.playlistMessage {
                    AppMessageView(message: message, onClose: { store.playlists.playlistMessage = nil })
                }
            }
            .onGeometryChange(for: Double.self) { $0.size.height } action: { layout.measureNotice($0) }
            // 파형은 본문 높이가 바뀔 때만 맞추고, 덱 내용이 늘면 덱만 스크롤한다(PR #151).
            LibraryDeckViewport(library: store, tags: store.tags, deck: deck, layout: layout, widthClass: widthClass)
            LibrarySplitHandle(layout: layout, height: $waveformHeight)
            VStack(spacing: 0) {
                ListActionBar(model: listActionBar)
                if showsSheet { SheetHeader() }
            }
            .onGeometryChange(for: Double.self) { $0.size.height } action: { layout.measureListHeader($0) }
            Group {
                if store.sidebar == .duplicates {
                    DuplicateTracksView(store: store)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: DeckLayout.minimumLibraryHeight, maxHeight: .infinity)
                } else if case let .usb(.pending(volumeKey)) = store.sidebar, let usb = store.usb {
                    UsbPendingView(store: store, usb: usb, volumeKey: volumeKey)
                        .id(volumeKey)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: DeckLayout.minimumLibraryHeight, maxHeight: .infinity)
                } else if showsSheet {
                    TagSheetView(store: store)
                        .onDisappear { store.canFillDownTags = false }
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: DeckLayout.minimumLibraryHeight, maxHeight: .infinity)
                        .overlay { EmptyLibraryOverlay(store: store) }
                } else {
                    TrackTable(source: store, deck: deck)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: DeckLayout.minimumLibraryHeight, maxHeight: .infinity)
                        .overlay { EmptyLibraryOverlay(store: store) }
                }
            }
            // 내부 곡 끌기는 재생 목록·덱이 맡으므로 파일 추가가 가로채지 않는다.
            .onDrop(of: [.fileURL], delegate: LibraryFileDropDelegate(window: window, highlight: $fileDropHighlight))
            .overlay {
                if fileDropHighlight.isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // 인스펙터가 본문을 임시 높이로 한 번 더 배치해, 그 크기·덱 높이가 진짜 값과 번갈아 와서 창 크기를 바꿀 때마다
        // 본문을 두 번씩 다시 계산했다(#138). 본문 크기와 덱 높이를 한 번에 재고 본문이 아닌 측정은 통째로 버린다.
        .backgroundPreferenceValue(DeckBoundsKey.self) { deckBounds in
            Color.clear.onGeometryChange(for: DetailGeometry.self) { proxy in
                DetailGeometry(size: proxy.size, deckHeight: deckBounds.map { proxy[$0.bounds].height } ?? 0,
                               waveformHeight: deckBounds?.waveformHeight ?? 0)
            } action: { geometry in
                guard DeckLayout.isDetailMeasurement(height: geometry.size.height) else { return }
                // 폭은 창 크기·사이드바·인스펙터가 움직이는 동안 프레임마다 바뀐다. 바뀐 상태만 써서
                // 이 본문과 덱을 프레임마다 다시 계산하지 않는다(#138).
                layout.measureDetail(height: geometry.size.height, deckHeight: geometry.deckHeight,
                                     waveformHeight: geometry.waveformHeight, hasTrack: deck.row != nil)
                let width = DeckWidthClass(width: geometry.size.width)
                if widthClass != width { widthClass = width }
                // 인스펙터를 열어 덱 폭이 모자라면 탐색 열을 접어 컨트롤 자리를 남긴다.
                var autoCollapse = sidebarAutoCollapse
                let collapse = autoCollapse.shouldCollapse(detailWidth: geometry.size.width, windowFrameRestored: windowFrameRestored)
                if autoCollapse != sidebarAutoCollapse { sidebarAutoCollapse = autoCollapse }
                if collapse { sidebarVisible.value = false }
            }
        }
        // 새 스냅샷을 읽고 다시 그릴 때도 첫 측정은 임시 폭이다.
        .onDisappear { sidebarAutoCollapse.reset() }
        .onChange(of: waveformHeight, initial: true) { layout.request(waveformHeight) }
        .onChange(of: textScale, initial: true) { layout.setTextScale(textScale) }
        .modifier(LibraryWaveformHeightContext(layout: layout, height: $waveformHeight))
    }
}

/// 덱 전체(스크롤 안 내용)의 위치·크기
private struct DeckBoundsKey: PreferenceKey {
    static let defaultValue: DeckMeasurement? = nil
    static func reduce(value: inout DeckMeasurement?, nextValue: () -> DeckMeasurement?) { value = value ?? nextValue() }
}

private struct DeckMeasurement {
    var bounds: Anchor<CGRect>
    var waveformHeight: Double
}

/// 한 배치에서 함께 잰 본문 크기와 덱 높이
private struct DetailGeometry: Equatable {
    var size: CGSize
    var deckHeight: Double
    var waveformHeight: Double
}

/// 높이 적용값이 바뀔 때만 덱·핸들·메뉴를 갱신하고, 곡 목록까지 다시 만들지 않는다.
private struct LibraryDeckViewport: View {
    /// 덱 묶음이 쓰는 라이브러리 입력과 태그 편집 조각(본문은 읽지 않고 넘긴다)
    let library: any DeckLibrarySource
    let tags: TagEditStore
    let deck: DeckModel
    let layout: LibraryLayoutMetrics
    var widthClass: DeckWidthClass

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        let height = layout.waveformHeight
        ScrollView(.vertical) {
            DeckView(library: library, tags: tags, deck: deck, widthClass: widthClass)
                .environment(\.deckWaveformHeight, height)
                .frame(maxWidth: .infinity, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .perfMeasuredLayout("swiftui.deck")
                .anchorPreference(key: DeckBoundsKey.self, value: .bounds) { DeckMeasurement(bounds: $0, waveformHeight: height) }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .frame(height: layout.viewportHeight)
        .modifier(DeckDropTarget(library: library))
    }
}

private struct LibrarySplitHandle: View {
    let layout: LibraryLayoutMetrics
    @Binding var height: Double

    var body: some View {
        SplitHandle(height: $height, displayedHeight: layout.waveformHeight, maximumHeight: layout.maximumWaveformHeight,
                    minimumHeight: layout.minimumWaveformHeight)
    }
}

private struct LibraryWaveformHeightContext: ViewModifier {
    let layout: LibraryLayoutMetrics
    @Binding var height: Double

    func body(content: Content) -> some View {
        let _ = PerfProbe.count("LibraryWaveformHeightContext")
        // 높이·상한을 읽으면 창 높이를 바꾸는 단계마다 메뉴 막대 전체를 다시 만든다(#155). 켤지 두 값만 읽는다.
        content.focusedSceneValue(\.waveformHeight, layout.waveformHeightMenu { height = $0 })
    }
}
