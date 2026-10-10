#if DEBUG
import AppKit
import AVFoundation
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// #255 USB 목록의 곡을 덱에 불러오기 확인(`--usb-deck-capture=<폴더> --usb-deck-mount=<마운트>`). #240과 같은 합성 라이브러리
/// (`UsbDragFixtureCapture`)를 내보낸 합성 디스크 이미지(DJCDECK) 하나만 쓰고 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`에서만 돈다.
/// USB 재생 목록 줄을 더블클릭해 짝인 로컬 곡을 덱에 올리고, 다른 줄을 골라 ⌘→로 올린다. 이어 USB 목록·USB 컬렉션·로컬 줄을 끌어
/// 덱 위에 놓고(`UsbDragCapture`의 끌기·놓기, 창 서버 세션 없이 SwiftUI 놓기 대상을 직접 부른다), Finder 음원도 놓아 본다.
/// 끌어 놓은 곡이 덱에 오르지 않으면 실패로 끝난다.
/// 경우마다 "덱 시험:" 줄을 남기고 이 프로세스의 주 창만 `screencapture -l`로 찍는다(앱 활성화 없음).
@MainActor
enum UsbDeckCapture {
    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let capture = args.first(where: { $0.hasPrefix("--usb-deck-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil,
              let mount = args.first(where: { $0.hasPrefix("--usb-deck-mount=") }).map({ String($0.dropFirst("--usb-deck-mount=".count)) })
        else { return }
        let directory = String(capture.dropFirst("--usb-deck-capture=".count))
        Task {
            do {
                _ = try UsbScratchPath.check(directory, as: .existingDirectory)
                _ = try UsbScratchPath.check(mount, as: .existingDirectory)
                try await run(store: store, directory: directory, mount: mount)
                FileHandle.standardOutput.write(Data("덱 시험 완료\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("덱 시험 실패: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data("덱 시험: \(line)\n".utf8))
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
        guard volume.isDiskImage, volume.name == "DJCDECK" else { throw Failure("합성 디스크 이미지(DJCDECK)가 아님") }
        let (events, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
        defer { continuation.finish() }
        let host = SystemUsbHost(io: UsbAppComposition.hostIO(snapshots: DJCPaths.userData.appending(path: "deck-usb-snapshots")), events: events,
                                 current: { [volume] })
        // 짝짓기 키는 읽은 합성 사본의 것(앱의 `UsbAppSetup.attach`와 같다)
        let keys = store.history.historyLocalKeys
        let usb = UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: UsbAppComposition.writeService(), localLibrary: { keys })
        store.usb = usb
        await usb.refresh()
        NSApp.appearance = NSAppearance(named: .aqua)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderBack(nil)
        window.setContentSize(NSSize(width: 1440, height: 900))
        let key = volume.usbKey
        guard let library = usb.libraries[key], let ga = library.playlists.first(where: { $0.name == "목록 가" }) else {
            throw Failure("합성 USB(DJCDECK)의 '목록 가'를 읽지 못했습니다")
        }
        log("짝 \(usb.localMatches[key]?.count ?? 0)곡")
        func settle(_ milliseconds: Int = 900) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
        store.sidebar = .usb(.playlist(volumeKey: key, id: ga.id))
        try await settle()
        guard let table = UsbDragCapture.views(in: content).compactMap({ $0 as? TrackListTableView }).first, let coordinator = table.coordinator else {
            throw Failure("곡 목록 표를 찾지 못했습니다")
        }
        func marks() -> String {
            guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "index" }) else { return "-" }
            return (0..<table.numberOfRows).map { row in
                (table.view(atColumn: column, row: row, makeIfNecessary: true) as? TrackIndexCell)?.deckSymbol == nil ? "·" : "▶"
            }.joined()
        }

        // 1. USB 재생 목록의 둘째 줄을 더블클릭한다 → 짝인 로컬 곡이 덱에 오르고 USB 줄 # 칸에 덱 표시
        table.selectRowIndexes([1], byExtendingSelection: false)
        coordinator.doubleClicked(row: 1, column: "title")
        try await settle(2500)
        log("1 더블클릭: 덱 곡 \(store.deckTrackID ?? "-") · USB 줄 덱 표시 [\(marks())] · 안내 \(store.staging.stagingMessage?.text ?? "-")")
        try UsbDragCapture.captureWindow(window, to: directory + "/usb-playlist-deck-loaded.jpg")

        // 2. 넷째 줄을 골라 ⌘→(덱 메뉴 '고른 곡 덱에 불러오기')로 올린다
        table.selectRowIndexes([3], byExtendingSelection: false)
        try await settle(300)
        let enabled = store.canLoadSelectionToDeck
        store.loadSelectionToDeck()
        try await settle(2500)
        log("2 ⌘→: 메뉴 켜짐 \(enabled) · 덱 곡 \(store.deckTrackID ?? "-") · USB 줄 덱 표시 [\(marks())]")
        try UsbDragCapture.captureWindow(window, to: directory + "/usb-playlist-deck-selection.jpg")

        // 3~5. 곡 줄을 눌러 끌어 덱 위에 놓는다: 표가 만든 끌 항목을 덱 놓기 대상(SwiftUI `onDrop`)의 실제 놓기 메서드에 넘긴다.
        // 더블클릭처럼 짝인 로컬 곡(로컬 줄은 그 곡)이 덱에 올라야 한다. 전에는 USB 줄을 놓아도 덱이 그대로였다(#255)
        func deckPoint() throws -> NSPoint {
            guard let list = UsbDragCapture.views(in: content).compactMap({ $0 as? TrackListTableView }).first?.enclosingScrollView else {
                throw Failure("곡 목록 표를 찾지 못했습니다")
            }
            // 덱은 곡 목록 바로 위에 있다
            let frame = list.convert(list.bounds, to: nil)
            return NSPoint(x: frame.midX, y: frame.maxY + 60)
        }
        func dragToDeck(_ step: String, _ item: SidebarItem, row: Int, capture: String) async throws {
            store.sidebar = item
            try await settle()
            guard let table = UsbDragCapture.views(in: content).compactMap({ $0 as? TrackListTableView }).first,
                  store.displayRows.indices.contains(row) else { throw Failure("곡 목록 표를 찾지 못했습니다") }
            let source = store.displayRows[row]
            let expected = source.isUsb ? UsbDeckLoad.localContentID(usbTrackID: source.track.id, matches: usb.localMatches) : source.track.id
            guard let expected, expected != store.deckTrackID else { throw Failure("\(step): 덱에 이미 있거나 짝 없는 줄을 골랐습니다") }
            table.selectRowIndexes([row], byExtendingSelection: false)
            store.staging.stagingMessage = nil
            let dragged = await UsbDragCapture.drag(table, row: row)
            let dropped = try await UsbDragCapture.drop(dragged, at: try deckPoint(), in: window)
            try await settle(2500)
            await dragged.end()
            log("\(step): \(source.title) 끌기 \(dragged.summary) · 놓기 \(dropped) · 덱 곡 \(store.deckTrackID ?? "-")(기대 \(expected)) · 안내 \(store.staging.stagingMessage?.text ?? "-")")
            try UsbDragCapture.captureWindow(window, to: directory + "/" + capture + ".jpg")
            guard store.deckTrackID == expected else { throw Failure("\(step): 덱에 \(expected)가 오르지 않았습니다") }
        }
        try await dragToDeck("3 USB 목록 줄 끌기", .usb(.playlist(volumeKey: key, id: ga.id)), row: 0, capture: "usb-playlist-deck-dropped")
        try await dragToDeck("4 USB 컬렉션 줄 끌기", .usb(.collection(volumeKey: key)), row: 4, capture: "usb-collection-deck-dropped")
        try await dragToDeck("5 로컬 줄 끌기", .filter(.all), row: 6, capture: "local-deck-dropped")

        // 6. Finder 음원(파일 주소만)을 덱 위에 놓으면 덱은 그대로 두고 추가한 곡으로 넘긴다
        let audio = URL(filePath: directory).appending(path: "finder-drop.wav")
        try? FileManager.default.removeItem(at: audio)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        silence.frameLength = 44_100
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: silence)
        let deckBefore = store.deckTrackID, stagedBefore = store.staging.staged.count
        let file = UsbDragCapture.Dragged(started: true, items: [[NSPasteboard.PasteboardType.fileURL.rawValue: audio.absoluteString]], writers: [])
        let dropped = try await UsbDragCapture.drop(file, at: try deckPoint(), in: window)
        for _ in 0..<50 where store.staging.staged.count == stagedBefore { try await settle(200) }
        log("6 Finder 음원 놓기: 놓기 \(dropped) · 덱 곡 \(store.deckTrackID ?? "-") · 추가한 곡 \(stagedBefore)→\(store.staging.staged.count) · 안내 \(store.staging.stagingMessage?.text ?? "-")")
        guard store.deckTrackID == deckBefore, store.staging.staged.count == stagedBefore + 1 else { throw Failure("6: Finder 음원이 추가한 곡으로 가지 않았습니다") }
    }
}
#endif
