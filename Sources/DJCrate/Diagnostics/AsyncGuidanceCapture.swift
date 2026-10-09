#if DEBUG
import AppKit
import DJCDomain
import Foundation
import RekordboxKit

extension DevSelfTests {
    /// 같은 합성 조건을 앱 활성화 없이 띄워 이 PID의 창만 기록한다.
    static func runAsyncGuidanceCaptureIfRequested(store: LibraryStore, deck: DeckModel) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--async-guidance-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        let directory = String(argument.dropFirst("--async-guidance-capture=".count))
        Task {
            for _ in 0..<200 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard store.rows.count == 2, store.rows.allSatisfy({ $0.title.hasPrefix("합성 곡 ·") }), !NSApp.isActive,
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
                  let valid = store.rowsByID["1"], let broken = store.rowsByID["2"] else { exit(2) }
            window.setContentSize(NSSize(width: 1440, height: 1000))
            var failures = 0
            @MainActor func capture(_ window: NSWindow, _ name: String) async {
                try? await Task.sleep(for: .milliseconds(600))
                guard !NSApp.isActive else { failures += 1; return }
                let process = Process()
                process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(window.windowNumber), "\(directory)/\(name).jpg"]
                do { try process.run(); process.waitUntilExit() } catch { failures += 1; return }
                if process.terminationStatus != 0 { failures += 1 }
            }
            store.loadToDeck(broken)
            await deck.loadTask?.value
            await capture(window, "audio-read")
            store.loadToDeck(valid)
            await deck.loadTask?.value
            deck.rename(UUID(), "사라진 큐")
            await capture(window, "cue-selection")
            if let snapshot = store.snapshotURL {
                await store.load(snapshot: snapshot.deletingLastPathComponent().appending(path: "missing.db"), quiet: true)
            }
            await capture(window, "snapshot-open")
            // XML로 만들 곡이 없으면 창 대신 목록 위 결과 줄로 알린다(#230)
            store.reflectionMessage = ReflectionPanels.blockedMessage(store.reflectionPlans(for: [valid]).filter { !$0.blockers.isEmpty })
            await capture(window, "xml-exclusion")
            FileHandle.standardError.write(Data("[비동기 안내 화면] \(failures == 0 ? "통과" : "실패") · 캡처 4개 · 실패 \(failures)건 · 앱 비활성\n".utf8))
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
