#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import Foundation
import Synchronization

/// LINK 막대(#272·#273)를 연결한 모양으로 캡처한다(`--link-capture=<폴더>`).
/// 가상 CDJ-3000 네 대와 DJM-900NXS2 한 대를 화면 모델에 직접 넣는다. 포트를 열지 않고 네트워크에 아무것도 보내지 않는다(LNK-4·LNK-6).
/// 플레이어 상태는 내어 준 합성 라이브러리의 앞 곡으로 채운다. 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`의 합성 라이브러리로 돌린다.
@MainActor
enum LinkCapture {
    static let argument = "--link-capture="

    nonisolated static let devices = [
        LinkDevice(number: 1, name: "CDJ-3000", kind: .player, address: "169.254.0.1"),
        LinkDevice(number: 2, name: "CDJ-3000", kind: .player, address: "169.254.0.2"),
        LinkDevice(number: 3, name: "CDJ-3000", kind: .player, address: "169.254.0.3"),
        LinkDevice(number: 4, name: "CDJ-3000", kind: .player, address: "169.254.0.4"),
        LinkDevice(number: 33, name: "DJM-900NXS2", kind: .mixer, address: "169.254.0.33"),
    ]

    /// 캡처 실행이면 가상 장치를 보이는 LINK 막대 모델, 아니면 nil
    static func model(arguments: [String], store: LibraryStore) -> LinkBarModel? {
        guard arguments.contains(where: { $0.hasPrefix(argument) }) else { return nil }
        let served = Mutex<[UInt32]>([])
        let server = LinkServerSource(
            start: { library, _, _, _ throws(LinkProblem) in served.withLock { $0 = library.tracks.prefix(3).map(\.id) } },
            stop: {},
            status: {
                let ids = served.withLock { $0 }
                func track(_ at: Int) -> UInt32? { ids.indices.contains(at) ? ids[at] : nil }
                // 1번은 재생 중 MASTER, 2번은 SYNC로 재생 중, 3번은 실어 두고 멈춤, 4번은 비어 있다
                return LinkServerStatus(deviceNumber: 17, mounted: Set(devices.map(\.address)), players: [
                    1: LinkPlayerState(isPlaying: true, isMaster: true, loadedTrackID: track(0), bpm: 128),
                    2: LinkPlayerState(isPlaying: true, isSync: true, loadedTrackID: track(1), bpm: 128),
                    3: LinkPlayerState(loadedTrackID: track(2), bpm: 124),
                    4: LinkPlayerState(),
                ])
            },
            load: { _, _ throws(LinkProblem) in },
            isRekordboxRunning: { false })
        let discovery = LinkDiscoverySource(
            announcements: {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        while !Task.isCancelled {
                            for device in devices { continuation.yield(device) }
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            isRekordboxRunning: { false }, now: { Date() })
        return LinkBarModel(discovery: LinkDiscovery(source: discovery), session: LinkSession(source: server),
                            library: { [weak store] in
                                guard let store, case .loaded = store.phase else { return nil }
                                return .init(rows: store.rows, playlists: store.playlists.rekordboxPlaylists, shareRoot: store.shareRoot.path)
                            })
    }

    static func runIfRequested(link: LinkBarModel?, store: LibraryStore) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(argument) }) else { return }
        let directory = String(argument.dropFirst(self.argument.count))
        guard let link, ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else {
            FileHandle.standardError.write(Data("LINK 캡처 실패: 임시 DJC_HOME·DJC_REKORDBOX_DIR을 주세요\n".utf8))
            exit(2)
        }
        Task {
            do {
                try await run(link: link, store: store, directory: directory)
                print("LINK 캡처 통과")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("LINK 캡처 실패: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private static func run(link: LinkBarModel, store: LibraryStore, directory: String) async throws {
        func wait(_ what: String, _ done: () -> Bool) async throws {
            for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(100)) }
            guard done() else { throw Failure(description: "\(what)을(를) 기다리다 멈췄습니다") }
        }
        try await wait("라이브러리") { if case .loaded = store.phase { true } else { false } }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
            throw Failure(description: "주 창을 확인하세요")
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await wait("장치") { link.devices.count == devices.count }
        link.toggle()
        try await wait("연결") { link.isConnected && link.player(devices[0])?.title != nil }
        try await Task.sleep(for: .milliseconds(1200))
        let path = directory + "/link-connected.png"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: path) else {
            throw Failure(description: "창을 찍지 못했습니다")
        }
        print("[LINK] 장치 \(link.devices.count)대, 연결됨 \(link.isConnected), 캡처 \(path)")
    }
}
#endif
