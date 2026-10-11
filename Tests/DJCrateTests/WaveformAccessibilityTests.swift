@testable import DJCrate
import CoreGraphics
import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit
import SwiftUI
import Testing

/// 파형·레벨 미터의 VoiceOver 글자와 로터 항목. Canvas에만 그려지던 정보를 말로 옮긴다.
@Suite("파형 접근성 — 값·로터")
struct WaveformAccessibilityTests {
    /// 120 BPM, 0초부터 0.5초 간격(2초마다 마디)
    let grid = BeatGrid(beats: (0..<400).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: Double($0) * 0.5) })

    @Test func 시각은_분_초로_읽는다() {
        // "1:23"은 VoiceOver가 시각(1시 23분)으로 읽는다.
        #expect(83.7.spokenClockText == "1분 23초")
        #expect(23.2.spokenClockText == "23초")
        #expect(0.0.spokenClockText == "0초")
        #expect(120.0.spokenClockText == "2분 0초")
    }

    @Test func 확대_파형_값은_위치_마디_다음_메모리_큐까지() {
        let cues = [EditableCue(kind: .memory, time: 87), EditableCue(kind: .hot(0), time: 84)]
        #expect(WaveformAccessibility.zoomValue(time: 83.2, grid: grid, cues: cues) == "1분 23초, 42.3마디, 다음 메모리 큐까지 8박")
        #expect(WaveformAccessibility.zoomValue(time: 83.2, grid: nil, cues: cues) == "1분 23초, 다음 메모리 큐까지 4초")
        #expect(WaveformAccessibility.zoomValue(time: 90, grid: grid, cues: cues) == "1분 30초, 46.1마디")
        let far = [EditableCue(kind: .memory, time: 100)]
        #expect(WaveformAccessibility.zoomValue(time: 20, grid: grid, cues: far) == "20초, 11.1마디, 다음 메모리 큐까지 40마디")
        #expect(WaveformAccessibility.zoomValue(time: 67, grid: grid, cues: far) == "1분 7초, 34.3마디, 다음 메모리 큐까지 16마디 2박")
    }

    @Test func 전체_파형_값은_곡_길이_중_위치() {
        #expect(WaveformAccessibility.overviewValue(time: 83.2, duration: 180, grid: grid) == "전체 3분 0초 중 1분 23초, 42.3마디")
        #expect(WaveformAccessibility.overviewValue(time: 5, duration: 180, grid: nil) == "전체 3분 0초 중 5초")
    }

    @Test func 레벨_미터_값은_지금_피크와_클리핑() {
        var reading = LevelMeter.Reading()
        reading.peak = (0.5, 0.25)
        reading.time = 100
        #expect(WaveformAccessibility.meterValue(reading, playing: true, now: 100.1) == "지금 피크 -6 dB, 클리핑 없음")
        reading.clipCount = 3
        #expect(WaveformAccessibility.meterValue(reading, playing: true, now: 100.1) == "지금 피크 -6 dB, 0dBFS를 3번 넘음")
        #expect(WaveformAccessibility.meterValue(reading, playing: true, now: 101) == "소리 없음, 0dBFS를 3번 넘음", "탭이 한동안 안 오면 무음")
        #expect(WaveformAccessibility.meterValue(reading, playing: false, now: 100.1) == "멈춤, 0dBFS를 3번 넘음")
        reading.peak = (1.2, 0.8)
        #expect(WaveformAccessibility.meterValue(reading, playing: true, now: 100.1) == "지금 피크 +2 dB, 0dBFS를 3번 넘음")
    }

    @Test func 큐_로터는_시간순이고_종류_이름_루프를_읽는다() {
        let hot = EditableCue(kind: .hot(0), time: 10, name: "Drop")
        let memory = EditableCue(kind: .memory, time: 5, loop: .init(end: 7, beats: 4))
        let markers = WaveformAccessibility.cueMarkers([hot, memory])
        #expect(markers.map(\.label) == ["메모리 큐, 5초, 4박 루프", "핫큐 A, 10초, Drop"])
        #expect(markers.map(\.time) == [5, 10])
        #expect(Set(markers.map(\.id)).count == 2)
    }

    /// #145: rekordbox 자동 큐는 파형 이름·로터에 '자동'을 함께 알린다(고치면 이름이 비어 빠진다).
    @Test func 자동_큐는_파형_이름과_로터에_자동을_붙인다() {
        let auto = EditableCue(kind: .memory, time: 1, name: "1.1Bars")
        #expect(WaveformAccessibility.cueMarkers([auto]).map(\.label) == ["메모리 큐, 1초, 1.1Bars, rekordbox 자동 큐"])
        #expect(WaveformAccessibility.cueName(auto) == "1.1Bars · 자동")
        #expect(WaveformAccessibility.cueName(EditableCue(kind: .memory, time: 1, name: "Drop")) == "Drop")
    }

    @Test func 섹션_로터는_에너지를_세_단계로_읽는다() {
        let markers = WaveformAccessibility.sectionMarkers([(start: 0, score: 1), (start: 30, score: 5), (start: 62, score: 9)])
        #expect(markers.map(\.label) == ["섹션 1, 0초, 에너지 약함", "섹션 2, 30초, 에너지 보통", "섹션 3, 1분 2초, 에너지 강함"])
        #expect(WaveformAccessibility.sectionMarkers([(start: 0, score: 1)]).map(\.label) == ["섹션 1, 0초"], "비교할 섹션이 없으면 에너지는 말하지 않는다")
    }

    @Test func 조성_로터는_바뀌는_곳만() {
        #expect(WaveformAccessibility.keyChangeMarkers([(start: 0, name: "8A")]).isEmpty)
        let markers = WaveformAccessibility.keyChangeMarkers([(start: 0, name: "8A"), (start: 60, name: "9A"), (start: 90, name: "8A")])
        #expect(markers.map(\.label) == ["조성 8A에서 9A로, 1분 0초", "조성 9A에서 8A로, 1분 30초"])
    }

    @Test func 제안_로터() {
        #expect(WaveformAccessibility.suggestionMarkers([30, 12]).map(\.label) == ["메모리 큐 제안, 12초", "메모리 큐 제안, 30초"])
    }
}

