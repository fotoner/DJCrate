import DJCDomain
import Foundation
import Testing

@Suite("화면 이름 정렬 순서")
struct UIStringsOrderTests {
    private func sorted(_ names: [String], _ language: String) -> [String] {
        names.sorted { UIStrings.standardOrder($0, $1, locale: Locale(identifier: language)) == .orderedAscending }
    }

    // CI 러너(en_US)에서 반영 복원 충돌 목록 순서가 달라졌다: 시스템 로캘 대신 화면 문구 언어를 따른다
    @Test func 순서는_시스템_로캘이_아니라_화면_문구_언어를_따른다() {
        #expect(sorted(["g", "곡 diff", "n"], "ko") == ["곡 diff", "g", "n"])
        #expect(sorted(["g", "곡 diff", "n"], "en") == ["g", "n", "곡 diff"])
    }

    @Test func 숫자는_값으로_대소문자는_구분하지_않고_비교한다() {
        #expect(sorted(["곡 10", "곡 2", "B", "a"], "ko") == ["곡 2", "곡 10", "a", "B"])
    }
}
