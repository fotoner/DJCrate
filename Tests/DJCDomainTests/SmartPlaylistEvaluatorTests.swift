import DJCDomain
import Foundation
import Testing

/// 인텔리전트 재생 목록 조건 계산기(순수 규칙). 곡·조건은 모두 합성이다.
/// 경계·대소문자·빈 값은 rekordbox와 맞춰 보지 않았다(묶음 3 M1) — 지금 값은 `SmartPlaylistSemantics.provisional`이고,
/// 아래 시험은 그 기본값과 반대 해석으로 바꿨을 때의 결과를 함께 못 박아 M1 결과를 한 줄로 반영할 수 있게 한다.
@Suite("인텔리전트 재생 목록 조건 계산")
struct SmartPlaylistEvaluatorTests {
    static func track(_ id: String, title: String = "", artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                      comment: String = "", year: Int? = nil, deleted: Bool = false) -> Track {
        Track(id: id, uuid: "uuid-\(id)", title: title, artist: artist, album: album, albumArtist: albumArtist, genre: nil, composer: nil,
              releaseYear: year, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 200, folderPath: "/m/\(id).mp3", comment: comment,
              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: deleted)
    }

    static func condition(_ property: String, _ op: Int, _ left: String = "", _ right: String = "", unit: String = "")
        -> SmartPlaylistDefinition.Condition {
        .init(propertyName: property, operatorCode: op, unit: unit, left: left, right: right)
    }

    static func list(_ conditions: [SmartPlaylistDefinition.Condition], match: SmartPlaylistDefinition.Match = .all) -> SmartPlaylistSource {
        .definition(SmartPlaylistDefinition(match: match, automaticUpdate: false, conditions: conditions))
    }

    static func ids(_ source: SmartPlaylistSource, _ tracks: [Track], _ semantics: SmartPlaylistSemantics = .provisional) -> [String]? {
        let result = SmartPlaylistEvaluator.evaluate(source, tracks: tracks, semantics: semantics)
        if case let .tracks(ids) = result { return ids }
        return nil
    }

    static let artists = [
        track("1", title: "Alpha", artist: "ClariS"),
        track("2", title: "alpha two", artist: "Claris"),
        track("3", title: "Beta", artist: "Other"),
        track("4", title: "Gamma", artist: nil),
        track("5", title: "ClariS Medley", artist: ""),
    ]

    // MARK: 글자

    @Test func 같음은_기본으로_대소문자를_가리지_않는다() {
        #expect(Self.ids(Self.list([Self.condition("artist", 1, "ClariS")]), Self.artists) == ["1", "2"])
    }

    @Test func 같음을_대소문자_구분으로_바꾸면_정확히_같은_곡만() {
        var semantics = SmartPlaylistSemantics.provisional
        semantics.ignoresCase = false
        #expect(Self.ids(Self.list([Self.condition("artist", 1, "ClariS")]), Self.artists, semantics) == ["1"])
    }

    @Test func 포함_시작_끝() {
        #expect(Self.ids(Self.list([Self.condition("name", 8, "ALPHA")]), Self.artists) == ["1", "2"])
        #expect(Self.ids(Self.list([Self.condition("name", 10, "alpha")]), Self.artists) == ["1", "2"])
        #expect(Self.ids(Self.list([Self.condition("name", 11, "two")]), Self.artists) == ["2"])
        #expect(Self.ids(Self.list([Self.condition("name", 11, "tw")]), Self.artists) == [])
        #expect(Self.ids(Self.list([Self.condition("name", 10, "lpha")]), Self.artists) == [])
    }

    @Test func 포함을_대소문자_구분으로_바꾸면_소문자_입력은_더_적게_걸린다() {
        var semantics = SmartPlaylistSemantics.provisional
        semantics.ignoresCase = false
        #expect(Self.ids(Self.list([Self.condition("name", 8, "alpha")]), Self.artists, semantics) == ["2"])
    }

