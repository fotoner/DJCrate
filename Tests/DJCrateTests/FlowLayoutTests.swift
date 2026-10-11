@testable import DJCrate
import AppKit
import Observation
import SwiftUI
import Testing

/// 칸 크기를 캐시에 재 두는 줄바꿈 배치가 칸 내용이 바뀐 뒤에도 새 크기로 줄을 나눈다(#138).
@MainActor
@Suite("줄바꿈 배치 캐시")
struct FlowLayoutTests {
    @Observable @MainActor final class Model {
        var secondWidth = 50.0
        var showThird = false
        var showText = false
        var textScale = 1.0
    }

    private struct Host: View {
        let model: Model
        var justified = false
        var body: some View {
            FlowLayout(spacing: 4, justified: justified, centerItems: justified) {
                if model.showText {
                    TextChip()
                } else {
                    Color.red.frame(width: 100, height: 20)
                    Color.blue.frame(width: model.secondWidth, height: 20)
                    if model.showThird { Color.green.frame(width: 40, height: 20) }
                }
            }
            .environment(\.textScale, model.textScale)
        }
    }

    private struct TextChip: View {
        @Environment(\.textScale) private var textScale
        var body: some View {
            Text(verbatim: "배율 캐시 확인").font(.scaled(.body, textScale)).fixedSize()
        }
    }

    private func size(_ controller: NSHostingController<Host>, width: Double) -> CGSize {
        controller.sizeThatFits(in: CGSize(width: width, height: 1000))
    }

    @Test(arguments: [false, true]) func 폭에_따라_줄을_나눈다(_ justified: Bool) {
        let controller = NSHostingController(rootView: Host(model: Model(), justified: justified))
        #expect(size(controller, width: 200).height == 20)
        #expect(size(controller, width: 120).height == 44)
    }

    /// 창에 올려 상태 변경이 반영되게 한다(뷰만 만들면 다음 실행 루프까지 갱신되지 않는다).
    private func window(_ controller: NSHostingController<Host>) -> NSWindow {
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 400, height: 300))
        window.orderBack(nil)
        return window
    }

    /// 실행 루프가 실제 새 배치 크기를 반영했는지 본다. 시간이 지나도 반영되지 않으면 마지막 크기로 실패한다.
    private func settle(_ controller: NSHostingController<Host>, width: Double, height: Double) async {
        for _ in 0..<200 {
            controller.view.layoutSubtreeIfNeeded()
            if size(controller, width: width).height == height { return }
            await Task.yield()
        }
    }

    @Test func 칸_크기가_바뀌면_새_크기로_다시_나눈다() async throws {
        _ = NSApplication.shared
        let model = Model()
        let controller = NSHostingController(rootView: Host(model: model))
        let window = window(controller)
        defer { window.close() }
        await settle(controller, width: 200, height: 20)
        #expect(size(controller, width: 200).height == 20)
        model.secondWidth = 300
        await settle(controller, width: 200, height: 44)
        #expect(size(controller, width: 200).height == 44)
        model.secondWidth = 50
        await settle(controller, width: 200, height: 20)
        #expect(size(controller, width: 200).height == 20)
    }

    @Test func 칸이_늘면_다시_나눈다() async throws {
        _ = NSApplication.shared
        let model = Model()
        let controller = NSHostingController(rootView: Host(model: model))
        let window = window(controller)
        defer { window.close() }
        await settle(controller, width: 160, height: 20)
        #expect(size(controller, width: 160).height == 20)
        model.showThird = true
        await settle(controller, width: 160, height: 44)
        #expect(size(controller, width: 160).height == 44)
    }

    @Test(arguments: [false, true]) func 글자_배율이_바뀌면_캐시도_새_자연_크기를_쓴다(_ justified: Bool) async {
        _ = NSApplication.shared
        let model = Model()
        model.showText = true
        let controller = NSHostingController(rootView: Host(model: model, justified: justified))
        let window = window(controller)
        defer { window.close() }
        let original = size(controller, width: 400)
        let enlarged = Model()
        enlarged.showText = true
        enlarged.textScale = 1.5
        let expected = size(NSHostingController(rootView: Host(model: enlarged, justified: justified)), width: 400)
        #expect(expected.height > original.height)
        model.textScale = 1.5
        await settle(controller, width: 400, height: expected.height)
        #expect(size(controller, width: 400) == expected)
        model.textScale = 1
        await settle(controller, width: 400, height: original.height)
        #expect(size(controller, width: 400) == original)
    }
}