@Suite("확대 파형 — 포인터 아래 대상")
struct ZoomPointerTests {
    let cue = EditableCue(kind: .memory, time: 10)
    /// 8초가 왼쪽 끝, 1초 = 100pt
    let xOf = { (t: Double) in CGFloat((t - 8) * 100) }

    /// 그리드 편집 여부는 받지 않는다: 그리드 편집 중에도 파형 끌기는 스크럽·큐 끌기다(#117).
    func target(_ x: CGFloat, suggestions: [Double] = [12], cues: [EditableCue]? = nil) -> ZoomPointerTarget {
        ZoomPointerTarget.at(x: x, cues: cues ?? [cue], suggestions: suggestions, xOf: xOf)
    }

    @Test func 큐_선은_7pt_제안은_11pt_안이면_잡힌다() {
        #expect(target(205) == .cue(cue.id))
        #expect(target(208) == .empty)
        #expect(target(390) == .suggestion(12))
        #expect(target(412) == .empty)
    }

    @Test func 큐가_제안보다_먼저() {
        let onSuggestion = EditableCue(kind: .hot(1), time: 12.02)
        #expect(target(400, cues: [cue, onSuggestion]) == .cue(onSuggestion.id))
    }

    @Test func 포인터_모양() {
        #expect(ZoomPointerTarget.pointer(hover: .empty, drag: nil) == .grabIdle)
        #expect(ZoomPointerTarget.pointer(hover: .cue(cue.id), drag: nil) == .columnResize)
        #expect(ZoomPointerTarget.pointer(hover: .suggestion(12), drag: nil) == .arrow)
        #expect(ZoomPointerTarget.pointer(hover: .cue(cue.id), drag: .empty) == .grabActive, "끄는 중에는 끌기 시작한 대상을 따른다")
        #expect(ZoomPointerTarget.pointer(hover: .empty, drag: .suggestion(12)) == .grabActive)
        #expect(ZoomPointerTarget.pointer(hover: .empty, drag: .cue(cue.id)) == .columnResize)
    }
}

/// 호버한 대상만 강조한다: 같은 곡을 호버 없이·호버해서 그려 달라진 열이 그 대상 자리뿐인지 본다.
@MainActor
@Suite("확대 파형 — 호버 강조")
struct ZoomHoverRenderTests {
    static let size = CGSize(width: 880, height: 169)

    /// 16초 창, 재생 위치 10초: x = (t − 2) × 55
    func harness() async throws -> DeckHarness {
        let hot = Cue(id: "hot", contentID: "1", kind: 1, inMsec: 12_000, name: "", colorTableIndex: nil)
        let memory = Cue(id: "mem", contentID: "1", kind: 0, inMsec: 6_000, name: "", colorTableIndex: nil)
        let h = try DeckHarness(cues: [hot, memory])
        try await h.loaded()
        h.deck.zoomSeconds = 16
        h.deck.seek(10)
        h.deck.suggestions = [7.5]
        return h
    }

    func pixels(_ deck: DeckModel, hover: ZoomPointerTarget) throws -> [UInt8] {
        let renderer = ImageRenderer(content: ZoomWaveformView(deck: deck, hover: hover).frame(width: Self.size.width, height: Self.size.height))
        let image = try #require(renderer.cgImage)
        let width = Int(Self.size.width), height = Int(Self.size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(origin: .zero, size: Self.size))
        return data
    }

    /// 두 그림이 다른 열(x)
    func changedColumns(_ a: [UInt8], _ b: [UInt8]) -> Set<Int> {
        let width = Int(Self.size.width)
        var columns = Set<Int>()
        for index in stride(from: 0, to: a.count, by: 4) where a[index..<index + 4] != b[index..<index + 4] {
            columns.insert(index / 4 % width)
        }
        return columns
    }

    @Test(arguments: [("hot", 550.0), ("mem", 220.0), ("suggestion", 302.5)])
    func 호버한_큐_선과_제안_배지만_달라진다(_ target: String, _ x: Double) async throws {
        let h = try await harness()
        let cues = try #require(h.deck.draft?.cues)
        let hover: ZoomPointerTarget = switch target {
        case "hot": .cue(try #require(cues.first { $0.kind == .hot(0) }).id)
        case "mem": .cue(try #require(cues.first { $0.kind == .memory }).id)
        default: .suggestion(7.5)
        }
        let changed = changedColumns(try pixels(h.deck, hover: .empty), try pixels(h.deck, hover: hover))
        #expect(!changed.isEmpty, "호버하면 그 대상이 굵어지거나 밝아진다")
        #expect(changed.allSatisfy { abs(Double($0) - x) <= 14 }, "다른 자리는 그대로다: \(changed.sorted())")
    }
}
