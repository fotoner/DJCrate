@testable import DJCDomain
import Testing

/// 파형을 끄는 동안의 핫큐(#133): 끈 거리 → 곡 위치(`ScrubAnchor`), 키 상태 → 새로 누른 핫큐 칸(`HotCueKeyWatch`)
@Suite("스크럽 중 핫큐 규칙")
struct ScrubHotCueRulesTests {
    @Test func 끈_거리만큼_끌기_시작_자리에서_움직인다() {
        var anchor = ScrubAnchor(at: 60)
        #expect(anchor.position(dragged: 2) == 62)
        #expect(anchor.position(dragged: -1.5) == 58.5)
    }

    @Test func 끄는_도중_자리를_옮기면_다음_끌기는_옮긴_자리에서_이어진다() {
        var anchor = ScrubAnchor(at: 60)
        _ = anchor.position(dragged: 2)
        anchor.move(to: 30)
        #expect(anchor.position(dragged: 2) == 30, "같은 거리면 옮긴 자리 그대로")
        #expect(anchor.position(dragged: 3.5) == 31.5)
        #expect(anchor.position(dragged: 0) == 28, "끌기 시작 자리로 되돌아가도 옮긴 만큼 어긋난 채")
    }

    @Test func 새로_누른_핫큐_키만_칸으로_돌려준다() {
        var watch = HotCueKeyWatch(shortcuts: .standard, pressed: [])
        #expect(watch.slots(pressed: [20]) == [2], "3 → C")
        #expect(watch.slots(pressed: [20]).isEmpty, "누르고 있는 동안은 한 번만")
        #expect(watch.slots(pressed: []).isEmpty)
        #expect(watch.slots(pressed: [20]) == [2], "뗐다가 다시 누르면 다시")
    }

    @Test func 끌기_전부터_누르고_있던_키는_뗐다가_다시_눌러야_한다() {
        var watch = HotCueKeyWatch(shortcuts: .standard, pressed: [18])
        #expect(watch.slots(pressed: [18]).isEmpty)
        #expect(watch.slots(pressed: [18, 19]) == [1], "새로 누른 2(B)만")
        #expect(watch.slots(pressed: [19]).isEmpty)
        #expect(watch.slots(pressed: [18, 19]) == [0])
    }

    @Test func 같은_칸의_두_키를_함께_누르면_한_번이고_여러_칸은_칸_순서대로() {
        var watch = HotCueKeyWatch(shortcuts: .standard, pressed: [])
        #expect(watch.slots(pressed: [18, 83]) == [0], "1과 숫자 패드 1")
        #expect(watch.slots(pressed: [18, 83, 21, 19]) == [1, 3])
    }

    @Test func 핫큐가_아닌_키는_보지_않고_바꾼_단축키를_따른다() {
        var shortcuts = DeckShortcuts.standard
        try? shortcuts.replace(20, with: 40, in: .hotCueC)   // C를 3 대신 K에
        var watch = HotCueKeyWatch(shortcuts: shortcuts, pressed: [])
        #expect(!watch.keys.contains(49) && watch.keys.contains(40) && !watch.keys.contains(20))
        #expect(watch.slots(pressed: [49, 20]).isEmpty, "Space·옛 키는 핫큐가 아님")
        #expect(watch.slots(pressed: [40]) == [2])
    }

    @Test func 다른_동작과_겹친_키는_단축키_표가_고른_동작을_따른다() throws {
        var shortcuts = DeckShortcuts.standard
        try shortcuts.add(18, to: .playPause)   // 1이 재생/정지(목록 위쪽)와 핫큐 A에 겹침
        let watch = HotCueKeyWatch(shortcuts: shortcuts, pressed: [])
        #expect(!watch.keys.contains(18) && watch.keys.contains(83))
    }
}
