import DJCApplication
@testable import DJCrate
import AppKit
import DJCDomain
import DJCAnalysis
import DJCStorage
import Foundation
import QuartzCore
import RekordboxFixtures
import SwiftUI
import Testing

#if DEBUG
/// 창 크기·사이드바·인스펙터가 움직이는 동안 큰 뷰의 본문이 프레임마다 다시 계산되지 않는다(#138).
/// 덱이 잰 높이(줄바꿈으로 프레임마다 바뀐다)를 그 뷰의 `@State`로 들면, 측정이 바뀔 때마다 본문이 다시 계산돼
/// 주 창 전체(툴바·사이드바·메뉴)와 덱 전체를 다시 잡느라 25ms를 넘는 프레임이 생겼다.
/// 계산 횟수는 `PerfProbe.body`가 센다. 다른 UI 시험의 전역 계측이 섞이지 않게 단독 실행한다.
/// `DJC_LAYOUT_RECOMPUTE_TESTS=1 swift test --filter LayoutRecomputeTests`
@MainActor
@Suite("창 크기·여닫기 — 본문 다시 계산", .serialized, .tags(.perfContract),
       .enabled(if: ProcessInfo.processInfo.environment["DJC_LAYOUT_RECOMPUTE_TESTS"] != nil
                || ProcessInfo.processInfo.environment["DJC_LAYOUT_BENCHMARK_DB"] != nil))
