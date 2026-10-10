#if DEBUG
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// #240 USB 끌어 놓기 재현·확인(`--usb-drag-capture=<폴더> --usb-drag-mount=<마운트>`). 합성 라이브러리(`UsbDragFixtureCapture`)와
/// 붙어 있는 합성 디스크 이미지(DJCDRAG) 하나만 쓰고 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`에서만 돈다.
/// 사용자 커서와 창 서버 끌기 세션은 쓰지 않는다: 곡 목록 표에는 실제 mouseDown 추적 루프가 읽을 끌기 이벤트를 넣고, 표가 끌기를 시작하면
/// 창 서버로 보내는 대신 표가 만든 끌 항목을 받는다(`dragSessionInterceptor`). 놓을 곳에는 그 항목을 담은 페이스트보드로
/// AppKit·SwiftUI의 실제 놓기 메서드(draggingEntered → performDragOperation)를 부른다. 경우마다 "끌기 시험:" 줄을 남기고,
/// 이 프로세스의 주 창만 `screencapture -l`로 찍는다(앱 활성화 없음).
@MainActor
enum UsbDragCapture {
    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let capture = args.first(where: { $0.hasPrefix("--usb-drag-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil,
              let mount = args.first(where: { $0.hasPrefix("--usb-drag-mount=") }).map({ String($0.dropFirst("--usb-drag-mount=".count)) })
        else { return }
        let directory = String(capture.dropFirst("--usb-drag-capture=".count))
        Task {
            do {
                _ = try UsbScratchPath.check(directory, as: .existingDirectory)
                _ = try UsbScratchPath.check(mount, as: .existingDirectory)
                try await run(store: store, directory: directory, mount: mount)
                FileHandle.standardOutput.write(Data("끌기 시험 완료\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("끌기 시험 실패: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data("끌기 시험: \(line)\n".utf8))
    }

    private static func run(store: LibraryStore, directory: String, mount: String) async throws {
        for _ in 0..<200 {
            if case .loaded = store.phase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard store.rows.count == 8, store.rows.allSatisfy({ $0.title.hasPrefix("끌기 시험 ") }),
              let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }), let content = window.contentView else {
            throw Failure("합성 라이브러리(UsbDragFixtureCapture)·주 창을 확인하세요")
        }
        let volume = try await BlockingWork.run(qos: .default) { try UsbVolumes.info(root: URL(filePath: mount)) }
        guard volume.isDiskImage, volume.name == "DJCDRAG" else { throw Failure("합성 디스크 이미지(DJCDRAG)가 아님") }
        let (events, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
        defer { continuation.finish() }
        let host = SystemUsbHost(io: UsbAppComposition.hostIO(snapshots: DJCPaths.userData.appending(path: "drag-usb-snapshots")), events: events,
                                 current: { [volume] })
        let usb = UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: UsbAppComposition.writeService(), localLibrary: { nil })
        usb.drafts = .live(directory: DJCPaths.usbDrafts)
        store.usb = usb
        await usb.refresh()
        NSApp.appearance = NSAppearance(named: .aqua)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderBack(nil)
        window.setContentSize(NSSize(width: 1440, height: 900))
        let key = volume.usbKey
        guard let library = usb.libraries[key],
              let ga = library.playlists.first(where: { $0.name == "목록 가" }), let na = library.playlists.first(where: { $0.name == "목록 나" })
        else { throw Failure("합성 USB(DJCDRAG)의 '목록 가'·'목록 나'를 읽지 못했습니다") }
        func path(_ name: String) -> String { directory + "/" + name + ".jpg" }
        func settle() async throws { try await Task.sleep(for: .milliseconds(900)) }
        func show(_ item: SidebarItem) async throws -> TrackListTableView {
            store.sidebar = item
            try await settle()
            guard let table = views(in: content).compactMap({ $0 as? TrackListTableView }).first else { throw Failure("곡 목록 표를 찾지 못했습니다") }
            return table
        }
        func usbDrafts() -> [UsbLibraryEdit] { usb.draftEdits[key] ?? [] }
        func titles(_ table: TrackListTableView) -> String {
            (0..<table.numberOfRows).compactMap { index in
                store.displayRows.indices.contains(index) ? store.displayRows[index].title.replacingOccurrences(of: "끌기 시험 ", with: "") : nil
            }.joined(separator: ",")
        }
        func selected(_ table: TrackListTableView) -> String {
            table.selectedRowIndexes.map { String($0 + 1) }.joined(separator: ",")
        }

        // 사이드바 줄 자리: 사이드바 표의 줄을 하나씩 골라 고른 대상(`store.sidebar`)이 되는 줄을 찾는다(SwiftUI 줄에는 글자 뷰가 없다)
        let sidebars = views(in: content).compactMap { $0 as? NSOutlineView }.filter { !($0 is TrackListTableView) }
        log("사이드바 표 \(sidebars.count)개: \(sidebars.map { "\(type(of: $0)) \($0.numberOfRows)줄" })")
        let local = SidebarItem.playlist("2403")
        let usbNa = SidebarItem.usb(.playlist(volumeKey: key, id: na.id)), usbCollection = SidebarItem.usb(.collection(volumeKey: key))
        var targets: [SidebarItem: NSPoint] = [:]
        for sidebar in sidebars { for index in 0..<sidebar.numberOfRows where targets.count < 3 {
            store.sidebar = .filter(.all)
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try await Task.sleep(for: .milliseconds(120))
            let item = store.sidebar
            guard [local, usbNa, usbCollection].contains(item), targets[item] == nil else { continue }
            let rect = sidebar.rect(ofRow: index)
            targets[item] = sidebar.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
            log("사이드바 줄 \(index): \(item)")
        } }
        guard targets.count == 3 else { throw Failure("사이드바에서 놓을 줄을 찾지 못했습니다: \(targets.keys)") }

        // 1. 기준(#38): 로컬 곡 두 개 → 로컬 '빈 목록'
        var table = try await show(.filter(.all))
        table.selectRowIndexes([4, 5], byExtendingSelection: false)
        var dragged = await drag(table, row: 5)
        log("1 로컬 곡 → 로컬 목록: 끌기 \(dragged.summary) · 선택 [\(selected(table))]")
        var dropped = try await drop(dragged, at: targets[local]!, in: window)
        try await settle()
        await dragged.end()
        log("1 로컬 곡 → 로컬 목록: 놓기 \(dropped) · '빈 목록' 곡 \(store.playlistItem("2403")?.entries.count ?? -1)개")

        // 2. 로컬 곡 두 개 → USB '목록 나'
        table.selectRowIndexes([6, 7], byExtendingSelection: false)
        dragged = await drag(table, row: 7)
        var before = usbDrafts().count
        dropped = try await drop(dragged, at: targets[usbNa]!, in: window)
        _ = await waitUntil { usbDrafts().count != before }
        await dragged.end()
        log("실행 취소 묶음 깊이 \(store.undoManager?.groupingLevel ?? -1) · \(store.undoManager?.undoActionName ?? "-")")
        log("2 로컬 곡 → USB 목록: 끌기 \(dragged.summary) · 놓기 \(dropped) · USB 초안 \(before)→\(usbDrafts().count)건 \(lastEdit(usbDrafts(), library))")

        // 3. USB '목록 가'에서 두 곡을 골라 끈다(고른 줄을 다시 누르고 끈다)
        table = try await show(.usb(.playlist(volumeKey: key, id: ga.id)))
        table.selectRowIndexes([1, 3], byExtendingSelection: false)
        try await settle()
        try captureWindow(window, to: path("usb-playlist-selected"))
        log("3 USB 목록 다중 선택: 끌기 전 순서 [\(titles(table))] · 선택 [\(selected(table))]")
        dragged = await drag(table, row: 3)
        log("3 USB 목록 다중 선택: 끌기 \(dragged.summary) · 끈 뒤 선택 [\(selected(table))] · 숨은 줄 \(Array(table.hiddenRowIndexes))")

        // 4. 그 두 곡을 목록 맨 위로(같은 목록 안 순서 바꾸기)
        before = usbDrafts().count
        let top = table.rect(ofRow: 0)
        dropped = try await drop(dragged, at: table.convert(NSPoint(x: top.minX + 200, y: top.minY + 2), to: nil), in: window, source: table)
        _ = await waitUntil { usbDrafts().count != before }
        await dragged.end()
        try await settle()
        log("4 USB 목록 순서 바꾸기: 놓기 \(dropped) · USB 초안 \(before)→\(usbDrafts().count)건 \(lastEdit(usbDrafts(), library)) · 보이는 순서 [\(titles(table))]")
        try captureWindow(window, to: path("usb-playlist-after-drop"))
        log("실행 취소 묶음 깊이 \(store.undoManager?.groupingLevel ?? -1) · \(store.undoManager?.undoActionName ?? "-")")
        if usbDrafts().count > before, let undo = store.undoManager, undo.canUndo {
            let title = undo.undoMenuItemTitle
            undo.undo()
            _ = await waitUntil { usbDrafts().count == before }
            try await settle()
            log("4 실행 취소(\(title)): USB 초안 \(usbDrafts().count)건 · 보이는 순서 [\(titles(table))]")
            undo.redo()
            _ = await waitUntil { usbDrafts().count == before + 1 }
            try await settle()
            log("4 실행 복귀: USB 초안 \(usbDrafts().count)건 · 보이는 순서 [\(titles(table))]")
        }

        // 5. USB 컬렉션의 두 곡 → USB '목록 나'
        table = try await show(usbCollection)
        table.selectRowIndexes([0, 1], byExtendingSelection: false)
        dragged = await drag(table, row: 1)
        before = usbDrafts().count
        dropped = try await drop(dragged, at: targets[usbNa]!, in: window)
        _ = await waitUntil { usbDrafts().count != before }
        log("5 USB 곡 → 다른 USB 목록: 끌기 \(dragged.summary) · 놓기 \(dropped) · USB 초안 \(before)→\(usbDrafts().count)건 \(lastEdit(usbDrafts(), library))")

        // 6·7. 받지 않을 곳: 로컬 목록, 같은 USB 컬렉션
        let localBefore = store.playlistItem("2403")?.entries.count ?? -1
        before = usbDrafts().count
        dropped = try await drop(dragged, at: targets[local]!, in: window)
        try await settle()
        log("6 USB 곡 → 로컬 목록: 놓기 \(dropped) · '빈 목록' 곡 \(localBefore)→\(store.playlistItem("2403")?.entries.count ?? -1)개 · USB 초안 \(usbDrafts().count)건")
        dropped = try await drop(dragged, at: targets[usbCollection]!, in: window)
        try await settle()
        await dragged.end()
        log("7 USB 곡 → 같은 USB 컬렉션: 놓기 \(dropped) · USB 초안 \(before)→\(usbDrafts().count)건")

        // 8. 끌 수 없는 USB 줄(초안을 받지 않는 볼륨): 끌기가 시작되지 않을 때 고른 줄이 숨지 않는다
        let drafts = usb.drafts
        usb.drafts = nil
        table = try await show(.usb(.playlist(volumeKey: key, id: ga.id)))
        table.selectRowIndexes([1, 3], byExtendingSelection: false)
        // 앞선 끌기가 순서를 바꿀 수 있는 목록이었으면 표는 간격 표시인 채로 남아 있다
        table.draggingDestinationFeedbackStyle = .gap
        dragged = await drag(table, row: 3)
        try await settle()
        log("8 초안을 받지 않는 USB 목록: 끌기 \(dragged.summary) · 선택 [\(selected(table))] · 숨은 줄 \(Array(table.hiddenRowIndexes))")
        try captureWindow(window, to: path("usb-playlist-not-draggable"))
        await dragged.end()
        usb.drafts = drafts

        _ = try await show(.usb(.playlist(volumeKey: key, id: na.id)))
        try captureWindow(window, to: path("usb-playlist-na"))
        store.sidebar = .usb(.pending(volumeKey: key))
        try await settle()
        try captureWindow(window, to: path("usb-pending"))
        for (index, edit) in usbDrafts().enumerated() { log("쓰기 대기 \(index + 1): \(UsbEditText.describe(edit, library: library))") }
    }

    private static func lastEdit(_ edits: [UsbLibraryEdit], _ library: UsbLibrary) -> String {
        edits.last.map { "(\(UsbEditText.describe($0, library: library)))" } ?? ""
    }

    // MARK: 끌기

    @MainActor
    struct Dragged {
        var started: Bool
        /// 항목마다 형식 → 글자
        var items: [[String: String]]
        var writers: [any NSPasteboardWriting]
        var session: NSDraggingSession?
        weak var table: NSTableView?

        /// 창 서버가 세션을 끝내면 표에 알리는 것과 같게(간격 표시로 숨긴 줄을 다시 보인다)
        func end() async {
            guard let session, let table else { return }
            let box = UncheckedBox((session, table))
            await UsbDragCapture.onRunLoop { (box.value.1 as NSDraggingSource).draggingSession?(box.value.0, endedAt: .zero, operation: .move) }
        }

        var summary: String {
            guard started else { return "시작 안 됨" }
            let types = Set(items.flatMap(\.keys)).map { $0.replacingOccurrences(of: "com.djcrate.", with: "") }.sorted()
            let ids = items.map { $0.first { $0.key.hasSuffix("track-ids") }?.value ?? "-" }
            return "\(items.count)개 [\(ids.joined(separator: " | "))] 형식 \(types)"
        }
    }

    /// 표의 줄을 눌러 끈다: mouseDown 추적 루프가 읽을 끌기·떼기 이벤트를 먼저 넣고 mouseDown을 부른다.
    /// 표가 끌기를 시작하면 창 서버 세션 대신 표가 만든 끌 항목을 받는다
    private static func drag(_ table: TrackListTableView, row: Int) async -> Dragged {
        let box = await onRunLoop { UncheckedBox(dragNow(table, row: row)) }
        return box.value
    }

    private static func dragNow(_ table: TrackListTableView, row: Int) -> Dragged {
        guard let window = table.window else { return Dragged(started: false, items: [], writers: []) }
        let rect = table.rect(ofRow: row)
        let start = table.convert(NSPoint(x: rect.minX + 200, y: rect.midY), to: nil)
        var captured: [NSDraggingItem]?
        var started: NSDraggingSession?
        table.dragSessionInterceptor = { [weak table] items in
            captured = items
            let session = (NSDraggingSession.self as NSObject.Type).init() as! NSDraggingSession
            started = session
            // 창 서버가 세션을 시작하면 표에 알리는 것과 같게(표가 끄는 줄로 대리자를 부른다)
            if let table { (table as NSDraggingSource).draggingSession?(session, willBeginAt: start) }
            return session
        }
        defer { table.dragSessionInterceptor = nil }
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ step: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + step, y: start.y - step), modifierFlags: [], timestamp: time + step / 1000,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        for step in 1...12 { if let moved = event(.leftMouseDragged, CGFloat(step * 4)) { NSApp.postEvent(moved, atStart: false) } }
        if let up = event(.leftMouseUp, 48) { NSApp.postEvent(up, atStart: false) }
        guard let down = event(.leftMouseDown, 0) else { return Dragged(started: false, items: [], writers: []) }
        table.mouseDown(with: down)
        // 끌기를 시작해 추적 루프가 일찍 끝났으면 남은 이벤트를 버린다
        if let late = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: time + 10, windowNumber: 0,
                                         context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.discardEvents(matching: [.leftMouseDragged, .leftMouseUp], before: late)
        }
        guard let captured else { return Dragged(started: false, items: [], writers: []) }
        let writers = captured.compactMap { $0.item as? any NSPasteboardWriting }
        let items = writers.map { writer -> [String: String] in
            guard let item = writer as? NSPasteboardItem else { return [:] }
            return Dictionary(item.types.compactMap { type in item.string(forType: type).map { (type.rawValue, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        return Dragged(started: true, items: items, writers: writers, session: started, table: table)
    }

    // MARK: 놓기

    /// 끈 항목을 담은 페이스트보드로 그 자리의 놓기 대상(등록한 형식이 있는 가장 안쪽 뷰)에 끌어 들어가 놓는다. 받았는지 글로 돌려준다
    private static func drop(_ dragged: Dragged, at point: NSPoint, in window: NSWindow, source: Any? = nil) async throws -> String {
        guard dragged.started else { return "끌 항목 없음" }
        guard let content = window.contentView else { throw Failure("창 내용이 없습니다") }
        var view = content.hitTest(point)
        while let current = view, current.registeredDraggedTypes.isEmpty { view = current.superview }
        guard let destination = view else { return "놓기 대상 없음" }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.djcrate.drag-capture.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        // 항목은 페이스트보드 하나에만 속한다: 같은 끌기를 여러 곳에 놓아 보므로 놓을 때마다 새 항목을 만든다
        pasteboard.writeObjects(dragged.items.map { values in
            let item = NSPasteboardItem()
            for (type, value) in values { item.setString(value, forType: NSPasteboard.PasteboardType(type)) }
            return item
        })
        let info = CaptureDraggingInfo(window: window, location: point, pasteboard: pasteboard, source: source)
        let target = UncheckedBox(destination as any NSDraggingDestination)
        let updated = await onRunLoop {
            let entered = target.value.draggingEntered?(info) ?? []
            return (target.value.draggingUpdated?(info) ?? entered).rawValue
        }
        try await Task.sleep(for: .milliseconds(150))
        guard updated != 0 else {
            await onRunLoop { target.value.draggingExited?(info) }
            keptInfos.append(info)
            nudgeEventLoop()
            return "받지 않음(\(type(of: destination)))"
        }
        let performed = await onRunLoop {
            let prepared = target.value.prepareForDragOperation?(info) ?? true
            let performed = prepared && (target.value.performDragOperation?(info) ?? false)
            target.value.concludeDragOperation?(info)
            target.value.draggingEnded?(info)
            return performed
        }
        // 실제 끌기 세션처럼 끌기 정보를 붙잡아 둔다(SwiftUI가 놓은 뒤에도 잠깐 들고 있다)
        keptInfos.append(info)
        nudgeEventLoop()
        try await Task.sleep(for: .milliseconds(150))
        return performed ? "받음(\(type(of: destination)))" : "놓기 실패(\(type(of: destination)))"
    }

    private static var keptInfos: [CaptureDraggingInfo] = []

    /// 놓기 대상에 넘길 끌기 정보(창 서버 세션 없이)
    @MainActor
    private final class CaptureDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation = [.copy, .move, .generic]
        let draggingLocation: NSPoint
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        let draggingPasteboard: NSPasteboard
        let draggingSource: Any?
        let draggingSequenceNumber = Int.random(in: 1_000...1_000_000)
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard, source: Any?) {
            draggingDestinationWindow = window
            draggingLocation = location
            draggingPasteboard = pasteboard
            draggingSource = source
            numberOfValidItemsForDrop = pasteboard.pasteboardItems?.count ?? 0
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        func resetSpringLoading() {}

        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
            guard classArray.contains(where: { $0 == NSPasteboardItem.self }) else { return }
            var stop: ObjCBool = false
            for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
                block(NSDraggingItem(pasteboardWriter: item), index, &stop)
                if stop.boolValue { break }
            }
        }
    }

    // MARK: 도움

    /// AppKit 추적 루프·놓기 메서드는 실제 이벤트처럼 실행 루프 차례에서 부른다. 실행 중인 Swift 작업 안에서 부르면 중첩 실행 루프가
    /// 다른 메인 액터 작업을 그 안에서 돌려 실행자 상태가 깨진다(이 시험에서 SwiftUI 배치 중에 죽었다)
    private static func onRunLoop<T: Sendable>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { continuation.resume(returning: body()) } }
        }
    }

    /// 앱 이벤트 하나를 넣는다. 실행 취소 관리자의 자동 묶음은 이벤트를 처리할 때 닫힌다(사용자 입력이 없는 이 시험에서는 안 닫혀
    /// 뒤 동작이 모두 한 묶음이 됐다). 실제 앱에서는 놓은 뒤의 마우스 이동 등이 이 일을 한다
    private static func nudgeEventLoop() {
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                             subtype: 0, data1: 0, data2: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private struct UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views(in:)) }

    /// 손쉬운 사용 요소 아래의 이름·값 글자(SwiftUI 요소는 비공식 속성 API로만 읽힌다)
    private static func axTexts(_ element: Any, depth: Int = 0) -> [String] {
        guard let object = element as? NSObject, depth < 8 else { return [] }
        let own = [NSAccessibility.Attribute.title, .description, .value].compactMap { object.accessibilityAttributeValue($0) as? String }
            .filter { !$0.isEmpty }
        let children = object.accessibilityAttributeValue(.children) as? [Any] ?? []
        return own + children.flatMap { axTexts($0, depth: depth + 1) }
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    static func captureWindow(_ window: NSWindow, to path: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(window.windowNumber), path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("창 캡처 실패: \(path)") }
    }
}
#endif
