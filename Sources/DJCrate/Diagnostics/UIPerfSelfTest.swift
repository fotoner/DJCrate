import AppKit
import DJCApplication
import DJCDomain
import Foundation
import OSLog
import QuartzCore

// 개발용 자가 측정은 디버그 빌드에만 들어간다(설치하는 릴리스 앱에는 없다).
#if DEBUG
/// 개발용: 화면 조작마다 메인 스레드가 얼마나 일하고 프레임이 얼마나 밀리는지 잰다(`--ui-perf=all` 또는 `--ui-perf=sidebar,sort,…`, #129).
/// 조작 이름: launch sidebar inspector resize scroll select sidebar-item sort search load zoom scrub play sheet edit preview,
/// drafts(곡 600개에 태그 초안을 만들어 이후 조작을 초안이 많은 상태에서 잰다), capture(`--ui-perf-capture=<폴더>`에
/// 인스펙터·빈 목록·여러 곡 선택 화면을 저장한다), grid(그리드 일괄 추정 중 메인 스레드, 초안을 남긴다). 이 셋은 all에 넣지 않는다.
/// 합성 사본(`UIPerfFixtureCapture`)과 `DJC_HOME=<임시 폴더>`로 돌린다. 바꾼 화면 설정(사이드바·인스펙터·태그 시트·창 크기)은 끝나면 되돌린다.
/// `--ui-perf-delay=<초>`는 조작을 시작하기 전에 기다린다. 이 워크트리의 실행 파일을 띄운 뒤 `xctrace record --attach <PID>`를 붙일 시간이다.
@MainActor
enum UIPerfSelfTest {
    static let requested: [String]? = {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-perf=") }) else { return nil }
        let names = arg.dropFirst("--ui-perf=".count).components(separatedBy: ",").filter { !$0.isEmpty }
        return names == ["all"] ? all : names
    }()
    static let all = ["launch", "sidebar", "inspector", "resize", "scroll", "select", "sidebar-item", "sort", "search",
                      "load", "zoom", "scrub", "play", "sheet", "edit", "preview"]
    /// 바꿀 수 있는 공유 설정(디버그 앱은 모든 작업 폴더가 같은 UserDefaults 영역을 쓴다). 끝나면 처음 값으로 되돌린다.
    static let restoredKeys = [SettingKeys.sidebarVisible.name, SettingKeys.showTagEditor.name, SettingKeys.sheetMode.name,
                               "NSWindow Frame djc.mainWindow", "NSSplitView Subview Frames main, SidebarNavigationSplitView",
                               "NSTableView Sort Ordering v2 djc.trackList.v2"]

    static func log(_ text: String) { FileHandle.standardError.write(Data("[화면 성능] \(text)\n".utf8)) }

    static func runIfRequested(store: LibraryStore, deck: DeckModel, windows: AppWindows, reflection: ReflectionCoordinator) {
        guard let names = requested else { return }
        // 실행 인자로 준 값(`-NSWindow Frame …`)이 아니라 저장된 값을 되돌린다.
        let stored = UserDefaults.standard.persistentDomain(forName: ProcessInfo.processInfo.processName) ?? [:]
        let saved = Dictionary(uniqueKeysWithValues: restoredKeys.map { ($0, stored[$0]) })
        func restore() {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        // 다른 작업이 남긴 값에 흔들리지 않게 목록 보기·사이드바 열림·인스펙터 닫힘에서 시작한다.
        UserDefaults.standard.set(false, forKey: SettingKeys.sheetMode.name)
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(false, forKey: SettingKeys.showTagEditor.name)
        Task {
            if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-perf-delay=") }),
               let seconds = Double(arg.dropFirst("--ui-perf-delay=".count)) {
                try? await Task.sleep(for: .seconds(seconds))
            }
            let recorder = UIPerfRecorder()
            let runner = UIPerfRunner(store: store, deck: deck, windows: windows, reflection: reflection, recorder: recorder)
            var load = [0.0, 0.0, 0.0]
            getloadavg(&load, 3)
            log(String(format: "부하(1·5·15분) %.1f %.1f %.1f · 코어 %d", load[0], load[1], load[2], ProcessInfo.processInfo.activeProcessorCount))
            let ok = await runner.run(names)
            var after = [0.0, 0.0, 0.0]
            getloadavg(&after, 3)
            log(String(format: "끝 부하 %.1f", after[0]))
            if let frame = runner.originalFrame { runner.window?.setFrame(frame, display: false) }
            restore()
            UserDefaults.standard.synchronize()
            exit(ok ? 0 : 1)
        }
    }
}

/// 메인 런루프가 깨어 일한 구간과 화면 갱신(디스플레이 링크) 시각을 모은다.
@MainActor
final class UIPerfRecorder: NSObject {
    private(set) var busy: [(start: Double, end: Double, cpu: Double)] = []
    private(set) var frames: [Double] = []
    private var wokeAt: Double = 0
    private var wokeCPU: Double = 0
    private var observer: CFRunLoopObserver?
    private var link: CADisplayLink?

