import DJCApplication
@testable import DJCrate
import AppKit
import SwiftUI
import Synchronization
import Testing

/// 재생 중 덱 머리 글자(남은 시간·재생 위치)는 초당 15번 바뀐다. 글자가 바뀔 때마다 덱 전체의 크기를
/// 다시 재면(`ScrollView` 재측정) 메인 스레드가 그만큼 일한다(#139). 글자 자리는 크기가 정해져 있어야 한다.
@MainActor
struct DeckHeaderLayoutTests {
    /// 자식 크기를 물어 오는 횟수를 센다(바깥 레이아웃이 자식 때문에 다시 계산됐는지 보는 표지).
    struct CountingLayout: Layout {
        final class Counter: Sendable {
            private let calls = Mutex(0)
            var sizeCalls: Int { calls.withLock { $0 } }
            func hit() { calls.withLock { $0 += 1 } }
        }
        let counter: Counter
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            counter.hit()
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    /// 창에 올리지 않은 호스팅 뷰. 바깥 레이아웃(`CountingLayout`)의 크기 요청 횟수를 센다.
    /// 재려는 것(글자가 바뀔 때 바깥을 다시 재는지)에 창은 필요 없다. 창이 없으면 시험 도중 사용자 화면에 창이 뜨지 않고
    /// 측정과 무관한 창 서버 사건(순서 바꾸기 완료·창 크기 맞춤·화면 표시 사이클)도 끼지 않는다.
    private func host<Content: View>(_ content: Content, counter: CountingLayout.Counter) -> NSView {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: CountingLayout(counter: counter) { content }.padding(20))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        return view
    }

    /// 값을 바꾼 뒤 SwiftUI가 그 변화를 반영하고 크기 요청이 더는 늘지 않을 때까지 기다린다.
    /// 걸린 시간이 아니라 "런루프를 돌려도 요청이 3번 연달아 늘지 않음"으로 끝을 정하므로 부하가 걸려 느려져도 같은 상태에서 잰다.
    private func settle(_ view: NSView, _ counter: CountingLayout.Counter) async throws {
        var quiet = 0, turns = 0
        var last = counter.sizeCalls
        // 턴 상한은 안전망이다(고쳐지지 않은 뷰가 요청을 끝없이 만들 때 시험이 멈추지 않게).
        while quiet < 3, turns < 500 {
            turns += 1
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            // 런루프를 한 바퀴 돌려 SwiftUI의 런루프 옵저버가 쌓인 갱신을 반영하게 한다.
            try await Task.sleep(for: .milliseconds(2))
            let now = counter.sizeCalls
            quiet = now == last ? quiet + 1 : 0
            last = now
        }
    }

    /// 장면 하나를 돌려 바깥 크기 요청이 몇 번 늘었는지 돌려준다: 처음 배치(`initial`), 처음 바뀐 뒤(`first`), 그 뒤 `steps`번 바꿀 때마다(`steps`).
    private func sizeCallsPerUpdate<Content: View>(_ content: (DeckModel) -> Content, steps: Int = 20) async throws
        -> (initial: Int, first: Int, steps: [Int]) {
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()))
        deck.duration = 200
        let counter = CountingLayout.Counter()
        let view = host(content(deck), counter: counter)
        try await settle(view, counter)
        let initial = counter.sizeCalls
        deck.displayTime = 0.5
        try await settle(view, counter)
        let first = counter.sizeCalls - initial
        var perStep: [Int] = []
        for step in 1...steps {
            let before = counter.sizeCalls
            deck.displayTime = 1 + Double(step) * 0.37
            try await settle(view, counter)
            perStep.append(counter.sizeCalls - before)
        }
        return (initial, first, perStep)
    }

    @Test func 글자_길이가_바뀌면_바깥_크기를_다시_잰다_기준_시험() async throws {
        // 이 시험 도구가 바깥 레이아웃의 재계산을 실제로 잡는지 확인한다(길이가 바뀌는 글자는 바깥 크기가 바뀐다).
        struct Growing: View {
            let deck: DeckModel
            var body: some View { Text(verbatim: String(repeating: "0", count: max(1, Int(deck.displayTime)))) }
        }
        let result = try await sizeCallsPerUpdate({ Growing(deck: $0) }, steps: 5)
        #expect(result.steps.reduce(0, +) > 0)
    }

    @Test func 재생_위치_글자가_바뀌어도_바깥_크기를_다시_재지_않는다() async throws {
        // 프로세스에서 처음 만든 뷰 그래프는 첫 갱신 몇 번(관측 1~7번)에도 바깥 크기를 다시 잰다(차가운 시작).
        // 같은 프로세스의 그 다음 그래프는 첫 갱신에도 다시 재지 않는다(#177). 그래서 같은 장면을 크기 요청 없이 끝나는
        // 실행이 나올 때까지 버리는 실행으로 먼저 돌려 데운 다음 잰다. 재는 기준은 그대로 "글자가 20번 바뀌는 동안 0회"다.
        // 고쳐지지 않은 뷰(글자마다 다시 잼)는 데워지지 않으므로 이 시험은 그대로 실패한다.
        for _ in 0..<5 {
            let warmup = try await sizeCallsPerUpdate { DeckHeaderTime(deck: $0) }
            if warmup.first == 0, warmup.steps.allSatisfy({ $0 == 0 }) { break }
        }
        let result = try await sizeCallsPerUpdate { DeckHeaderTime(deck: $0) }
        #expect(result.initial > 0)
        #expect(result.steps.reduce(0, +) == 0)
    }
}
