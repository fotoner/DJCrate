import Foundation
import Testing
@testable import DJCDomain

/// 평점·곡 색 칸(#65, `rating`·`color`): rekordbox 7.2.18 실험(2026-10-04 묶음 2: 평점 "DJC 시험 02" 0 → 3 → 5 → 0,
/// 곡 색 "DJC 시험 04" 없음 → Red → Blue → 없음, 모두 동기화 상태 0 곡)에서 본 값의 모양을 초안 칸으로 다룬다.
/// - 평점: `djmdContent.Rating` 정수 0~5(별 수 그대로). 초안 값은 "1"~"5", 없으면 빈칸(쓰면 0).
/// - 곡 색: `djmdContent.ColorID` = `djmdColor.ID`('1'~'8'). 초안 값은 그 번호, 없으면 빈칸(쓰면 '0').
@Suite("태그 평점·곡 색 칸")
struct RatingColorTagTests {
    func track(rating: Int = 0, colorID: String? = nil, dataStatus: Int? = 0) -> Track {
        Track(id: "1", uuid: "u", title: "Song", artist: "A", album: "Al", albumArtist: nil, genre: "Anime",
              composer: nil, releaseYear: 2013, trackNumber: 1, key: "5A", bpm: 154, lengthSeconds: 269,
              folderPath: "/x.m4a", comment: "", importedOn: "2023-11-21",
              analysisDataPath: nil, imagePath: nil, isDeleted: false, rating: rating, colorID: colorID, dataStatus: dataStatus)
    }

    // MARK: 칸 이름·순서

    @Test func 칸_이름과_순서는_옛_칸_뒤에_붙인다() {
        #expect(TagFields.Key.rating.rawValue == "rating" && TagFields.Key.color.rawValue == "color")
        #expect(TagFields.Key.rating.label == "평점" && TagFields.Key.color.label == "곡 색")
        // 옛 칸 순서는 그대로(순서에 기대는 출력·시험이 바뀌지 않게)
        #expect(Array(TagFields.Key.allCases.prefix(10)) == [.title, .artist, .album, .albumArtist, .genre, .composer, .year, .trackNumber, .comment, .musicalKey])
        #expect(Array(TagFields.Key.allCases.suffix(2)) == [.rating, .color])
        #expect(TagFields.Key.independent == [.musicalKey, .rating, .color])
    }

    @Test func 곡의_rekordbox_값이_기준값이다() {
        #expect(TagFields(track: track(rating: 3, colorID: "2")).rating == "3")
        #expect(TagFields(track: track(rating: 3, colorID: "2")).color == "2")
        // 0·'0'·''은 없음(빈칸)이다
        #expect(TagFields(track: track(rating: 0, colorID: "0")).rating == "")
        #expect(TagFields(track: track(rating: 0, colorID: "0")).color == "")
        #expect(TagFields(track: track(colorID: "")).color == "")
        #expect(track(colorID: "0").colorID == nil && track(colorID: "").colorID == nil && track(colorID: "7").colorID == "7")
        var fields = TagFields()
        fields[.rating] = "5"
        fields[.color] = "7"
        #expect(fields.rating == "5" && fields.color == "7" && fields[.rating] == "5" && fields[.color] == "7")
    }

    @Test func 곡은_동기화_상태를_든다() {
        #expect(track(dataStatus: 256).dataStatus == 256)
        let staged = StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/x.mp3", title: "x", duration: 1, addedOn: "2026-10-06").track
        #expect(staged.dataStatus == nil && staged.rating == 0 && staged.colorID == nil)
    }

    // MARK: 평점 값

    @Test(arguments: [("3", "3"), (" 5 ", "5"), ("★★", "2"), ("★★★★★", "5"), ("0", ""), ("", ""), ("★☆☆☆☆", "1")])
    func 평점_입력은_초안_값으로_다듬는다(raw: String, expected: String) {
        #expect(TrackRating.accepted(raw) == expected)
    }