    @Test func 같지_않음과_포함하지_않음은_빈_값을_기본으로_포함한다() {
        // 4(아티스트 없음)·5(빈 글자)도 'ClariS가 아님'
        #expect(Self.ids(Self.list([Self.condition("artist", 2, "ClariS")]), Self.artists) == ["3", "4", "5"])
        #expect(Self.ids(Self.list([Self.condition("artist", 9, "ari")]), Self.artists) == ["3", "4", "5"])
    }

    @Test func 부정을_빈_값_제외로_바꾸면_값이_있는_곡만_남는다() {
        var semantics = SmartPlaylistSemantics.provisional
        semantics.negationMatchesEmpty = false
        #expect(Self.ids(Self.list([Self.condition("artist", 2, "ClariS")]), Self.artists, semantics) == ["3"])
        #expect(Self.ids(Self.list([Self.condition("artist", 9, "ari")]), Self.artists, semantics) == ["3"])
    }

    @Test func 빈_값은_같음_포함_시작_끝에_걸리지_않는다() {
        for op in [1, 8, 10, 11] {
            let found = Self.ids(Self.list([Self.condition("artist", op, "x")]), [Self.track("4"), Self.track("5", artist: "")])
            #expect(found == [], "연산자 \(op)")
        }
    }

    @Test func 합성_분해_글자가_달라도_같은_글자는_같다() {
        // 'é'를 한 글자(NFC)와 e + 결합 악센트(NFD)로
        let nfd = Self.track("1", title: "Cafe\u{301}")
        #expect(Self.ids(Self.list([Self.condition("name", 1, "Caf\u{E9}")]), [nfd]) == ["1"])
        #expect(Self.ids(Self.list([Self.condition("name", 8, "af\u{E9}")]), [nfd]) == ["1"])
    }

    @Test func 글자_항목은_제목_아티스트_앨범_앨범_아티스트_코멘트에_각각_묶인다() {
        let track = Self.track("1", title: "T", artist: "A", album: "B", albumArtist: "C", comment: "D")
        for (name, value) in [("name", "T"), ("artist", "A"), ("album", "B"), ("albumArtist", "C"), ("comments", "D")] {
            #expect(Self.ids(Self.list([Self.condition(name, 1, value)]), [track]) == ["1"], "\(name)")
            #expect(Self.ids(Self.list([Self.condition(name, 1, "없는 값")]), [track]) == [], "\(name)")
        }
    }

    // MARK: 숫자(연도)

    static let years = [Self.track("1", year: 2014), Self.track("2", year: 2015), Self.track("3", year: 2016), Self.track("4", year: 2020),
                        Self.track("5", year: 2021), Self.track("6", year: nil)]

    @Test func 연도_같음과_같지_않음() {
        #expect(Self.ids(Self.list([Self.condition("year", 1, "2015")]), Self.years) == ["2"])
        // 연도 없는 곡(6)은 기본으로 '아님'에 든다
        #expect(Self.ids(Self.list([Self.condition("year", 2, "2015")]), Self.years) == ["1", "3", "4", "5", "6"])
    }

    @Test func 연도_보다_큼과_작음은_기본으로_경계를_뺀다() {
        #expect(Self.ids(Self.list([Self.condition("year", 3, "2016")]), Self.years) == ["4", "5"])
        #expect(Self.ids(Self.list([Self.condition("year", 4, "2016")]), Self.years) == ["1", "2"])
    }

    @Test func 큼과_작음을_경계_포함으로_바꾸면_같은_연도가_든다() {
        var semantics = SmartPlaylistSemantics.provisional
        semantics.greaterIncludesEqual = true
        semantics.lessIncludesEqual = true
        #expect(Self.ids(Self.list([Self.condition("year", 3, "2016")]), Self.years, semantics) == ["3", "4", "5"])
        #expect(Self.ids(Self.list([Self.condition("year", 4, "2016")]), Self.years, semantics) == ["1", "2", "3"])
    }

