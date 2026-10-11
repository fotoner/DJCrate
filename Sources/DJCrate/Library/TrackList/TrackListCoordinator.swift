import DJCDomain
import AppKit
import SwiftUI

@MainActor
final class TrackListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let store: LibraryStore
    /// 메뉴가 시작하는 다른 영역의 흐름(쓰기·추가 목록·XML·USB 편집)
    let actions: TrackListActions
    private(set) lazy var recoveryMenu = DraftRecoveryMenu(store: store, recover: actions.recoverDraft)
    weak var table: NSTableView?
    private(set) var rows: [TrackRow] = []
    private(set) var largestRowIndex = 0
    private(set) var rowIDs: [TrackRow.ID] = []
    private(set) var edited: Set<String> = []
    private(set) var snapshotURL: URL?
    private(set) var previewRevision = 0
    private(set) var commentPreset: CommentPreset?
    private(set) var classHiddenWhenEnabled = false
    private(set) var waveformMode = WaveformColorMode.threeBand
    private(set) var previewCues: [String: [PreviewCueMark]] = [:]
    private(set) var textScale = 1.0
    private(set) var fonts = TrackTextCell.Fonts(scale: 1)
    private(set) var tagRevision = 0
    /// USB 목록을 보는 중(읽기 전용, 갱신 상태 칸을 보인다). 처음 한 번은 저장된 칸 배치와 무관하게 맞추려고 nil에서 시작한다
    private(set) var usbMode: Bool?
    /// 표 → 스토어로 선택·정렬을 넘기는 중에는 스토어 → 표 동기화를 건너뛴다(되먹임 방지).
    private var syncing = false

    /// 칸에서 바로 고치는 중인 태그(#88). 대상 곡과 시작 값은 편집을 시작할 때 정한다.
    struct InlineEdit {
        let row: Int
        let column: String
        let session: TrackListTagEditing.Session
        weak var cell: TrackTextCell?
        weak var field: NSTextField?
    }
    var inlineEdit: InlineEdit?
    /// 다시 누른 태그 칸을 고치기 전 기다림(더블클릭이면 취소)
    var pendingEdit: Task<Void, Never>?
    /// 마우스 버튼이 눌려 있는지(누른 채 끌면 고치지 않는다). 시스템 전체 상태라 시험이 바꿔 끼운다.
    var isMouseDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    /// 줄 끌기를 시작한 횟수. 누른 줄을 끌었으면(덱에 놓기 등) 그 클릭으로 칸을 고치지 않는다.
    var dragGeneration = 0
    /// 덱에 올린 곡(ContentID)과 재생 중인지. # 칸에 스피커로 보인다.
    private(set) var deckTrackID: String?
    private(set) var deckPlaying = false
    /// 열려 있는 고르기 메뉴(키 #204, 평점·곡 색 #65). 메뉴 추적은 동기식이라 여는 동안만 있다.
    var activeKeyMenu: NSMenu?
    var isEditing: Bool { inlineEdit != nil || activeKeyMenu != nil }
    /// 고치는 중인 칸 이름(시험용)
    var editingColumn: String? { inlineEdit?.column }
    /// 마지막으로 누른 칸(줄 ID와 칸 이름). 키 칸을 누른 뒤의 Return은 그 줄에서 키 메뉴를 연다(표에는 칸 커서가 없다).
    struct ClickedCell: Equatable {
        let rowID: TrackRow.ID
        let column: String
    }
    private(set) var clickedCell: ClickedCell?

    /// 누른 줄이 선택에서 빠졌으면(키보드로 옮김·검색에서 돌아옴·스토어가 다른 줄을 고름) 기억을 버린다.
    /// 클릭은 누른 줄을 고르므로 클릭 자체의 선택 알림에는 지워지지 않는다(알림 시점에 기대지 않는다).
    private func forgetClickedCell(unlessSelected ids: Set<TrackRow.ID>) {
        if let clicked = clickedCell, !ids.contains(clicked.rowID) { clickedCell = nil }
    }

    /// 누른 자리를 기억한다. 줄이나 칸 밖이면 잊는다.
    func noteClick(row: Int, column: String?) {
        clickedCell = rows.indices.contains(row) ? column.map { ClickedCell(rowID: rows[row].id, column: $0) } : nil
    }

    /// 메뉴 추적은 동기식이라 시험은 이것을 바꿔 끼워 표시만 보고 고르기는 따로 보낸다.
    var presentKeyMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: point, in: view)
    }

    init(store: LibraryStore, actions: TrackListActions) {
        self.store = store
        self.actions = actions
    }

    // MARK: - 스토어 → 표

    func updateCommentPreset(_ preset: CommentPreset) {
        guard commentPreset != preset, let table,
              let column = table.tableColumns.first(where: { $0.identifier.rawValue == "class" }) else { return }
        // 강제로 숨긴 상태가 사용자가 고른 열 숨김 설정을 덮지 않게 따로 기억한다.
        let hidden = column.isHidden
        if commentPreset == nil {
            classHiddenWhenEnabled = store.settings.defaults.object(forKey: SettingKeys.commentClassColumnHidden.name) as? Bool ?? hidden
        } else if commentPreset?.rule != nil {
            classHiddenWhenEnabled = hidden
        }
        store.settings.set(SettingKeys.commentClassColumnHidden, classHiddenWhenEnabled)
        commentPreset = preset
        column.isHidden = preset.rule == nil || classHiddenWhenEnabled
        cancelEditing()
        reloadVisible(table)
    }

    /// 글자 배율(보기 › 글자 크게·작게)이 바뀌면 글자 크기와 줄 높이를 함께 바꾼다. 보이지 않는 줄은 나타날 때 새 글자로 채운다.
    func updateTextScale(_ scale: Double) {
        guard scale != textScale, let table else { return }
        textScale = scale
        fonts = TrackTextCell.Fonts(scale: scale)
        table.rowHeight = TextScale.length(24, scale: scale)
        updateIndexWidth(table)
        cancelEditing()
        reloadVisible(table)
    }

    func updateWaveformMode(_ mode: WaveformColorMode) {
        guard mode != waveformMode, let table else { return }
        waveformMode = mode
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "preview" }) else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                         columnIndexes: IndexSet(integer: column))
    }

    func update(rows: [TrackRow], edited: Set<String>, selection: Set<TrackRow.ID>,
                sortOrder: [KeyPathComparator<TrackRow>], snapshotURL: URL?, previewRevision: Int) {
        guard let table else { return }
        applySortIndicator(sortOrder, table: table)
        let snapshotChanged = self.snapshotURL != snapshotURL || self.previewRevision != previewRevision
        self.snapshotURL = snapshotURL
        self.previewRevision = previewRevision
        // 같은 배열이면(== 는 저장소가 같을 때 바로 참) 비교 비용이 없다.
        if rows != self.rows || snapshotChanged {
            // 줄이 바뀌면(필터·검색·정렬·새 스냅샷) 고치던 칸을 먼저 닫는다. 편집 위치가 줄 번호라 그대로 두면 다른 곡에 남는다.
            cancelPendingEdit()
            cancelEditing()
            clickedCell = nil
            let ids = rows.map(\.id)
            let reordered = ids != rowIDs
            self.rows = rows
            largestRowIndex = max(rows.count, rows.compactMap { $0.historyTrackNumber ?? $0.playlistTrackNumber }.max() ?? 0)
            rowIDs = ids
            self.edited = edited
            if reordered {
                replaceRows(table)
                applySelection(selection, table: table, scroll: true)
            } else {
                // 순서는 같고 내용만 바뀜(새 스냅샷): 보이는 줄만 다시 그린다.
                reloadVisible(table)
            }
        } else if edited != self.edited {
            let changed = edited.symmetricDifference(self.edited)
            self.edited = edited
            if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "edited" }) {
                let indexes = IndexSet(rows.indices.filter { changed.contains(rows[$0].track.uuid) })
                table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: column))
            }
        }
        if !syncing, selection != selectedIDs(table) {
            applySelection(selection, table: table, scroll: true)
            forgetClickedCell(unlessSelected: selection)
        }
        updateIndexWidth(table)
    }

    private func updateIndexWidth(_ table: NSTableView) {
        guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == "index" }) else { return }
        let width = ceil((String(largestRowIndex) as NSString).size(withAttributes: [.font: fonts.digits]).width) + 12
        // 저장된 v2 배치가 좁아도 번호·글자 배율에 필요한 너비를 되찾는다.
        column.minWidth = max(48, width)
        column.width = max(column.width, column.minWidth)
    }

    private(set) var cueCounts: [String: CueCounts] = [:]

    /// 개수가 같은 이동이어도 그 곡의 미리 보기만 다시 그린다.
    func updatePreviewCues(_ cues: [String: [PreviewCueMark]]) {
        guard cues != previewCues, let table else { return }
        let changed = Set(cues.keys).union(previewCues.keys).filter { cues[$0] != previewCues[$0] }
        previewCues = cues
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "preview" }) else { return }
        let indexes = IndexSet(rows.indices.filter { changed.contains(rows[$0].track.uuid) })
        if !indexes.isEmpty { table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: column)) }
    }

    /// 초안 큐 개수가 바뀐 곡만 핫큐·메모리 칸을 다시 그린다.
    func updateCueCounts(_ counts: [String: CueCounts]) {
        guard counts != cueCounts, let table else { return }
        let changed = Set(counts.keys).union(cueCounts.keys).filter { counts[$0] != cueCounts[$0] }
        cueCounts = counts
        let columns = IndexSet(table.tableColumns.indices.filter { ["hotCues", "memoryCues"].contains(table.tableColumns[$0].identifier.rawValue) })
        let indexes = IndexSet(rows.indices.filter { changed.contains(rows[$0].track.uuid) })
        if !indexes.isEmpty, !columns.isEmpty { table.reloadData(forRowIndexes: indexes, columnIndexes: columns) }
    }

    private func selectedIDs(_ table: NSTableView) -> Set<TrackRow.ID> {
        Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
    }

    private func applySelection(_ selection: Set<TrackRow.ID>, table: NSTableView, scroll: Bool) {
        let indexes = IndexSet(rows.indices.filter { selection.contains(rows[$0].id) })
        syncing = true
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        syncing = false
        if scroll, let first = indexes.first { table.scrollRowToVisible(first) }
    }

    private func applySortIndicator(_ sortOrder: [KeyPathComparator<TrackRow>], table: NSTableView) {
        let wanted: [NSSortDescriptor] = sortOrder.first.flatMap { comparator in
            TrackColumn.sortKey(of: comparator.keyPath).map { [NSSortDescriptor(key: $0, ascending: comparator.order == .forward)] }
        } ?? []
        let current = table.sortDescriptors.prefix(1).map { ($0.key, $0.ascending) }
        if !current.elementsEqual(wanted.map { ($0.key, $0.ascending) }, by: ==) {
            syncing = true
            table.sortDescriptors = wanted
            syncing = false
        }
    }

    /// 줄이 바뀌면(사이드바 항목·정렬·검색) `reloadData`로 다시 불러오지 않는다. 그러면 만들어 둔 셀·행 뷰를 모두 버리고
    /// 새로 만들어 목록 전환마다 곡 수와 상관없이 무거웠다(#137). 줄 수만 알리고, 만들어 둔 줄(보이는 줄과 미리 준비한 줄)의 칸을 제자리에서 다시 채운다.
    /// `reloadData(forRowIndexes:)`도 쓰지 않는다. 칸을 뗐다 붙이며 줄마다 키 뷰 순서를 다시 계산해 그것만으로 전환 비용의 큰 몫이었다.
    private func replaceRows(_ table: NSTableView) {
        // 줄 수가 줄며 표가 선택을 잘라도 스토어 선택은 그대로 둔다(바로 뒤에 새 목록 기준으로 다시 고른다).
        // 표 높이는 기본으로 0.25초 동안 늘고 줄며 프레임마다 창을 다시 배치하므로 애니메이션 없이 바로 바꾼다.
        syncing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteNumberOfRowsChanged()
        }
        syncing = false
        let columns = table.tableColumns.map(\.identifier.rawValue)
        table.enumerateAvailableRowViews { rowView, index in
            guard rows.indices.contains(index) else { return }
            for (column, id) in columns.enumerated() {
                if let cell = rowView.view(atColumn: column) as? NSView { fill(cell, column: id, row: index) }
            }
        }
    }

    private func reloadVisible(_ table: NSTableView) {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    /// 태그 초안이 바뀌면(목록·시트·인스펙터·되돌리기·외부 초안) 보이는 태그 칸과 분류 칸을 제자리에서 다시 채운다.
    /// 다시 불러오지 않으므로 고치던 칸이 닫히지 않는다.
    func updateTagRevision(_ revision: Int) {
        guard revision != tagRevision, let table else { return }
        tagRevision = revision
        refreshTagCells(table)
    }

    /// rekordbox에 쓰기 시작하면 고치던 칸을 닫는다(쓰는 동안에는 초안을 바꾸지 않는다).
    func updateWriteLock(_ locked: Bool) {
        if locked { cancelEditing() }
    }

    /// USB 목록도 컬렉션과 같은 칸 배치(보이는 칸·순서·폭)를 쓴다. 다른 점은 갱신 상태 칸이 USB 목록에서만 보이는 것뿐이다(#256).
    /// 배치를 바꿨다 되돌리지 않으므로 자동 저장도 멈추지 않는다. 멈췄다 다시 켜면 AppKit이 저장된 배치를 다시 읽어 머리글이 어긋났다(#241).
    /// 고치던 칸은 닫는다.
    func updateUsbMode(_ usb: Bool) {
        guard usbMode != usb else { return }
        usbMode = usb
        cancelPendingEdit()
        cancelEditing()
        clickedCell = nil
        guard let table, let column = table.tableColumns.first(where: { $0.identifier.rawValue == TrackColumn.usbSyncID }),
              column.isHidden == usb else { return }
        // 숨김을 바꾸면 AppKit이 남는 폭을 늘어나는 칸에 나눠(uniform) 다른 칸 폭이 바뀌고, 드나들수록 컬렉션과 폭이 달라졌다.
        // 다른 칸 폭은 바꾸기 직전 폭으로 그 자리에서 되돌린다(갱신 상태 칸 폭만큼 표가 넓어지거나 좁아진다)
        let widths = table.tableColumns.filter { $0 !== column }.map { ($0, $0.width) }
        column.isHidden = !usb
        for (other, width) in widths where other.width != width { other.width = width }
        // 칸 하나만 숨기거나 보여도 그 뒤 칸 자리가 모두 바뀐다. 머리글 전체를 지금 칸 순서로 다시 그린다
        table.tile()
        table.headerView?.needsDisplay = true
        table.needsDisplay = true
    }

    /// 덱에 올린 곡이나 재생 상태가 바뀌면 그 곡의 # 칸만 다시 그린다.
    func updateDeck(trackID: String?, playing: Bool) {
        guard trackID != deckTrackID || playing != deckPlaying, let table else { return }
        let old = deckTrackID
        deckTrackID = trackID
        deckPlaying = playing
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "index" }) else { return }
        // USB 줄은 짝인 로컬 곡으로 덱 곡과 견준다(#255)
        let indexes = IndexSet(rows.indices.filter { store.isDeckTrack(rows[$0], deckTrackID: old) || store.isDeckTrack(rows[$0], deckTrackID: trackID) })
        if !indexes.isEmpty { table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: column)) }
    }

    // MARK: - 표 → 스토어

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let table else { return }
        let ids = selectedIDs(table)
        forgetClickedCell(unlessSelected: ids)
        if ids != store.selection {
            syncing = true
            store.selection = ids
            syncing = false
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !syncing else { return }
        // 머리글을 눌러 정렬을 바꾸면 줄이 바뀌기 전에 고치던 칸을 확정한다.
        finishEditing(commit: true, restoreFocus: true)
        clickedCell = nil
        guard let first = tableView.sortDescriptors.first, let key = first.key else {
            store.sortOrder = []
            return
        }
        if let comparator = TrackColumn.comparator(key: key, ascending: first.ascending) {
            syncing = true
            store.sortOrder = [comparator]
            syncing = false
        }
    }
}
