#if DEBUG
import AppKit
import DJCDomain

extension DevSelfTests {
    /// 읽지 못한 초안 안내(#174)와 연결되지 않은 초안 줄·목록(#175)을 캡처한다(`--draft-notice-capture=<폴더>`).
    /// 창을 앞으로 가져오지 않고 이 앱의 창 번호로만 찍는다. 합성 사본(곡 제목이 "합성 곡"으로 시작)에서만 돈다.
    static func runDraftNoticeCaptureIfRequested(store: LibraryStore) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--draft-notice-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        let directory = String(argument.dropFirst("--draft-notice-capture=".count))
        func log(_ text: String) { FileHandle.standardError.write(Data("[초안 안내 화면] \(text)\n".utf8)) }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<100 {
                if case .loaded = store.phase { break }
                await wait(0.1)
            }
            guard !store.rows.isEmpty, store.rows.allSatisfy({ $0.title.hasPrefix("합성 곡") }),
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
                log("합성 사본이 아닙니다")
                exit(2)
            }
            var failures = 0
            // 지역 함수는 둘러싼 Task의 메인 액터 격리를 물려받지 않으므로 창 번호를 읽는 이 함수에 따로 적는다.
            @MainActor func capture(_ window: NSWindow, _ name: String) {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/\(name).png"]
                do { try process.run(); process.waitUntilExit() } catch { failures += 1; return }
                if process.terminationStatus != 0 { failures += 1 }
            }
            log("안내: \(store.draftFileMessage?.text ?? "없음") · 연결되지 않은 초안 \(store.unlinkedDraftUUIDs.count)곡")
            store.sidebar = .filter(.all)
            await wait(1.5)
            capture(window, "after-notice")
            store.sidebar = .pending
            await wait(1.5)
            capture(window, "after-pending")
            store.openUnlinkedDrafts()
            await wait(2)
            if let sheet = window.attachedSheet ?? NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
                capture(sheet, "after-sheet")
            } else {
                log("목록 창을 찾지 못했습니다")
                failures += 1
            }
            log(failures == 0 ? "끝: 통과" : "끝: 캡처 실패 \(failures)건")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
