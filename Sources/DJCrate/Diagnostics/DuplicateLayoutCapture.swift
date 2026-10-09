#if DEBUG
import AppKit
import DJCDomain
import QuartzCore

extension DevSelfTests {
    /// 중복 후보 화면을 라이트·다크로 캡처하고 목록 스크롤 한 번 처리 시간을 잰다(`--duplicates-capture=<폴더>`).
    /// `DuplicateReadTests`의 아트워크 합성 사본에서만 돈다(실제 라이브러리 화면을 남기지 않게).
    static func runDuplicateLayoutIfRequested(store: LibraryStore) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--duplicates-capture=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        let directory = String(argument.dropFirst("--duplicates-capture=".count))
        func log(_ text: String) { FileHandle.standardError.write(Data("[중복 후보 화면] \(text)\n".utf8)) }
        Task {
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<100 {
                if case .loaded = store.phase { break }
                await wait(0.1)
            }
            guard !store.duplicateGroups.isEmpty, store.rows.allSatisfy({ $0.title.hasPrefix("합성 중복 ") }),
                  let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
                log("아트워크 합성 사본이 아닙니다")
                exit(2)
            }
            store.sidebar = .duplicates
            // 세 번째 묶음(서로 다른 그림)까지 보이는 높이
            window.setContentSize(NSSize(width: 1100, height: 900))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            await wait(1)
            var failures = 0
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                await wait(1.5)
                let capture = Process()
                capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/\(name).png"]
                do { try capture.run(); capture.waitUntilExit() } catch { failures += 1; continue }
                if capture.terminationStatus != 0 { failures += 1 }
            }
            @MainActor func tables(_ view: NSView) -> [NSTableView] {
                ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
            }
            // 사이드바도 표라서 줄이 가장 많은 표를 후보 목록으로 본다.
            guard let content = window.contentView, let table = tables(content).max(by: { $0.numberOfRows < $1.numberOfRows }),
                  let clip = table.enclosingScrollView?.contentView else {
                log("후보 목록을 찾지 못했습니다")
                exit(1)
            }
            log("후보 목록 줄 \(table.numberOfRows)")
            // 3초씩: 천천히(8ms마다 14px), 빠르게 훑기(8ms마다 70px). `--scroll-perf`와 같은 방식이다.
            for (name, step) in [("천천히 스크롤", 14.0), ("빠르게 스크롤", 70.0)] {
                var costs: [Double] = []
                let started = ProcessInfo.processInfo.systemUptime
                var y = clip.bounds.origin.y
                var down = true
                while ProcessInfo.processInfo.systemUptime - started < 3 {
                    y += down ? step : -step
                    let maxY = table.bounds.height - clip.bounds.height
                    if y >= maxY { down = false } else if y <= 0 { down = true }
                    let t0 = CACurrentMediaTime()
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maxY)))
                    table.enclosingScrollView?.reflectScrolledClipView(clip)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    costs.append((CACurrentMediaTime() - t0) * 1000)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                let sorted = costs.sorted()
                log(String(format: "%@: %d번 · 한 번 처리 평균 %.2fms · 상위 10%% %.2fms · 최대 %.2fms · 16.7ms 넘음 %d번", name, costs.count,
                           costs.reduce(0, +) / Double(max(costs.count, 1)), sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0,
                           costs.filter { $0 > 16.7 }.count))
            }
            log(failures == 0 ? "끝: 통과" : "끝: 캡처 실패 \(failures)건")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
