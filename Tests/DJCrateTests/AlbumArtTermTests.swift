import Foundation
import Testing

/// 곡 아트워크를 가리키는 화면 문구는 한 이름 "앨범아트"로 쓰고(#198), 영어는 uncountable·Title Case 규칙을 지킨다.
/// 카탈로그를 직접 읽으므로 새 문구가 옛 이름("그림"·"아트워크"·"앨범 아트"·"앨범 커버")으로 되돌아오면 여기서 걸린다.
@Suite("앨범아트 용어")
struct AlbumArtTermTests {
    typealias Entry = (key: String, values: [(language: String, text: String)])

    static let entries: [Entry] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Sources/DJCrate/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else { return [] }
        return strings.map { key, value in
            var values: [(String, String)] = []
            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for (language, localization) in localizations {
                guard let localization = localization as? [String: Any] else { continue }
                if let unit = localization["stringUnit"] as? [String: Any], let text = unit["value"] as? String {
                    values.append((language, text))
                }
                let forms = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
                for form in forms.values {
                    if let unit = (form as? [String: Any])?["stringUnit"] as? [String: Any], let text = unit["value"] as? String {
                        values.append((language, text))
                    }
                }
            }
            return (key, values)
        }
    }()

    static func texts(_ language: String) -> [(key: String, text: String)] {
        entries.flatMap { entry in entry.values.filter { $0.language == language }.map { (entry.key, $0.text) } }
    }

    static func english(_ key: String) -> String? { texts("en").first { $0.key == key }?.text }

    @Test func 카탈로그를_읽었다() {
        #expect(Self.entries.count > 1000)
        #expect(Self.english("앨범아트") == "Album Art")
    }

    @Test func 한국어_문구는_앨범아트로_통일한다() {
        for term in ["그림", "아트워크", "앨범 아트", "앨범 커버"] {
            let hits = Self.entries.map(\.key).filter { $0.contains(term) }
            #expect(hits.isEmpty, "\(term): \(hits)")
        }
    }

    @Test func 영어와_일본어에_옛_이름이_남지_않는다() {
        // 폴더 이름(share/PIONEER/Artwork)은 rekordbox의 실제 이름이라 그대로 둔다.
        let artwork = Self.texts("en").map { ($0.key, $0.text.replacingOccurrences(of: "share/PIONEER/Artwork", with: "")) }
            .filter { $0.1.localizedCaseInsensitiveContains("artwork") }
        #expect(artwork.isEmpty, "\(artwork.map(\.0))")
        let japanese = Self.texts("ja").filter { $0.text.contains("アートワーク") }
        #expect(japanese.isEmpty, "\(japanese.map(\.key))")
    }

    @Test func 폴더_경로는_일괄_치환에_바뀌지_않는다() throws {
        let key = "앨범아트 폴더(share/PIONEER/Artwork) 아래에 링크가 있어 share 밖에 쓸 수 있으니 링크를 실제 폴더로 바꾼 뒤 다시 쓰세요"
        let english = try #require(Self.english(key))
        #expect(english.contains("(share/PIONEER/Artwork)") && !english.contains("Album art)"))
        #expect(Self.texts("ja").first { $0.key == key }?.text.contains("share/PIONEER/Artwork") == true)
    }

    @Test func 영어_album_art는_셀_수_없는_말이다() {
        // 뒤에 셀 수 있는 이름이 붙지 않은 "an album art"와 복수형 "album arts"는 틀린 문장이다.
        let pattern = #/\b(?:an?|another|these|those) album art\b(?! (?:draft|drafts|record|file|files|path|folder|copy))|album arts/#
            .ignoresCase()
        let wrong = Self.texts("en").filter { $0.text.firstMatch(of: pattern) != nil }
        #expect(wrong.isEmpty, "\(wrong.map(\.text))")
    }

    @Test(arguments: [
        ("앨범아트 고르기", "Choose Album Art"),
        ("앨범아트 넣기", "Add Album Art"),
        ("앨범아트 바꾸기", "Replace Album Art"),
        ("앨범아트 지우기", "Remove Album Art"),
        ("앨범아트 초안 버리기", "Discard Album Art Draft"),
    ])
    func 버튼과_메뉴_영어는_Title_Case다(key: String, expected: String) {
        #expect(Self.english(key) == expected)
    }

    @Test func 안내_문장_속_메뉴_이름도_같은_Title_Case다() {
        let messages = Self.texts("en").filter { $0.text.localizedCaseInsensitiveContains("Discard Album Art Draft") }
        #expect(messages.count >= 3)
        #expect(messages.allSatisfy { $0.text.contains("Discard Album Art Draft") || $0.key == "앨범아트 초안 버리기" })
    }
}
