@testable import DJCDomain
import Testing

@Suite("곡 편집 줄 확대·가로 스크롤")
struct EditViewportTests {
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    func near(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Bool { near(a.lowerBound, b.lowerBound) && near(a.upperBound, b.upperBound) }

    @Test func 처음에는_줄_전체를_폭에_맞춘다() {
        let view = EditViewport()
        #expect(near(view.visible(length: 100), 0...100) && view.scale(length: 100) == 1 && !view.isZoomed(length: 100))
        #expect(near(view.x(of: 25, width: 400, length: 100), 100) && near(view.time(atX: 100, width: 400, length: 100), 25))
        // 빈 줄(결과 없음)
        #expect(near(view.visible(length: 0), 0...0) && view.x(of: 3, width: 400, length: 0) == 0)
    }

    @Test func 가리킨_자리를_그대로_두고_확대한다() {
        var view = EditViewport()
        // 50초(가운데)를 두고 4배: 37.5~62.5초
        view.zoom(by: 4, around: 50, length: 100, minimumSpan: 4)
        #expect(near(view.visible(length: 100), 37.5...62.5) && near(view.scale(length: 100), 4) && view.isZoomed(length: 100))
        #expect(near(view.x(of: 50, width: 400, length: 100), 200))
        // 40초(왼쪽에서 10%)를 두고 2배 더: 40 − 1.25 = 38.75초부터 12.5초
        view.zoom(by: 2, around: 40, length: 100, minimumSpan: 4)
        #expect(near(view.visible(length: 100), 38.75...51.25) && near(view.x(of: 40, width: 400, length: 100), 40))
        // 가장 짧게 보이는 길이에서 멈춘다
        view.zoom(by: 100, around: 40, length: 100, minimumSpan: 4)
        #expect(near(view.visible(length: 100).upperBound - view.visible(length: 100).lowerBound, 4))
        // 줄보다 넓히면 전체(스크롤 없음)
        view.zoom(by: 0.001, around: 40, length: 100, minimumSpan: 4)
        #expect(view == EditViewport() && view.scale(length: 100) == 1)
    }

    @Test func 줄_끝에서_확대해도_줄_밖을_보이지_않는다() {
        var view = EditViewport()
        view.zoom(by: 4, around: 100, length: 100, minimumSpan: 4)
        #expect(near(view.visible(length: 100), 75...100))
        // 80초(왼쪽에서 20%)를 두고 2배 축소하면 70~120초가 되지만 줄 끝에 붙여 50~100초
        view.zoom(by: 0.5, around: 80, length: 100, minimumSpan: 4)
        #expect(near(view.visible(length: 100), 50...100))
        view.fit()
        view.zoom(by: 4, around: 0, length: 100, minimumSpan: 4)
        #expect(near(view.visible(length: 100), 0...25))
    }

    @Test func 가로로_스크롤하고_줄_끝에서_멈춘다() {
        var view = EditViewport()
        // 전체를 보이면 스크롤할 곳이 없다
        view.scroll(by: 10, length: 100)
        #expect(view == EditViewport())
        view.zoom(by: 4, around: 0, length: 100, minimumSpan: 4)
        view.scroll(by: 10, length: 100)
        #expect(near(view.visible(length: 100), 10...35))
        view.scroll(by: 500, length: 100)
        #expect(near(view.visible(length: 100), 75...100))
        view.scroll(by: -500, length: 100)
        #expect(near(view.visible(length: 100), 0...25))
        view.scroll(to: 30, length: 100)
        #expect(near(view.visible(length: 100), 30...55))
    }

    @Test func 재생선이_보이는_자리_밖으로_나가면_넘긴다() {
        var view = EditViewport()
        view.reveal(80, length: 100)
        #expect(view == EditViewport())
        view.zoom(by: 4, around: 0, length: 100, minimumSpan: 4)
        // 보이는 자리 안이면 그대로
        view.reveal(20, length: 100)
        #expect(near(view.visible(length: 100), 0...25))
        // 오른쪽 밖: 왼쪽 10% 자리에(다음 쪽으로 넘긴다)
        view.reveal(40, length: 100)
        #expect(near(view.visible(length: 100), 37.5...62.5))
        // 왼쪽 밖: 오른쪽 90% 자리에
        view.reveal(30, length: 100)
        #expect(near(view.visible(length: 100), 7.5...32.5))
    }

    @Test func 줄이_짧아지면_보이는_자리를_줄_안으로_당긴다() {
        var view = EditViewport()
        view.zoom(by: 4, around: 100, length: 100, minimumSpan: 4)
        #expect(near(view.visible(length: 100), 75...100))
        // 결과가 60초로 줄면 35~60초, 20초로 줄면 전체
        #expect(near(view.visible(length: 60), 35...60) && near(view.visible(length: 20), 0...20) && view.scale(length: 20) == 1)
        // 결과가 늘어도 보이는 길이(마디 폭)는 그대로
        #expect(near(view.visible(length: 200), 75...100) && near(view.scale(length: 200), 8))
    }
}
