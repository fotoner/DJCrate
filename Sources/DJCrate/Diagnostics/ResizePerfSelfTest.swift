import AppKit
import DJCAdapters
import DJCDomain
import Foundation
import QuartzCore

#if DEBUG
enum ResizePerfAxis: String, CaseIterable {
    case width, height

    static func parse(_ value: String) -> [Self]? {
        if value == "all" { return allCases }
        let names = value.components(separatedBy: ",")
        let axes = names.compactMap(Self.init(rawValue:))
        return axes.count == names.count && Set(axes).count == axes.count ? axes : nil
    }

    func frame(from original: NSRect, step: Int) -> NSRect {
        var frame = original
        let offset = Double(step < 20 ? step : 39 - step)
        if self == .width { frame.size.width -= offset * 15 }
        else { frame.size.height -= offset * 8 }
        return frame
    }
}

struct ResizePerfDistribution: Codable {
    var count: Int
    var median: Double
    var maximum: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        let middle = sorted.count / 2
        median = sorted.isEmpty ? 0 : sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        maximum = sorted.last ?? 0
    }
}

/// 포커스·입력·재생을 바꾸지 않고 메인 창을 가로·세로 40단계씩 왕복한다.
/// 호출 후 16ms 대기하므로 실제 드래그 입력률이나 표시 FPS를 뜻하지 않는다.
@MainActor
enum ResizePerfSelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--resize-perf=") } }

    static func log(_ text: String) { FileHandle.standardError.write(Data("[창 크기 성능] \(text)\n".utf8)) }

    static func startupRefusal(arguments: [String] = ProcessInfo.processInfo.arguments,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let argument = arguments.first(where: { $0.hasPrefix("--resize-perf=") }) else { return nil }
        guard ResizePerfAxis.parse(String(argument.dropFirst("--resize-perf=".count))) != nil else {
            return "--resize-perf=all 또는 width,height로 축을 지정하세요"
        }
        guard environment["DJC_HOME"]?.isEmpty == false,
              environment["DJC_REKORDBOX_DIR"]?.isEmpty == false,
              environment["DJC_DB"]?.isEmpty == false else {
            return "합성 사본(DJC_DB·DJC_REKORDBOX_DIR)과 임시 DJC_HOME을 지정하세요"
        }
        if let value = option("repeats", in: arguments), Int(value).map({ (1...10).contains($0) }) != true {
            return "--resize-perf-repeats=1부터 10까지 지정하세요"
        }
        if let value = option("delay", in: arguments), Double(value).map({ $0.isFinite && (0...60).contains($0) }) != true {
            return "--resize-perf-delay=0부터 60까지 지정하세요"
        }
        return nil
    }

    private static func option(_ name: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        let prefix = "--resize-perf-\(name)="
        return arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }

    private static let restoredKeys = UIPerfSelfTest.restoredKeys + [SettingKeys.waveformHeight.name, SettingKeys.cueListFilter.name,
        "djc.trackList.indexColumnPlaced", "djc.trackList.albumColumnPlaced", "djc.trackList.tempoColumnPlaced",
        "djc.trackList.formatColumnPlaced", "djc.trackList.tagColumnsPlaced"]
    private static var savedSettings: [Any?] = []

    /// 표가 처음 만들어질 때 열 배치 표시를 저장할 수 있어, 뷰 생성 전에 보관한다.
    static func saveSettings() {
        let stored = UserDefaults.standard.persistentDomain(forName: ProcessInfo.processInfo.processName) ?? [:]
        savedSettings = restoredKeys.map { stored[$0] }
    }

    static func runIfRequested(store: LibraryStore, deck: DeckModel) {
        guard isRequested else { return }
        UserDefaults.standard.set(false, forKey: SettingKeys.sheetMode.name)
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(false, forKey: SettingKeys.showTagEditor.name)
        UserDefaults.standard.set(150.0, forKey: SettingKeys.waveformHeight.name)
        UserDefaults.standard.set(CueListFilter.all.rawValue, forKey: SettingKeys.cueListFilter.name)
        Task {
            let ok = await run(store: store, deck: deck)
            // 전체 영역을 덮어쓰지 않고 이번 측정에서 바꿀 수 있는 키만 복원한다.
            for (key, value) in zip(restoredKeys, savedSettings) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            UserDefaults.standard.synchronize()
            exit(ok ? 0 : 1)
        }
    }

    private static func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func findTable(_ view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.identifier == KeyRouter.trackListID { return table }
        for child in view.subviews { if let table = findTable(child) { return table } }
        return nil
    }

    private static func emit(_ name: String, _ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        FileHandle.standardError.write(Data("\(name) \(String(decoding: data, as: UTF8.self))\n".utf8))
    }

    private static func pair(_ values: [Double]) -> [String: Any] {
        let distribution = ResizePerfDistribution(values)
        return ["count": distribution.count, "median": distribution.median, "max": distribution.maximum,
                "total": values.reduce(0, +)]
    }

    private static func capture(_ window: NSWindow) -> Bool {
        guard let directory = option("capture") else { return true }
        do {
            let root = URL(filePath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "-t", "jpg", root.appending(path: "resize.jpg").path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { log("측정 창 캡처 실패"); return false }
    }

    private static func run(store: LibraryStore, deck: DeckModel) async -> Bool {
        for _ in 0..<600 {
            if case .loaded = store.phase, !store.rows.isEmpty,
               NSApp.windows.contains(where: { findTable($0.contentView) != nil }) { break }
            await wait(0.05)
        }
        guard case .loaded = store.phase,
              let window = NSApp.windows.first(where: { findTable($0.contentView) != nil }),
              let content = window.contentView,
              let row = store.displayRows.first else { log("메인 창·합성 라이브러리를 찾지 못함"); return false }
        // 비활성 창에도 스크롤이 들어올 수 있어 준비·측정 동안 사용자 입력을 받지 않는다.
        let ignoredMouseEvents = window.ignoresMouseEvents
        window.ignoresMouseEvents = true
        defer { window.ignoresMouseEvents = ignoredMouseEvents }
        let original = window.frame
        defer { window.setFrame(original, display: false) }
        window.setContentSize(NSSize(width: 1500, height: 900))
        window.orderFrontRegardless()
        store.selection = [row.id]
        store.loadToDeck(row)
        for _ in 0..<600 {
            if deck.draft != nil, deck.waveform != nil, !deck.isAnalyzingSections { break }
            await wait(0.05)
        }
        // 섹션 완료 표시는 그리드 추정 시작보다 먼저 내려간다. 캡처·측정 도중 내용이 바뀌지 않게 둘 다 마친다.
        await deck.loadTask?.value
        await deck.suggestionTask?.value
        guard let audio = deck.audio as? DeckAudio else { log("측정용 앱 오디오를 찾지 못함"); return false }
        for _ in 0..<600 where !audio.canLoopSampleAccurately { await wait(0.05) }
        guard deck.draft != nil, deck.waveform != nil, !deck.isAnalyzingSections, !deck.isPlaying,
              audio.canLoopSampleAccurately else {
            log("정지한 덱·파형 준비 실패"); return false
        }
        await wait(1)
        if let delay = option("delay").flatMap(Double.init) { await wait(delay) }
        guard !NSApp.isActive, !window.isKeyWindow else { log("포커스를 가져와 측정을 중단함"); return false }
        let playhead = deck.playhead
        guard capture(window) else { return false }
        let base = window.frame
        let recorder = UIPerfRecorder()
        recorder.start(in: content)
        let axes = ResizePerfAxis.parse(String(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--resize-perf=") }!.dropFirst("--resize-perf=".count)))!
        let repeats = option("repeats").flatMap(Int.init) ?? 3
        for round in 0...repeats {
            for axis in axes {
                recorder.reset()
                PerfProbe.resetBodyCounts()
                var steps: [Double] = [], layouts: [Double] = [], displays: [Double] = [], cpus: [Double] = []
                var intervals: [String: [Double]] = [:]
                var load = [0.0, 0.0, 0.0]
                getloadavg(&load, 3)
                let start = CACurrentMediaTime(), cpu = UIPerfRecorder.threadCPU()
                for step in 0..<40 {
                    PerfProbe.reset()
                    let counts = PerfProbe.bodySnapshot()
                    let t = CACurrentMediaTime(), c = UIPerfRecorder.threadCPU()
                    window.setFrame(axis.frame(from: base, step: step), display: false)
                    let resized = CACurrentMediaTime()
                    window.layoutIfNeeded()
                    content.layoutSubtreeIfNeeded()
                    let laidOut = CACurrentMediaTime()
                    content.displayIfNeeded()
                    let displayed = CACurrentMediaTime()
                    let sync = (displayed - t) * 1000
                    let syncCPU = (UIPerfRecorder.threadCPU() - c) * 1000
                    await wait(0.016)
                    steps.append(sync); layouts.append((laidOut - resized) * 1000)
                    displays.append((displayed - laidOut) * 1000); cpus.append(syncCPU)
                    let stepIntervals = PerfProbe.intervalSnapshot()
                    for (name, values) in stepIntervals { intervals[name, default: []] += values }
                    let bodies = PerfProbe.bodySnapshot().mapValues { $0 }
                        .reduce(into: [String: Int]()) { result, item in
                            let count = item.value - (counts[item.key] ?? 0)
                            if count > 0 { result[item.key] = count }
                        }
                    if round > 0 {
                        let previous = recorder.frames.last { $0 < t }.map { [$0] } ?? []
                        let stepFrames = previous + recorder.frames.filter { $0 >= t }
                        let stepGaps = zip(stepFrames.dropFirst(), stepFrames).map { ($0 - $1) * 1000 }
                        emit("RESIZE_STEP", ["axis": axis.rawValue, "round": round, "step": step,
                            "resize_ms": (resized - t) * 1000, "layout_flush_ms": (laidOut - resized) * 1000,
                            "display_flush_ms": (displayed - laidOut) * 1000, "sync_ms": sync, "sync_cpu_ms": syncCPU,
                            "zoom_draw_ms": pair(PerfProbe.drawSnapshot()), "interval_ms": stepIntervals.mapValues(pair),
                            "frame_gap_ms": pair(stepGaps), "bodies": bodies])
                    }
                }
                let end = CACurrentMediaTime()
                let totalCPU = (UIPerfRecorder.threadCPU() - cpu) * 1000
                let gaps = zip(recorder.frames.dropFirst(), recorder.frames).map { ($0 - $1) * 1000 }
                emit("RESIZE_SUMMARY", ["axis": axis.rawValue, "round": round, "warmup": round == 0,
                    "sync_ms": pair(steps), "layout_flush_ms": pair(layouts), "display_flush_ms": pair(displays),
                    "sync_cpu_ms": pair(cpus), "total_cpu_ms": totalCPU,
                    "frame_gap_ms": pair(gaps), "elapsed_ms": (end - start) * 1000,
                    "bodies": PerfProbe.bodySnapshot(), "load_average": load,
                    "interval_ms": intervals.mapValues(pair), "hidden": PerfProbe.hidden.sorted(),
                    "active": NSApp.isActive, "key_window": window.isKeyWindow,
                    "ignores_mouse_events": window.ignoresMouseEvents, "playhead": deck.playhead])
                guard !gaps.isEmpty, !NSApp.isActive, !window.isKeyWindow,
                      window.ignoresMouseEvents, deck.playhead == playhead else {
                    log("프레임을 재지 못했거나 입력 격리·재생 위치·포커스가 바뀌어 실패함"); return false
                }
                await wait(0.3)
            }
        }
        log("통과: 가로·세로 단계 기록 완료(첫 왕복은 준비 측정)")
        return true
    }
}
#endif
