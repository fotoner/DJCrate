#if DEBUG
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// #237 변경 전·후 실제 앱 화면 기록(`--issue237-capture=<폴더>`). 합성 라이브러리(레이아웃 시험)와 붙어 있는 합성 USB 디스크 이미지만 쓰고
/// 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`에서만 돈다. 앱 활성화·물리 입력 없이 이 프로세스의 창과 팝업 메뉴 창만 `screencapture -l`로 찍는다
/// (메뉴는 앱 안에서 `NSMenu.popUp`으로 열고 그 메뉴 창 번호만 기록한다).
/// 이 Mac에 붙어 있는 다른 디스크 이미지가 화면에 섞이지 않게 `--issue237-usb-mount=<마운트>` 볼륨 하나만 읽는 USB 절로 바꾼다.
/// 장면: 툴바·쓰기 대기 목록(쓰기 대기 바)·메뉴(rekordbox)·곡 우클릭 메뉴·쓰기 결과 토스트, USB 쓰기 대기(초안 버리기)·편집 메뉴(실행 취소).
@MainActor
enum Issue237Capture {
    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let capture = args.first(where: { $0.hasPrefix("--issue237-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        let directory = String(capture.dropFirst("--issue237-capture=".count))
        guard let mount = args.first(where: { $0.hasPrefix("--issue237-usb-mount=") }).map({ String($0.dropFirst("--issue237-usb-mount=".count)) }) else { return }
        Task {
            do {
                _ = try UsbScratchPath.check(directory, as: .existingDirectory)
                _ = try UsbScratchPath.check(mount, as: .existingDirectory)
                try await run(store: store, directory: directory, mount: mount)
                FileHandle.standardOutput.write(Data("#237 캡처 완료\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("#237 캡처 실패: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private static func run(store: LibraryStore, directory: String, mount: String) async throws {
        for _ in 0..<200 {
            if case .loaded = store.phase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !store.rows.isEmpty, store.rows.allSatisfy({ $0.title.hasPrefix("레이아웃 시험 ") }),
              let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }), let content = window.contentView else {
            throw Failure("합성 라이브러리·주 창을 확인하세요")
        }
        let volume = try await Task.detached { try UsbVolumes.info(root: URL(filePath: mount)) }.value
        guard volume.isDiskImage, volume.name == "DJCDEMO" else { throw Failure("합성 디스크 이미지(DJCDEMO)가 아님") }
        let (events, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
        defer { continuation.finish() }
        let host = SystemUsbHost(io: UsbAppComposition.hostIO(snapshots: DJCPaths.userData.appending(path: "issue237-usb-snapshots")), events: events, current: { [volume] })
        let usb = UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: UsbAppComposition.writeService(), localLibrary: { nil })
        usb.drafts = .live(directory: DJCPaths.usbDrafts)
        store.usb = usb
        await usb.refresh()
        NSApp.appearance = NSAppearance(named: .aqua)
        // 메뉴는 화면에 보이는 창에서만 열린다: 지금 보는 데스크톱으로 옮기고 다른 창 뒤에 둔다(앱은 활성화하지 않는다)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderBack(nil)
        window.setContentSize(NSSize(width: 1440, height: 900))
        func path(_ name: String) -> String { directory + "/" + name + ".jpg" }
        func settle() async throws { try await Task.sleep(for: .milliseconds(900)) }

        // 쓰기 대기: 큐 초안 3곡, 앞의 두 곡을 고른다
        for row in store.rows.prefix(3) {
            var draft = CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues)
            draft.cues.append(EditableCue(id: UUID(), kind: .memory, time: 10, name: "합성 큐"))
            try CueDraftStore.save(draft)
            store.cueDraftChanged(draft)
        }
        store.selection = Set(store.rows.prefix(2).map(\.id))
        try await settle()
        try captureWindow(window, to: path("toolbar"))

        if let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.items.contains { $0.title.hasPrefix("rekordbox에 쓰기") } }) {
            try await captureMenu(menu, in: content, at: NSPoint(x: 40, y: content.isFlipped ? 40 : content.bounds.height - 40), to: path("menu-rekordbox"))
        } else {
            throw Failure("rekordbox 메뉴를 찾지 못했습니다")
        }

        guard let table = findTable(in: content), let context = table.menu else { throw Failure("곡 목록 표·우클릭 메뉴를 찾지 못했습니다") }
        context.delegate?.menuNeedsUpdate?(context)
        let rowRect = table.rect(ofRow: 0)
        try await captureMenu(context, in: table, at: NSPoint(x: min(rowRect.midX, 520), y: rowRect.midY), to: path("menu-context"))

        let backup = DJCPaths.userData.appending(path: "synthetic-backup")
        store.lastWriteBackup = backup
        store.toast = AppToast(kind: .warning, title: String(ui: "일부 곡을 썼습니다"),
                               detail: String(ui: "합성 데이터의 화면 배치 시험입니다"), undoBackup: backup)
        try await settle()
        try captureWindow(window, to: path("toast"))
        store.toast = nil

        store.sidebar = .pending
        try await settle()
        try captureWindow(window, to: path("pending-bar"))

        // USB: 붙어 있는 합성 디스크 이미지 한 개의 곡 2개 빼기 초안
        let key = volume.usbKey
        guard let library = usb.libraries[key], var actions = store.usbEdits else { throw Failure("합성 USB(DJCDEMO)를 읽지 못했습니다") }
        let rows = UsbLibraryRows.collection(library: library, volumeKey: key, mountPoint: volume.mountPoint, badges: [:])
        await actions.removeTracks(Array(rows.prefix(2)), volumeKey: key)
        guard let count = usb.draftCounts[key], count > 0 else { throw Failure("USB 초안이 쌓이지 않았습니다") }
        store.sidebar = .usb(.pending(volumeKey: key))
        try await settle()
        try captureWindow(window, to: path("usb-pending"))

        // 초안 버리기: 변경 전에는 확인 창(그 창을 기록하고 취소), 변경 뒤에는 바로 버린다
        let prompter = AlertCapturePrompter(path: path("usb-discard-alert"))
        actions.prompter = prompter
        await actions.discardDraft(volumeKey: key)
        if let failure = prompter.failure { throw failure }
        let discarded = (usb.draftCounts[key] ?? 0) == 0
        FileHandle.standardOutput.write(Data("#237 초안 버리기: 확인 창 \(prompter.asked ? "떴음" : "없음") · 초안 \(count)건 → \(usb.draftCounts[key] ?? 0)건\n".utf8))
        if discarded {
            try await settle()
            try captureWindow(window, to: path("usb-discarded"))
            let undo = store.undoManager
            FileHandle.standardOutput.write(Data("#237 편집 메뉴 실행 취소 제목: \(undo?.undoMenuItemTitle ?? "-") · canUndo \(undo?.canUndo ?? false)\n".utf8))
            if let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.items.contains { $0.action == Selector(("undo:")) } }) {
                try await captureMenu(edit, in: content, at: NSPoint(x: 120, y: content.isFlipped ? 40 : content.bounds.height - 40), to: path("menu-edit-undo"))
            }
            undo?.undo()
            try await Task.sleep(for: .milliseconds(1500))
            FileHandle.standardOutput.write(Data("#237 실행 취소 뒤 초안 \(usb.draftCounts[key] ?? 0)건\n".utf8))
            try captureWindow(window, to: path("usb-restored"))
        }
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews { if let found = findTable(in: sub) { return found } }
        return nil
    }

