@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// 앱이 정하는 문구 카탈로그. 핵심부 `UIStrings`는 번들을 모르고 앱이 만든 찾기 함수를 쓴다(전역 값은 바꾸지 않고 본다).
@Suite("앱 문구 카탈로그")
struct AppStringsTests {
    @Test func 앱_카탈로그는_이_타깃_번들의_번역을_찾는다() throws {
        let path = try #require(UIStrings.appResources.path(forResource: "en", ofType: "lproj"))
        let english = try #require(Bundle(path: path))
        let catalog = UIStrings.Catalog.bundle(english)
        #expect(catalog.string("닫기", Locale(identifier: "en")) == "Close")
        #expect(String(localized: catalog.resource("닫기", Locale(identifier: "en"))) == "Close")
    }

    @Test func 정하지_않은_실행은_원문과_원문_언어를_쓴다() {
        #expect(UIStrings.catalog == nil && UIStrings.locale == UIStrings.sourceLocale)
        #expect(String(ui: "닫기") == "닫기")
    }
}
