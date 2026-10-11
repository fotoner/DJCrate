@testable import DJCrate
import Testing

@Suite("덱 — 창 크기에 따른 배치")
struct DeckLayoutTests {
    @Test func 낮은_창에서_목록_최소_높이를_남긴다() {
        let height = DeckLayout.waveformHeight(requested: 480, detailHeight: 650,
                                               deckChromeHeight: 190, otherHeight: 40)
        #expect(height == 270)
        #expect(650 - height - 190 - 40 == DeckLayout.minimumLibraryHeight)
    }

    @Test func 창을_다시_키우면_저장한_파형_높이로_돌아온다() {
        let requested = 480.0
        #expect(DeckLayout.waveformHeight(requested: requested, detailHeight: 650,
                                         deckChromeHeight: 190, otherHeight: 40) < requested)
        #expect(DeckLayout.waveformHeight(requested: requested, detailHeight: 900,
                                         deckChromeHeight: 190, otherHeight: 40) == requested)
    }

    @Test(arguments: [-10.0, 80, 150, 480, 700])
    func 파형_높이는_기존_범위_안에_둔다(_ requested: Double) {
        let height = DeckLayout.waveformHeight(requested: requested, detailHeight: 1200,
                                               deckChromeHeight: 190, otherHeight: 40)
        #expect(height == min(max(requested, 80), 480))
    }

    @Test func 컨트롤이_늘어나면_파형을_먼저_줄인다() {
        #expect(DeckLayout.waveformHeight(requested: 480, detailHeight: 650,
                                         deckChromeHeight: 320, otherHeight: 60) == 120)
    }

    @Test func 덱이_최소_파형보다_커도_목록과_핸들은_남긴다() {
        let waveform = DeckLayout.waveformHeight(requested: 480, detailHeight: 650,
                                                 deckChromeHeight: 480, otherHeight: 60)
        #expect(waveform == 80)
        let viewport = DeckLayout.deckViewportHeight(contentHeight: waveform + 480,
                                                     detailHeight: 650, otherHeight: 60)
        #expect(viewport == 440)
        #expect(viewport < waveform + 480)
        #expect(650 - viewport - 60 == DeckLayout.minimumLibraryHeight)
    }

    /// 덱 폭이 프레임마다 바뀌어도(창 크기·사이드바·인스펙터 애니메이션) 배치 단계가 같으면 덱 본문을 다시 계산하지 않는다(#138).
    @Test func 덱_배치_단계는_경계를_넘을_때만_바뀐다() {
        #expect(DeckWidthClass(width: 1200) == DeckWidthClass(width: 1390))
        #expect(DeckWidthClass(width: 700) == DeckWidthClass(width: 1149))
        #expect(DeckWidthClass(width: 1400) == DeckWidthClass(width: 2400))
        #expect(DeckWidthClass(width: 1149) == DeckWidthClass(width: 1150))
        #expect(DeckWidthClass(width: 1399) != DeckWidthClass(width: 1400))
    }

    @Test func 넓은_덱은_큐_목록을_넓힌다() {
        #expect(DeckWidthClass(width: 1399).cueListWidth == 250)
        #expect(DeckWidthClass(width: 1400).cueListWidth == 290)
    }

    /// 인스펙터(`.inspector`)가 본문을 툴바 높이로 한 번 더 배치해, 그 크기도 진짜 본문 크기와 번갈아 측정으로 왔다(#138).
    @Test func 목록_최소_높이보다_낮은_본문_측정은_버린다() {
        #expect(!DeckLayout.isDetailMeasurement(height: 52))
        #expect(!DeckLayout.isDetailMeasurement(height: 0))
        #expect(DeckLayout.isDetailMeasurement(height: 648))
        #expect(DeckLayout.isDetailMeasurement(height: DeckLayout.minimumLibraryHeight))
    }
}
