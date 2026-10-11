import Foundation
import Testing
@testable import DJCDomain

/// 태그의 열째 칸 키(#5, `musicalKey`): rekordbox 표기 그대로(`ScaleName`, 예 "8A"), 비우면 키 없음.
/// 목록의 키 칸(`"key"`)은 보기 전용으로 두려고 이름이 겹치지 않는다.
@Suite("태그 키 칸")
struct MusicalKeyTagTests {
    func track(key: String? = "5A") -> Track {
        Track(id: "1", uuid: "u", title: "Song", artist: "A", album: "Al", albumArtist: nil, genre: "Anime",
              composer: nil, releaseYear: 2013, trackNumber: 1, key: key, bpm: 154, lengthSeconds: 269,
              folderPath: "/x.m4a", comment: "", importedOn: "2023-11-21",
              analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    // MARK: 칸 이름

    @Test func 키_칸_이름은_목록_키_칸과_겹치지_않는다() {
        #expect(TagFields.Key.musicalKey.rawValue == "musicalKey")
        #expect(TagFields.Key(rawValue: "key") == nil)
        #expect(TagFields.Key.musicalKey.label == "키")
        // 옛 칸 순서는 그대로 두고 맨 뒤에 붙인다(순서에 기대는 출력·시험이 바뀌지 않게)
        #expect(Array(TagFields.Key.allCases.prefix(9)) == [.title, .artist, .album, .albumArtist, .genre, .composer, .year, .trackNumber, .comment])
        #expect(TagFields.Key.allCases[9] == .musicalKey, "평점·곡 색(#65)은 그 뒤에 붙는다")
    }

    @Test func 곡의_rekordbox_키가_기준값이다() {
        #expect(TagFields(track: track(key: "5A")).musicalKey == "5A")
        #expect(TagFields(track: track(key: nil)).musicalKey == "")
        // 살아 있는 옛 표기 줄이나 삭제 표시 줄의 이름도 읽는 그대로 둔다(고르지는 못한다)
        #expect(TagFields(track: track(key: "Em")).musicalKey == "Em")
        var fields = TagFields()
        fields[.musicalKey] = "8A"
        #expect(fields.musicalKey == "8A" && fields[.musicalKey] == "8A")
    }

    // MARK: Camelot 이름

    @Test func 받는_이름은_Camelot_스물네_개뿐이다() {
        let names = KeyNotation.camelotNames
        #expect(names.count == 24 && Set(names).count == 24)
        #expect(names.first == "1A" && names[1] == "1B" && names.last == "12B")
        #expect(names.allSatisfy { KeyNotation.normalizedCamelotName($0) == $0 })
        #expect(!names.contains("Am") && !names.contains("0A") && !names.contains("13A"))
    }

    @Test(arguments: [("8a", "8A"), (" 12b ", "12B"), ("08A", "8A"), ("1A", "1A")])
    func 입력은_정확한_이름으로_다듬는다(raw: String, expected: String) {
        #expect(KeyNotation.normalizedCamelotName(raw) == expected)
    }

    @Test(arguments: ["Am", "C major", "1m", "13A", "0B", "8", "A", "8C", "8AA", "8 A", "-1A"])
    func 다른_표기는_바꾸지_않고_거절한다(raw: String) {
        #expect(KeyNotation.normalizedCamelotName(raw) == nil)
    }

    // MARK: 초안 문제

    @Test func 키를_고쳤을_때만_이름을_본다() {
        var draft = TagDraft(track: track(key: "Em"))
        draft.fields.comment = "코멘트만 고침"
        #expect(draft.issues.isEmpty, "옛 표기 키를 가진 곡도 다른 칸은 쓸 수 있다")
        draft.fields.musicalKey = "Am"
        #expect(draft.issues.contains { $0.contains("1A") && $0.contains("12B") })
        draft.fields.musicalKey = "8A"
        #expect(draft.issues.isEmpty)
        draft.fields.musicalKey = ""
        #expect(draft.issues.isEmpty && draft.changedKeys.contains(.musicalKey))
        // Camelot 스물네 이름이 아니면(소문자·범위 밖·다른 표기) 초안 문제다(RekordboxTagKeyTests에서 옮김)
        for name in ["C", "8a", "13A", "0A", "키"] {
            var other = TagDraft(trackUUID: "u", base: TagFields())
            other.fields.musicalKey = name
            #expect(other.issues.contains { $0.contains("1A~12B") }, "\(name)")
        }
    }

    @Test func 키만_고친_초안과_섞인_초안을_가린다() {
        var draft = TagDraft(track: track())
        draft.fields.musicalKey = "6A"
        #expect(draft.changedKeys == [.musicalKey] && draft.hasChanges)
        draft.fields.musicalKey = "5A"
        #expect(!draft.hasChanges)
    }

    @Test func 고르기_목록은_없음과_스물네_이름이고_옛_표기_현재값은_맨_앞에_보인다() {
        #expect(KeyNotation.pickerChoices(current: "5A") == KeyNotation.camelotNames)
        #expect(KeyNotation.pickerChoices(current: "") == KeyNotation.camelotNames)
        #expect(KeyNotation.pickerChoices(current: "Em") == ["Em"] + KeyNotation.camelotNames)
    }

    // MARK: 옛 초안

    @Test func 키_칸이_없는_옛_초안_파일도_읽는다() throws {
        let json = """
        {"trackUUID":"u","base":{"title":"A","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":""},\
        "fields":{"title":"B","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":""}}
        """
        let draft = try JSONDecoder().decode(TagDraft.self, from: Data(json.utf8))
        #expect(draft.base.musicalKey == "" && draft.fields.musicalKey == "")
        #expect(draft.changedKeys == [.title])
    }

    @Test func 새_초안은_키_칸을_담아_다시_읽으면_같다() throws {
        var draft = TagDraft(track: track())
        draft.fields.musicalKey = "6A"
        let data = try JSONEncoder().encode(draft)
        #expect(String(decoding: data, as: UTF8.self).contains("\"musicalKey\":\"6A\""))
        #expect(try JSONDecoder().decode(TagDraft.self, from: data) == draft)
    }

    @Test func 키_칸이_아닌_옛_칸이_빠진_파일은_여전히_손상으로_본다() {
        let json = """
        {"trackUUID":"u","base":{"title":"A"},"fields":{"title":"B"}}
        """
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TagDraft.self, from: Data(json.utf8)) }
    }

    // MARK: 기준 비교에서 키를 빼는 규칙

    @Test func 키를_안_고친_초안은_키를_지금_값으로_맞춘다() {
        // 키가 없던 시절의 초안(디코딩하면 '')이 이미 키가 있는 곡에서 어긋난 초안으로 보이지 않게
        var draft = TagDraft(trackUUID: "u", base: TagFields())
        draft.fields.title = "새 제목"
        var current = TagFields()
        current.musicalKey = "5A"
        let adopted = draft.adoptingMusicalKey(of: current)
        #expect(adopted.base.musicalKey == "5A" && adopted.fields.musicalKey == "5A" && adopted.changedKeys == [.title])
        // 키를 고친 초안은 그대로 둔다(기준이 어긋났는지 쓰기가 가려야 한다)
        draft.fields.musicalKey = "6A"
        #expect(draft.adoptingMusicalKey(of: current) == draft)
    }
}
