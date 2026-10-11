@testable import DJCrate
import SwiftUI
import Testing

/// 앱을 켜거나 새 스냅샷을 읽은 뒤 사이드바가 보였다가 사라지지 않는다(#119).
/// 실제 앱에서 본문(덱·목록)을 처음 그릴 때 폭이 100×100pt로 한 번 잡힌 뒤 창 폭으로 바뀌었다.
@Suite("주 창 — 사이드바 표시·자동 접기")
struct SidebarVisibilityTests {
    /// 본문 폭을 차례로 쟀을 때 매번 사이드바를 접어야 했는지. nil은 본문을 다시 그린 것(`reset`).
    private func collapses(_ widths: [Double?], windowFrameRestored: Bool = true) -> [Bool] {
        var sidebar = SidebarVisibility()
        return widths.compactMap { width in
            guard let width else { sidebar.reset(); return nil }
            return sidebar.shouldCollapse(detailWidth: width, windowFrameRestored: windowFrameRestored)
        }
    }

    @Test func 저장한_표시_상태로_시작한다() {
        #expect(SidebarVisibility.columns(visible: true) == .all)
        #expect(SidebarVisibility.columns(visible: false) == .detailOnly)
    }

    @Test func 탐색_열을_숨긴_것만_닫힌_상태로_저장한다() {
        #expect(!SidebarVisibility.isVisible(.detailOnly))
        #expect(SidebarVisibility.isVisible(.all))
        #expect(SidebarVisibility.isVisible(.doubleColumn))
        #expect(SidebarVisibility.isVisible(.automatic))
    }

    @Test func 본문을_처음_그릴_때의_임시_폭으로는_접지_않는다() {
        #expect(collapses([100, 1440]) == [false, false])
    }

    @Test func 새_스냅샷으로_본문을_다시_그려도_접지_않는다() {
        #expect(collapses([100, 1192, nil, 100, 1192]) == [false, false, false, false])
    }

    @Test func 인스펙터를_열어_본문이_모자라면_접는다() {
        // 1100pt 창에서 인스펙터(340pt)를 열면 본문 512pt
        #expect(collapses([100, 852, 512]) == [false, false, true])
    }

    @Test func 창_프레임을_복원하기_전의_폭은_기준으로_쓰지_않는다() {
        // 기본 크기(1440pt)에서 잰 폭이 기준이 되면, 저장된 좁은 창으로 바뀔 때 접혀 버린다.
        var sidebar = SidebarVisibility()
        let beforeRestore = sidebar.shouldCollapse(detailWidth: 1192, windowFrameRestored: false)
        let afterRestore = sidebar.shouldCollapse(detailWidth: 512, windowFrameRestored: true)
        #expect(!beforeRestore)
        #expect(!afterRestore)
        #expect(collapses([1192, 512], windowFrameRestored: false) == [false, false])
    }

    @Test func 모자란_채로_뜬_본문은_저절로_바꾸지_않는다() {
        #expect(collapses([512, 500]) == [false, false])
    }

    @Test func 최소_폭보다_좁아질_때부터_접는다() {
        let minimum = DeckLayout.minimumDetailWidth
        #expect(collapses([700, minimum]) == [false, false])
        #expect(collapses([700, minimum - 0.5]) == [false, true])
    }

    /// 창 크기를 바꾸거나 사이드바·인스펙터가 움직이는 동안 본문 폭은 프레임마다 바뀐다. 상태가 폭을 그대로 들고 있으면
    /// 프레임마다 주 창 본문·사이드바 목록·메뉴까지 다시 계산했다(#138). 최소 폭을 넘나들 때만 바뀐다.
    @Test func 같은_쪽에서_폭만_바뀌면_상태를_바꾸지_않는다() {
        var sidebar = SidebarVisibility()
        _ = sidebar.shouldCollapse(detailWidth: 100, windowFrameRestored: true)
        _ = sidebar.shouldCollapse(detailWidth: 1192, windowFrameRestored: true)
        let wide = sidebar
        for width in stride(from: 1190.0, through: DeckLayout.minimumDetailWidth, by: -15) {
            let collapse = sidebar.shouldCollapse(detailWidth: width, windowFrameRestored: true)
            #expect(!collapse)
            #expect(sidebar == wide)
        }
        let collapse = sidebar.shouldCollapse(detailWidth: DeckLayout.minimumDetailWidth - 1, windowFrameRestored: true)
        #expect(collapse)
        let narrow = sidebar
        #expect(narrow != wide)
        for width in [600.0, 560, 610] {
            let again = sidebar.shouldCollapse(detailWidth: width, windowFrameRestored: true)
            #expect(!again)
            #expect(sidebar == narrow)
        }
    }
}
