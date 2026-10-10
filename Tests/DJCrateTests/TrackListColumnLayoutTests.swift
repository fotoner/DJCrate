@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// USB 목록에 들어갔다 나올 때 곡 목록 칸 배치·머리글(#241, #256)
@MainActor
@Suite("곡 목록 칸 배치")
struct TrackListColumnLayoutTests {
    @MainActor
    private struct Layout: Equatable {
        var order: [String]
        var hidden: [String: Bool]
        var widths: [String: CGFloat]
        var titles: [String: String]

        init(_ table: NSTableView) {
            order = table.tableColumns.map { $0.identifier.rawValue }
            hidden = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.isHidden) })
            widths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) })
            titles = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.headerCell.stringValue) })
        }
    }

    /// 머리글 전체 다시 그리기를 요청받은 때의 칸 순서를 기록한다(화면 밖 창에서는 `needsDisplay`가 남지 않는다).
    /// 일부 칸만 무효화한 뒤 순서가 바뀌면 나머지 자리는 옛 순서로 그린 그림이 남는다(#241).
    final class RecordingHeaderView: NSTableHeaderView {
        var orderAtFullRedraw: [String]?
        private func record(_ rect: NSRect) {
            guard let tableView, rect.contains(visibleRect) else { return }
            orderAtFullRedraw = tableView.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }
        }
        override var needsDisplay: Bool {
            get { super.needsDisplay }
            set {
                if newValue { record(bounds) }
                super.needsDisplay = newValue
            }
        }
        override func setNeedsDisplay(_ invalidRect: NSRect) {
            record(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    /// 보이는 칸의 머리글 자리가 지금 칸 순서·너비대로 빈틈 없이 이어지는지(숨김·옮김 뒤 낡은 칸 위치로 그리지 않는지).
    /// 첫·끝 칸은 표 안쪽 여백만큼 폭이 달라 가운데 칸만 너비를 견준다
    private func expectFreshGeometry(_ table: NSTableView, sourceLocation: SourceLocation = #_sourceLocation) {
        let visible = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        var previous: NSRect?
        for (position, index) in visible.enumerated() {
            let column = table.tableColumns[index]
            let header = table.headerView?.headerRect(ofColumn: index) ?? .zero
            #expect(header == table.rect(ofColumn: index).intersection(header), "\(column.identifier.rawValue)", sourceLocation: sourceLocation)
            if let previous {
                #expect(abs(header.minX - previous.maxX) < 0.5, "\(column.identifier.rawValue)", sourceLocation: sourceLocation)
            }
            if position > 0, position < visible.count - 1 {
                #expect(abs(header.width - (column.width + table.intercellSpacing.width)) < 0.5, "\(column.identifier.rawValue)",
                        sourceLocation: sourceLocation)
            }
            previous = header
        }
    }

    /// 앱과 같은 칸(`TrackColumn.all`)·제목을 단 표를 창 안 스크롤 뷰에 둔다. 사용자 배치처럼 갱신 상태 칸은 숨긴 채 맨 끝, 키 뒤에 평점·곡 색.
    private func makeTable(autosaveName: String? = nil) -> (NSWindow, NSTableView, TrackListCoordinator) {
        _ = NSApplication.shared
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("columns"), persist: false),
                                 saveTagDrafts: { _ in })
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
        let table = NSTableView()
        table.headerView = RecordingHeaderView()
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = coordinator
        table.delegate = coordinator
        for spec in TrackColumn.all {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.resizingMask = spec.flexible ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            column.isHidden = TrackColumn.hiddenByDefault.contains(spec.id) || spec.id == TrackColumn.usbSyncID
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        if let autosaveName {
            table.autosaveName = autosaveName
            table.autosaveTableColumns = true
        }
        coordinator.table = table
        coordinator.updateUsbMode(false)
        window.displayIfNeeded()
        return (window, table, coordinator)
    }

    @Test("모든 칸에 머리글 제목이 있고 데이터 칸과 같은 식별자에 붙는다")
    func everyColumnHasHeaderTitle() {
        let (window, table, _) = makeTable()
        for column in table.tableColumns {
            let spec = TrackColumn.all.first { $0.id == column.identifier.rawValue }
            #expect(spec != nil)
            // 앨범아트·초안 칸은 그림 머리글이지만 제목(접근성·칸 메뉴)은 있다
            #expect(column.title == spec?.title && !column.title.isEmpty, "\(column.identifier.rawValue)")
            let index = table.column(withIdentifier: column.identifier)
            #expect(table.headerView?.headerRect(ofColumn: index).minX == table.rect(ofColumn: index).minX)
        }
        withExtendedLifetime(window) {}
    }

    /// 사용자가 옮기고 넓히고 숨긴 칸 배치(미리 보기 칸을 켜고 코멘트를 앞으로, 제목 폭, 앨범 숨김)
    private func arrangeLikeUser(_ table: NSTableView) {
        table.moveColumn(table.column(withIdentifier: .init("comment")), toColumn: 2)
        table.tableColumns.first { $0.identifier.rawValue == "title" }?.width = 148
        table.tableColumns.first { $0.identifier.rawValue == "album" }?.isHidden = true
        table.tableColumns.first { $0.identifier.rawValue == "preview" }?.isHidden = false
    }

    /// USB 목록은 컬렉션과 같은 칸 배치를 쓴다(#256). 다른 점은 갱신 상태 칸이 보이는 것뿐이다
    @Test("USB 목록을 몇 번 드나들어도 칸 순서·너비·숨김이 그대로이고 갱신 상태 칸만 켜졌다 꺼진다")
    func usbRoundTripsKeepUserLayout() {
        let (window, table, coordinator) = makeTable()
        arrangeLikeUser(table)
        window.displayIfNeeded()
        let before = Layout(table)
        var usb = before
        usb.hidden[TrackColumn.usbSyncID] = false

        for _ in 0..<3 {
            coordinator.updateUsbMode(true)
            expectFreshGeometry(table)
            window.displayIfNeeded()
            #expect(Layout(table) == usb)

            coordinator.updateUsbMode(false)
            expectFreshGeometry(table)
            window.displayIfNeeded()
            #expect(Layout(table) == before)
        }
        withExtendedLifetime(window) {}
    }

    /// 자동 저장을 멈췄다 다시 켜면 AppKit이 저장된 배치를 읽어 머리글만 낡은 칸 순서로 남았다(#241).
    /// USB 목록도 같은 배치를 쓰므로 자동 저장을 멈추지 않고, 갱신 상태 칸을 켜고 끈 뒤 머리글 전체를 지금 칸 순서로 다시 그린다
    @Test("자동 저장 중인 표도 USB 목록을 드나들면 칸 배치가 그대로이고 머리글을 지금 칸 순서로 다시 그린다")
    func usbRoundTripWithAutosaveRedrawsHeader() throws {
        let name = "djc.test.trackList.\(UUID().uuidString)"
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(name) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let (window, table, coordinator) = makeTable(autosaveName: name)
        arrangeLikeUser(table)
        window.displayIfNeeded()
        let before = Layout(table)
        let header = try #require(table.headerView as? RecordingHeaderView)

        header.orderAtFullRedraw = nil
        coordinator.updateUsbMode(true)
        #expect(table.autosaveTableColumns)
        #expect(header.orderAtFullRedraw == table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue })
        #expect(header.orderAtFullRedraw?.contains(TrackColumn.usbSyncID) == true)
        window.displayIfNeeded()

        header.orderAtFullRedraw = nil
        coordinator.updateUsbMode(false)
        #expect(table.autosaveTableColumns)
        #expect(Layout(table) == before)
        #expect(header.orderAtFullRedraw == table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue })
        withExtendedLifetime(window) {}
    }

    @Test("갱신 상태 칸은 처음 한 번만 키 칸 바로 뒤로 옮기고 그 뒤로는 사용자가 옮긴 자리를 지킨다")
    func usbSyncColumnPlacedOnceAfterKey() {
        let (window, table, coordinator) = makeTable()
        let defaults = TestDefaults.make("usb-sync-column")
        func position(_ id: String) -> Int { table.column(withIdentifier: .init(id)) }

        TrackColumn.placeUsbSyncColumn(in: table, defaults: defaults)
        #expect(position(TrackColumn.usbSyncID) == position("key") + 1)

        table.moveColumn(position(TrackColumn.usbSyncID), toColumn: 1)
        TrackColumn.placeUsbSyncColumn(in: table, defaults: defaults)
        coordinator.updateUsbMode(true)
        coordinator.updateUsbMode(false)
        coordinator.updateUsbMode(true)
        #expect(position(TrackColumn.usbSyncID) == 1)
        #expect(!table.tableColumns[1].isHidden)
        withExtendedLifetime(window) {}
    }

    /// 같은 배치라 USB 목록에서도 칸 메뉴로 칸을 고른다. 고른 칸은 나와도 그대로다. 갱신 상태 칸은 메뉴에 없고 USB 목록이 정한다
    @Test("USB 목록에서 고른 칸은 컬렉션에도 그대로이고 모든 칸 보이기는 갱신 상태 칸을 USB 목록에서만 보인다")
    func columnMenuWorksInUsbList() throws {
        let (window, table, coordinator) = makeTable()
        func hidden(_ id: String) -> Bool { table.tableColumns.first { $0.identifier.rawValue == id }?.isHidden ?? false }
        coordinator.updateUsbMode(true)
        let menu = coordinator.makeColumnMenu(table)
        coordinator.menuNeedsUpdate(menu)
        #expect(!menu.items.contains { $0.representedObject as? String == TrackColumn.usbSyncID })
        let genre = try #require(menu.items.first { $0.representedObject as? String == "genre" })
        #expect(genre.action != nil)
        coordinator.toggleColumn(genre)
        #expect(hidden("genre"))

        coordinator.showAllColumns()
        #expect(!hidden("genre") && !hidden("preview") && !hidden(TrackColumn.usbSyncID))
        coordinator.updateUsbMode(false)
        #expect(!hidden("genre") && !hidden("preview") && hidden(TrackColumn.usbSyncID))
        coordinator.showAllColumns()
        #expect(hidden(TrackColumn.usbSyncID))
        withExtendedLifetime(window) {}
    }
}
