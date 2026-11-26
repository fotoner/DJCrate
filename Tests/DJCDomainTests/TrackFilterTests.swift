import DJCDomain
import Foundation
import Testing

/// 목록 필터 조건(#351): BPM 범위·키·장르·평점·곡 색 여러 개, 조건끼리 AND. 곡 목록과 CLI `djc search --bpm/--key`가 같은 판정을 쓴다.
@Suite("목록 필터 규칙")
struct TrackFilterTests {
    static func track(key: String? = nil, bpm: Double? = nil, genre: String? = nil, rating: Int = 0, color: String? = nil) -> Track {
        Track(id: "1", uuid: "u1", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: genre, composer: nil,
              releaseYear: nil, trackNumber: nil, key: key, bpm: bpm, lengthSeconds: 0, folderPath: "/music/곡.mp3", comment: "",
              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false, rating: rating, colorID: color)
    }

    static func row(_ track: Track) -> TrackRow { TrackRow(track: track, cues: [], playCount: 0) }

    // MARK: 빈 필터

    @Test func 조건이_없으면_모든_곡이_맞는다() {
        let filter = TrackFilter()
        #expect(filter.isEmpty)
        #expect(filter.matches(Self.track()))
        #expect(filter.matches(Self.row(Self.track(key: "8A", bpm: 128, genre: "House", rating: 3, color: "2"))))
    }

    // MARK: BPM 범위

    @Test func BPM_범위는_양끝을_포함한다() {
        let filter = TrackFilter(bpm: BPMRange(lower: 120, upper: 130))
        #expect(!filter.isEmpty)
        for (bpm, expected) in [(119.99, false), (120.0, true), (125.5, true), (130.0, true), (130.01, false)] {
            #expect(filter.matches(Self.track(bpm: bpm)) == expected, "\(bpm)")
        }
    }

    @Test func BPM_한쪽만_주면_그_쪽은_열려_있다() {
        let atLeast = TrackFilter(bpm: BPMRange(lower: 128, upper: nil)), atMost = TrackFilter(bpm: BPMRange(lower: nil, upper: 100))
        #expect(atLeast.matches(Self.track(bpm: 128)) && atLeast.matches(Self.track(bpm: 174)) && !atLeast.matches(Self.track(bpm: 127.9)))
        #expect(atMost.matches(Self.track(bpm: 100)) && atMost.matches(Self.track(bpm: 70)) && !atMost.matches(Self.track(bpm: 100.1)))
    }

    @Test func BPM를_모르는_곡은_BPM_조건에_맞지_않는다() {
        #expect(!TrackFilter(bpm: BPMRange(lower: 0.1, upper: 999)).matches(Self.track(bpm: nil)))
        // 양쪽 다 비운 범위는 조건이 아니다
        #expect(TrackFilter(bpm: BPMRange(lower: nil, upper: nil)).isEmpty)
        #expect(TrackFilter(bpm: BPMRange(lower: nil, upper: nil)).matches(Self.track(bpm: nil)))
    }

    @Test func 거꾸로_준_범위는_아무_곡도_맞지_않는다() {
        // 순서를 몰래 바꾸지 않는다: 사용자가 최소 칸에 130을 치는 도중에도 값 그대로 판정한다
        #expect(!TrackFilter(bpm: BPMRange(lower: 130, upper: 120)).matches(Self.track(bpm: 125)))
    }

    @Test func BPM_글자는_소수_한_자리까지_군더더기_없이_쓴다() {
        #expect(BPMRange.format(128) == "128" && BPMRange.format(127.5) == "127.5" && BPMRange.format(127.25) == "127.25")
    }

    // MARK: 키

