@testable import DJCrate
import Testing

/// 끌어다 놓은 뒤에는 드롭 테두리가 남지 않는다(#127).
/// SwiftUI(macOS 27)는 놓을 때 dropUpdated → performDrop 뒤 concludeDragOperation에서 dropUpdated를 한 번 더 부르고,
/// draggingEnded에서는 dropExited를 보내지 않는다. 목록 테두리는 그 마지막 dropUpdated에서 다시 켜져 남았다.
@Suite("드롭 강조 — 놓은 뒤 테두리")
struct DropHighlightTests {
    private enum Call { case entered(Bool), updated(Bool), exited, dropped }

    /// 차례로 부른 뒤 강조가 켜져 있는지
    private func isTargeted(after calls: [Call]) -> Bool {
        var highlight = DropHighlight()
        for call in calls {
            switch call {
            case .entered(let accepted): highlight.enter(accepted: accepted)
            case .updated(let accepted): highlight.update(accepted: accepted)
            case .exited: highlight.exit()
            case .dropped: highlight.drop()
            }
        }
        return highlight.isTargeted
    }

    @Test func 받을_수_있는_끌기가_들어오면_켠다() {
        #expect(isTargeted(after: [.entered(true), .updated(true)]))
        #expect(!isTargeted(after: [.entered(false), .updated(false)]))
    }

    @Test func 끄는_중_받을_수_없게_되면_끈다() {
        #expect(!isTargeted(after: [.entered(true), .updated(true), .updated(false)]))
    }

    @Test func 밖으로_나가면_끈다() {
        #expect(!isTargeted(after: [.entered(true), .updated(true), .exited]))
    }

    @Test func 놓은_뒤_마지막_dropUpdated가_와도_다시_켜지_않는다() {
        // 놓기: dropUpdated → performDrop → (concludeDragOperation) dropUpdated. dropExited는 오지 않는다.
        #expect(!isTargeted(after: [.entered(true), .updated(true), .updated(true), .dropped, .updated(true)]))
    }

    @Test func 놓은_뒤_새로_끌어_오면_다시_켠다() {
        #expect(isTargeted(after: [.entered(true), .updated(true), .dropped, .updated(true),
                                   .entered(true), .updated(true)]))
    }
}
