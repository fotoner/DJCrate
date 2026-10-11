@testable import DJCrate
import AppKit
import DJCDomain
import Testing

/// 사이드바 항목·정렬·검색으로 곡 목록이 바뀔 때(#137): 보이는 셀·행 뷰를 버리지 않고 다시 채우되,
/// 글자·선택·스크롤·칸 편집·정렬 표시는 전과 같게 둔다.
@Suite("곡 목록이 바뀔 때 셀 다시 쓰기")
@MainActor
struct TrackListReloadTests {
    static func rows(_ ids: some Sequence<Int>) -> [TrackRow] {
        ids.map { TrackListTagEditTests.row(String($0), title: "합성 곡 \($0)") }
    }

    private func update(_ h: ListHarness, _ rows: [TrackRow], selection: Set<TrackRow.ID>? = nil,
                        sortOrder: [KeyPathComparator<TrackRow>] = []) {
        h.coordinator.update(rows: rows, edited: [], selection: selection ?? h.store.selection, sortOrder: sortOrder,
                             snapshotURL: nil, previewRevision: 0)
        h.window.layoutIfNeeded()
        h.table.layoutSubtreeIfNeeded()
    }

    /// 표가 만들어 둔 줄(보이는 줄 + 미리 준비한 줄)마다 제목 칸 셀
    private func titleCells(_ h: ListHarness) -> [Int: TrackTextCell] {
        guard let column = h.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" }) else { return [:] }
        var cells: [Int: TrackTextCell] = [:]
        h.table.enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: column) as? TrackTextCell { cells[row] = cell }
        }
        return cells
    }

    private func rowViews(_ h: ListHarness) -> Set<ObjectIdentifier> {
        var views: Set<ObjectIdentifier> = []
        h.table.enumerateAvailableRowViews { rowView, _ in views.insert(ObjectIdentifier(rowView)) }
        return views
    }

    private func harness(_ rows: [TrackRow], selection: Set<TrackRow.ID> = []) -> ListHarness {
        let h = ListHarness(rows: rows, selection: selection)
        h.store.selection = selection
        h.window.layoutIfNeeded()
        h.table.layoutSubtreeIfNeeded()
        return h
    }

    @Test func 목록이_바뀌어도_보이는_셀과_행_뷰를_새로_만들지_않는다() throws {
        let h = harness(Self.rows(1...200))
        defer { h.close() }
        let cells = Set(titleCells(h).values.map(ObjectIdentifier.init))
        let rowViews = rowViews(h)
        try #require(cells.count > 5)
        update(h, Self.rows(301...500))
        #expect(Set(titleCells(h).values.map(ObjectIdentifier.init)).isSubset(of: cells))
        #expect(self.rowViews(h).isSubset(of: rowViews))
        update(h, Self.rows(301...500).reversed())
        #expect(Set(titleCells(h).values.map(ObjectIdentifier.init)).isSubset(of: cells))
        #expect(self.rowViews(h).isSubset(of: rowViews))
    }

    /// 칸이 다른 칸(폭이 다른 열)으로 옮겨 가면 칸마다 다시 배치해야 한다. 만들어 둔 칸은 그 자리에서 다시 채운다.
    @Test func 목록이_바뀌어도_칸은_제자리에서_다시_채운다() throws {
        let h = harness(Self.rows(1...200))
        defer { h.close() }
        func cells() -> [String: ObjectIdentifier] {
            var cells: [String: ObjectIdentifier] = [:]
            h.table.enumerateAvailableRowViews { rowView, row in
                for column in 0..<h.table.numberOfColumns {
                    if let cell = rowView.view(atColumn: column) as? NSView { cells["\(row):\(column)"] = ObjectIdentifier(cell) }
                }
            }
            return cells
        }
        let before = cells()
        try #require(before.count > 20)
        update(h, Self.rows(301...500).reversed())
        let after = cells()
        #expect(after == before)
        let titles = titleCells(h)
        for (row, cell) in titles { #expect(cell.text == "합성 곡 \(500 - row)") }
    }

    @Test(arguments: [3, 12, 200, 400])
    func 줄_수가_바뀌면_만들어_둔_줄이_모두_새_곡을_보인다(count: Int) throws {
        let h = harness(Self.rows(1...200))
        defer { h.close() }
        let next = Self.rows((1...count).map { 1000 + $0 })
        update(h, next)
        #expect(h.table.numberOfRows == count)
        let shown = titleCells(h)
        try #require(!shown.isEmpty)
        for (row, cell) in shown { #expect(cell.text == next[row].title) }
        // 아래로 스크롤해 새로 보이는 줄도 새 곡이다.
        h.table.scrollRowToVisible(count - 1)
        h.table.layoutSubtreeIfNeeded()
        for (row, cell) in titleCells(h) { #expect(cell.text == next[row].title) }
        // # 칸 번호도 새 자리로 다시 매긴다.
        let index = try #require(h.view(row: count - 1, column: "index") as? TrackIndexCell)
        #expect(index.text == "\(count)")
    }

    /// 표 높이를 0.25초 애니메이션으로 바꾸면 그동안 프레임마다 표·창을 다시 배치한다(사이드바 항목 전환이 그만큼 길어졌다).
    /// 애니메이션은 창이 화면에 있을 때만 돌아서 화면 밖 좌표에 띄워 본다.
    @Test(arguments: [(200, 400), (400, 250)])
    func 줄_수가_바뀌면_표_높이를_애니메이션_없이_바로_맞춘다(from: Int, to: Int) async throws {
        let h = harness(Self.rows(1...from))
        defer { h.close() }
        h.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        h.window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(50))
        h.coordinator.update(rows: Self.rows((1...to).map { 1000 + $0 }), edited: [], selection: [], sortOrder: [],
                             snapshotURL: nil, previewRevision: 0)
        let padding = h.table.rect(ofRow: 0).minY
        let height = h.table.rect(ofRow: to - 1).maxY + padding
        #expect(h.table.frame.height == height, "\(h.table.frame.height) \(height)")
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.table.frame.height == height, "\(h.table.frame.height) \(height)")
    }

    @Test func 순서만_바뀌면_선택한_곡을_따라가고_그_줄을_보인다() {
        let rows = Self.rows(1...200)
        let h = harness(rows, selection: ["5"])
        defer { h.close() }
        update(h, rows.reversed(), sortOrder: [KeyPathComparator(\TrackRow.title, order: .reverse)])
        #expect(h.table.selectedRowIndexes == IndexSet(integer: 195))
        #expect(h.table.rows(in: h.table.visibleRect).contains(195))
        #expect(h.store.selection == ["5"])
        #expect(h.table.sortDescriptors.first?.key == "title")
        #expect(h.table.sortDescriptors.first?.ascending == false)
    }

    @Test func 목록이_줄어_고른_곡이_빠져도_스토어의_선택은_그대로다() {
        let h = harness(Self.rows(1...200), selection: ["150"])
        defer { h.close() }
        h.table.scrollRowToVisible(149)
        update(h, Self.rows(1...20))
        #expect(h.table.selectedRowIndexes.isEmpty)
        #expect(h.store.selection == ["150"])
        // 고른 곡이 다시 보이는 목록으로 돌아오면 그 줄을 다시 고른다.
        update(h, Self.rows(1...200))
        #expect(h.table.selectedRowIndexes == IndexSet(integer: 149))
        #expect(h.store.selection == ["150"])
    }

    @Test func 고른_곡이_없으면_목록이_바뀌어도_스크롤_위치를_그대로_둔다() {
        let h = harness(Self.rows(1...200))
        defer { h.close() }
        h.table.scrollRowToVisible(120)
        h.table.layoutSubtreeIfNeeded()
        let top = h.table.visibleRect.minY
        #expect(top > 0)
        update(h, Self.rows(301...500))
        #expect(h.table.visibleRect.minY == top)
        #expect(h.table.selectedRowIndexes.isEmpty)
    }

    @Test func 목록이_바뀌면_고치던_칸은_확정하지_않고_닫는다() throws {
        let rows = Self.rows(1...50)
        let h = harness(rows, selection: ["1"])
        defer { h.close() }
        #expect(h.coordinator.beginEditing(row: 0, column: "title"))
        h.type("바꾸던 제목")
        update(h, Self.rows(1...50).reversed())
        #expect(!h.coordinator.isEditing)
        #expect(h.store.tagDrafts.isEmpty)
        let cell = try #require(h.cell(row: 49, column: "title"))
        #expect(!cell.label.isHidden)
        #expect(cell.text == "합성 곡 1")
        // 입력 칸이 다시 쓰인 셀에 남지 않는다.
        for cell in titleCells(h).values { #expect(!cell.subviews.contains { $0 is NSTextField && $0 !== cell.label }) }
    }

    // MARK: - 글자 칸 배치

    private func laidOut(_ cell: TrackTextCell, width: CGFloat = 220, height: CGFloat) -> TrackTextCell {
        cell.frame = NSRect(x: 0, y: 0, width: width, height: height)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    /// 글자 자리(글자 칸의 정렬 사각형, 프레임은 양옆 2pt 여백을 더 가진다). 세로는 프레임을 가운데에 둔다.
    private func slot(_ view: NSView) -> NSRect { view.alignmentRect(forFrame: view.frame) }

    /// 글자 자리는 양옆 2pt 안쪽에서 세로 가운데, 초안 표식은 왼쪽 위 7pt, 입력 칸은 글자 자리에 뜬다.
    @Test(arguments: [(1.0, 24.0), (1.5, 36.0), (0.85, 20.0)])
    func 글자_칸은_글자를_가운데에_두고_표식과_입력_칸을_제자리에_둔다(scale: Double, height: Double) throws {
        let cell = TrackTextCell()
        cell.fonts = TrackTextCell.Fonts(scale: scale)
        cell.set("합성 곡 제목", color: .labelColor, draft: true)
        _ = laidOut(cell, height: height)
        let label = slot(cell.label)
        #expect(label.minX == 2)
        #expect(label.maxX == 218)
        #expect(cell.label.frame.midY == CGFloat(height) / 2)
        #expect(cell.label.frame.height == cell.label.intrinsicContentSize.height)
        let mark = try #require(cell.subviews.first { $0 is DraftCornerView })
        #expect(mark.frame == NSRect(x: 0, y: cell.isFlipped ? 0 : CGFloat(height) - 7, width: 7, height: 7))
        let field = cell.beginEditing(text: "합성 곡 제목", placeholder: nil)
        cell.layoutSubtreeIfNeeded()
        #expect(slot(field).minX == label.minX)
        #expect(slot(field).maxX == label.maxX)
        #expect(field.frame.midY == CGFloat(height) / 2)
        cell.endEditing()
        #expect(field.superview == nil)
    }

    @Test func 폭이_바뀌면_글자_자리도_따라_줄고_는다() {
        let cell = laidOut(TrackTextCell(), height: 24)
        cell.set("합성 곡", color: .labelColor)
        cell.frame.size.width = 90
        cell.layoutSubtreeIfNeeded()
        #expect(slot(cell.label).maxX == 88)
        cell.frame.size.width = 400
        cell.layoutSubtreeIfNeeded()
        #expect(slot(cell.label).maxX == 398)
    }

    @Test func 아이콘은_세로_가운데에_두고_제목은_그_뒤에서_시작한다() throws {
        let cell = TrackTextCell()
        cell.set("스트리밍 곡", color: .secondaryLabelColor, symbol: LibraryFilter.streaming.systemImage)
        _ = laidOut(cell, height: 24)
        let icon = try #require(cell.subviews.first { $0 is NSImageView && !$0.isHidden })
        let image = try #require((icon as? NSImageView)?.image?.size)
        #expect(icon.frame.minX == 2)
        #expect(icon.frame.size == image)
        #expect(abs(icon.frame.midY - 12) <= 0.5)
        #expect(slot(cell.label).minX == 2 + ceil(image.width) + 3)
        #expect(slot(cell.label).maxX == 218)
        // 아이콘을 지우면 글자가 다시 앞으로 온다.
        cell.set("로컬 곡", color: .labelColor)
        cell.layoutSubtreeIfNeeded()
        #expect(slot(cell.label).minX == 2)
    }
}
