#if DEBUG
import AppKit

extension DevSelfTests {
    /// 실제 도구 막대에서 검색 포커스가 검색칸과 이웃 버튼의 폭을 바꾸는지 확인한다.
    static func runSearchLayoutIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--search-layout-selftest"),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        Task {
            func wait() async { try? await Task.sleep(for: .milliseconds(500)) }
            @MainActor func capture(_ window: NSWindow, name: String) -> Bool {
                guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--search-layout-captures=") }) else { return true }
                let directory = String(argument.dropFirst("--search-layout-captures=".count))
                let command = Process()
                command.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                command.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/\(name).png"]
                do { try command.run() } catch { return false }
                command.waitUntilExit()
                return command.terminationStatus == 0
            }
            @MainActor func searchWindow() -> NSWindow? {
                NSApp.windows.first { $0.toolbar?.items.contains(where: { $0 is NSSearchToolbarItem }) == true }
            }
            for _ in 0..<20 {
                if searchWindow() != nil { break }
                await wait()
            }
            guard let window = searchWindow(),
                  let toolbar = window.toolbar,
                  let search = toolbar.items.compactMap({ $0 as? NSSearchToolbarItem }).first else {
                FileHandle.standardError.write(Data("[검색 배치 시험] 검색 도구 막대를 찾지 못했습니다\n".utf8))
                exit(2)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            await wait()
            let originalSize = window.contentView?.frame.size ?? NSSize(width: 1440, height: 900)
            var failures = 0
            for width: CGFloat in [1100, 1200, 1440, 1800] {
                search.endSearchInteraction()
                window.setContentSize(NSSize(width: width, height: 700))
                await wait()
                window.contentView?.layoutSubtreeIfNeeded()
                let field = search.searchField
                let before = field.convert(field.bounds, to: nil)
                let neighbors = toolbar.items.filter { !($0 is NSSearchToolbarItem) }.compactMap(\.view)
                    .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }
                let positions = neighbors.map { $0.convert($0.bounds, to: nil) }
                if width == 1200, !capture(window, name: "unfocused") { failures += 1 }
                search.beginSearchInteraction()
                await wait()
                window.contentView?.layoutSubtreeIfNeeded()
                let after = field.convert(field.bounds, to: nil)
                if width == 1200, !capture(window, name: "focused") { failures += 1 }
                let movement = zip(neighbors, positions).map { view, frame in
                    let now = view.convert(view.bounds, to: nil)
                    return max(abs(now.minX - frame.minX), abs(now.width - frame.width))
                }.max() ?? 0
                let focused = (window.firstResponder as? NSTextView)?.delegate === field
                let visibleIDs = Set((toolbar.visibleItems ?? []).map { $0.itemIdentifier.rawValue })
                let controlsVisible = ["viewMode", "relatedTracks", "addFiles", "tagEditor", "snapshot", "reflection"]
                    .allSatisfy { visibleIDs.contains($0) }
                let stable = focused && controlsVisible && !neighbors.isEmpty && before.width > 0
                    && abs(before.width - after.width) <= 0.5 && movement <= 0.5
                if !stable { failures += 1 }
                let line = String(format: "[검색 배치 시험] 창 %.0f(실제 %.0f) · 검색 폭 %.2f → %.2f · 선호 폭 %.2f · 이웃 %d개 최대 이동 %.2f · 포커스 %@ · 버튼 표시 %@ · %@\n",
                                  width, window.contentView?.frame.width ?? 0, before.width, after.width,
                                  search.preferredWidthForSearchField, neighbors.count, movement,
                                  focused ? "있음" : "없음", controlsVisible ? "모두" : "일부", stable ? "통과" : "실패")
                FileHandle.standardError.write(Data(line.utf8))
            }
            search.endSearchInteraction()
            window.setContentSize(originalSize)
            FileHandle.standardError.write(Data("[검색 배치 시험] 끝: \(failures == 0 ? "통과" : "실패 \(failures)건")\n".utf8))
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
