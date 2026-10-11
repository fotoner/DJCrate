@testable import DJCDomain
import Foundation
import Testing

@Suite("글자 배율(보기 › 글자 크게·작게)")
struct TextScaleTests {
    @Test func 설정_이름과_기본값() {
        #expect(SettingKeys.textScale.name == "view.textScale")
        #expect(SettingKeys.textScale.defaultValue == 1)
        #expect(SettingKeys.all.contains(SettingKeys.textScale.name))
    }

    @Test func 한_단계씩_키우고_줄이며_끝에서_멈춘다() {
        #expect(TextScale.stepped(1, by: 1) == 1.15)
        #expect(TextScale.stepped(1.15, by: 1) == 1.3)
        #expect(TextScale.stepped(1.3, by: -1) == 1.15)
        #expect(TextScale.stepped(1.5, by: 1) == 1.5)
        #expect(TextScale.stepped(1, by: -1) == 1)
        #expect(TextScale.canStep(1, by: 1))
        #expect(!TextScale.canStep(1, by: -1))
        #expect(!TextScale.canStep(1.5, by: 1))
        #expect(TextScale.canStep(1.5, by: -1))
    }

    /// 1배보다 작게는 하지 않는다. 가장 작은 글자(10pt)가 macOS 최소 크기 밑으로 내려가지 않게.
    @Test func 가장_작은_단계는_1배() {
        #expect(TextScale.steps.first == 1)
        #expect(TextScale.steps == TextScale.steps.sorted())
    }

    @Test func 저장된_값은_가장_가까운_단계로_읽는다() {
        #expect(SettingKeys.textScale.value(from: nil) == 1)
        #expect(SettingKeys.textScale.value(from: 1.2) == 1.15)
        #expect(SettingKeys.textScale.value(from: 1.3) == 1.3)
        #expect(SettingKeys.textScale.value(from: 9.0) == 1.5)
        #expect(SettingKeys.textScale.value(from: 0.5) == 1)
        #expect(SettingKeys.textScale.value(from: Double.nan) == 1)
        #expect(SettingKeys.textScale.value(from: "1.3") == 1)
        // 단계를 건너뛴 값을 저장해 두었어도 한 단계 움직이면 이웃 단계로 간다.
        #expect(TextScale.stepped(1.2, by: 1) == 1.3)
        #expect(TextScale.stepped(1.2, by: -1) == 1.15)
    }

    @Test func 글자_크기는_배율을_곱하되_10pt_밑으로_내려가지_않는다() {
        #expect(TextScale.pointSize(8, scale: 1) == 10)
        #expect(TextScale.pointSize(10, scale: 1) == 10)
        #expect(TextScale.pointSize(11, scale: 1) == 11)
        // 0.5pt 단위로 반올림한다.
        #expect(TextScale.pointSize(9, scale: 1.15) == 10.5)
        #expect(TextScale.pointSize(11, scale: 1.3) == 14.5)
        #expect(TextScale.pointSize(13, scale: 1.5) == 19.5)
    }

    @Test func 줄_높이와_칸_크기는_정수_pt로_반올림한다() {
        #expect(TextScale.length(24, scale: 1) == 24)
        #expect(TextScale.length(24, scale: 1.15) == 28)
        #expect(TextScale.length(22, scale: 1.3) == 29)
        #expect(TextScale.length(16, scale: 1.5) == 24)
        #expect(TextScale.length(20, scale: 1.15) == 23)
    }

    /// 작은 컨트롤(11pt)은 글자가 1.3배 넘게 커지면 한 단계 큰 컨트롤(13pt)로 바꾼다.
    @Test func 큰_배율에서는_컨트롤도_한_단계_키운다() {
        #expect(TextScale.controlSizeBoost(1) == 0)
        #expect(TextScale.controlSizeBoost(1.15) == 0)
        #expect(TextScale.controlSizeBoost(1.3) == 1)
        #expect(TextScale.controlSizeBoost(1.5) == 1)
    }
}

@Suite("확대 파형 눈금 라벨")
struct BeatRulerLabelTests {
    /// 10pt 숫자 한 자는 약 6pt. "14.1"은 네 자 + 여백 5pt = 29pt가 있어야 쓴다.
    let char = BeatRulerLabel.charWidth(pointSize: 10)

    @Test func 글자_폭은_글자_크기를_따른다() {
        #expect(char == 6)
        #expect(BeatRulerLabel.charWidth(pointSize: 15) == 9)
        #expect(BeatRulerLabel.width(of: "14.1", charWidth: 6) == 29)
    }

    /// #118: rekordbox처럼 박을 1부터 센다(1.1 1.2 1.3 1.4 2.1 …).
    @Test func 박은_1부터_센다() {
        let labels = (0..<8).map { i in
            BeatRulerLabel.text(bar: i / 4 + 1, beat: i % 4 + 1, isDownbeat: i % 4 == 0, beatWidth: 40, charWidth: char)
        }
        #expect(labels == ["1.1", "1.2", "1.3", "1.4", "2.1", "2.2", "2.3", "2.4"])
    }