    @Test(arguments: ["6", "-1", "세 개", "3.5", "★★★★★★", "a"])
    func 평점이_아닌_입력은_거절한다(raw: String) {
        #expect(TrackRating.accepted(raw) == nil)
    }

    @Test func 평점은_별로_보인다() {
        #expect(TrackRating.stars("3") == "★★★☆☆")
        #expect(TrackRating.stars("5") == "★★★★★")
        #expect(TrackRating.stars("") == "")
        #expect(TrackRating.choices == ["1", "2", "3", "4", "5"])
    }

    /// 칸이 좁아 별 다섯 칸이 안 들어갈 때 쓰는 짧은 표기. 잘린 별("★★★…")은 3·4·5를 가릴 수 없어, 숫자를 앞에 둔다.
    @Test func 평점은_좁은_칸용_숫자_표기가_있다() {
        #expect(TrackRating.choices.map(TrackRating.compact) == ["1★", "2★", "3★", "4★", "5★"])
        #expect(TrackRating.compact("") == "" && TrackRating.compact("0") == "" && TrackRating.compact("x") == "")
        #expect(TrackRating.compact("9") == "5★", "별은 다섯을 넘지 않는다(stars와 같다)")
        // 다섯 값이 서로 다르게 읽혀야 한다
        #expect(Set(TrackRating.choices.map(TrackRating.compact)).count == 5)
    }

    // MARK: 곡 색 값

    @Test func rekordbox_기본_여덟_색은_번호와_이름이_정해져_있다() {
        // 묶음 2 사본의 djmdColor: ID '1'~'8', SortKey 1~8, Commnt Pink·Red·Orange·Yellow·Green·Aqua·Blue·Purple
        #expect(TrackColor.rekordboxDefaults.map(\.id) == ["1", "2", "3", "4", "5", "6", "7", "8"])
        #expect(TrackColor.rekordboxDefaults.map(\.name) == ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"])
    }

    @Test(arguments: [("2", "2"), ("red", "2"), (" Blue ", "7"), ("PURPLE", "8"), ("", ""), ("0", "")])
    func 곡_색_입력은_번호로_다듬는다(raw: String, expected: String) {
        #expect(TrackColor.accepted(raw, in: TrackColor.rekordboxDefaults) == expected)
    }

    @Test(arguments: ["9", "빨강", "Rose", "-1"])
    func 모르는_색은_거절한다(raw: String) {
        #expect(TrackColor.accepted(raw, in: TrackColor.rekordboxDefaults) == nil)
    }

    @Test func 라이브러리에서_바꾼_색_이름도_받는다() {
        let colors = [TrackColor(id: "1", name: "Opener"), TrackColor(id: "2", name: "Peak")]
        #expect(TrackColor.accepted("peak", in: colors) == "2")
        #expect(TrackColor.name(of: "2", in: colors) == "Peak")
        #expect(TrackColor.name(of: "9", in: colors) == "9", "모르는 번호는 번호 그대로 보인다")
        #expect(TrackColor.name(of: "", in: colors) == "")
    }

    // MARK: 초안 문제

    @Test func 고친_평점과_곡_색만_값을_본다() {
        var draft = TagDraft(track: track(rating: 2, colorID: "3"))
        draft.fields.comment = "코멘트만"
        #expect(draft.issues.isEmpty)
        draft.fields.rating = "6"
        #expect(draft.issues.contains { $0.contains("평점") && $0.contains("rekordbox에 쓰세요") })
        draft.fields.rating = ""
        #expect(draft.issues.isEmpty && draft.changedKeys.contains(.rating))
        draft.fields.color = "9"
        #expect(draft.issues.contains { $0.contains("곡 색") && $0.contains("rekordbox에 쓰세요") })
        draft.fields.color = "7"
        #expect(draft.issues.isEmpty)
        // 여덟 색 밖(번호 0·이름)과 1~5 밖 평점(음수·별 표기)도 초안 문제다(RekordboxTagRatingColorTests에서 옮김)
        for (key, value, word) in [(TagFields.Key.color, "0", "곡 색"), (.color, "Red", "곡 색"), (.rating, "-1", "평점"), (.rating, "★", "평점")] {
            var other = TagDraft(trackUUID: "u", base: TagFields())
            other.fields[key] = value
            #expect(other.issues.contains { $0.contains(word) }, "\(value)")
        }
    }

