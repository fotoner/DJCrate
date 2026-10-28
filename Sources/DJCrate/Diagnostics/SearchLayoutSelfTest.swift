#if DEBUG
import AppKit

extension DevSelfTests {
    /// 실제 도구 막대에서 검색 포커스가 검색칸과 이웃 버튼의 폭을 바꾸는지 확인한다.
    /// 창 아래 상태 줄(#298)이 창 폭 안·도구 막대 아래에 있고 활동 단추가 그 줄 안에 보이는지도 본다.
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
            // 사용자화로 저장된 구성이 지운 항목(옛 `reflection`)을 들고 있어도 빈 칸 없이 남은 항목만 보이는지 알 수 있게 항목 목록을 남긴다
            let itemList = toolbar.items.map(\.itemIdentifier.rawValue).joined(separator: ",")
            FileHandle.standardError.write(Data("[검색 배치 시험] 도구 막대 항목: \(itemList)\n".utf8))
            for width: CGFloat in [1100, 1155, 1200, 1440, 1800] {
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
                let hiddenControls = ["viewMode", "addFiles", "tagEditor", "snapshot"].filter { !visibleIDs.contains($0) }
                let controlsVisible = hiddenControls.isEmpty
                // 상태 줄 자리는 위 왼쪽 원점의 창 좌표다. 도구 막대 아래 끝은 내용 영역(`contentLayoutRect`)의 위 끝이다
                let content = window.contentView?.frame.size ?? .zero
                let toolbarBottom = content.height - window.contentLayoutRect.maxY
                let bar = SelfTestFrames.frames.first { $0.key.hasPrefix("statusBar.") }?.value
                let button = SelfTestFrames.frames["statusBarActivity"]
                let barFits = bar.map { $0.width > 0 && $0.minY >= toolbarBottom && abs($0.maxY - content.height) <= 0.5
                    && $0.minX >= -0.5 && $0.maxX <= content.width + 0.5 } ?? false
                let buttonFits = barFits && button.map { $0.width > 0 && bar?.insetBy(dx: -0.5, dy: -0.5).contains($0) == true } ?? false
                let stable = focused && controlsVisible && !neighbors.isEmpty && before.width > 0
                    && abs(before.width - after.width) <= 0.5 && movement <= 0.5 && buttonFits
                if !stable { failures += 1 }
                let line = String(format: "[검색 배치 시험] 창 %.0f(실제 %.0f) · 검색 폭 %.2f → %.2f · 선호 폭 %.2f · 이웃 %d개 최대 이동 %.2f · 포커스 %@ · 버튼 표시 %@ · 상태 줄 %@(%@) · %@\n",
                                  width, window.contentView?.frame.width ?? 0, before.width, after.width,
                                  search.preferredWidthForSearchField, neighbors.count, movement,
                                  focused ? "있음" : "없음", controlsVisible ? "모두" : "일부(접힘: \(hiddenControls.joined(separator: ",")))", buttonFits ? "맞음" : "어긋남",
                                  bar.map { NSStringFromRect($0) } ?? "없음", stable ? "통과" : "실패")
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
