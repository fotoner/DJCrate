import DJCDomain
import AppKit
import SwiftUI

/// 곡 목록.
///
/// SwiftUI `Table`은 7천 줄 배열이 바뀔 때마다(필터·검색·정렬·선택) 행 비교와 레이아웃 비용이 커서
/// 스크롤·선택이 무거웠다. AppKit `NSTableView`(데이터 소스 + 셀 재사용)로 그리고,
/// 선택·정렬은 스토어와 양방향으로 맞춘다. 열 너비·순서는 자동 저장된다.
///
/// 덱에서는 미리 보기 파형 색 방식과 재생 중인지만 읽는다(`TrackListDeckStatus`). 두 값은 이 본문에서 읽어,
/// 재생·일시정지가 이 목록만 다시 계산하고 둘러싼 본문(`LibraryDetail`)까지 퍼지지 않게 한다.
struct TrackTable<Deck: TrackListDeckStatus>: View {
    @Bindable var store: LibraryStore
    let deck: Deck
    /// 메뉴가 시작하는 흐름(조립 지점이 한 번 만들어 내려 준다)
    @Environment(\.trackListActions) private var actions
    @Environment(\.reflection) private var reflection

    var body: some View {
        // 조립 지점 없이 목록만 띄운 화면(시험)도 같은 실제 묶음을 쓴다(쓰기는 붙인 것이 있을 때만).
        TrackListView(store: store, actions: actions ?? .live(store: store, reflection: reflection), mode: deck.waveformColorMode,
                      deckPlaying: deck.isPlaying)
    }
}

/// 곡 목록이 덱에서 읽는 값: 미리 보기 파형 색 방식, 재생 중인지(# 칸 스피커 모양)
@MainActor
protocol TrackListDeckStatus: AnyObject {
    var waveformColorMode: WaveformColorMode { get }
    var isPlaying: Bool { get }
}

extension DeckModel: TrackListDeckStatus {}

private struct TrackListView: NSViewRepresentable {
    let store: LibraryStore
    let actions: TrackListActions
    let mode: WaveformColorMode
    /// 덱에 올린 곡의 # 칸 스피커 모양(재생 중이면 소리 나는 모양)
    let deckPlaying: Bool

    func makeCoordinator() -> TrackListCoordinator { TrackListCoordinator(store: store, actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackListTableView()
        table.identifier = KeyRouter.trackListID
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.style = .inset
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        // 한 글자 키는 덱 단축키로 쓰므로 제목 타이핑 선택과 겹치지 않게 한다.
        table.allowsTypeSelect = false
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for spec in TrackColumn.all {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.resizingMask = spec.flexible ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            if let key = spec.sortKey {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: spec.ascendingFirst)
            }
            if !spec.help.isEmpty { column.headerToolTip = spec.help }
            if spec.id == "thumb" {
                column.headerCell.attributedStringValue = TrackColumn.artworkHeader
                column.headerCell.setAccessibilityLabel(spec.title)
            }
            if spec.id == "edited" {
                column.headerCell.attributedStringValue = TrackColumn.draftHeader
                column.headerCell.setAccessibilityLabel(spec.title)
            }
            column.isHidden = TrackColumn.hiddenByDefault.contains(spec.id) || spec.id == TrackColumn.usbSyncID
            table.addTableColumn(column)
        }
        table.menu = context.coordinator.makeMenu()
        // 앱 안에서는 재생 목록에 넣거나 순서를 바꾸고, 앱 밖에는 음원 파일을 복사한다.
        table.registerForDraggedTypes([PlaylistDragType.pasteboardTracks])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
        table.autosaveName = "djc.trackList.v2"
        table.autosaveTableColumns = !PerfProbe.enabled
        // 머리글을 오른쪽 클릭하면 보일 칸을 고른다(숨김 상태도 자동 저장된다).
        table.headerView?.menu = context.coordinator.makeColumnMenu(table)
        TrackColumn.placeNewColumns(in: table)
        TrackColumn.migrateRatingWidth(in: table, remember: !PerfProbe.enabled)
        if let show = PerfProbe.previewColumnVisible {
            table.tableColumns.first(where: { $0.identifier.rawValue == "preview" })?.isHidden = !show
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.updateCommentPreset(store.commentPreset)
        context.coordinator.updateTextScale(context.environment.textScale)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        PerfProbe.count("TrackListView.update")
        context.coordinator.updateWriteLock(store.isWritingRekordbox)
        context.coordinator.updateUsbMode(store.isUsbSelection)
        context.coordinator.updateTextScale(context.environment.textScale)
        context.coordinator.updateCommentPreset(store.commentPreset)
        context.coordinator.update(rows: store.displayRows, edited: store.listMarkedUUIDs,
                                   selection: store.selection, sortOrder: store.sortOrder, snapshotURL: store.snapshotURL,
                                   previewRevision: store.previewRevision)
        context.coordinator.updateTagRevision(store.tagRevision)
        context.coordinator.updateCueCounts(store.draftCueCounts)
        context.coordinator.updatePreviewCues(store.draftPreviewCues)
        context.coordinator.updateWaveformMode(mode)
        context.coordinator.updateDeck(trackID: store.deckTrackID, playing: deckPlaying)
    }
}