    // MARK: 옛 초안

    @Test func 평점과_곡_색_칸이_없는_옛_초안_파일도_읽는다() throws {
        // 키 칸까지 있던 초안(#5 뒤, #65 전)
        let fields = #"{"title":"A","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":"","musicalKey":"5A"}"#
        let json = #"{"trackUUID":"u","base":\#(fields),"fields":\#(fields.replacingOccurrences(of: "\"A\"", with: "\"B\""))}"#
        let draft = try JSONDecoder().decode(TagDraft.self, from: Data(json.utf8))
        #expect(draft.base.rating == "" && draft.base.color == "" && draft.fields.rating == "" && draft.fields.color == "")
        #expect(draft.changedKeys == [.title])
    }

    @Test func 새_초안은_두_칸을_담아_다시_읽으면_같다() throws {
        var draft = TagDraft(track: track())
        draft.fields.rating = "4"
        draft.fields.color = "2"
        let data = try JSONEncoder().encode(draft)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"rating\":\"4\"") && text.contains("\"color\":\"2\""))
        #expect(try JSONDecoder().decode(TagDraft.self, from: data) == draft)
    }

    // MARK: 기준 비교에서 빼는 규칙

    @Test func 고치지_않은_평점과_곡_색은_지금_값으로_맞춘다() {
        // 칸이 없던 옛 초안(읽으면 '')이 이미 평점·색이 있는 곡에서 그 칸을 "고친" 것으로 보이지 않게
        var draft = TagDraft(trackUUID: "u", base: TagFields())
        draft.fields.title = "새 제목"
        var current = TagFields()
        current.rating = "3"
        current.color = "2"
        current.musicalKey = "5A"
        let adopted = draft.adoptingIndependentKeys(of: current)
        #expect(adopted.base.rating == "3" && adopted.fields.rating == "3" && adopted.base.color == "2" && adopted.fields.color == "2")
        #expect(adopted.base.musicalKey == "5A" && adopted.changedKeys == [.title])
        // 고친 칸은 그대로 둔다(기준이 어긋났는지는 쓰기가 가린다)
        draft.fields.rating = "5"
        let partly = draft.adoptingIndependentKeys(of: current)
        #expect(partly.base.rating == "" && partly.fields.rating == "5" && partly.base.color == "2")
        // 키만 맞추는 옛 함수는 평점·색을 건드리지 않는다
        #expect(draft.adoptingMusicalKey(of: current).base.rating == "")
    }

    // MARK: 확인한 범위 (곡 상태·재생 목록)

    @Test func 평점과_곡_색은_상태_0·256·257_곡을_재생_목록에_들어도_확인했다() {
        // 상태 0: 2026-10-04 묶음 2 S1~S3. 동기화 256 → 257: #173 S1 T11·T12(2026-10-04), 사본 재현 2026-10-07.
        // 재생 목록에 든 곡: R65(rekordbox 7.2.18, 2026-10-09) — 곡이 든 목록의 XML Timestamp만 바뀐다(정보 패널 칸과 같다)
        #expect(TagWriteScope.scope(for: .rating) == TagWriteScope(states: [0, 256, 257], playlistXML: true))
        #expect(TagWriteScope.scope(for: .color) == TagWriteScope(states: [0, 256, 257], playlistXML: true))
        for key in TagFields.Key.allCases where key != .rating && key != .color {
            #expect(TagWriteScope.scope(for: key) == .common, "\(key)")
        }
        #expect(TagWriteScope.blockReason(keys: [.rating, .title], state: 0, inPlaylist: false) == nil)
        #expect(TagWriteScope.blockReason(keys: [.title, .musicalKey], state: 256, inPlaylist: true) == nil)
        for state in [0, 256, 257] {
            for listed in [false, true] {
                #expect(TagWriteScope.blockReason(keys: [.rating, .color], state: state, inPlaylist: listed) == nil, "\(state) \(listed)")
            }
        }
    }

    @Test func 범위_밖의_곡_상태는_칸_이름과_할_일을_함께_알린다() throws {
        // 범위 표가 곡 상태를 좁히면(지금은 평점·곡 색도 공통과 같은 0·256·257) 동기화 곡을 그 칸만 막는다
        let narrow = TagWriteScope(states: [0], playlistXML: false)
        let reason = try #require(TagWriteScope.blockReason(keys: [.title, .rating, .color], state: 256, inPlaylist: false,
                                                            scopes: [.rating: narrow, .color: narrow]))
        #expect(reason.contains("동기화") && reason.contains("평점·곡 색") && reason.contains("rekordbox에서"))
        let colorOnly = try #require(TagWriteScope.blockReason(keys: [.color], state: 257, inPlaylist: false, scopes: [.color: narrow]))
        #expect(colorOnly.contains("곡 색") && !colorOnly.contains("평점"))
    }

    @Test func 초안이_있을_때만_그_칸_초안을_버리라고_한다() throws {
        // 초안을 만들기 전(인스펙터·목록·djc draft·XML 가져오기)에는 버릴 초안이 없다. 쓰기 확인(초안이 있음)만 그 할 일을 붙인다.
        let before = try #require(TagWriteScope.blockReason(keys: [.rating], state: 258, inPlaylist: false))
        #expect(before.contains("rekordbox에서 직접 고치세요") && !before.contains("초안"))
        let drafted = try #require(TagWriteScope.blockReason(keys: [.rating], state: 258, inPlaylist: false, hasDraft: true))
        #expect(drafted.contains("rekordbox에서 직접 고치거나 이 칸 초안을 버리세요"))
        let narrow = [TagFields.Key.color: TagWriteScope(states: [0, 256, 257], playlistXML: false)]
        let listed = try #require(TagWriteScope.blockReason(keys: [.color], state: 0, inPlaylist: true, scopes: narrow))
        #expect(listed.contains("재생 목록") && !listed.contains("초안"))
        #expect(TagWriteScope.blockReason(keys: [.color], state: 0, inPlaylist: true, scopes: narrow, hasDraft: true)?.contains("초안을 버리세요") == true)
    }

    @Test func 상태를_모르는_곡도_막는다() {
        #expect(TagWriteScope.blockReason(keys: [.rating], state: nil, inPlaylist: false) != nil)
        #expect(TagWriteScope.blockReason(keys: [.rating], state: 258, inPlaylist: false) != nil)
    }

    @Test func 재생_목록_XML을_확인하지_않은_범위면_재생_목록에_든_곡을_막는다() throws {
        let narrow = [TagFields.Key.rating: TagWriteScope(states: [0, 256, 257], playlistXML: false)]
        let reason = try #require(TagWriteScope.blockReason(keys: [.rating], state: 0, inPlaylist: true, scopes: narrow))
        #expect(reason.contains("재생 목록") && reason.contains("평점") && reason.contains("rekordbox에서"))
    }

    @Test func 범위를_넓히면_한_곳만_고친다() {
        // 실험으로 동기화 곡·재생 목록을 확인하면 표만 바꾼다: 표에 없는 칸은 공통 범위다
        #expect(TagWriteScope.blockReason(keys: [.rating], state: 256, inPlaylist: true, scopes: [:]) == nil)
        #expect(TagWriteScope.blockReason(keys: [.rating], state: 256, inPlaylist: true,
                                          scopes: [.rating: TagWriteScope(states: [0, 256, 257], playlistXML: false)])?.contains("재생 목록") == true)
    }
}
