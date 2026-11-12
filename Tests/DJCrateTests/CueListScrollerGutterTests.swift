@testable import DJCrate
import AppKit
import DJCDomain
import SwiftUI
import Testing

/// #347: 시스템 스크롤 막대가 "항상"이면 세로 막대(17pt)가 큐 목록 폭을 가져가 이름 칸이 「…」로 잘렸다.
/// 막대가 없을 때(겹쳐 그림)와 같은 이름 칸이 남아야 한다.
@MainActor
@Suite("덱 — 큐 목록 이름 칸과 스크롤 막대")
struct CueListScrollerGutterTests {
    /// 덱의 큐 목록 폭(글자 배율 1, 본문 1400 미만)
    private static let listWidth = CGFloat(DeckWidthClass(width: 1200).cueListWidth)
    private static let legacyWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    // MARK: 계산

    @Test(arguments: TextScale.steps)
    func 막대가_없으면_시각_칸_예비_폭은_그대로다(scale: Double) {
        #expect(CueRowLayout.timeColumnMinWidth(scale: scale, scrollerWidth: 0) == TextScale.length(56, scale: scale))
    }

    @Test(arguments: TextScale.steps)
    func 막대가_가져간_폭만큼_시각_칸_예비_폭이_줄어_이름_칸에_돌아간다(scale: Double) {
        let reserve = TextScale.length(56, scale: scale)
        #expect(CueRowLayout.timeColumnMinWidth(scale: scale, scrollerWidth: Self.legacyWidth) == reserve - Self.legacyWidth)
    }

    @Test func 예비_폭보다_큰_막대도_음수_폭을_만들지_않는다() {
        #expect(CueRowLayout.timeColumnMinWidth(scale: 1, scrollerWidth: 500) == 0)
    }

    // MARK: 실제 목록

    private func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.enclosingScrollView != nil { return table }
        for sub in view.subviews { if let found = findTable(in: sub) { return found } }
        return nil
    }

    private func buttonFrames(in view: NSView, root: NSView) -> [NSRect] {
        var frames: [NSRect] = []
        if view is NSButton { frames.append(root.convert(view.bounds, from: view)) }
        for sub in view.subviews { frames += buttonFrames(in: sub, root: root) }
        return frames
    }

    /// 한 줄 셀을 그려 열(x)마다 글자·그림이 있는지 본다. `detailsMinX`는 세부 편집 단추의 왼쪽 끝(pt)이다.
    private struct RowInk {
        var columns: [Bool]
        var scale: CGFloat
        var detailsMinX: CGFloat
    }

    private func rowInk(_ table: NSTableView, row: Int) -> RowInk? {
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
        // 세부 편집·삭제 단추(왼쪽부터). 종류 선택기는 단추로 잡히지 않는다.
        let buttons = buttonFrames(in: cell, root: cell).sorted { $0.minX < $1.minX }
        guard buttons.count >= 2, let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { return nil }
        cell.cacheDisplay(in: cell.bounds, to: rep)
        let background = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB)
        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let background else { return false }
            return abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                + abs(color.blueComponent - background.blueComponent) + abs(color.alphaComponent - background.alphaComponent) > 0.4
        }
        let columns = (0..<rep.pixelsWide).map { x in (0..<rep.pixelsHigh).contains { isInk(x, $0) } }
        return RowInk(columns: columns, scale: CGFloat(rep.pixelsWide) / cell.bounds.width, detailsMinX: buttons[0].minX)
    }

    /// 이름이 있는 첫 줄에서 시각 글자 오른쪽에 그려진 글자의 폭(pt). 아직 그려지지 않았으면 nil.
    /// 시각 글자의 오른쪽 끝은 이름이 빈 둘째 줄에서 잰다(시각 글자는 자릿수가 같아 두 줄에서 같은 자리에 끝난다).
    private func nameInkWidth(_ table: NSTableView) -> CGFloat? {
        guard let named = rowInk(table, row: 0), let empty = rowInk(table, row: 1) else { return nil }
        let limit = Int((named.detailsMinX - 2) * named.scale)
        guard limit <= empty.columns.count, let timeRight = (0..<limit).last(where: { empty.columns[$0] }) else { return nil }
        let name = ((timeRight + Int(3 * named.scale))..<max(timeRight + Int(3 * named.scale), limit)).filter { named.columns[$0] }
        guard let first = name.first, let last = name.last else { return 0 }
        return CGFloat(last - first + 1) / named.scale
    }

    /// 큐 목록을 창에 올린다. 막대를 늘 보이게 하는 방식(legacy)으로 두되, `scrollerShown`이 참이면 큐가 목록 높이보다 많아
    /// 세로 막대가 폭을 가져가고, 거짓이면 큐가 모두 들어가 막대가 숨는다(겹쳐 그리는 막대가 폭을 가져가지 않는 것과 같은 폭이다).
    private func hostedTable(scrollerShown shown: Bool) async throws -> (NSWindow, NSTableView, DeckHarness) {
        let names = ["Break", "Intro", "Build", "Drop", "Hook", "Outro"]
        let count = shown ? 20 : 6
        // 첫 줄은 이름이 있고 둘째 줄은 이름이 비었다
        let cues = (0..<count).map {
            Cue(id: "c\($0)", contentID: "1", kind: 0, inMsec: 5_000 + $0 * 9_000, name: $0 == 1 ? "" : names[$0 % names.count], colorTableIndex: nil)
        }
        let h = try DeckHarness(cues: cues)
        try await h.loaded()
        _ = NSApplication.shared
        let gutter = ScrollerGutter(fixed: shown ? Self.legacyWidth : 0)
        let view = CueListView(deck: h.deck, gutter: gutter).frame(width: Self.listWidth, height: 340)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        let found = await waitForState { findTable(in: window.contentView).map { $0.numberOfRows == count } ?? false }
        let table = try #require(found ? findTable(in: window.contentView) : nil, "큐 목록의 표를 찾지 못했다")
        let scroll = try #require(table.enclosingScrollView)
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let settled = await waitForState {
            let taken = scroll.frame.width - scroll.contentSize.width
            return (shown ? taken > Self.legacyWidth : taken < 4) && table.view(atColumn: 0, row: 1, makeIfNecessary: false) != nil
        }
        #expect(settled, "막대 \(shown ? "보임" : "숨김") 상태가 목록 폭에 반영되지 않았다: 목록 \(scroll.frame.width), 내용 \(scroll.contentSize.width)")
        return (window, table, h)
    }

    /// "Break"(캡션 10pt)의 글자 폭. 이름 칸이 모자라 「B…」로 잘리면 이보다 한참 좁다.
    private static let breakWidth = NSString(string: "Break").size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width

    @Test(arguments: [false, true])
    func 짧은_큐_이름은_막대가_늘_보여도_잘리지_않는다(scrollerShown: Bool) async throws {
        let (window, table, h) = try await hostedTable(scrollerShown: scrollerShown)
        defer { window.close(); withExtendedLifetime(h) {} }
        var ink: CGFloat = 0
        // 이름 글자가 그려질 때까지 기다린다(전혀 안 그려지면 0으로 판정한다).
        _ = await waitForState { ink = nameInkWidth(table) ?? 0; return ink > 0 }
        #expect(ink >= Self.breakWidth - 4, "막대 \(scrollerShown ? "보임" : "숨김"): 이름 글자 폭 \(ink)pt < Break \(Self.breakWidth)pt — 잘렸다")
    }
}
