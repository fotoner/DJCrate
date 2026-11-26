@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCTestKit
import ImageIO
import Synchronization
import SwiftUI
import Testing

/// 태그 시트의 앨범아트 열과 전체 경로 칸(#352). 앨범아트는 맨 앞에서 보기만 하고, 파일 칸은 음원의 전체 경로를 보인다(길면 가운데를 줄인다).
/// 복사 값은 줄이지 않은 경로 전체다.
@Suite("태그 시트 — 앨범아트 열·전체 경로", .serialized)
@MainActor
struct SheetArtPathTests {
    static let longPath = "/Users/dj/Music/Collection/2026/Warehouse Nights/Disc 2/01 A Very Long Track Name That Never Fits.mp3"

    static func row(_ id: String, title: String, path: String? = nil, imagePath: String? = nil) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "uuid-\(id)", title: title, artist: "합성 아티스트", album: nil, albumArtist: nil,
                              genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120,
                              lengthSeconds: 180, folderPath: path ?? "/x/\(id).mp3", comment: "",
                              importedOn: nil, analysisDataPath: nil, imagePath: imagePath, isDeleted: false),
                 cues: [], playCount: 0)
    }

    /// 열을 `SheetColumn.all` 순서로 만든 시트(저장된 배치 없이 새로 시작한 모양). 클립보드는 시험 것을 쓴다.
    @MainActor
    final class Harness {
        let store: LibraryStore
        let coordinator: SheetCoordinator
        let table = SheetTableView()
        let window: NSWindow
        let pasteboard = NSPasteboard.withUniqueName()

        init(rows: [TrackRow], store: LibraryStore = .test(saveTagDrafts: { _ in })) {
            _ = NSApplication.shared
            self.store = store
            coordinator = SheetCoordinator(store: store)
            coordinator.pasteboard = pasteboard
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            table.coordinator = coordinator
            coordinator.table = table
            table.delegate = coordinator
            table.dataSource = coordinator
            table.rowHeight = 22
            table.allowsMultipleSelection = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for spec in SheetColumn.all {
                let column = NSTableColumn(identifier: .init(spec.id))
                column.width = spec.width
                table.addTableColumn(column)
            }
            let scroll = NSScrollView()
            scroll.documentView = table
            window.contentView = scroll
            coordinator.update(rows: rows, revision: 0)
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func column(_ id: String) -> Int { table.column(withIdentifier: .init(id)) }

        func cell(_ id: String, row: Int) throws -> NSView {
            try #require(coordinator.tableView(table, viewFor: table.tableColumns[column(id)], row: row))
        }

        var copied: String? { pasteboard.string(forType: .string) }
    }

    /// 실제 시트를 호스팅 뷰에 붙인 표(저장된 배치를 되살리는 경로를 포함한다)
    static func hostedTable(store: LibraryStore) throws -> (SheetTableView, NSWindow) {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: TagSheetView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> SheetTableView? {
            (view as? SheetTableView) ?? view.subviews.lazy.compactMap { find($0) }.first
        }
        let table = try #require(find(controller.view))
        return (table, window)
    }

    // MARK: - 열 순서

    @Test func 열_순서는_앨범아트가_맨_앞이고_그_뒤로_번호와_제목이_온다() throws {
        #expect(SheetColumn.all.map(\.id) == ["thumb", "index", "title", "artist", "album", "albumArtist", "genre", "composer", "year",
                                              "trackNumber", "key", "rating", "color", "comment", "file"])
        let thumb = try #require(SheetColumn.spec(id: "thumb"))
        #expect(thumb.key == nil, "보기만 하는 열이라 태그 칸이 아니다")
        #expect(thumb.title == "앨범아트")
    }

    @Test func 호스팅한_표는_앨범아트가_맨_앞이고_정렬_머리글이_없다() throws {
        let (table, window) = try Self.hostedTable(store: .test(saveTagDrafts: { _ in }))
        defer { window.close() }
        #expect(table.tableColumns.first?.identifier.rawValue == "thumb")
        #expect(table.tableColumns.map(\.identifier.rawValue) == SheetColumn.all.map(\.id))
        #expect(table.tableColumns.first?.sortDescriptorPrototype == nil)
    }

    // MARK: - 시작 커서

    @Test func 시작_커서는_제목_칸이다() throws {
        // 표를 붙이기 전에도(열 정의 순서로) 제목 칸이다
        let bare = SheetCoordinator(store: .test(saveTagDrafts: { _ in }))
        let titleIndex = try #require(SheetColumn.all.firstIndex { $0.id == "title" })
        #expect(bare.cursor == CellPosition(row: 0, column: titleIndex) && bare.anchor == bare.cursor)
        // 실제 시트(저장된 배치를 되살린 표)에서는 표의 제목 열이다
        let (table, window) = try Self.hostedTable(store: .test(saveTagDrafts: { _ in }))
        defer { window.close() }
        let coordinator = try #require(table.coordinator)
        let title = table.column(withIdentifier: .init("title"))
        #expect(title >= 0)
        #expect(coordinator.cursor == CellPosition(row: 0, column: title) && coordinator.anchor == coordinator.cursor)
    }

    @Test func 저장된_배치로_열이_옮겨져_있어도_제목_열에_커서를_둔다() throws {
        let h = Harness(rows: [Self.row("1", title: "곡 하나")])
        defer { h.window.close() }
        h.table.moveColumn(h.column("title"), toColumn: h.column("comment"))
        let title = h.column("title")
        #expect(title != SheetColumn.initialCursorColumn)
        h.coordinator.placeCursorOnTitleColumn()
        #expect(h.coordinator.cursor == CellPosition(row: 0, column: title) && h.coordinator.anchor == h.coordinator.cursor)
        #expect(h.coordinator.editableKey(row: 0, column: h.coordinator.cursor.column) == .title)
    }

    @Test func 시작_커서에서_글자를_치면_제목을_편집한다() throws {
        let h = Harness(rows: [Self.row("1", title: "곡 하나")])
        defer { h.window.close() }
        h.window.makeFirstResponder(h.table)
        h.coordinator.beginEditing()
        #expect(h.coordinator.isEditing)
        #expect(h.coordinator.editingOriginal == "곡 하나", "시작 칸이 제목이라 편집 원본이 제목이다")
        h.coordinator.cancelEditing()
    }

    // MARK: - 전체 경로

    @Test func 파일_칸은_전체_경로를_보이고_가운데를_줄인다() throws {
        let h = Harness(rows: [Self.row("1", title: "곡 하나", path: Self.longPath)])
        defer { h.window.close() }
        let file = h.column("file")
        #expect(h.coordinator.text(row: 0, column: file) == Self.longPath)
        let cell = try #require(h.cell("file", row: 0) as? SheetCell)
        #expect(cell.label.stringValue == Self.longPath)
        #expect(cell.label.lineBreakMode == .byTruncatingMiddle)
        // 다른 열은 끝을 줄인다
        let title = try #require(h.cell("title", row: 0) as? SheetCell)
        #expect(title.label.lineBreakMode == .byTruncatingTail)
    }

    @Test func 칸을_다른_열로_다시_써도_줄이는_자리가_그_열을_따른다() throws {
        let cell = SheetCell()
        cell.configure(text: Self.longPath, edited: false, readOnly: true, selected: false, active: false, lineBreak: .byTruncatingMiddle)
        #expect(cell.label.lineBreakMode == .byTruncatingMiddle)
        cell.configure(text: "제목", edited: false, readOnly: false, selected: false, active: false)
        #expect(cell.label.lineBreakMode == .byTruncatingTail)
    }

    @Test func 파일_칸_툴팁은_전체_경로를_읽기_전용_이유와_함께_보인다() throws {
        let h = Harness(rows: [Self.row("1", title: "곡 하나", path: Self.longPath)])
        defer { h.window.close() }
        let rect = h.table.frameOfCell(atColumn: h.column("file"), row: 0)
        let tip = h.table.view(h.table, stringForToolTip: 0, point: NSPoint(x: rect.midX, y: rect.midY), userData: nil)
        #expect(tip.hasPrefix(Self.longPath) && tip.contains("읽기 전용"))
    }

    @Test func 앨범아트_칸에는_툴팁이_없다() throws {
        let h = Harness(rows: [Self.row("1", title: "곡 하나")])
        defer { h.window.close() }
        let rect = h.table.frameOfCell(atColumn: h.column("thumb"), row: 0)
        #expect(h.table.view(h.table, stringForToolTip: 0, point: NSPoint(x: rect.midX, y: rect.midY), userData: nil).isEmpty)
    }

    @Test func 복사_값은_줄이지_않은_경로_전체다() throws {
        let h = Harness(rows: [Self.row("1", title: "곡 하나", path: Self.longPath),
                               Self.row("2", title: "곡 둘", path: "/x/짧은 경로.mp3")])
        defer { h.window.close() }
        // 파일 칸 하나
        h.coordinator.select(.init(row: 0, column: h.column("file")), extend: false)
        h.coordinator.copySelection()
        #expect(h.copied == Self.longPath)
        // 파일 칸 두 줄
        h.coordinator.select(.init(row: 1, column: h.column("file")), extend: true)
        h.coordinator.copySelection()
        #expect(h.copied == Self.longPath + "\n/x/짧은 경로.mp3")
        // 제목에서 파일까지: 마지막 칸이 경로 전체다
        h.coordinator.select(.init(row: 0, column: h.column("title")), extend: false)
        h.coordinator.select(.init(row: 0, column: h.column("file")), extend: true)
        h.coordinator.copySelection()
        let fields = try #require(h.copied?.split(separator: "\t", omittingEmptySubsequences: false))
        #expect(fields.first == "곡 하나" && fields.last == Substring(Self.longPath))
    }

    @Test func 경로_칸은_붙여넣어도_바뀌지_않는다() throws {
        let h = Harness(rows: [Self.row("1", title: "곡 하나", path: Self.longPath)])
        defer { h.window.close() }
        h.coordinator.select(.init(row: 0, column: h.column("file")), extend: false)
        h.coordinator.paste(string: "/엉뚱/경로.mp3")
        #expect(h.store.tagDrafts.isEmpty)
        #expect(h.coordinator.text(row: 0, column: h.column("file")) == Self.longPath)
    }

    // MARK: - 앨범아트 열

    @Test func 앨범아트_열은_곡_목록과_같은_칸과_캐시로_그림을_읽는다() async throws {
        let calls = Mutex<[(path: String?, root: URL?)]>([])
        let jpeg = ImageFixture.image(width: 8, height: 8)
        let store = LibraryStore.test(saveTagDrafts: { _ in }, ports: { ports in
            ports.artwork.listThumbnail = { path, root in
                calls.withLock { $0.append((path, root)) }
                return CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
        })
        let row = Self.row("1", title: "곡 하나", imagePath: "/PIONEER/Artwork/1/artwork.jpg")
        let h = Harness(rows: [row], store: store)
        defer { h.window.close() }
        let cell = try #require(h.cell("thumb", row: 0) as? ThumbnailCell)
        func shown() -> NSImageView? { cell.subviews.compactMap { $0 as? NSImageView }.first }
        #expect(await waitForState { shown()?.imageScaling == .scaleProportionallyUpOrDown }, "그림을 받으면 자리 표시 기호 대신 그림이 보인다")
        #expect(calls.withLock { $0.map(\.path) } == ["/PIONEER/Artwork/1/artwork.jpg"])
        #expect(calls.withLock { $0.map(\.root) } == [store.shareRoot])
        #expect(shown()?.accessibilityLabel() == "앨범아트")
        // 곡 목록 칸이 같은 곡의 그림을 읽어도 캐시에서 온다(같은 그림)
        let listCell = ThumbnailCell(thumbnails: store.thumbnails)
        listCell.configure(row: row, shareRoot: store.shareRoot)
        let listShown = { listCell.subviews.compactMap { $0 as? NSImageView }.first }
        #expect(await waitForState { listShown()?.imageScaling == .scaleProportionallyUpOrDown })
        #expect(calls.withLock(\.count) == 1)
    }

    @Test func 앨범아트_열은_선택하지_않고_첫_번째_선택_칸은_번호_칸이다() throws {
        let h = Harness(rows: [Self.row("1", title: "곡 하나"), Self.row("2", title: "곡 둘")])
        defer { h.window.close() }
        let index = h.column("index")
        #expect(h.column("thumb") == 0 && index == 1)
        // 앨범아트를 눌러도(커서를 앞으로 보내도) 번호 칸에서 멈춘다
        h.coordinator.select(.init(row: 1, column: 0), extend: false)
        #expect(h.coordinator.cursor == CellPosition(row: 1, column: index))
        h.coordinator.move(rows: 0, columns: -1, extend: false)
        #expect(h.coordinator.cursor.column == index)
        // 전체 선택도 번호 칸부터다
        h.coordinator.selectAll()
        #expect(h.coordinator.anchor == CellPosition(row: 0, column: index))
        #expect(h.coordinator.cursor == CellPosition(row: 1, column: h.coordinator.columnCount - 1))
        // 복사한 줄은 앞이 빈 칸 없이 번호로 시작한다
        h.coordinator.copySelection()
        let first = try #require(h.copied?.split(separator: "\n").first)
        #expect(first.hasPrefix("1\t곡 하나\t"))
    }

    /// 표 위의 칸(열 이름·줄)에 닿는 마우스 이벤트
    private func mouse(_ type: NSEvent.EventType, _ h: Harness, column id: String, row: Int) throws -> NSEvent {
        let rect = h.table.frameOfCell(atColumn: h.column(id), row: row)
        let point = h.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                               windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func 앨범아트_칸을_오른쪽_클릭해도_고른_범위_안이면_선택을_유지한다() throws {
        let h = Harness(rows: (1...4).map { Self.row(String($0), title: "곡 \($0)") })
        defer { h.window.close() }
        h.coordinator.select(.init(row: 0, column: h.column("title")), extend: false)
        h.coordinator.select(.init(row: 2, column: h.column("title")), extend: true)
        // 고른 줄(0~2) 안의 앨범아트 칸: 선택이 한 줄로 접히지 않는다(메뉴의 대상 곡도 고른 줄 전체다)
        #expect(h.table.menu(for: try mouse(.rightMouseDown, h, column: "thumb", row: 1)) != nil)
        #expect(h.coordinator.selectionRect.rows == 0...2)
        // 고른 줄 밖(3번째 줄)의 앨범아트 칸: 엑셀처럼 그 줄의 첫 선택 칸으로 옮긴다
        _ = h.table.menu(for: try mouse(.rightMouseDown, h, column: "thumb", row: 3))
        #expect(h.coordinator.cursor == CellPosition(row: 3, column: h.column("index")) && h.coordinator.anchor == h.coordinator.cursor)
    }

    @Test func 앨범아트_열_위에서_끌어도_같은_칸이면_다시_선택하지_않는다() throws {
        let h = Harness(rows: (1...3).map { Self.row(String($0), title: "곡 \($0)") })
        defer { h.window.close() }
        let index = h.column("index")
        h.coordinator.select(.init(row: 1, column: index), extend: false)
        // 커서가 앨범아트 옆 번호 칸에 있으므로, 같은 줄 앨범아트 위를 끄는 것은 칸이 안 바뀐 것이다
        #expect(h.coordinator.clamped(CellPosition(row: 1, column: 0)) == CellPosition(row: 1, column: index))
        h.store.selection = []
        h.table.mouseDragged(with: try mouse(.leftMouseDragged, h, column: "thumb", row: 1))
        #expect(h.store.selection.isEmpty, "같은 칸 위에서는 선택을 다시 쓰지 않는다")
        // 다른 줄의 앨범아트 위로 끌면 그 줄의 첫 선택 칸까지 범위를 넓힌다
        h.table.mouseDragged(with: try mouse(.leftMouseDragged, h, column: "thumb", row: 2))
        #expect(h.coordinator.cursor == CellPosition(row: 2, column: index) && h.coordinator.selectionRect.rows == 1...2)
    }

    @Test func 커서를_옮겨도_앨범아트_그림이_자리_표시_기호로_돌아가지_않는다() async throws {
        let calls = Mutex<Int>(0)
        let jpeg = ImageFixture.image(width: 8, height: 8)
        let store = LibraryStore.test(saveTagDrafts: { _ in }, ports: { ports in
            ports.artwork.listThumbnail = { _, _ in
                calls.withLock { $0 += 1 }
                return CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
        })
        let rows = (1...3).map { Self.row(String($0), title: "곡 \($0)", imagePath: "/PIONEER/Artwork/\($0)/artwork.jpg") }
        let h = Harness(rows: rows, store: store)
        defer { h.window.close() }
        h.window.makeFirstResponder(h.table)
        for row in rows.indices { _ = try h.cell("thumb", row: row) }
        func cells() -> [ThumbnailCell?] { rows.indices.map { h.table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? ThumbnailCell } }
        func shown(_ cell: ThumbnailCell?) -> Bool {
            cell?.subviews.compactMap { $0 as? NSImageView }.first?.imageScaling == .scaleProportionallyUpOrDown
        }
        #expect(await waitForState { calls.withLock { $0 } == 3 && cells().allSatisfy(shown) })
        let before = cells()
        #expect(before.allSatisfy { $0 != nil })
        // 커서를 옮기면 보이는 칸을 다시 읽지만(`reloadVisible`), 그림 칸은 같은 곡이면 그대로라 그림이 바로 남아 있고 다시 읽지도 않는다
        for step in 0..<6 {
            h.coordinator.move(rows: step % 2 == 0 ? 1 : -1, columns: 0, extend: false)
            #expect(cells().allSatisfy(shown), "옮긴 직후에도 그림이 보인다(자리 표시 기호로 깜박이지 않는다)")
        }
        #expect(zip(before, cells()).allSatisfy { $0 === $1 })
        #expect(calls.withLock { $0 } == 3)
    }
}