    @Test func 범위는_기본으로_양끝을_포함한다() {
        #expect(Self.ids(Self.list([Self.condition("year", 5, "2015", "2020")]), Self.years) == ["2", "3", "4"])
        var semantics = SmartPlaylistSemantics.provisional
        semantics.rangeIncludesEnds = false
        #expect(Self.ids(Self.list([Self.condition("year", 5, "2015", "2020")]), Self.years, semantics) == ["3"])
    }

    @Test func 연도가_없는_곡은_크기_비교와_범위에_걸리지_않는다() {
        for (op, right) in [(3, ""), (4, ""), (5, "2030")] {
            let found = Self.ids(Self.list([Self.condition("year", op, "1900", right)]), [Self.track("6", year: nil)])
            #expect(found == [], "연산자 \(op)")
        }
    }

    // MARK: 모두·하나라도

    @Test func 모두는_교집합_하나라도는_합집합() {
        let tracks = [Self.track("1", artist: "A", year: 2000), Self.track("2", artist: "A", year: 2010), Self.track("3", artist: "B", year: 2010)]
        let conditions = [Self.condition("artist", 1, "A"), Self.condition("year", 1, "2010")]
        #expect(Self.ids(Self.list(conditions, match: .all), tracks) == ["2"])
        #expect(Self.ids(Self.list(conditions, match: .any), tracks) == ["1", "2", "3"])
    }

    @Test func 결과는_입력_곡_순서를_따르고_지워진_곡은_뺀다() {
        let tracks = [Self.track("9", title: "x"), Self.track("2", title: "x", deleted: true), Self.track("5", title: "x"), Self.track("1", title: "x")]
        #expect(Self.ids(Self.list([Self.condition("name", 1, "x")]), tracks) == ["9", "5", "1"])
    }

    @Test func 곡이_없으면_빈_목록() {
        #expect(Self.ids(Self.list([Self.condition("name", 1, "x")]), []) == [])
    }

    // MARK: 지원하지 않는 조건

    @Test func 아직_맞춰_보지_않은_항목은_계산하지_않는다() {
        let names = ["bpm", "grouping", "stockDate", "dateCreated", "counter", "fileName", "genre", "key", "label", "mixName", "myTag", "rating",
                     "dateReleased", "remixedBy", "duration", "producer", "originalArtist"]
        for name in names {
            let result = SmartPlaylistEvaluator.evaluate(Self.list([Self.condition(name, 1, "1")]), tracks: Self.artists)
            #expect(result.trackIDs.isEmpty, "\(name)")
            #expect(result.unsupportedReasons.count == 1, "\(name)")
            #expect(result.unsupportedReasons.first?.contains(name) == true, "\(name)")
        }
    }

    @Test func 지원하지_않는_조건이_하나라도_있으면_곡을_보이지_않는다() {
        let supported = Self.condition("name", 8, "alpha")
        let unsupported = Self.condition("rating", 3, "3")
        for match in [SmartPlaylistDefinition.Match.all, .any] {
            let result = SmartPlaylistEvaluator.evaluate(Self.list([supported, unsupported], match: match), tracks: Self.artists)
            #expect(result == .unsupported(result.unsupportedReasons))
            #expect(result.trackIDs.isEmpty)
            #expect(result.unsupportedReasons.count == 1)
        }
    }

    @Test func 지원하지_않는_조건마다_이유를_하나씩_낸다() {
        let result = SmartPlaylistEvaluator.evaluate(
            Self.list([Self.condition("rating", 3, "3"), Self.condition("name", 1, "x"), Self.condition("bpm", 3, "12800")]),
            tracks: Self.artists)
        #expect(result.unsupportedReasons.count == 2)
    }

    @Test func 같은_이유는_한_번만_낸다() {
        let result = SmartPlaylistEvaluator.evaluate(
            Self.list([Self.condition("rating", 3, "3"), Self.condition("rating", 4, "5")]), tracks: Self.artists)
        #expect(result.unsupportedReasons.count == 1)
    }

