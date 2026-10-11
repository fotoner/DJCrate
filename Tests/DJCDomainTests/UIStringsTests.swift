import DJCDomain
import Foundation
import Testing

/// 카탈로그 번들을 정하지 않은 테스트는 원문(한국어)을 그대로 쓴다. 시스템 언어와 관계없이 같아야 한다.
@Suite("문구 카탈로그")
struct UIStringsTests {
    @Test func 번들을_정하지_않으면_원문을_그대로_쓴다() {
        let count = 3
        let name = "시험곡"
        #expect(String(ui: "곡 \(count)개") == "곡 3개")
        #expect(String(ui: "\(name)을 지웠습니다") == "시험곡을 지웠습니다")
        #expect(String(localized: LocalizedStringResource.ui("곡 \(count)개")) == "곡 3개")
    }
}