    func start(in view: NSView) {
        if observer == nil {
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
                let now = CACurrentMediaTime()
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if activity == .afterWaiting {
                        self.wokeAt = now
                        self.wokeCPU = UIPerfRecorder.threadCPU()
                    } else if self.wokeAt > 0 {
                        self.busy.append((self.wokeAt, now, UIPerfRecorder.threadCPU() - self.wokeCPU))
                        self.wokeAt = 0
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func frame(_ link: CADisplayLink) { frames.append(CACurrentMediaTime()) }

    func reset() { busy = []; frames = [] }

    /// 메인 스레드가 쓴 CPU 시간(초). 다른 프로세스 때문에 기다린 시간은 빠진다(부하가 높을 때도 견줄 수 있다).
    static func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000 }

    /// `from`부터 `to`까지의 결과. 지금 일하는 중인 구간(측정 코드 자신)은 `now`로 닫는다.
    func result(from start: Double, to end: Double, sync: Double) -> UIPerfSample {
        var spans = busy.filter { $0.end > start && $0.start < end }.map { (max($0.start, start), min($0.end, end)) }
        // 창에 걸친 구간은 걸친 비율만큼만 CPU 시간에 넣는다.
        var cpu = busy.filter { $0.end > start && $0.start < end }.reduce(0.0) {
            let whole = $1.end - $1.start
            return $0 + ($1.cpu * (whole > 0 ? (min($1.end, end) - max($1.start, start)) / whole : 1))
        }
        if wokeAt > 0, wokeAt < end {
            spans.append((max(wokeAt, start), min(CACurrentMediaTime(), end)))
            cpu += UIPerfRecorder.threadCPU() - wokeCPU
        }
        let total = spans.reduce(0) { $0 + ($1.1 - $1.0) }
        let longest = spans.map { $0.1 - $0.0 }.max() ?? 0
        // 조작 뒤 메인 스레드가 100ms 넘게 쉬기 직전까지(애니메이션 프레임처럼 짧게 이어지는 일도 포함)
        var settled = start
        for span in spans.sorted(by: { $0.0 < $1.0 }) where span.1 - span.0 >= 0.001 {
            if span.0 - settled > 0.1 { break }
            settled = max(settled, span.1)
        }
        let ticks = frames.filter { $0 >= start && $0 <= end }
        let gaps = zip(ticks.dropFirst(), ticks).map { $0 - $1 }
        return UIPerfSample(sync: sync * 1000, busy: total * 1000, cpu: cpu * 1000, longest: longest * 1000, settled: (settled - start) * 1000,
                            maxFrameGap: (gaps.max() ?? 0) * 1000, slowFrames: gaps.filter { $0 > 0.025 }.count)
    }
}

/// 조작 한 번의 수치(ms)
struct UIPerfSample {
    /// 조작 호출 자체
    var sync: Double
    /// 창 안에서 메인 스레드가 일한 시간 합
    var busy: Double
    /// 런루프 구간으로 추정한 메인 스레드 CPU 시간(측정 구간에 걸친 몫은 비율로 나눈다)
    var cpu: Double
    /// 한 번에 가장 길게 일한 시간(그동안 화면이 멈춘다)
    var longest: Double
    /// 조작부터 메인 스레드가 조용해질 때까지
    var settled: Double
    var maxFrameGap: Double
    /// 25ms 넘게 걸린 프레임 수
    var slowFrames: Int
}

@MainActor
final class UIPerfRunner {
    let store: LibraryStore
    let deck: DeckModel
    let windows: AppWindows
    let reflection: ReflectionCoordinator
    let recorder: UIPerfRecorder
    private(set) var window: NSWindow?
    private(set) var originalFrame: NSRect?
    private var table: NSTableView?
    private var failed = false
    private let signposter = OSSignposter(subsystem: "DJCrate.uiperf", category: .pointsOfInterest)

    init(store: LibraryStore, deck: DeckModel, windows: AppWindows, reflection: ReflectionCoordinator, recorder: UIPerfRecorder) {
        self.store = store
        self.deck = deck
        self.windows = windows
        self.reflection = reflection
        self.recorder = recorder
    }

    private func log(_ text: String) { UIPerfSelfTest.log(text) }
    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// 한 조작을 여러 번 재고 중앙값·최대를 적는다.
    @discardableResult
    private func measure(_ name: String, repeats: Int = 5, window span: Double = 0.8, rest: Double = 0.3,
                         prepare: (Int) async -> Void = { _ in }, action: (Int) -> Void) async -> [UIPerfSample] {
        var samples: [UIPerfSample] = []
        for index in 0..<repeats {
            await prepare(index)
            await wait(rest)
            let start = CACurrentMediaTime()
            action(index)
            let sync = CACurrentMediaTime() - start
            await wait(span)
            samples.append(recorder.result(from: start, to: start + span, sync: sync))
        }
        report(name, samples)
        return samples
    }

    private func report(_ name: String, _ samples: [UIPerfSample]) {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        func pair(_ values: [Double]) -> String { String(format: "%.1f(최대 %.1f)", median(values), values.max() ?? 0) }
        log("\(name) ×\(samples.count): 호출 \(pair(samples.map(\.sync)))ms · 메인 일한 합 \(pair(samples.map(\.busy)))ms(CPU 추정 \(pair(samples.map(\.cpu)))ms)"
            + " · 한 번 최대 \(pair(samples.map(\.longest)))ms · 조용해질 때까지 \(pair(samples.map(\.settled)))ms"
            + " · 프레임 최대 간격 \(pair(samples.map(\.maxFrameGap)))ms · 25ms 넘은 프레임 \(samples.map(\.slowFrames).reduce(0, +))")
    }

    private func findTable(_ view: NSView?, id: NSUserInterfaceItemIdentifier? = KeyRouter.trackListID) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, id == nil || table.identifier == id { return table }
        for sub in view.subviews { if let found = findTable(sub, id: id) { return found } }
        return nil
    }

    private func findSplitController(_ view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController { return controller }
        for sub in view.subviews { if let found = findSplitController(sub) { return found } }
        return nil
    }

    func run(_ names: [String]) async -> Bool {
        let launched = CACurrentMediaTime()
        for _ in 0..<600 {
            if case .loaded = store.phase, !store.rows.isEmpty { break }
            await wait(0.05)
        }
        guard case .loaded = store.phase else { log("라이브러리를 읽지 못함"); return false }
        let loadedAt = CACurrentMediaTime()
        for _ in 0..<100 where findTable(NSApp.windows.first { $0.isVisible }?.contentView) == nil { await wait(0.05) }
        guard let window = NSApp.windows.first(where: { $0.isVisible && findTable($0.contentView) != nil }),
              let table = findTable(window.contentView), let content = window.contentView else { log("목록을 찾지 못함"); return false }
        self.window = window
        self.table = table
        originalFrame = window.frame
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        recorder.start(in: content)
        deck.audio.volume = 0.0003
        await wait(1.0)
        if names.contains("launch") {
            log(String(format: "첫 로딩: 프로세스 시작 → 목록 읽음 %.0fms · 목록 읽음 → 측정 준비 %.0fms · 곡 %d개 · 재생 목록 %d개",
                       (loadedAt - launched + UIPerfRunner.processAge(at: launched)) * 1000, (CACurrentMediaTime() - loadedAt) * 1000,
                       store.rows.count, store.playlistCount))
        }
        for name in names where name != "launch" {
            recorder.reset()
            PerfProbe.resetBodyCounts()
            // Instruments(Time Profiler)에서 조작별 구간을 나눠 보게 관심 지점 구간을 남긴다.
            let state = signposter.beginInterval("ui-perf", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
            defer { signposter.endInterval("ui-perf", state) }
            switch name {
            case "sidebar": await sidebar()
            case "inspector": await inspector()
            case "resize": await resize()
            case "scroll": await scroll()
            case "select": await select()
            case "sidebar-item": await sidebarItems()
            case "sort": await sort()
            case "search": await search()
            case "load": await load()
            case "zoom": await zoom()
            case "scrub": await scrub()
            case "play": await play()
            case "sheet": await sheet()
            case "edit": await edit()
            case "preview": await preview()
            case "drafts": await drafts()
            case "capture": await capture()
            case "grid": await gridBatch()
            default: log("모르는 조작: \(name)")
            }
            if let counts = PerfProbe.bodySummary() { log("  본문 계산 횟수(\(name)): \(counts)") }
        }
        if deck.isPlaying { deck.togglePlay() }
        return !failed
    }

    /// 프로세스가 시작된 뒤 지난 시간(초)
    static func processAge(at now: Double) -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let started = info.kp_proc.p_un.__p_starttime
        let startDate = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - startDate - (CACurrentMediaTime() - now)
    }

    // MARK: - 창·레이아웃

    private func sidebar() async {
        guard let controller = findSplitController(window?.contentView) else { log("사이드바: 나눔 보기를 찾지 못함"); failed = true; return }
        // 닫기·열기를 번갈아: 짝수 번째가 닫기
        var closes: [UIPerfSample] = [], opens: [UIPerfSample] = []
        let samples = await measure("사이드바 닫기·열기(번갈아)", repeats: 8, window: 0.9) { _ in controller.toggleSidebar(nil) }
        for (index, sample) in samples.enumerated() { if index % 2 == 0 { closes.append(sample) } else { opens.append(sample) } }
        report("  사이드바 닫기", closes)
        report("  사이드바 열기", opens)
    }

    private func inspector() async {
        if let row = store.displayRows.first { store.selection = [row.id] }
        let key = SettingKeys.showTagEditor.name
        let samples = await measure("인스펙터 열기·닫기(번갈아)", repeats: 8, window: 0.9) { _ in
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        }
        report("  인스펙터 열기", samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
        report("  인스펙터 닫기", samples.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        UserDefaults.standard.set(false, forKey: key)
        await wait(0.5)
    }

    private func resize() async {
        guard let window, let original = originalFrame else { return }
        // 끌어서 크기 바꾸기처럼 16ms마다 조금씩(폭 −300 → 되돌리기)
        var costs: [Double] = []
        var cpuCosts: [Double] = []
        recorder.reset()
        let start = CACurrentMediaTime()
        for step in 0..<40 {
            let offset = CGFloat(step < 20 ? step : 39 - step) * 15
            var frame = original
            frame.size.width -= offset
            let t0 = CACurrentMediaTime(), c0 = UIPerfRecorder.threadCPU()
            window.setFrame(frame, display: true)
            costs.append((CACurrentMediaTime() - t0) * 1000)
            cpuCosts.append((UIPerfRecorder.threadCPU() - c0) * 1000)
            await wait(0.016)
        }
        let whole = recorder.result(from: start, to: CACurrentMediaTime(), sync: 0)
        window.setFrame(original, display: true)
        // 좁아지면 사이드바가 저절로 접힐 수 있다. 다음 조작은 열린 상태에서 잰다.
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        await wait(0.5)
        let sorted = costs.sorted()
        let cpuSorted = cpuCosts.sorted()
        log(String(format: "창 크기 바꾸기 40단계: 한 단계 평균 %.1fms · 중앙 %.1fms · 최대 %.1fms · 프레임 최대 간격 %.1fms · 25ms 넘은 프레임 %d · CPU 평균 %.1fms · CPU 중앙 %.1fms",
                   costs.reduce(0, +) / Double(costs.count), sorted[sorted.count / 2], sorted.last ?? 0, whole.maxFrameGap, whole.slowFrames,
                   cpuCosts.reduce(0, +) / Double(cpuCosts.count), cpuSorted[cpuSorted.count / 2]))
    }

    // MARK: - 목록

    private func scrollTable(_ table: NSTableView, label: String) async {
        guard let clip = table.enclosingScrollView?.contentView, let window else { return }
        for (name, step) in [("천천히", 14.0), ("빠르게", 70.0)] {
            var costs: [Double] = []
            recorder.reset()
            let start = CACurrentMediaTime()
            var y = clip.bounds.origin.y
            var down = true
            while CACurrentMediaTime() - start < 3 {
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
            let whole = recorder.result(from: start, to: CACurrentMediaTime(), sync: 0)
            let sorted = costs.sorted()
            log(String(format: "%@ %@ 스크롤 3초: 한 번 평균 %.2fms · 상위 10%% %.2fms · 최대 %.2fms · 메인 일한 합 %.0fms/초 · 프레임 최대 간격 %.1fms · 25ms 넘은 프레임 %d",
                       label, name, costs.reduce(0, +) / Double(costs.count), sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0,
                       whole.busy / 3, whole.maxFrameGap, whole.slowFrames))
        }
        clip.scroll(to: .zero)
        table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    private func scroll() async {
        guard let table else { return }
        if deck.isPlaying { deck.togglePlay() }
        await scrollTable(table, label: "곡 목록(정지)")
        guard deck.canPlay else { return }
        deck.seek(0)
        deck.togglePlay()
        await wait(1)
        await scrollTable(table, label: "곡 목록(재생 중)")
        deck.togglePlay()
    }

    private func select() async {
        guard let table else { return }
        // ↓ 키처럼 한 줄씩 옮겨 고른다(표 → 스토어 선택 → 창 부제·인스펙터 등).
        await measure("곡 선택 한 줄씩", repeats: 12, window: 0.35, rest: 0.1) { index in
            table.selectRowIndexes(IndexSet(integer: 10 + index), byExtendingSelection: false)
            table.scrollRowToVisible(10 + index)
        }
        await measure("곡 여러 개 고르기(⌘A)", repeats: 3, window: 0.6, prepare: { _ in
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            await self.wait(0.3)
        }) { _ in table.selectAll(nil) }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func sidebarItems() async {
        let playlists = store.playlistIndex.values.filter { !$0.isFolder && !$0.isSmart }.sorted { $0.trackIDs.count > $1.trackIDs.count }
        let history = store.history.histories.first
        var targets: [(String, SidebarItem)] = [("전체", .filter(.all))]
        if let big = playlists.first { targets.append(("큰 재생 목록(\(big.trackIDs.count)곡)", .playlist(big.id))) }
        if let small = playlists.last { targets.append(("작은 재생 목록(\(small.trackIDs.count)곡)", .playlist(small.id))) }
        if let history { targets.append(("재생 기록", .history(history.id))) }
        targets.append(("큐 없음 필터", .filter(.noCues)))
        targets.append(("rekordbox 쓰기 대기", .pending))
        for (label, item) in targets + [("전체로 돌아오기", .filter(.all))] {
            await measure("사이드바 항목 → \(label)", repeats: 1, window: 0.8, prepare: { _ in
                if self.store.sidebar == item { self.store.sidebar = .filter(.streaming); await self.wait(0.4) }
            }) { _ in self.store.sidebar = item }
        }
        // 목록 사이를 연달아 옮겨 다니기(재생 목록 → 재생 목록)
        let hop = Array(playlists.prefix(6))
        await measure("재생 목록끼리 옮겨 다니기", repeats: hop.count, window: 0.6) { index in self.store.sidebar = .playlist(hop[index].id) }
        store.sidebar = .filter(.all)
        await wait(0.5)
    }

    private func sort() async {
        guard let table else { return }
        let keys: [(String, NSSortDescriptor)] = [("제목", NSSortDescriptor(key: "title", ascending: true)),
                                                 ("아티스트", NSSortDescriptor(key: "artist", ascending: true)),
                                                 ("BPM", NSSortDescriptor(key: "bpm", ascending: false)),
                                                 ("추가한 날", NSSortDescriptor(key: "imported", ascending: false))]
        let original = table.sortDescriptors
        for (label, descriptor) in keys {
            await measure("정렬 → \(label)", repeats: 1, window: 0.8) { _ in table.sortDescriptors = [descriptor] }
        }
        table.sortDescriptors = original
        await wait(0.5)
    }

    private func search() async {
        let text = "합성 곡 12"
        let prefixes = (1...text.count).map { String(text.prefix($0)) }
        await measure("검색 한 글자씩 입력", repeats: prefixes.count, window: 0.3, rest: 0.05) { index in self.store.search = prefixes[index] }
        await measure("검색 지우기", repeats: 1, window: 0.8) { _ in self.store.search = "" }
    }

    // MARK: - 덱

    private func waitDeck(_ id: String) async {
        for _ in 0..<200 where deck.row?.id != id || !deck.canPlay || deck.waveform == nil { await wait(0.05) }
    }

    private func load() async {
        let rows = Array(store.displayRows.prefix(40).enumerated().filter { $0.offset % 7 == 0 }.map(\.element))
        await measure("덱에 올리기", repeats: rows.count, window: 1.5, rest: 0.5) { index in self.store.loadToDeck(rows[index]) }
        if let last = rows.last { await waitDeck(last.id) }
    }

    private func ensureDeck() async {
        if deck.row == nil, let row = store.displayRows.first { store.loadToDeck(row); await waitDeck(row.id) }
    }

    private func zoom() async {
        await ensureDeck()
        let steps = [8.0, 4, 8, 16, 32, 16]
        let original = deck.zoomSeconds
        await measure("확대·축소(멈춤)", repeats: steps.count, window: 0.4) { index in self.deck.setZoom(steps[index]) }
        deck.seek(10)
        deck.togglePlay()
        await wait(0.5)
        await measure("확대·축소(재생 중)", repeats: steps.count, window: 0.4) { index in self.deck.setZoom(steps[index]) }
        deck.togglePlay()
        deck.setZoom(original)
    }

    private func scrub() async {
        await ensureDeck()
        deck.seek(20)
        deck.togglePlay()
        await wait(0.5)
        var costs: [Double] = []
        recorder.reset()
        let start = CACurrentMediaTime()
        deck.beginScrub()
        for step in 0..<120 {
            let t0 = CACurrentMediaTime()
            deck.scrub(to: 20 + Double(step) * 0.05)
            costs.append((CACurrentMediaTime() - t0) * 1000)
            try? await Task.sleep(for: .milliseconds(16))
        }
        deck.endScrub()
        let whole = recorder.result(from: start, to: CACurrentMediaTime(), sync: 0)
        let sorted = costs.sorted()
        log(String(format: "스크럽 2초(16ms마다): 한 번 평균 %.2fms · 최대 %.2fms · 메인 일한 합 %.0fms/초 · 프레임 최대 간격 %.1fms · 25ms 넘은 프레임 %d",
                   costs.reduce(0, +) / Double(costs.count), sorted.last ?? 0, whole.busy / 2, whole.maxFrameGap, whole.slowFrames))
        await wait(0.3)
        if deck.isPlaying { deck.togglePlay() }
    }

    private func play() async {
        await ensureDeck()
        deck.seek(10)
        recorder.reset()
        deck.togglePlay()
        await wait(0.5)
        let start = CACurrentMediaTime()
        recorder.reset()
        await wait(3)
        let whole = recorder.result(from: start, to: CACurrentMediaTime(), sync: 0)
        log(String(format: "재생 중 가만히 3초: 메인 일한 합 %.0fms/초 · 한 번 최대 %.1fms · 프레임 최대 간격 %.1fms · 25ms 넘은 프레임 %d",
                   whole.busy / 3, whole.longest, whole.maxFrameGap, whole.slowFrames))
        deck.togglePlay()
    }

    // MARK: - 편집

    private func sheet() async {
        let key = SettingKeys.sheetMode.name
        await measure("태그 시트 열기", repeats: 1, window: 1.2) { _ in UserDefaults.standard.set(true, forKey: key) }
        await wait(0.5)
        if let sheet = Self.allTables(window?.contentView).first(where: { $0 is SheetTableView }) {
            await scrollTable(sheet, label: "태그 시트")
        } else {
            log("태그 시트 표를 찾지 못함")
        }
        await measure("태그 시트 닫기(목록으로)", repeats: 1, window: 1.2) { _ in UserDefaults.standard.set(false, forKey: key) }
        await wait(0.5)
        // 다시 목록 표를 붙잡는다(시트를 닫으면 표를 새로 만든다).
        if let window, let table = findTable(window.contentView) { self.table = table }
    }

    private static func allTables(_ view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { allTables($0) }
    }

    private func edit() async {
        await ensureDeck()
        guard deck.canOpenTrackEdit else { log("곡 편집 창: 열 수 없는 곡"); return }
        await measure("곡 편집 창 열기", repeats: 3, window: 1.5, rest: 0.5, prepare: { _ in
            self.windows.trackEdit.window?.close()
            await self.wait(0.3)
        }) { _ in Task { await self.windows.trackEdit.open() } }
        windows.trackEdit.window?.close()
        window?.makeKeyAndOrderFront(nil)
        await wait(0.5)
    }

    /// 측정한 상태의 화면을 눈으로 확인한다(인스펙터 내용, 검색 결과가 없을 때 안내, 여러 곡 선택 부제).
    private func capture() async {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-perf-capture=") }), let window else {
            log("화면 저장: --ui-perf-capture=<폴더>가 없음"); return
        }
        let directory = String(arg.dropFirst("--ui-perf-capture=".count))
        // 화면 기록 권한 없이도 되게 창 뷰(제목 막대 포함)를 직접 그린다.
        func shot(_ name: String) {
            guard let frame = window.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                log("화면 저장 \(name): 실패"); return
            }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let saved = (try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(directory)/\(name).png"))) != nil
            log("화면 저장 \(name): \(saved ? "통과" : "실패")")
        }
        let key = SettingKeys.showTagEditor.name
        if let row = store.displayRows.dropFirst(2).first { store.selection = [row.id] }
        // 반투명 영역(사이드바·인스펙터)은 그림에 안 나오므로 인스펙터 입력 칸 수로 내용이 떴는지 본다.
        func editableFields(_ view: NSView?) -> Int {
            guard let view else { return 0 }
            return ((view as? NSTextField)?.isEditable == true ? 1 : 0) + view.subviews.reduce(0) { $0 + editableFields($1) }
        }
        let closed = editableFields(window.contentView)
        UserDefaults.standard.set(true, forKey: key)
        await wait(1.2)
        shot("inspector")
        log("입력 칸: 인스펙터 닫힘 \(closed)개 · 열림 \(editableFields(window.contentView))개")
        UserDefaults.standard.set(false, forKey: key)
        await wait(1.0)
        log("입력 칸: 다시 닫은 뒤 \(editableFields(window.contentView))개")
        store.selection = Set(store.displayRows.prefix(2).map(\.id))
        await wait(0.5)
        shot("selection")
        store.search = "없는 곡을 찾는 검색어"
        await wait(0.8)
        shot("empty")
        store.search = ""
        await wait(0.5)
    }

    /// 그리드 일괄 추정(#141): 곡마다 초안이 저장되고 진행이 오른다. 사이드바가 이 값을 읽으면 곡마다 재생 목록 List를 다시 비교한다.
    /// 곡마다 추정이 몇 초씩 돌아 곡 12개로 잰다(끝날 때까지, 최대 3분). 초안은 DJC_HOME에 남는다.
    private func gridBatch() async {
        let items = store.rows.prefix(12).map { GridJobItem(uuid: $0.track.uuid, path: $0.track.folderPath, staged: false) }
        guard !items.isEmpty else { log("그리드 일괄 추정: 곡이 없음"); return }
        recorder.reset()
        let start = CACurrentMediaTime()
        store.enqueueGrid(items)
        while store.gridJob != nil, CACurrentMediaTime() - start < 180 { await wait(0.1) }
        let elapsed = (CACurrentMediaTime() - start) * 1000
        let result = recorder.result(from: start, to: CACurrentMediaTime(), sync: 0)
        log(String(format: "그리드 일괄 추정 곡 %d개: 걸린 시간 %.0fms · 메인 일한 합 %.0fms · 한 번 최대 %.1fms · 프레임 최대 간격 %.1fms · 25ms 넘은 프레임 %d · 쓰기 대기 %d곡",
                   items.count, elapsed, result.busy, result.longest, result.maxFrameGap, result.slowFrames, store.pendingLibraryCount))
    }

    private func drafts() async {
        let rows = Array(store.rows.prefix(600))
        await measure("태그 초안 600곡 만들기", repeats: 1, window: 1.5) { _ in self.store.tags.setTag(.comment, "성능 측정 초안", rows: rows) }
        log("쓰기 대기 \(store.pendingLibraryCount)곡")
    }

    private func preview() async {
        let tracks = Array(store.rows.prefix(50))
        guard let id = store.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "성능 측정 목록", tracks: tracks) else {
            log("쓰기 미리 보기: 재생 목록 초안을 만들지 못함"); return
        }
        store.renamingPlaylistID = nil
        await wait(0.5)
        recorder.reset()
        let start = CACurrentMediaTime()
        store.setWriteLock(true)
        do {
            let preview = try await reflection.session.previewWrite(rows: [], playlists: true)
            let whole = recorder.result(from: start, to: CACurrentMediaTime(), sync: 0)
            log(String(format: "쓰기 미리 보기(재생 목록 초안 1건): 걸린 시간 %.0fms · 메인 일한 합 %.0fms · 한 번 최대 %.1fms · 프레임 최대 간격 %.1fms · 재생 목록 %d건",
                       (CACurrentMediaTime() - start) * 1000, whole.busy, whole.longest, whole.maxFrameGap, preview.report.playlistWritten.count))
        } catch {
            log("쓰기 미리 보기 실패: \(AppErrorMessage.message(for: error))")
        }
        store.writeStage = nil
        store.setWriteLock(false)
        store.discardPlaylistDraft(id)
        store.sidebar = .filter(.all)
        await wait(0.5)
    }
}
#endif
