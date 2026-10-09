@testable import DJCrate
import DJCTestKit
import Observation
import DJCDomain
import Foundation
import SwiftUI
import Synchronization
import Testing

@MainActor
@Suite("라이브러리 높이 측정과 적용")
struct LibraryLayoutMetricsTests {
    @Test(arguments: TextScale.steps, [80.0, 150.0, 480.0])
    func 글자_배율의_최소_확대_높이를_실제_적용값으로_쓴다(_ scale: Double, _ requested: Double) {
        let layout = LibraryLayoutMetrics()
        layout.measureDetail(height: 1600, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        layout.request(requested)
        layout.setTextScale(scale)
        let minimum = max(80, TextScale.length(190, scale: scale) - 8
            - WaveformMetrics(scale: scale).overviewHeight - TextScale.length(28, scale: scale))
        #expect(layout.minimumWaveformHeight == minimum)
        #expect(layout.waveformHeight == max(requested, minimum))
    }

    @Test func 최소_파형에서_메뉴와_핸들은_실제_높이를_기준으로_움직인다() {
        let layout = LibraryLayoutMetrics()
        layout.measureDetail(height: 1600, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        layout.request(80)
        layout.setTextScale(1.5)
        var requested = 80.0
        let control = WaveformHeightControl(displayed: layout.waveformHeight, maximum: layout.maximumWaveformHeight,
                                            minimum: layout.minimumWaveformHeight) { requested = $0 }
        #expect(control.canGrow)
        #expect(!control.canShrink)
        control.grow()
        #expect(requested == 156)
        let handle = SplitHandle(height: .constant(80), displayedHeight: layout.waveformHeight,
                                 maximumHeight: layout.maximumWaveformHeight, minimumHeight: layout.minimumWaveformHeight)
        #expect(handle.draggedHeight(from: handle.displayedHeight, translation: 1) == 137)
        #expect(handle.draggedHeight(from: handle.displayedHeight, translation: -100) == 136)
        // 끄는 중 표시 높이가 바뀌어도 시작점에 누적 이동량을 더한다.
        #expect(handle.draggedHeight(from: 136, translation: 30) == 166)
        #expect(handle.draggedHeight(from: 136, translation: 1000) == 480)
        #expect(!WaveformHeightControl(displayed: 136, maximum: 480, minimum: 136) { _ in }.canShrink)
        #expect(DeckLayout.steppedWaveformHeight(displayed: 146, direction: -1, maximum: 480, minimum: 136) == 136)
    }

    @Test func 낮은_창의_조작_상한은_실제_최소_높이보다_작아지지_않는다() {
        let layout = LibraryLayoutMetrics()
        layout.setTextScale(1.5)
        layout.measureDetail(height: 900, deckHeight: 456, waveformHeight: 136, hasTrack: true)
        layout.measureDetail(height: 650, deckHeight: 456, waveformHeight: 136, hasTrack: true)
        layout.request(480)
        #expect(layout.waveformHeight == 136)
        #expect(layout.maximumWaveformHeight == 136)
        let control = WaveformHeightControl(displayed: layout.waveformHeight, maximum: layout.maximumWaveformHeight,
                                            minimum: layout.minimumWaveformHeight) { _ in }
        #expect(!control.canGrow && !control.canShrink)
        #expect(layout.viewportHeight == 453)
    }

    @Test func 배율과_창_크기는_저장한_pt_요청값을_바꾸지_않는다() throws {
        let domain = TestDefaults.suiteName("waveform-height")
        let defaults = TestDefaults.open(domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(80.0, forKey: SettingKeys.waveformHeight.name)
        let layout = LibraryLayoutMetrics()
        layout.request(defaults.double(forKey: SettingKeys.waveformHeight.name))
        layout.setTextScale(1.5)
        #expect(layout.waveformHeight == 136)
        #expect(defaults.double(forKey: SettingKeys.waveformHeight.name) == 80)
        layout.setTextScale(1)
        #expect(layout.waveformHeight == 80)
        layout.setTextScale(1.5)
        let control = WaveformHeightControl(displayed: layout.waveformHeight, maximum: layout.maximumWaveformHeight,
                                            minimum: layout.minimumWaveformHeight) { defaults.set($0, forKey: SettingKeys.waveformHeight.name) }
        control.grow()
        layout.request(defaults.double(forKey: SettingKeys.waveformHeight.name))
        #expect(layout.waveformHeight == 156)
        layout.measureDetail(height: 1600, deckHeight: 476, waveformHeight: 156, hasTrack: true)
        layout.measureDetail(height: 650, deckHeight: 476, waveformHeight: 156, hasTrack: true)
        #expect(layout.waveformHeight == 136)
        #expect(defaults.double(forKey: SettingKeys.waveformHeight.name) == 156)
        layout.measureDetail(height: 1600, deckHeight: 456, waveformHeight: 136, hasTrack: true)
        #expect(layout.waveformHeight == 156)
        layout.setTextScale(1)
        #expect(layout.waveformHeight == 156)
        #expect(defaults.double(forKey: SettingKeys.waveformHeight.name) == 156)
    }

    @Test func 들어맞는_창의_원시_높이는_덱과_파형에_알리지_않는다() {
        let layout = LibraryLayoutMetrics()
        layout.measureDetail(height: 900, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        let changed = Mutex(false)
        withObservationTracking {
            _ = layout.waveformHeight
            _ = layout.viewportHeight
        } onChange: { changed.withLock { $0 = true } }
        for height in stride(from: 900.0, through: 748, by: -8) {
            layout.measureDetail(height: height, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        }
        #expect(!changed.withLock { $0 })
        #expect(layout.waveformHeight == 150)
        #expect(layout.viewportHeight == 390)
        #expect(layout.maximumWaveformHeight == 311)
    }

    @Test func 메뉴_문맥은_창_높이가_바뀌어도_키울_줄일_수_있는지가_같으면_알리지_않는다() {
        let layout = LibraryLayoutMetrics()
        layout.measureDetail(height: 900, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        #expect(layout.canGrowWaveform && layout.canShrinkWaveform)
        let changed = Mutex(false)
        withObservationTracking {
            _ = layout.canGrowWaveform
            _ = layout.canShrinkWaveform
        } onChange: { changed.withLock { $0 = true } }
        let maximum = layout.maximumWaveformHeight
        for height in stride(from: 900.0, through: 748, by: -8) {
            layout.measureDetail(height: height, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        }
        // 상한은 단계마다 바뀌지만 메뉴가 쓰는 두 값은 그대로다.
        #expect(layout.maximumWaveformHeight != maximum)
        #expect(!changed.withLock { $0 })
        // 메뉴를 누르면 그때의 보이는 높이·상한으로 한 칸 움직인다.
        var requested: Double?
        let menu = layout.waveformHeightMenu { requested = $0 }
        menu.grow()
        #expect(requested == 150 + DeckLayout.waveformHeightStep)
        layout.request(480)
        #expect(layout.waveformHeight == layout.maximumWaveformHeight)
        #expect(!layout.canGrowWaveform && layout.canShrinkWaveform)
        #expect(changed.withLock { $0 })
        menu.shrink()
        #expect(requested == layout.maximumWaveformHeight - DeckLayout.waveformHeightStep)
    }

    @Test func 낮아진_창과_알림과_머리글은_기존_최소_높이_규칙을_쓴다() {
        let layout = LibraryLayoutMetrics()
        layout.request(480)
        layout.measureDetail(height: 650, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        layout.measureNotice(30)
        layout.measureListHeader(60)
        #expect(layout.waveformHeight == DeckLayout.waveformHeight(requested: 480, detailHeight: 650,
                                                                  deckChromeHeight: 240, otherHeight: 97))
        #expect(layout.viewportHeight == 403)
        #expect(650 - layout.viewportHeight - 97 == DeckLayout.minimumLibraryHeight)
        layout.measureDetail(height: 100, deckHeight: 500, waveformHeight: 80, hasTrack: true)
        #expect(layout.viewportHeight == 403)
    }

    @Test func 곡_내용만_늘면_파형을_보존하고_창을_줄였다_키우면_요청값을_복원한다() {
        let layout = LibraryLayoutMetrics()
        layout.measureDetail(height: 1000, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        layout.request(480)
        #expect(layout.waveformHeight == 480)
        layout.measureDetail(height: 1000, deckHeight: 880, waveformHeight: 480, hasTrack: true)
        #expect(layout.waveformHeight == 480)
        layout.measureDetail(height: 650, deckHeight: 880, waveformHeight: 480, hasTrack: true)
        #expect(layout.waveformHeight == 80)
        #expect(layout.viewportHeight == 453)
        layout.measureDetail(height: 1200, deckHeight: 480, waveformHeight: 80, hasTrack: true)
        #expect(layout.waveformHeight == 480)
        #expect(layout.viewportHeight == 880)
    }

    @Test func 같은_값을_반복해도_적용값을_알리지_않는다() {
        let layout = LibraryLayoutMetrics()
        let changed = Mutex(false)
        withObservationTracking {
            _ = layout.waveformHeight
            _ = layout.maximumWaveformHeight
            _ = layout.viewportHeight
        } onChange: { changed.withLock { $0 = true } }
        layout.request(150)
        layout.measureNotice(0)
        layout.measureListHeader(40)
        layout.measureDetail(height: 650, deckHeight: 390, waveformHeight: 150, hasTrack: true)
        #expect(!changed.withLock { $0 })
    }
}
