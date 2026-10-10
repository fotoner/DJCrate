#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// #241 곡 목록 머리글 기록(`--column-header-capture=<폴더> --column-header-usb-mount=<합성 디스크 이미지 마운트>`).
/// 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`의 합성 라이브러리와 합성 디스크 이미지 볼륨 하나만 읽는다(USB 절을 그 볼륨으로 바꾼다).
/// 로컬 목록 → USB 목록 → USB 쓰기 대기 → USB 목록 → 로컬 목록으로 오가며 창만 `screencapture -l`로 찍고, 칸마다 순서·숨김·머리글 자리를 출력한다.
@MainActor
enum ColumnHeaderCapture {
    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let capture = args.first(where: { $0.hasPrefix("--column-header-capture=") }),
              let mount = args.first(where: { $0.hasPrefix("--column-header-usb-mount=") })
                .map({ String($0.dropFirst("--column-header-usb-mount=".count)) }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              let rekordbox = ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] else { return }
        let directory = String(capture.dropFirst("--column-header-capture=".count))
        Task {
            do {
                for path in [directory, mount, rekordbox] { _ = try UsbScratchPath.check(path, as: .existingDirectory) }
                try await run(store: store, directory: directory, mount: mount)
                FileHandle.standardOutput.write(Data("머리글 캡처 완료\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("머리글 캡처 실패: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private static func run(store: LibraryStore, directory: String, mount: String) async throws {
        for _ in 0..<200 {
            if case .loaded = store.phase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
            throw Failure(description: "주 창을 확인하세요")
        }
        let volume = try await BlockingWork.run(qos: .default) { try UsbVolumes.info(root: URL(filePath: mount)) }
        guard volume.isDiskImage else { throw Failure(description: "합성 디스크 이미지가 아님") }
        let (events, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
        defer { continuation.finish() }
        let host = SystemUsbHost(io: UsbAppComposition.hostIO(snapshots: DJCPaths.userData.appending(path: "column-header-usb-snapshots")), events: events,
                                 current: { [volume] })
        let usb = UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: UsbAppComposition.writeService(), localLibrary: { nil })
        store.usb = usb
        await usb.refresh()
        NSApp.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1440, height: 900))
        func settle() async throws { try await Task.sleep(for: .milliseconds(900)) }

        try await settle()
        try shoot(window, directory + "/local.jpg", "로컬")
        store.sidebar = .usb(.collection(volumeKey: volume.usbKey))
        try await settle()
        try shoot(window, directory + "/usb.jpg", "USB")
        // 쓰기 대기는 곡 목록 대신 다른 화면이라 곡 목록 표가 새로 만들어진다
        store.sidebar = .usb(.pending(volumeKey: volume.usbKey))
        try await settle()
        store.sidebar = .usb(.collection(volumeKey: volume.usbKey))
        try await settle()
        store.sidebar = .filter(.all)
        try await settle()
        try shoot(window, directory + "/local-after-usb.jpg", "로컬(USB 뒤)")
    }

    private static func shoot(_ window: NSWindow, _ path: String, _ label: String) throws {
        guard let table = window.contentView.flatMap(trackTable) else { throw Failure(description: "곡 목록이 없습니다") }
        print("[\(label)] 순서 " + table.tableColumns.map { $0.identifier.rawValue + ($0.isHidden ? "(숨김)" : "") }.joined(separator: ","))
        for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
            let header = table.headerView?.headerRect(ofColumn: index) ?? .zero
            print("[\(label)] \(column.identifier.rawValue) 제목=\(column.title) 칸=\(Int(table.rect(ofColumn: index).minX)) 머리글=\(Int(header.minX))")
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(window.windowNumber), path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(description: "창 캡처 실패: \(path)") }
    }

    private static func trackTable(_ view: NSView) -> TrackListTableView? {
        if let table = view as? TrackListTableView { return table }
        for sub in view.subviews { if let found = trackTable(sub) { return found } }
        return nil
    }
}
#endif
