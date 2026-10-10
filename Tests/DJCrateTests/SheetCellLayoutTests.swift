@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestKit
import RekordboxFixtures
import Testing

/// 태그 시트 칸을 가볍게 만든 것(#140)이 모양·동작을 바꾸지 않는지 고정한다.
/// 칸마다 툴팁·제약이 있으면 스크롤 때 추적 영역 갱신과 제약 계산이 칸 수만큼 돌아 프레임이 밀렸다.
@Suite("태그 시트 칸 배치", .serialized)
@MainActor
struct SheetCellLayoutTests {
    /// 제약 배치를 쓰던 옛 칸(라벨 좌우 4pt·세로 가운데, 초안 표식 7×7 왼쪽 위)을 그대로 만든 기준.
    /// `editing`이면 편집 입력 칸(라벨 좌우에 맞추고 세로 가운데)도 함께 만든다.
    private func reference(width: CGFloat, height: CGFloat, text: String, font: NSFont, editing: Bool = false) -> (label: NSRect, mark: NSRect, field: NSRect?) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = font
        label.cell?.usesSingleLineMode = true
        label.cell?.isScrollable = false
        root.addSubview(label)
        let mark = DraftCornerView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mark)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            mark.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mark.topAnchor.constraint(equalTo: root.topAnchor),
            mark.widthAnchor.constraint(equalToConstant: 7),
            mark.heightAnchor.constraint(equalToConstant: 7),
        ])
        var field: NSTextField?
        if editing {
            let input = NSTextField(string: text)
            input.font = font
            input.isBordered = false
            input.drawsBackground = true
            input.cell?.usesSingleLineMode = true
            input.cell?.isScrollable = true
            input.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(input)
            NSLayoutConstraint.activate([
                input.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                input.trailingAnchor.constraint(equalTo: label.trailingAnchor),
                input.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            ])
            field = input
        }
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        return (label.frame, mark.frame, field?.frame)
    }

    private func place(_ cell: SheetCell, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        cell.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = cell
        cell.layoutSubtreeIfNeeded()
        return window
    }

    @Test(arguments: [(220.0, 1.0, "합성 곡 1"), (44.0, 1.0, "12"), (120.0, 1.5, ""), (300.0, 0.8, "긴 제목 긴 제목 긴 제목 긴 제목 긴 제목 긴 제목")])
    func 글자와_초안_표식_자리가_제약_배치와_같다(_ width: Double, _ scale: Double, _ text: String) {
        let font = SheetCell.font(scale: scale)
        let height = (22 * scale).rounded()
        let cell = SheetCell()
        cell.label.font = font
        cell.configure(text: text, edited: true, readOnly: false, selected: false, active: false)
        let window = place(cell, width: width, height: height)
        defer { window.close() }
        let expected = reference(width: width, height: height, text: text, font: font)
        #expect(abs(cell.label.frame.minX - expected.label.minX) <= 0.5)
        #expect(abs(cell.label.frame.maxX - expected.label.maxX) <= 0.5)
        #expect(abs(cell.label.frame.minY - expected.label.minY) <= 0.5)
        #expect(abs(cell.label.frame.height - expected.label.height) <= 0.5)
        let mark = cell.subviews.first { $0 is DraftCornerView }
        #expect(mark?.frame.size == expected.mark.size)
        #expect(mark.map { abs($0.frame.minX - expected.mark.minX) <= 0.5 && abs($0.frame.minY - expected.mark.minY) <= 0.5 } == true)
    }

    @Test func 칸_너비가_바뀌면_글자_자리가_따라간다() {
        let cell = SheetCell()
        cell.configure(text: "합성 곡 1", edited: false, readOnly: false, selected: false, active: false)
        let window = place(cell, width: 220, height: 22)
        defer { window.close() }
        cell.setFrameSize(NSSize(width: 100, height: 22))
        cell.layoutSubtreeIfNeeded()
        let expected = reference(width: 100, height: 22, text: "합성 곡 1", font: SheetCell.font(scale: 1))
        #expect(abs(cell.label.frame.maxX - expected.label.maxX) <= 0.5)
        #expect(abs(cell.label.frame.width - expected.label.width) <= 0.5)
    }

    @Test func 칸에는_제약이_없다() {
        let cell = SheetCell()
        cell.configure(text: "합성 곡 1", edited: true, readOnly: false, selected: true, active: true)
        let window = place(cell, width: 220, height: 22)
        defer { window.close() }
        #expect(cell.constraints.isEmpty)
        #expect(cell.label.constraints.isEmpty)
        #expect(cell.label.translatesAutoresizingMaskIntoConstraints)
    }

    @Test func 편집_입력_칸은_글자_칸_자리에_놓이고_끝나면_제약도_남지_않는다() {
        let cell = SheetCell()
        cell.configure(text: "합성 곡 1", edited: false, readOnly: false, selected: true, active: true)
        let window = place(cell, width: 220, height: 22)
        defer { window.close() }
        let field = cell.beginEditing(text: "합성 곡 1")
        cell.layoutSubtreeIfNeeded()
        let expected = reference(width: 220, height: 22, text: "합성 곡 1", font: SheetCell.font(scale: 1), editing: true)
        let expectedField = expected.field ?? .zero
        #expect(abs(field.frame.minX - expectedField.minX) <= 0.5)
        #expect(abs(field.frame.maxX - expectedField.maxX) <= 0.5)
        #expect(abs(field.frame.minY - expectedField.minY) <= 0.5)
        #expect(abs(field.frame.height - expectedField.height) <= 0.5)
        #expect(cell.label.isHidden)
        cell.endEditing()
        #expect(cell.editingField == nil && !cell.label.isHidden)
        #expect(cell.constraints.isEmpty)
    }

    @Test func 칸을_다시_써도_툴팁을_칸마다_만들지_않는다() {
        let cell = SheetCell()
        cell.configure(text: "합성 곡 1", edited: false, readOnly: false, selected: false, active: false)
        #expect(cell.toolTip == nil)
        #expect(cell.label.toolTip == nil)
        #expect(cell.trackingAreas.isEmpty)
    }

    @Test func 툴팁은_표_하나가_눌린_칸의_전체_글자로_알려_준다() throws {
        let h = SheetCellLayoutHarness()
        defer { h.window.close() }
        #expect(h.table.toolTipTag != nil)
        // AppKit이 툴팁 글자를 물을 때 부르는 메서드가 ObjC에 보여야 한다
        #expect(h.table.responds(to: NSSelectorFromString("view:stringForToolTip:point:userData:")))
        for row in 0..<3 {
            let rect = h.table.frameOfCell(atColumn: 1, row: row)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            #expect(h.table.view(h.table, stringForToolTip: 0, point: point, userData: nil) == "합성 곡 \(row + 1)")
        }
        // 다른 열은 그 열의 글자
        let fileColumn = try #require(SheetColumn.all.firstIndex { $0.id == "file" })
        let file = h.table.frameOfCell(atColumn: fileColumn, row: 0)
        let fileReason = try #require(TrackListTagEditing.unavailableReason(h.coordinator.rows[0], key: nil))
        #expect(h.table.view(h.table, stringForToolTip: 0, point: NSPoint(x: file.midX, y: file.midY), userData: nil)
                == h.coordinator.text(row: 0, column: fileColumn) + "\n" + fileReason)
        // 줄 밖(빈 곳)은 툴팁 없음
        #expect(h.table.view(h.table, stringForToolTip: 0, point: NSPoint(x: 5, y: h.table.bounds.maxY + 200), userData: nil).isEmpty)
        // 보이는 칸 어디에도 칸별 툴팁이 없다
        for row in 0..<3 {
            for column in 0..<SheetColumn.all.count {
                let cell = try #require(h.table.view(atColumn: column, row: row, makeIfNecessary: true) as? SheetCell)
                #expect(cell.toolTip == nil)
            }
        }
    }

    @Test func 표_크기가_바뀌면_툴팁_영역도_새_크기로_옮겨진다() {
        let h = SheetCellLayoutHarness()
        defer { h.window.close() }
        let first = h.table.toolTipTag
        h.table.setFrameSize(NSSize(width: h.table.frame.width + 100, height: h.table.frame.height + 50))
        #expect(h.table.toolTipTag != nil)
        #expect(h.table.toolTipTag != first)
        #expect(h.table.toolTipRect == h.table.bounds)
    }

    @Test func 스트리밍_칸의_전체_글자와_편집_불가_이유를_표_툴팁으로_알린다() throws {
        let folder = try TemporaryFolder()
        let store = LibraryStore.test(saveTagDrafts: { _ in }, backupDirectory: folder.url.appending(path: "backups"),
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil,
                                 stagingSaver: { _ in }, draftHome: folder.url.appending(path: "drafts"),
                                 rekordboxDatabase: folder.url.appending(path: "master.db"), rekordboxShareRoot: folder.url.appending(path: "share"))
        let h = SheetCellLayoutHarness(store: store)
        defer { h.window.close() }
        let stream = TrackListTagEditTests.row("stream", streaming: true)
        h.coordinator.update(rows: [stream], revision: 1)
        let rect = h.table.frameOfCell(atColumn: 1, row: 0)
        let reason = try #require(TrackListTagEditing.unavailableReason(stream, key: .title))
        #expect(h.table.view(h.table, stringForToolTip: 0, point: NSPoint(x: rect.midX, y: rect.midY), userData: nil)
                == h.coordinator.text(row: 0, column: 1) + "\n" + reason)
        let cell = try #require(h.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? SheetCell)
        #expect(cell.toolTip == nil && cell.label.toolTip == nil)
    }

    @Test func 선택과_기준_칸_초안_색이_칸에_반영되고_풀리면_지워진다() {
        let cell = SheetCell()
        cell.configure(text: "값", edited: false, readOnly: false, selected: false, active: false)
        let window = place(cell, width: 220, height: 22)
        defer { window.close() }
        #expect(cell.layer?.backgroundColor == nil)
        #expect(cell.layer?.borderWidth == 0)
        cell.configure(text: "값", edited: true, readOnly: false, selected: true, active: true)
        #expect(cell.layer?.backgroundColor != nil)
        #expect(cell.layer?.borderWidth == 2)
        #expect(cell.showsDraftMark)
        // 그리기 직전 갱신이 이미 맞는 상태를 흐트리지 않는다
        cell.viewWillDraw()
        #expect(cell.layer?.backgroundColor != nil && cell.layer?.borderWidth == 2)
        cell.configure(text: "값", edited: false, readOnly: true, selected: false, active: false)
        #expect(cell.layer?.backgroundColor == nil)
        #expect(cell.layer?.borderWidth == 0)
        #expect(!cell.showsDraftMark)
    }

    @Test func 초안_칸의_읽기_값은_칸을_다시_쓴_뒤에도_따라온다() {
        let cell = SheetCell()
        cell.configure(text: "새 제목", edited: true, readOnly: false, selected: false, active: false)
        let draftValue = cell.label.cell?.accessibilityValue()
        #expect((draftValue as? String) == "새 제목, 초안")
        // 재사용: 초안이 아닌 칸으로 바뀌면 이전 초안 값이 남지 않는다
        cell.configure(text: "다른 제목", edited: false, readOnly: false, selected: false, active: false)
        #expect((cell.label.cell?.accessibilityValue() as? String) == "다른 제목")
    }
}

@MainActor
private final class SheetCellLayoutHarness {
    let store: LibraryStore
    let coordinator: SheetCoordinator
    let table = SheetTableView()
    let window: NSWindow

    init(store: LibraryStore = LibraryStore.test(saveTagDrafts: { _ in })) {
        self.store = store
        _ = NSApplication.shared
        coordinator = SheetCoordinator(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        table.coordinator = coordinator
        coordinator.table = table
        table.delegate = coordinator
        table.dataSource = coordinator
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for spec in SheetColumn.all {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.width = spec.width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        window.contentView = scroll
        coordinator.update(rows: (1...3).map { TrackListTagEditTests.row(String($0), title: "합성 곡 \($0)") }, revision: 0)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
