import DJCDomain
import AppKit
import SwiftUI

/// 엑셀처럼 셀 단위로 편집하는 태그 시트. 편집은 DJCrate 초안에만 저장된다.
///
/// - 클릭: 셀 선택 / Shift+클릭·드래그: 범위 / 방향키·Tab: 이동(Shift로 범위 확장)
/// - 더블클릭·Return·타이핑: 편집 시작 / Return: 확정 후 아래로 / Tab: 확정 후 오른쪽 / Esc: 취소
/// - 커서 줄은 고른 곡일 뿐 덱은 그대로다. ⌘→·오른쪽 클릭 '덱에 불러오기'로 덱에 올린다(#93)
/// - ⌘C·⌘V: 탭 구분 텍스트(엑셀·구글 시트 호환) / ⌘D: 아래로 채우기 / Delete: 지우기
/// - ⌘Z·⇧⌘Z: 실행 취소·실행 복귀 / ⌘A: 전체 선택
struct TagSheetView: NSViewRepresentable {
    @Bindable var store: LibraryStore

    func makeCoordinator() -> SheetCoordinator { SheetCoordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = SheetTableView()
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        for column in SheetColumn.all {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            if column.key != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            }
            table.addTableColumn(tableColumn)
        }
        table.autosaveName = SheetColumn.autosaveName
        table.autosaveTableColumns = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.updateTextScale(context.environment.textScale)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let reflection = context.environment.reflection
        context.coordinator.recoverDraft = { [weak reflection] row, kind in reflection?.startRecovery(row: row, kind: kind) }
        context.coordinator.updateTextScale(context.environment.textScale)
        context.coordinator.update(rows: store.displayRows, revision: store.tagRevision)
    }
}

struct SheetColumn {
    let id: String
    let title: String
    let width: CGFloat
    /// nil이면 읽기 전용(복사만 된다).
    let key: TagFields.Key?
    /// 끌어서 줄일 수 있는 가장 좁은 폭
    var minWidth: CGFloat = 30

    /// 표가 열 배치를 저장하는 이름. 열을 더하기 전에 저장한 배치는 열 순서가 달라 새 열이 맨 끝으로 밀리므로 이름을 올려 새로 시작한다
    /// (키 열 "v2", 평점·곡 색 열 "v3").
    static let autosaveName = "djc.tagSheet.v3"

    /// 열 이름(identifier)으로 열 정의를 찾는다. 화면 위치로 찾지 않는다: 저장된 배치를 되살리거나 사용자가 열을 옮기면 위치가 `all` 순서와 다르다.
    static func spec(id: String) -> SheetColumn? { all.first { $0.id == id } }

    static let all: [SheetColumn] = [
        SheetColumn(id: "index", title: "#", width: 44, key: nil),
        SheetColumn(id: "title", title: String(ui: "제목"), width: 220, key: .title),
        SheetColumn(id: "artist", title: String(ui: "아티스트"), width: 170, key: .artist),
        SheetColumn(id: "album", title: String(ui: "앨범"), width: 170, key: .album),
        SheetColumn(id: "albumArtist", title: String(ui: "앨범 아티스트"), width: 120, key: .albumArtist),
        SheetColumn(id: "genre", title: String(ui: "장르"), width: 90, key: .genre),
        SheetColumn(id: "composer", title: String(ui: "작곡가"), width: 110, key: .composer),
        SheetColumn(id: "year", title: String(ui: "연도"), width: 52, key: .year),
        SheetColumn(id: "trackNumber", title: String(ui: "트랙"), width: 44, key: .trackNumber),
        // 키는 글자를 쓰지 않고 목록(Camelot 이름·없음)에서 고른다. 열 이름이 목록의 키 칸과 같아 머리글 정렬도 같다.
        SheetColumn(id: "key", title: String(ui: "키"), width: 52, key: .musicalKey),
        // 평점(별)·곡 색(rekordbox 이름)도 목록에서 고른다(#65). 붙여넣기는 "3"·"★★★", 색 번호·이름을 받는다.
        // 평점은 별 다섯 칸(12pt에서 61pt)이 글자 배율 1.0에서 여유 있게 들어가는 폭이고, 큰 배율·좁은 폭에서는 칸이 "5★"로 줄여 보인다.
        // 최소 폭은 가장 큰 배율(1.5배, 18pt)에서 숫자 표기("5★", 29pt)가 들어가는 폭이다.
        // 곡 색은 색 점 없이 이름만 보이므로, 이름이 잘려도 같은 글자가 되지 않게 최소 폭을 둔다(1.5배에서 "Pi…"·"Pu…"가 갈린다).
        SheetColumn(id: "rating", title: String(ui: "평점"), width: 76, key: .rating, minWidth: 40),
        SheetColumn(id: "color", title: String(ui: "곡 색"), width: 76, key: .color, minWidth: 48),
        SheetColumn(id: "comment", title: String(ui: "코멘트"), width: 300, key: .comment),
        SheetColumn(id: "file", title: String(ui: "파일"), width: 220, key: nil),
    ]
}

struct CellPosition: Equatable {
    var row: Int
    var column: Int
}
