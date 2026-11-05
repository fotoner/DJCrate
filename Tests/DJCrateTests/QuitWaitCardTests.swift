@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import SwiftUI
import Testing

/// 종료를 기다리는 중 카드(#300): 단계 카드 안에 들어가도 최대 폭 안에서 줄을 바꿔 보인다. 지난 시간·[종료 취소]의 동작은 AppQuitControllerTests가 본다.
@MainActor
@Suite("종료 기다림 카드")
struct QuitWaitCardTests {
    static let wait = QuitWait(startedAt: Date(timeIntervalSince1970: 0))

    @Test(arguments: [1.0, 1.4]) func 단계_카드는_종료_안내가_들어가도_최대_폭_안에_뜬다(_ scale: Double) {
        _ = NSApplication.shared
        func size(_ wait: QuitWait?) -> CGSize {
            let card = WritingStageCard(stage: WriteStage("rekordbox에 쓰는 중…"), quitWait: wait, onCancel: {}).environment(\.textScale, scale)
            return NSHostingController(rootView: card).sizeThatFits(in: CGSize(width: 1800, height: 900))
        }
        let plain = size(nil), waiting = size(Self.wait)
        #expect(waiting.width <= TextScale.length(400, scale: scale) + 56)
        #expect(waiting.height > plain.height, "종료 안내와 [종료 취소]가 카드 안에 더해진다")
    }

    @Test func 진행_안내가_없는_틈의_카드도_안내와_종료_취소를_보인다() {
        _ = NSApplication.shared
        let overlay = QuitWaitOverlay(wait: Self.wait, onCancel: {})
        let size = NSHostingController(rootView: overlay).sizeThatFits(in: CGSize(width: 900, height: 600))
        #expect(size.width > 0 && size.height > 0)
        let section = NSHostingController(rootView: QuitWaitSection(wait: Self.wait, onCancel: {})).sizeThatFits(in: CGSize(width: 900, height: 600))
        #expect(section.width <= 400 + 56 && section.height > 0)
    }

    @Test func 기다림_문구는_쓰기_용어를_쓴다() {
        #expect(QuitWait.title.contains("쓰는 중") && !QuitWait.title.contains("저장"))
    }
}
