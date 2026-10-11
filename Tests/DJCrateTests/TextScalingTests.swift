@testable import DJCrate
import AppKit
import DJCDomain
import SwiftUI
import Testing

@Suite("글자 배율 — 앱")
struct TextScalingTests {
    /// 1배가 아닐 때 쓰는 텍스트 스타일 크기·굵기는 macOS 기본(NSFont.preferredFont)과 같아야 한다.
    @Test(arguments: [(Font.TextStyle.largeTitle, NSFont.TextStyle.largeTitle), (.title, .title1), (.title2, .title2),
                      (.title3, .title3), (.headline, .headline), (.subheadline, .subheadline), (.body, .body),
                      (.callout, .callout), (.footnote, .footnote), (.caption, .caption1), (.caption2, .caption2)])
    func 텍스트_스타일_크기는_macOS_기본과_같다(_ style: Font.TextStyle, _ appKit: NSFont.TextStyle) {
        let font = NSFont.preferredFont(forTextStyle: appKit)
        #expect(style.macPointSize == Double(font.pointSize))
        // 굵기 특성이 비어 있는 스타일(caption2 = SF Medium)이 있어 글꼴 이름으로 본다.
        let name = font.fontName
        #expect(style.macWeight == (name.hasSuffix("Bold") ? .bold : name.hasSuffix("Medium") ? .medium : .regular))
    }

    @Test func 작은_컨트롤은_큰_배율에서_한_단계_커진다() {
        #expect(ControlSize.small.scaled(1) == .small)
        #expect(ControlSize.small.scaled(1.15) == .small)
        #expect(ControlSize.small.scaled(1.3) == .regular)
        #expect(ControlSize.mini.scaled(1.5) == .small)
        #expect(ControlSize.regular.scaled(1.5) == .large)
    }

    /// 메뉴 '글자 크게'는 '+'에 걸려 Shift 없이 누른 ⌘=에는 반응하지 않는다. ⌘=도 ⌘+로 본다.
    @Test func 커맨드_등호는_글자_크게로_본다() {
        #expect(KeyRoutingPolicy.isTextBiggerAlias(keyCode: 24, modifiers: [.command]))
        #expect(!KeyRoutingPolicy.isTextBiggerAlias(keyCode: 24, modifiers: [.command, .shift]))
        #expect(!KeyRoutingPolicy.isTextBiggerAlias(keyCode: 24, modifiers: []))
        #expect(!KeyRoutingPolicy.isTextBiggerAlias(keyCode: 24, modifiers: [.command, .option]))
        #expect(!KeyRoutingPolicy.isTextBiggerAlias(keyCode: 27, modifiers: [.command]))
    }

    /// 메뉴 항목과 같은 방식으로 ⌘+ 항목을 만들고, 바꿔 넣은 ⌘= 이벤트가 그 항목에 걸리는지 본다.
    @MainActor
    @Test func 바꿔_넣은_이벤트는_글자_크게_항목에_걸린다() throws {
        final class Target: NSObject {
            var hits = 0
            @objc func bigger(_ sender: Any?) { hits += 1 }
        }
        // 메뉴는 NSApp을 거쳐 동작을 보낸다.
        _ = NSApplication.shared
        let target = Target()
        let menu = NSMenu()
        let item = NSMenuItem(title: "글자 크게", action: #selector(Target.bigger(_:)), keyEquivalent: "+")
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        menu.addItem(item)
        let equals = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "=",
                                                   charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24))
        #expect(!menu.performKeyEquivalent(with: equals))
        let alias = try #require(KeyRouter.textBiggerEvent(from: equals))
        #expect(menu.performKeyEquivalent(with: alias))
        #expect(target.hits == 1)
    }

    @Test func 파형_글자_크기는_10pt에서_배율을_따른다() {
        #expect(WaveformMetrics(scale: 1).labelSize == 10)
        #expect(WaveformMetrics(scale: 1.5).labelSize == 15)
        #expect(WaveformMetrics(scale: 1).rulerHeight == 16)
        #expect(WaveformMetrics(scale: 1.5).rulerHeight == 24)
        // 전체 파형: 아래 띠(섹션·조성)가 커진 만큼 전체 높이도 늘려 파형 높이는 그대로다.
        let base = WaveformMetrics(scale: 1), big = WaveformMetrics(scale: 1.5)
        #expect(base.overviewHeight == 86)
        #expect(base.overviewHeight - base.overviewBandsHeight == big.overviewHeight - big.overviewBandsHeight)
        #expect(big.keyBandHeight >= big.labelSize + 2)
    }
}

@Suite("파형 라벨 겹침")
struct WaveformLabelLayoutTests {
    /// 큐 이름은 왼쪽부터 놓고, 앞 이름과 겹치는 이름은 뺀다(글자를 줄이지 않는다).
    @Test func 앞_라벨과_겹치는_라벨은_뺀다() {
        let spans = [(start: 10.0, end: 80.0), (start: 60.0, end: 130.0), (start: 90.0, end: 150.0), (start: 200.0, end: 240.0)]
        #expect(WaveformMetrics.visibleLabels(spans, gap: 4) == [true, false, true, true])
    }

    @Test func 간격보다_가까우면_겹친_것으로_본다() {
        #expect(WaveformMetrics.visibleLabels([(start: 0, end: 50), (start: 52, end: 90)], gap: 4) == [true, false])
        #expect(WaveformMetrics.visibleLabels([(start: 0, end: 50), (start: 54, end: 90)], gap: 4) == [true, true])
    }

    /// 순서가 섞여 들어와도 화면 왼쪽부터 판단하고, 결과는 들어온 순서로 돌려준다.
    @Test func 들어온_순서와_상관없이_왼쪽부터_판단한다() {
        #expect(WaveformMetrics.visibleLabels([(start: 60, end: 130), (start: 10, end: 80)], gap: 4) == [false, true])
    }
}