    @Test func 모르는_항목과_연산자와_단위는_계산하지_않는다() {
        let cases: [SmartPlaylistDefinition.Condition] = [
            Self.condition("newField", 1, "x"),
            Self.condition("name", 99, "x"),
            Self.condition("name", 0, "x"),
            Self.condition("name", 1, "x", unit: "day"),
            Self.condition("year", 1, "2000", unit: "month"),
        ]
        for condition in cases {
            let result = SmartPlaylistEvaluator.evaluate(Self.list([condition]), tracks: Self.artists)
            #expect(result.trackIDs.isEmpty, "\(condition)")
            #expect(result.unsupportedReasons.count == 1, "\(condition)")
        }
    }

    @Test func 항목에_맞지_않는_연산자는_계산하지_않는다() {
        // 글자에 크기 비교·범위·최근, 연도에 포함·시작·끝·최근
        let cases: [SmartPlaylistDefinition.Condition] = [
            Self.condition("name", 3, "x"), Self.condition("name", 4, "x"), Self.condition("name", 5, "a", "b"),
            Self.condition("name", 6, "3"), Self.condition("name", 7, "3"),
            Self.condition("year", 6, "3"), Self.condition("year", 7, "3"),
            Self.condition("year", 8, "20"), Self.condition("year", 9, "20"), Self.condition("year", 10, "20"), Self.condition("year", 11, "20"),
        ]
        for condition in cases {
            let result = SmartPlaylistEvaluator.evaluate(Self.list([condition]), tracks: Self.years)
            #expect(result.trackIDs.isEmpty, "\(condition)")
            #expect(!result.unsupportedReasons.isEmpty, "\(condition)")
        }
    }

    @Test func 값이_비었거나_숫자가_아니거나_범위가_뒤집혔으면_계산하지_않는다() {
        let cases: [SmartPlaylistDefinition.Condition] = [
            Self.condition("name", 1, ""), Self.condition("artist", 8, ""),
            Self.condition("year", 1, ""), Self.condition("year", 1, "20x5"), Self.condition("year", 3, "2015.5"),
            Self.condition("year", 5, "2020", "2015"), Self.condition("year", 5, "2015", ""), Self.condition("year", 5, "", "2015"),
        ]
        for condition in cases {
            let result = SmartPlaylistEvaluator.evaluate(Self.list([condition]), tracks: Self.years)
            #expect(result.trackIDs.isEmpty, "\(condition)")
            #expect(!result.unsupportedReasons.isEmpty, "\(condition)")
        }
    }

    @Test func 글자_조건의_오른쪽_값은_쓰지_않는다() {
        // 같음·포함 등은 ValueRight를 보지 않는다
        #expect(Self.ids(Self.list([Self.condition("artist", 1, "ClariS", "무시")]), Self.artists) == ["1", "2"])
    }

    @Test func 조건이_없는_목록과_읽지_못한_목록은_계산하지_않는다() {
        let empty = SmartPlaylistEvaluator.evaluate(Self.list([]), tracks: Self.artists)
        #expect(empty.trackIDs.isEmpty)
        #expect(!empty.unsupportedReasons.isEmpty)
        let unreadable = SmartPlaylistEvaluator.evaluate(.unreadable("조건 칸을 읽지 못했습니다"), tracks: Self.artists)
        #expect(unreadable == .unsupported(["조건 칸을 읽지 못했습니다"]))
    }

    @Test func 계산한_결과는_이유가_없다() {
        let result = SmartPlaylistEvaluator.evaluate(Self.list([Self.condition("name", 1, "Beta")]), tracks: Self.artists)
        #expect(result == .tracks(["3"]))
        #expect(result.unsupportedReasons.isEmpty)
        #expect(result.trackIDs == ["3"])
    }

    @Test func 기본_해석은_문서화한_값이다() {
        let semantics = SmartPlaylistSemantics.provisional
        #expect(semantics.ignoresCase)
        #expect(!semantics.greaterIncludesEqual)
        #expect(!semantics.lessIncludesEqual)
        #expect(semantics.rangeIncludesEnds)
        #expect(semantics.negationMatchesEmpty)
    }
}
