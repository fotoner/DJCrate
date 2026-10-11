@testable import DJCrate
import AppKit
import DJCDomain
import SwiftUI
import Testing

/// #152: 큐 목록은 SwiftUI `List` 안의 AppKit 표를 찾아 자동 행 높이를 끈다. 표를 못 찾으면 화면은 그대로 동작하고
/// 곡을 올릴 때마다 행 높이를 다시 재는 옛 비용으로 조용히 돌아가므로, 실제 창에서 고정이 걸리는지 시험으로 지킨다.
@MainActor
@Suite("덱 — 큐 목록 고정 행 높이")
struct CueListRowHeightTests {
    /// 창 안의 큐 목록 표(스크롤 뷰에 든 NSTableView)
    private func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.enclosingScrollView != nil { return table }
        for sub in view.subviews { if let found = findTable(in: sub) { return found } }
        return nil
    }

    private func host(_ deck: DeckModel, scale: Double) -> NSWindow {
        _ = NSApplication.shared
        let view = CueListView(deck: deck).environment(\.textScale, scale).frame(width: 420, height: 360)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }

    @Test(arguments: [1.0, 1.3])
    func 큐가_있는_목록은_자동_행_높이를_끄고_글자_배율에_맞는_고정_높이를_쓴다(scale: Double) async throws {
        let cues = (0..<6).map { Cue(id: "c\($0)", contentID: "1", kind: 0, inMsec: 5_000 + $0 * 9_000, name: "", colorTableIndex: nil) }
        let h = try DeckHarness(cues: cues)
        try await h.loaded()
        let window = host(h.deck, scale: scale)
        defer { window.close() }

        let expected = CGFloat(TextScale.length(28, scale: scale))
        var found: NSTableView?
        for _ in 0..<200 {
            found = findTable(in: window.contentView)
            if let found, !found.usesAutomaticRowHeights, found.rowHeight == expected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let table = try #require(found, "큐 목록의 표를 찾지 못했다 — SwiftUI List 안쪽 구조가 바뀌었는지 확인")
        #expect(table.usesAutomaticRowHeights == false)
        #expect(table.rowHeight == expected)
        #expect(table.numberOfRows == 6)
    }

    /// 곡이 바뀌어 큐 id가 모두 새로 만들어지면 SwiftUI가 표의 행 높이를 기본값(24pt)으로 되돌렸다.
    @Test(arguments: [1.0, 1.3])
    func 곡이_바뀌어_큐가_통째로_교체돼도_고정_행_높이가_유지된다(scale: Double) async throws {
        let first = (0..<3).map { Cue(id: "a\($0)", contentID: "1", kind: 0, inMsec: 5_000 + $0 * 9_000, name: "", colorTableIndex: nil) }
        let h = try DeckHarness(cues: first)
        try await h.loaded()
        let window = host(h.deck, scale: scale)
        defer { window.close() }
        let expected = CGFloat(TextScale.length(28, scale: scale))
        for _ in 0..<200 where !(findTable(in: window.contentView).map { !$0.usesAutomaticRowHeights && $0.rowHeight == expected && $0.numberOfRows == 3 } ?? false) {
            try await Task.sleep(for: .milliseconds(10))
        }

        // 다른 곡의 초안이 들어온 것처럼 큐 id를 모두 새로 만든다.
        h.deck.draft = CueDraft(trackUUID: "track-2", rekordboxCues: (0..<5).map {
            Cue(id: "b\($0)", contentID: "2", kind: 0, inMsec: 3_000 + $0 * 7_000, name: "", colorTableIndex: nil)
        }, newID: { UUID() })
        for _ in 0..<200 where findTable(in: window.contentView)?.numberOfRows != 5 { try await Task.sleep(for: .milliseconds(10)) }
        // SwiftUI가 행을 바꾸며 표 설정을 되돌려도 다시 맞춰질 시간을 준다.
        try await Task.sleep(for: .milliseconds(500))

        let table = try #require(findTable(in: window.contentView))
        #expect(table.numberOfRows == 5)
        #expect(table.usesAutomaticRowHeights == false)
        #expect(table.rowHeight == expected)
    }
}
