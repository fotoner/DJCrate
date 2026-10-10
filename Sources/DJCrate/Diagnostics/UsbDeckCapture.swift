#if DEBUG
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// #255 USB 목록의 곡을 덱에 불러오기 확인(`--usb-deck-capture=<폴더> --usb-deck-mount=<마운트>`). #240과 같은 합성 라이브러리
/// (`UsbDragFixtureCapture`)를 내보낸 합성 디스크 이미지(DJCDECK) 하나만 쓰고 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`에서만 돈다.
/// USB 재생 목록 줄을 더블클릭해 짝인 로컬 곡을 덱에 올리고, 다른 줄을 골라 ⌘→로 올린다. 덱 위에 끌어 놓기는 SwiftUI `onDrop`이라
/// 창 서버 세션 없이는 부를 수 없어 여기서 보지 않는다(받는 곳 `loadDroppedUsbTracks`는 `UsbDeckLoadTests`가 본다).
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
        log("1 더블클릭: 덱 곡 \(store.deckTrackID ?? "-") · USB 줄 덱 표시 [\(marks())] · 안내 \(store.stagingMessage?.text ?? "-")")
        try UsbDragCapture.captureWindow(window, to: directory + "/usb-playlist-deck-loaded.jpg")

        // 2. 넷째 줄을 골라 ⌘→(덱 메뉴 '고른 곡 덱에 불러오기')로 올린다
        table.selectRowIndexes([3], byExtendingSelection: false)
        try await settle(300)
        let enabled = store.canLoadSelectionToDeck
        store.loadSelectionToDeck()
        try await settle(2500)
        log("2 ⌘→: 메뉴 켜짐 \(enabled) · 덱 곡 \(store.deckTrackID ?? "-") · USB 줄 덱 표시 [\(marks())]")
        try UsbDragCapture.captureWindow(window, to: directory + "/usb-playlist-deck-selection.jpg")
    }
}
#endif