    @Test func 같은_키는_표기가_달라도_Camelot으로_바꿔_맞춘다() {
        let filter = TrackFilter(key: KeyCondition("8A"))
        // A단조 = Camelot 8A. 음이름·Camelot·Open Key(1m)가 모두 같은 키다
        for stored in ["8A", "8a", " 08A ", "Am", "A minor", "1m"] {
            #expect(filter.matches(Self.track(key: stored)), "\(stored)")
        }
        for stored in ["8B", "9A", "7A", "C", "Em"] { #expect(!filter.matches(Self.track(key: stored)), "\(stored)") }
    }

    @Test func 조건을_음이름으로_줘도_같은_키로_맞춘다() {
        let filter = TrackFilter(key: KeyCondition("Am"))
        #expect(filter.matches(Self.track(key: "8A")) && filter.matches(Self.track(key: "Am")) && !filter.matches(Self.track(key: "8B")))
    }

    @Test func 키가_없는_곡은_키_조건에_맞지_않는다() {
        #expect(!TrackFilter(key: KeyCondition("8A")).matches(Self.track(key: nil)))
        #expect(!TrackFilter(key: KeyCondition("8A", mode: .compatible)).matches(Self.track(key: "")))
    }

    @Test func 어울리는_키는_같은_번호의_A_B와_번호_앞뒤_같은_글자다() {
        let filter = TrackFilter(key: KeyCondition("8A", mode: .compatible))
        for stored in ["8A", "8B", "7A", "9A"] { #expect(filter.matches(Self.track(key: stored)), "\(stored)") }
        for stored in ["7B", "9B", "6A", "10A", "1A", "12A"] { #expect(!filter.matches(Self.track(key: stored)), "\(stored)") }
        // 저장 표기가 달라도 같다: Em = 9A, Dm = 7A, C = 8B
        for stored in ["Em", "Dm", "C", "Am"] { #expect(filter.matches(Self.track(key: stored)), "\(stored)") }
    }

    @Test func 어울리는_키는_12와_1을_이어_준다() {
        let twelve = TrackFilter(key: KeyCondition("12B", mode: .compatible)), one = TrackFilter(key: KeyCondition("1A", mode: .compatible))
        #expect(twelve.matches(Self.track(key: "1B")) && twelve.matches(Self.track(key: "11B")) && twelve.matches(Self.track(key: "12A")))
        #expect(!twelve.matches(Self.track(key: "1A")) && !twelve.matches(Self.track(key: "2B")))
        #expect(one.matches(Self.track(key: "12A")) && one.matches(Self.track(key: "2A")) && one.matches(Self.track(key: "1B")))
        #expect(!one.matches(Self.track(key: "12B")))
    }

    @Test func 바꿀_수_없는_값은_글자가_같을_때만_맞는다() {
        // 조건이 Camelot이 아닌 값: 어울리는 키를 골라도 같은 키(글자 일치)로만 맞는다
        let odd = TrackFilter(key: KeyCondition("Atonal", mode: .compatible))
        #expect(odd.matches(Self.track(key: "atonal")) && odd.matches(Self.track(key: " ATONAL ")))
        #expect(!odd.matches(Self.track(key: "8A")) && !odd.matches(Self.track(key: nil)))
        // 곡의 값이 Camelot으로 안 바뀌면 Camelot 조건에 맞지 않는다
        #expect(!TrackFilter(key: KeyCondition("8A", mode: .compatible)).matches(Self.track(key: "Atonal")))
        #expect(!TrackFilter(key: KeyCondition("8A")).matches(Self.track(key: "???")))
    }

    @Test func 키_조건은_Camelot_이름과_고른_방식을_들고_있다() {
        #expect(KeyCondition("08a").camelot == "8A" && KeyCondition("Am").camelot == "8A" && KeyCondition("Atonal").camelot == nil)
        #expect(KeyCondition("8A").mode == .same && KeyCondition("8A", mode: .compatible).mode == .compatible)
    }

    // MARK: 장르

    @Test func 장르는_대소문자와_NFC를_무시한_정확_일치다() {
        let filter = TrackFilter(genre: "Deep House")
        #expect(filter.matches(Self.track(genre: "deep house")) && filter.matches(Self.track(genre: "DEEP HOUSE")))
        // 부분 일치는 아니다
        #expect(!filter.matches(Self.track(genre: "House")) && !filter.matches(Self.track(genre: "Deep House 2")))
        #expect(!filter.matches(Self.track(genre: nil)) && !filter.matches(Self.track(genre: "")))
        // 값 앞뒤의 공백은 다른 장르로 치지 않는다(고르기 목록에 같은 이름이 둘 보이지 않게)
        #expect(filter.matches(Self.track(genre: " Deep House ")) && TrackFilter(genre: " deep house ").matches(Self.track(genre: "Deep House")))
        let nfd = "가요".decomposedStringWithCanonicalMapping
        #expect(TrackFilter(genre: "가요").matches(Self.track(genre: nfd)) && TrackFilter(genre: nfd).matches(Self.track(genre: "가요")))
    }

    @Test func 빈_장르_글자는_조건이_아니다() {
        #expect(TrackFilter(genre: "").isEmpty && TrackFilter(genre: "  ").isEmpty && TrackFilter(genre: nil).isEmpty)
        #expect(!TrackFilter(genre: "House").isEmpty)
    }

    // MARK: 곡 색 여러 개

    @Test func 곡_색은_고른_색_가운데_하나이면_맞는다() {
        let filter = TrackFilter(colorIDs: ["2", "7"])
        #expect(filter.matches(Self.track(color: "2")) && filter.matches(Self.track(color: "7")))
        #expect(!filter.matches(Self.track(color: "3")) && !filter.matches(Self.track(color: nil)))
        #expect(!filter.isEmpty && TrackFilter(colorIDs: []).isEmpty)
    }

    // MARK: 평점, AND

    @Test func 평점은_N개_이상이다() {
        #expect(TrackFilter(minimumRating: 3).matches(Self.track(rating: 3)) && !TrackFilter(minimumRating: 3).matches(Self.track(rating: 2)))
    }

    @Test func 조건끼리는_모두_맞아야_한다() {
        let filter = TrackFilter(minimumRating: 3, colorIDs: ["2"], bpm: BPMRange(lower: 120, upper: 130),
                                 key: KeyCondition("8A", mode: .compatible), genre: "House")
        let all = Self.track(key: "9A", bpm: 126, genre: "house", rating: 4, color: "2")
        #expect(filter.matches(all) && filter.matches(Self.row(all)))
        // 조건 하나씩만 어긋나도 빠진다
        for odd in [Self.track(key: "9A", bpm: 126, genre: "house", rating: 2, color: "2"),
                    Self.track(key: "9A", bpm: 126, genre: "house", rating: 4, color: "3"),
                    Self.track(key: "9A", bpm: 140, genre: "house", rating: 4, color: "2"),
                    Self.track(key: "3B", bpm: 126, genre: "house", rating: 4, color: "2"),
                    Self.track(key: "9A", bpm: 126, genre: "techno", rating: 4, color: "2")] {
            #expect(!filter.matches(odd) && !filter.matches(Self.row(odd)))
        }
    }

    @Test func 곡_값과_곡_줄은_같은_판정이다() {
        let tracks = [Self.track(key: "Am", bpm: 128, genre: "House"), Self.track(key: "8B", bpm: 90, genre: "한국 가요".decomposedStringWithCanonicalMapping),
                      Self.track(), Self.track(key: "Atonal", bpm: 128, genre: "house", rating: 5, color: "1")]
        let filters = [TrackFilter(), TrackFilter(bpm: BPMRange(lower: 100, upper: nil)), TrackFilter(key: KeyCondition("8A", mode: .compatible)),
                       TrackFilter(genre: "한국 가요"), TrackFilter(colorIDs: ["1"], genre: "House"), TrackFilter(key: KeyCondition("Atonal"))]
        for filter in filters {
            for track in tracks { #expect(filter.matches(track) == filter.matches(Self.row(track))) }
        }
    }

    // MARK: 곡 줄에 미리 바꿔 두는 값

    @Test func 곡_줄은_Camelot_키와_장르_키를_만들_때_한_번_바꿔_둔다() {
        let row = Self.row(Self.track(key: "Am", genre: "Deep House"))
        #expect(row.camelotKey == "8A")
        #expect(row.genreKey == "deep house")
        #expect(Self.row(Self.track(key: nil, genre: nil)).camelotKey == nil && Self.row(Self.track(genre: nil)).genreKey == "")
        let nfd = Self.row(Self.track(genre: "가요".decomposedStringWithCanonicalMapping)).genreKey
        #expect(Array(nfd.unicodeScalars) == Array("가요".precomposedStringWithCanonicalMapping.unicodeScalars))
    }

    // MARK: 장르 고르기 목록

    @Test func 장르_목록은_표기가_달라도_하나로_합치고_가장_많이_쓴_표기를_이름순으로_보인다() {
        let nfd = "가요".decomposedStringWithCanonicalMapping
        let rows = [Self.row(Self.track(genre: "House")), Self.row(Self.track(genre: "house")), Self.row(Self.track(genre: "House ")),
                    Self.row(Self.track(genre: "Techno")), Self.row(Self.track(genre: nfd)), Self.row(Self.track(genre: "가요")),
                    Self.row(Self.track(genre: "")), Self.row(Self.track(genre: nil)), Self.row(Self.track(genre: "  "))]
        // House는 "House" 둘(앞뒤 공백을 뗀 것 포함)과 "house" 하나라 "House"를 보인다. 한글은 NFC·NFD가 한 이름이다.
        // 이름순은 시스템의 표준 정렬(`localizedStandardCompare`)을 따르고 한글이 영문 앞이다
        let choices = TrackFilter.genreChoices(in: rows)
        #expect(choices.count == 3 && choices.map { $0.precomposedStringWithCanonicalMapping } == ["가요", "House", "Techno"])
        #expect(TrackFilter.genreChoices(in: []).isEmpty)
    }
}
