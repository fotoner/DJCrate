@testable import DJCrate
import Foundation
import Testing

/// 앱 카탈로그가 번들에 언어별로 들어가는지. 시스템 언어와 관계없이 언어 폴더를 골라 찾는다.
@Suite("앱 문구 카탈로그")
struct LocalizationCatalogTests {
    private func lookup(_ key: String, in language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
        return value == "\u{0}" ? nil : value
    }

    @Test(arguments: ["en", "ja"])
    func 영어_일본어_번역이_번들에_들어간다(language: String) throws {
        let value = try #require(lookup("일반", in: language))
        #expect(!value.isEmpty)
        #expect(value != "일반")
    }

    @Test func 뜻이_다른_같은_원문은_키를_나눠_번역한다() {
        #expect(lookup("재생", in: "en") == "Playback")
        #expect(lookup("library.column.plays", in: "en") == "Plays")
    }

    @Test func 복원은_쓰기_전_상태를_명시하고_확인_버튼에는_말줄임표가_없다() {
        #expect(lookup("쓰기 전으로 복원…", in: "en") == "Restore Before Write…")
        #expect(lookup("쓰기 전으로 복원…", in: "ja") == "書き込み前に復元…")
        #expect(lookup("쓰기 전으로 복원", in: "en") == "Restore Before Write")
        #expect(lookup("쓰기 전으로 복원", in: "ja") == "書き込み前に復元")
    }

    @Test func 영어는_수에_따라_복수형을_고른다() throws {
        let path = try #require(Bundle.module.path(forResource: "en", ofType: "lproj"))
        let format = try #require(Bundle(path: path)).localizedString(forKey: "마디 %lld개", value: nil, table: nil)
        // 복수형 규칙은 형식을 채우는 로캘의 언어를 따른다(앱에서는 화면 언어와 같다).
        let english = Locale(identifier: "en_US")
        #expect(String(format: format, locale: english, 1) == "1 bar")
        #expect(String(format: format, locale: english, 3) == "3 bars")
    }

    @Test func 개발_빌드도_macOS_언어_목록을_가진다() throws {
        // 실행 파일에 넣은 Info.plist(Package.swift의 -sectcreate)와 같은 파일이다.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/DJCrate/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url))
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(plist["CFBundleLocalizations"] as? [String] == ["ko", "en", "ja"])
    }
}