struct LayoutRecomputeTests {
    /// 합성 곡 하나를 덱에 올린 주 창(사이드바 열림)
    private func mainWindow(width: Double = 1440, waveformHeight: Double = 150,
                            prepareStore: (LibraryStore) -> Void = { _ in }) async throws -> (window: NSWindow, deck: DeckModel, close: () -> Void) {
        _ = NSApplication.shared
        let settingNames = [SettingKeys.sidebarVisible.name, SettingKeys.showTagEditor.name, SettingKeys.sheetMode.name, SettingKeys.waveformHeight.name, SettingKeys.cueListFilter.name]
        let savedSettings = settingNames.map { UserDefaults.standard.object(forKey: $0) }
        func restoreSettings() {
            for (key, value) in zip(settingNames, savedSettings) { UserDefaults.standard.set(value, forKey: key) }
        }
        var prepared = false
        var cleanup: () -> Void = restoreSettings
        defer { if !prepared { cleanup() } }
        UserDefaults.standard.set(true, forKey: SettingKeys.sidebarVisible.name)
        UserDefaults.standard.set(false, forKey: SettingKeys.showTagEditor.name)
        UserDefaults.standard.set(false, forKey: SettingKeys.sheetMode.name)
        UserDefaults.standard.set(waveformHeight, forKey: SettingKeys.waveformHeight.name)
        UserDefaults.standard.set(CueListFilter.all.rawValue, forKey: SettingKeys.cueListFilter.name)
        let fixture = try historyFixture()
        let snapshot = ProcessInfo.processInfo.environment["DJC_LAYOUT_BENCHMARK_DB"].map { URL(filePath: $0) } ?? fixture.database
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                      rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot)
        await store.load(snapshot: snapshot)
        prepareStore(store)
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let controller = NSHostingController(rootView: ContentView(store: store, deck: deck, app: AppComposition(store: store, deck: deck), windowFrameRestored: false))
        let window = UnconstrainedWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        cleanup = { window.close(); restoreSettings() }
        window.setContentSize(NSSize(width: width, height: 900))
        window.orderBack(nil)
        let row = try #require(store.rows.first)
        deck.load(row)
        for _ in 0..<300 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(deck.draft != nil)
        if ProcessInfo.processInfo.environment["DJC_LAYOUT_BENCHMARK_DB"] != nil {
            try #require(deck.hasRekordboxGrid)
            deck.waveform = try WaveformCache.load(fileAt: URL(filePath: row.track.folderPath), key: row.track.uuid)
        }
        try await Task.sleep(for: .milliseconds(800))
        prepared = true
        return (window, deck, cleanup)
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @Test func 초안_있는_곡과_없는_곡을_골라도_목록_첫_줄_위치가_같다() async throws {
        var captured: LibraryStore?
        let (window, _, close) = try await mainWindow { captured = $0 }
        defer { close() }
        let store = try #require(captured)
        let draftRow = try #require(store.rows.dropFirst().first)
        let cleanRow = try #require(store.rows.first)
        var draft = TagDraft(track: draftRow.track); draft.fields.comment = "내 편집"
        store.tagDrafts[draftRow.track.uuid] = draft
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.identifier == KeyRouter.trackListID { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(window.contentView.flatMap { table(in: $0) })
        var positions: [Double] = []
        for row in [cleanRow, draftRow, cleanRow, draftRow] {
            store.selection = [row.id]
            try await settle(window)
            positions.append(list.convert(list.rect(ofRow: 0), to: nil).minY)
        }
        print("TRACE 선택별 목록 첫 줄:", positions)
        #expect(positions.allSatisfy { abs($0 - positions[0]) < 0.5 })
    }

    @Test func 창_폭을_조금씩_바꿔도_주_창_본문은_거의_다시_계산되지_않는다() async throws {
        let (window, _, close) = try await mainWindow()
        defer { close() }
        PerfProbe.countsBodies = true
        defer { PerfProbe.countsBodies = false }
        try await settle(window)
        PerfProbe.resetBodyCounts()
        // 끌어서 크기 바꾸기처럼 조금씩 좁혔다가 되돌린다.
        for step in 0..<40 {
            let offset = Double(step < 20 ? step : 39 - step) * 15
            window.setContentSize(NSSize(width: 1440 - offset, height: 900))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        try await settle(window)
        print("TRACE 창 폭 40단계:", PerfProbe.bodySummary() ?? "-")
        // 한 단계마다가 아니라 배치 단계(폭 구간)나 덱 높이가 바뀔 때 몇 번뿐이어야 한다(최신 dev 재현: 155·266번).
        #expect(PerfProbe.bodyCount("ContentView") <= 2)
        #expect(PerfProbe.bodyCount("DeckView") <= 5)
    }

    @Test func 창_높이가_바뀌어도_파형과_덱이_들어맞으면_큰_본문을_다시_계산하지_않는다() async throws {
        PerfProbe.countsBodies = true
        defer { PerfProbe.countsBodies = false }
        let (window, _, close) = try await mainWindow()
        defer { close() }
        try await settle(window)
        let waveformHeight = try #require(PerfProbe.lastWaveformHeight)
        PerfProbe.resetBodyCounts()
        for step in 0..<40 {
            let offset = Double(step < 20 ? step : 39 - step) * 8
            window.setContentSize(NSSize(width: 1440, height: 900 - offset))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        try await settle(window)
        print("TRACE 창 높이 40단계:", PerfProbe.bodySummary() ?? "-")
        #expect(PerfProbe.lastWaveformHeight == waveformHeight)
        #expect(PerfProbe.bodyCount("ContentView") <= 2)
        #expect(PerfProbe.bodyCount("LibraryDetail") <= 2)
        #expect(PerfProbe.bodyCount("DeckView") <= 5)
        #expect(PerfProbe.bodyCount("TrackListView.update") <= 2)
        // 파형 높이 상한은 단계마다 바뀌어도 메뉴('파형 크게·작게') 문맥은 다시 싣지 않는다. 실으면 창이 앞에 있을 때
        // 메뉴 막대 전체(`AppCommands`)를 단계마다 다시 만든다(최신 dev 재현: 40단계에 41번).
        #expect(PerfProbe.bodyCount("LibraryWaveformHeightContext") <= 2)
    }

    @Test func 창_높이에_맞춰_파형을_줄여도_덱_전체_본문은_다시_계산하지_않는다() async throws {
        PerfProbe.countsBodies = true
        defer { PerfProbe.countsBodies = false }
        let (window, _, close) = try await mainWindow(waveformHeight: 480)
        defer { close() }
        // 곡을 올릴 때 보존한 요청 높이를 첫 창 크기 변경으로 맞춘 뒤 왕복을 비교한다.
        window.setContentSize(NSSize(width: 1440, height: 892))
        try await settle(window)
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await settle(window)
        let originalHeight = try #require(PerfProbe.lastWaveformHeight)
        var heights: [Double] = []
        PerfProbe.resetBodyCounts()
        for step in 0..<40 {
            let offset = Double(step < 20 ? step : 39 - step) * 8
            window.setContentSize(NSSize(width: 1440, height: 900 - offset))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            heights.append(try #require(PerfProbe.lastWaveformHeight))
        }
        try await settle(window)
        print("TRACE 파형이 줄어드는 창 높이 40단계:", PerfProbe.bodySummary() ?? "-")
        // 높이 적용·복원은 계속 일어나되, 헤더·큐 목록·나머지 조작부까지 다시 만들지 않는다.
        #expect(originalHeight - (heights.min() ?? originalHeight) > 100)
        #expect(PerfProbe.lastWaveformHeight == originalHeight)
        #expect(UserDefaults.standard.double(forKey: SettingKeys.waveformHeight.name) == 480)
        #expect(PerfProbe.bodyCount("ContentView") <= 2)
        #expect(PerfProbe.bodyCount("LibraryDetail") <= 2)
        #expect(PerfProbe.bodyCount("DeckView") == 0)
        #expect(PerfProbe.bodyCount("TrackListView.update") <= 2)
    }

    @Test func 창_높이에_맞춰_파형을_줄여도_이전_다음_곡은_다시_찾지_않는다() async throws {
        PerfProbe.countsBodies = true
        defer { PerfProbe.countsBodies = false }
        var captured: LibraryStore?
        let (window, deck, close) = try await mainWindow(waveformHeight: 480) { captured = $0 }
        defer { close() }
        let store = try #require(captured)
        window.setContentSize(NSSize(width: 1440, height: 892))
        try await settle(window)
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await settle(window)
        PerfProbe.resetBodyCounts()
        for step in 0..<40 {
            let offset = Double(step < 20 ? step : 39 - step) * 8
            window.setContentSize(NSSize(width: 1440, height: 900 - offset))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        try await settle(window)
        print("TRACE 파형이 줄어드는 창 높이 40단계(이전·다음 곡):", PerfProbe.bodySummary() ?? "-")
        // 파형 칸은 높이에 맞춰 다시 계산되지만, 목록·덱 곡이 그대로라 이전·다음 곡은 다시 찾지 않는다.
        // 찾을 때마다 표시 목록을 훑는다(덱 곡이 목록에 없으면 끝까지, 최신 dev 재현: 40단계에 38번).
        #expect(PerfProbe.bodyCount("DeckWaveformGroup") > 20)
        #expect(PerfProbe.bodyCount("DeckTrackNavigation.adjacentRows") == 0)
        // 덱 곡이 바뀌면 다시 찾는다. 불러오기를 마저 기다려 다음 시험의 본문 횟수에 섞이지 않게 한다.
        deck.load(try #require(store.rows.dropFirst().first))
        await deck.loadTask?.value
        try await settle(window)
        #expect(PerfProbe.bodyCount("DeckTrackNavigation.adjacentRows") >= 1)
    }

    private func splitController(_ view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController { return controller }
        for sub in view.subviews { if let found = splitController(sub) { return found } }
        return nil
    }

    @Test func 사이드바를_여닫아도_덱은_여닫을_때마다_몇_번만_다시_계산된다() async throws {
        let (window, _, close) = try await mainWindow()
        defer { close() }
        PerfProbe.countsBodies = true
        defer { PerfProbe.countsBodies = false }
        try await settle(window)
        let controller = try #require(splitController(window.contentView))
        PerfProbe.resetBodyCounts()
        for _ in 0..<8 {
            controller.toggleSidebar(nil)
            try await Task.sleep(for: .milliseconds(700))
        }
        // 애니메이션 프레임마다가 아니라 큐 목록 폭 단계가 바뀔 때만 덱을 다시 계산한다.
        #expect(PerfProbe.bodyCount("DeckView") <= 20)
        #expect(PerfProbe.bodyCount("ContentView") <= 12)
    }
    @Test func 곡_로드와_덱_내용_변경은_파형_높이를_줄이지_않는다() async throws {
        PerfProbe.countsBodies = true
        defer { PerfProbe.countsBodies = false }
        let (window, deck, close) = try await mainWindow()
        defer { close() }
        try await settle(window)
        let loaded = try #require(PerfProbe.lastWaveformHeight)
        #expect(loaded == 150)
        deck.loudness = Loudness(integrated: -5.4, peak: 0, clippedRuns: 1500)
        try await settle(window)
        #expect(PerfProbe.lastWaveformHeight == loaded)
        let row = deck.row
        deck.load(nil)
        try await settle(window)
        deck.load(row)
        try await settle(window)
        #expect(PerfProbe.lastWaveformHeight == loaded)
    }

    @Test func 수동_파형_높이를_바꾸고_창_높이를_바꿔도_저장값은_유지한다() async throws {
        PerfProbe.countsBodies = true
        defer { PerfProbe.countsBodies = false }
        let (window, _, close) = try await mainWindow()
        defer { close() }
        UserDefaults.standard.set(480.0, forKey: SettingKeys.waveformHeight.name)
        try await settle(window)
        let grown = try #require(PerfProbe.lastWaveformHeight)
        #expect(grown > 150)
        window.setContentSize(NSSize(width: 1440, height: 680))
        try await settle(window)
        #expect(try #require(PerfProbe.lastWaveformHeight) < grown)
        #expect(UserDefaults.standard.double(forKey: SettingKeys.waveformHeight.name) == 480)
        UserDefaults.standard.set(80.0, forKey: SettingKeys.waveformHeight.name)
        try await settle(window)
        #expect(PerfProbe.lastWaveformHeight == 80)
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await settle(window)
        #expect(UserDefaults.standard.double(forKey: SettingKeys.waveformHeight.name) == 80)
        #expect(PerfProbe.lastWaveformHeight == 80)
    }

    /// 실제 커서·키·포커스를 건드리지 않는 테스트 창에서 번갈아 A/B할 때 쓴다.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_LAYOUT_BENCHMARK_DB"] != nil))
    func 저부하_배치_성능_기록() async throws {
        let (window, deck, close) = try await mainWindow(width: 1700)
        defer { close() }
        let recorder = UIPerfRecorder()
        recorder.start(in: try #require(window.contentView))
        PerfProbe.countsBodies = true
        defer { PerfProbe.countsBodies = false }
        try await settle(window)
        let controller = try #require(splitController(window.contentView))
        for name in ["sidebar", "inspector", "resize"] {
            recorder.reset()
            PerfProbe.resetBodyCounts()
            let start = CACurrentMediaTime(), cpu = UIPerfRecorder.threadCPU()
            var steps: [Double] = [], stepCPUs: [Double] = []
            if name == "resize" {
                for step in 0..<40 {
                    let offset = Double(step < 20 ? step : 39 - step) * 15
                    let t = CACurrentMediaTime(), c = UIPerfRecorder.threadCPU()
                    window.setContentSize(NSSize(width: 1700 - offset, height: 900))
                    window.contentView?.layoutSubtreeIfNeeded()
                    steps.append((CACurrentMediaTime() - t) * 1000)
                    stepCPUs.append((UIPerfRecorder.threadCPU() - c) * 1000)
                    try await Task.sleep(for: .milliseconds(16))
                }
                try await settle(window)
            } else {
                for index in 0..<8 {
                    if name == "sidebar" { controller.toggleSidebar(nil) }
                    else { UserDefaults.standard.set(index % 2 == 0, forKey: SettingKeys.showTagEditor.name) }
                    try await Task.sleep(for: .milliseconds(700))
                }
            }
            let end = CACurrentMediaTime(), cpuMS = (UIPerfRecorder.threadCPU() - cpu) * 1000
            let sample = recorder.result(from: start, to: end, sync: 0)
            func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[sorted.count / 2] }
            let values: [String: Any] = ["operation": name, "cpu_ms": cpuMS, "busy_ms": sample.busy,
                "max_frame_gap_ms": sample.maxFrameGap, "slow_frames": sample.slowFrames,
                "frames": recorder.frames.count, "step_median_ms": median(steps), "step_cpu_median_ms": median(stepCPUs),
                "ContentView": PerfProbe.bodyCount("ContentView"), "LibraryDetail": PerfProbe.bodyCount("LibraryDetail"),
                "DeckView": PerfProbe.bodyCount("DeckView"), "CueListView": PerfProbe.bodyCount("CueListView"),
                "TrackTable": PerfProbe.bodyCount("TrackListView.update"), "body_summary": PerfProbe.bodySummary() ?? ""]
            let json = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            print("LAYOUT_SAMPLE " + String(decoding: json, as: UTF8.self))
        }
        #expect(!deck.isPlaying)
    }

}

#endif

/// 화면보다 큰 창 크기도 그대로 둔다(시험 기계의 화면 크기와 관계없이 같은 폭·높이로 잰다).
final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
