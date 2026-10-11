@testable import DJCrate
import AppKit
import DJCDomain
import Testing

/// 평점 칸 폭 규칙(#65)을 창 없이 본다: 곡 목록 칸과 태그 시트 칸이 같은 규칙(`FittingText`)을 쓴다.
/// 칸 모양(글자 자리 여백·최소 폭)이 이 규칙에 맞는 자리를 넘기는지는 `RatingColumnFitTests`·`SheetRatingFitTests`가 실제 표로 한 번씩 본다.
@Suite("맞춤 글자")
@MainActor
struct FittingTextTests {
    static let stars = TrackRating.choices.map(TrackRating.stars)
    static let compact = TrackRating.choices.map(TrackRating.compact)

    /// 글자 배율 1.0·1.3·1.5(설정 › 글자 크기의 단계 가운데 큰 쪽)에서 자리 폭을 한 칸씩 바꿔 가며 본다.
    @Test(arguments: [1.0, 1.3, 1.5])
    func 어떤_자리_폭에서도_평점_다섯_값이_서로_다르고_잘리지_않는다(_ scale: Double) {
        let font = NSFont.systemFont(ofSize: TextScale.pointSize(NSFont.systemFontSize, scale: scale))
        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let narrowest = Self.compact.map(width).max() ?? 0
        // 칸 폭 = 글자 + 글자 자리 양옆 2pt. 칸을 가장 좁게 끌어도 숫자 표기는 들어간다.
        #expect(TrackColumn.ratingMinWidth >= narrowest + 4)
        var shownStars = 0, shownCompact = 0
        for slot in stride(from: narrowest, through: 220, by: 1) {
            let shown = zip(Self.stars, Self.compact).map { FittingText.choose(full: $0, compact: $1, font: font, slot: slot) }
            #expect(Set(shown).count == 5, "자리 \(slot) 배율 \(scale): \(shown)")
            #expect(shown.allSatisfy { width($0) <= slot }, "자리 \(slot) 배율 \(scale): \(shown) 잘리면 안 된다")
            if shown == Self.stars { shownStars += 1 } else if shown == Self.compact { shownCompact += 1 }
        }
        // 좁을 때는 숫자, 넉넉하면 별(두 모양 모두 쓰인다)
        #expect(shownStars > 0 && shownCompact > 0)
    }

    @Test func 줄일_글자나_자리나_글꼴을_모르면_그대로다() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #expect(FittingText.choose(full: "★★★★★", compact: nil, font: font, slot: 1) == "★★★★★")
        #expect(FittingText.choose(full: "★★★★★", compact: "5★", font: font, slot: nil) == "★★★★★")
        #expect(FittingText.choose(full: "★★★★★", compact: "5★", font: nil, slot: 1) == "★★★★★")
    }
}