    /// 확인 창을 실제 NSAlert로 그려 기록하고 취소한다. 물리 입력·모달은 쓰지 않는다.
    private final class AlertCapturePrompter: HeadlessReflectionPrompter {
        let path: String
        var asked = false
        var failure: (any Error)?

        init(path: String) { self.path = path }

        func show(_ prompt: ReflectionPrompt) -> Bool {
            asked = true
            let alert = AlertPrompter().makeAlert(prompt)
            alert.layout()
            alert.window.orderBack(nil)
            alert.window.displayIfNeeded()
            defer { alert.window.orderOut(nil) }
            do { try Issue237Capture.captureWindow(alert.window, to: path) } catch { failure = error }
            return false
        }

        func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice { .cancel }
    }

    private static func captureWindow(_ window: NSWindow, to path: String) throws {
        try screencapture(windowNumber: window.windowNumber, to: path)
    }

    /// 메뉴를 팝업으로 열어 두고 그 메뉴 창만 기록한 뒤 닫는다. 팝업이 열려 있는 동안 메인 큐는 돌지 않아 기록은 다른 스레드가 하고,
    /// 닫기만 메인 실행 루프(추적 모드 포함)에 맡긴다. 비활성 앱은 메뉴를 열지 못해 열려 있는 동안만 활성화한다
    private static func captureMenu(_ menu: NSMenu, in view: NSView, at point: NSPoint, to path: String) async throws {
        guard let window = view.window else { throw Failure("창이 없습니다") }
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(600))
        let result = ThreadResult()
        Thread.detachNewThread {
            var id: Int?
            for _ in 0..<15 {
                Thread.sleep(forTimeInterval: 0.2)
                id = menuWindowNumbers().first
                if id != nil { break }
            }
            Thread.sleep(forTimeInterval: 0.3)
            if let id {
                do { try screencapture(windowNumber: id, to: path) } catch { result.failure = error }
            } else {
                result.failure = Failure("메뉴 창을 찾지 못했습니다: \(path)")
            }
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { menu.cancelTracking() }
            CFRunLoopWakeUp(main)
        }
        if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        NSApp.deactivate()
        try await Task.sleep(for: .milliseconds(800))
        if let failure = result.failure { throw failure }
    }

    private final class ThreadResult: @unchecked Sendable {
        var failure: (any Error)?
    }

    /// 이 프로세스의 화면에 보이는 메뉴 수준(≥ 101) 창 번호, 큰 것부터
    nonisolated private static func menuWindowNumbers() -> [Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 101 }
            .sorted {
                func area(_ w: [String: Any]) -> Double {
                    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
                    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
                }
                return area($0) > area($1)
            }
            .compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    nonisolated private static func screencapture(windowNumber: Int, to path: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(windowNumber), path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("창 캡처 실패: \(path)") }
    }
}
#endif
