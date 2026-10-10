@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestKit
import Foundation
import SwiftUI
import Testing

#if DEBUG
@MainActor
@Suite("덱 — 파형 묶음의 빈 높이", .serialized)
struct DeckWaveformLayoutTests {
    /// 배율·요청값 식 12경우는 `LibraryLayoutMetricsTests`가 순수하게 본다. 실제 창은 배율마다 한 번, 요청값마다 한 번 이상
    /// (가장 큰 배율의 최소 요청 포함) 띄워 묶음이 빈 높이 없이 채워지는 연결만 본다.
    @Test(arguments: zip(TextScale.steps, [80.0, 150.0, 480.0, 80.0]))
    func 조작부가_남긴_최소_높이는_확대_파형이_채운다(_ scale: Double, _ requested: Double) async throws {
        _ = NSApplication.shared
        let harness = try DeckHarness()
        try await harness.loaded()
        let deck = harness.deck
        let domain = TestDefaults.suiteName("deck-waveform-layout")
        let defaults = TestDefaults.open(domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = LibraryStore.test(settings: SettingsStore(defaults: defaults, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        let key = String(describing: ObjectIdentifier(deck))
        let zoomKey = "deck.zoom.\(key)", groupKey = "deck.waveGroup.\(key)"
        defer {
            SelfTestFrames.frames.removeValue(forKey: zoomKey)
            SelfTestFrames.frames.removeValue(forKey: groupKey)
        }
        let controller = NSHostingController(rootView: DeckView(store: store, deck: deck, widthClass: DeckWidthClass(width: 1300))
            .environment(\.deckWaveformHeight, requested)
            .environment(\.textScale, scale).defaultAppStorage(defaults)
            .fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1300, height: 900))
        defer { window.close() }
        // 창 표시·픽셀에 기대지 않고 두 실측 크기가 연속으로 같아진 뒤 검증한다.
        var previous: (zoom: CGRect, group: CGRect)?
        var settled = 0
        for _ in 0..<80 where settled < 2 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let zoom = SelfTestFrames.frames[zoomKey], let group = SelfTestFrames.frames[groupKey],
               !zoom.isEmpty, !group.isEmpty {
                settled = previous?.zoom == zoom && previous?.group == group ? settled + 1 : 0
                previous = (zoom, group)
            }
            if settled < 2 { try await Task.sleep(for: .milliseconds(50)) }
        }
        let zoom = try #require(SelfTestFrames.frames[zoomKey])
        let group = try #require(SelfTestFrames.frames[groupKey])
        let overviewAndTempo = WaveformMetrics(scale: scale).overviewHeight + TextScale.length(28, scale: scale)
        let blank = group.height - zoom.height - 8 - overviewAndTempo
        print("[덱 파형 배치] 배율=\(scale) 요청=\(requested) 확대=\(zoom.height) 묶음=\(group.height) 빈 높이=\(blank)")
        #expect(settled == 2)
        #expect(abs(blank) < 1)
        #expect(abs(zoom.minY - group.minY) < 1)
        #expect(zoom.height >= requested)
        #expect(!window.isVisible)
    }
}
#endif
