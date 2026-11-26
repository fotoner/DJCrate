@testable import DJCrate
import AppKit
import Foundation
import SwiftUI
import Testing

#if DEBUG
/// 자가 테스트가 화면 자리를 이름으로 찾는다. 줄인 칩처럼 자리·크기는 그대로인데 이름(글)만 바뀌는 뷰도
/// 새 이름으로 기록돼야 자가 테스트가 정상 칩을 "없음"으로 잘못 판정하지 않는다(#351).
@MainActor
@Suite("자가 테스트 자리 기록", .serialized)
struct SelfTestFrameNameTests {
    @Observable final class Label {
        var name: String
        init(_ name: String) { self.name = name }
    }

    struct Probe: View {
        let label: Label
        var body: some View {
            Text(verbatim: "칩").frame(width: 120, height: 20).selfTestFrame(label.name, clearsOnDisappear: true)
        }
    }

    @Test func 같은_자리에서_이름만_바뀌어도_새_이름을_기록하고_옛_이름은_지운다() async throws {
        _ = NSApplication.shared
        let old = "selftest.namechange.외 5", new = "selftest.namechange.외 2"
        defer {
            SelfTestFrames.frames.removeValue(forKey: old)
            SelfTestFrames.frames.removeValue(forKey: new)
        }
        let label = Label(old)
        let window = NSWindow(contentViewController: NSHostingController(rootView: Probe(label: label)))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // 창 배치가 끝나 자리가 두 번 연속 같아질 때까지 기다린다
        var previous: CGRect?, settled = 0
        #expect(await waitForState {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let frame = SelfTestFrames.frames[old] else { return false }
            settled = frame == previous ? settled + 1 : 0
            previous = frame
            return settled >= 2
        })
        let frame = try #require(SelfTestFrames.frames[old])

        label.name = new
        #expect(await waitForState { window.contentView?.layoutSubtreeIfNeeded(); return SelfTestFrames.frames[new] != nil })
        #expect(SelfTestFrames.frames[new] == frame, "자리는 그대로다")
        #expect(SelfTestFrames.frames[old] == nil, "옛 이름의 자리는 지운다")
    }
}
#endif