    @Test func 자리가_넉넉하면_모든_박에_마디_박을_쓴다() {
        #expect(BeatRulerLabel.text(bar: 14, beat: 1, isDownbeat: true, beatWidth: 40, charWidth: char) == "14.1")
        #expect(BeatRulerLabel.text(bar: 14, beat: 3, isDownbeat: false, beatWidth: 40, charWidth: char) == "14.3")
    }

    @Test func 박이_좁으면_뒷박은_점과_박만_쓰고_더_좁으면_뺀다() {
        #expect(BeatRulerLabel.text(bar: 14, beat: 3, isDownbeat: false, beatWidth: 20, charWidth: char) == ".3")
        #expect(BeatRulerLabel.text(bar: 14, beat: 3, isDownbeat: false, beatWidth: 12, charWidth: char) == nil)
        // 첫 박은 마디 폭(4박) 안에 들어가면 쓴다.
        #expect(BeatRulerLabel.text(bar: 14, beat: 1, isDownbeat: true, beatWidth: 12, charWidth: char) == "14.1")
    }

    @Test func 마디도_좁으면_라벨을_몇_마디마다로_줄인다() {
        // 한 마디 20pt: 두 마디(40pt)에 한 번 → 1·3·5… 마디
        #expect(BeatRulerLabel.text(bar: 13, beat: 1, isDownbeat: true, beatWidth: 5, charWidth: char) == "13.1")
        #expect(BeatRulerLabel.text(bar: 14, beat: 1, isDownbeat: true, beatWidth: 5, charWidth: char) == nil)
        // 한 마디 12pt: 네 마디(48pt)에 한 번 → 1·5·9·13… 마디
        #expect(BeatRulerLabel.text(bar: 13, beat: 1, isDownbeat: true, beatWidth: 3, charWidth: char) == "13.1")
        #expect(BeatRulerLabel.text(bar: 15, beat: 1, isDownbeat: true, beatWidth: 3, charWidth: char) == nil)
        // 세 자리 마디도 같은 간격 안에서 고른다(한 마디 8pt → 여덟 마디 64pt ≥ "121.1" 35pt… 네 마디 32pt는 모자람)
        #expect(BeatRulerLabel.text(bar: 121, beat: 1, isDownbeat: true, beatWidth: 2, charWidth: char) == "121.1")
        #expect(BeatRulerLabel.text(bar: 125, beat: 1, isDownbeat: true, beatWidth: 2, charWidth: char) == nil)
    }

    @Test func 글자를_키우면_같은_자리에서_라벨이_줄어든다() {
        let big = BeatRulerLabel.charWidth(pointSize: 15)
        #expect(BeatRulerLabel.text(bar: 14, beat: 3, isDownbeat: false, beatWidth: 40, charWidth: char) == "14.3")
        #expect(BeatRulerLabel.text(bar: 14, beat: 3, isDownbeat: false, beatWidth: 40, charWidth: big) == ".3")
        #expect(BeatRulerLabel.text(bar: 14, beat: 3, isDownbeat: false, beatWidth: 20, charWidth: big) == nil)
    }

    /// 첫 박 라벨("1.1")이 한 박보다 길면 바로 뒤 박 라벨과 겹친다. 그 박 라벨은 빼고, 겹치지 않는 박부터 쓴다.
    @Test func 첫_박_라벨이_넘치는_자리의_뒷박_라벨은_뺀다() {
        let big = BeatRulerLabel.charWidth(pointSize: 15)   // "1.1" = 34.5pt
        #expect(BeatRulerLabel.text(bar: 1, beat: 1, isDownbeat: true, beatWidth: 26, charWidth: big) == "1.1")
        #expect(BeatRulerLabel.text(bar: 1, beat: 2, isDownbeat: false, beatWidth: 26, charWidth: big) == nil)
        #expect(BeatRulerLabel.text(bar: 1, beat: 3, isDownbeat: false, beatWidth: 26, charWidth: big) == ".3")
        #expect(BeatRulerLabel.text(bar: 1, beat: 4, isDownbeat: false, beatWidth: 26, charWidth: big) == ".4")
        // 10pt에서는 같은 폭에 다 들어간다.
        #expect(BeatRulerLabel.text(bar: 1, beat: 2, isDownbeat: false, beatWidth: 26, charWidth: char) == "1.2")
    }

    /// 그리드 편집 중 아래쪽 박 번호(1~4): 첫 박은 늘, 나머지는 박 사이에 들어갈 때만
    @Test func 그리드_편집_박_번호도_자리가_없으면_첫_박만() {
        #expect(BeatRulerLabel.showsBeatNumber(isDownbeat: true, beatWidth: 4, charWidth: char))
        #expect(BeatRulerLabel.showsBeatNumber(isDownbeat: false, beatWidth: 11, charWidth: char))
        #expect(!BeatRulerLabel.showsBeatNumber(isDownbeat: false, beatWidth: 10, charWidth: char))
    }
}
