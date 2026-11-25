import DJCDomain
import Foundation
import Testing

/// 곡 검색 규칙(#350): 검색 키의 칸·정규화와 검색어의 낱말 AND. 곡 목록·중복 후보·CLI가 같은 규칙을 쓴다.
@Suite("곡 검색 규칙")
struct TrackSearchTests {
    static func track(title: String = "곡", artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                      genre: String? = nil, composer: String? = nil, comment: String = "", path: String = "/music/곡.mp3") -> Track {
        Track(id: "1", uuid: "u1", title: title, artist: artist, album: album, albumArtist: albumArtist, genre: genre,
              composer: composer, releaseYear: nil, trackNumber: nil, key: nil, bpm: nil, lengthSeconds: 0,
              folderPath: path, comment: comment, importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    static func found(_ query: String, in track: Track) -> Bool {
        TrackSearch.Query(query).matches(key: TrackSearch.key(for: track))
    }

    @Test func 검색_키는_여덟_칸을_담는다() {
        let track = Self.track(title: "Title", artist: "Artist", album: "Album", albumArtist: "AlbumArtist", genre: "Genre",
                               composer: "Composer", comment: "Comment", path: "/music/folder/File Name.flac")
        for word in ["title", "artist", "album", "albumartist", "genre", "composer", "comment", "file name.flac"] {
            #expect(Self.found(word, in: track), "\(word)")
        }
        // 폴더 이름은 찾지 않는다
        #expect(!Self.found("folder", in: track) && !Self.found("music", in: track))
    }

    @Test func 키는_NFC_소문자이고_칸_사이를_넘는_낱말은_맞지_않는다() {
        let nfd = "한글 제목".decomposedStringWithCanonicalMapping
        let track = Self.track(title: "ALPHA\(nfd)", artist: "beta")
        let key = TrackSearch.key(for: track)
        #expect(Array(key.unicodeScalars) == Array(key.precomposedStringWithCanonicalMapping.unicodeScalars))
        #expect(key == key.lowercased())
        // 제목 끝과 아티스트 앞이 이어져 보여도 한 낱말로는 맞지 않는다
        #expect(!Self.found("제목beta", in: track))
    }

    @Test func NFD_한글_파일_이름을_NFC_검색어로_찾고_반대도_된다() {
        let name = "밤의 드라이브.mp3"
        let nfdTrack = Self.track(path: "/음악/\(name.decomposedStringWithCanonicalMapping)")
        let nfcTrack = Self.track(path: "/음악/\(name)")
        for track in [nfdTrack, nfcTrack] {
            #expect(Self.found("드라이브", in: track))
            #expect(Self.found(name, in: track))
            #expect(Self.found("드라이브".decomposedStringWithCanonicalMapping, in: track))
            #expect(Self.found(name.decomposedStringWithCanonicalMapping, in: track))
        }
        // 제목·아티스트·앨범도 NFD로 저장돼 있을 수 있다
        let tagged = Self.track(title: "새벽".decomposedStringWithCanonicalMapping, artist: "가수".decomposedStringWithCanonicalMapping)
        #expect(Self.found("새벽 가수", in: tagged))
    }

    @Test func 검색어의_낱말도_NFC_소문자_글자로_바꾼다() {
        // Swift의 문자열 비교는 NFC와 NFD를 같게 보므로 변환했는지는 글자 조각(스칼라)으로 본다
        let terms = TrackSearch.Query("한글".decomposedStringWithCanonicalMapping + " ABC").terms
        #expect(terms.count == 2)
        #expect(Array(terms[0].unicodeScalars) == Array("한글".unicodeScalars) && Array(terms[1].unicodeScalars) == Array("abc".unicodeScalars))
    }

    @Test func 칸_구분_글자는_검색어에서도_낱말_경계라_낱말이_칸을_넘어_맞지_않는다() {
        // 키는 칸 사이를 U+001F로 가른다. 검색어에 그 글자가 들어와도 낱말 안에 남지 않는다(CLI 인자로는 넣을 수 있다)
        #expect(TrackSearch.Query("제목\u{1F}beta").terms == ["제목", "beta"])
        #expect(!Self.found("alpha\u{1F}", in: Self.track(title: "x")))
        let track = Self.track(title: "alpha", artist: "beta")
        #expect(!Self.found("alphabeta", in: track))
        #expect(TrackSearch.Query("alpha\u{1F}beta").terms.allSatisfy { !$0.contains("\u{1F}") })
    }

    @Test func 띄어_쓴_낱말은_모두_맞아야_하고_순서와_칸은_상관없다() {
        let track = Self.track(title: "Alpha", artist: "Kim", album: "Blue Hour", composer: "Satie")
        #expect(Self.found("alpha kim", in: track) && Self.found("kim alpha", in: track))
        #expect(Self.found("alp ki blu sat", in: track))
        #expect(!Self.found("alpha lee", in: track))
        // 한 낱말은 한 칸 안에서 이어져야 한다: 낱말을 다시 붙이면 맞지 않는다
        #expect(Self.found("blue hour", in: track) && !Self.found("bluehour", in: track))
    }

    @Test func 공백은_종류와_개수와_상관없이_낱말_경계다() {
        let track = Self.track(title: "Alpha", artist: "Kim")
        for query in ["  alpha   kim ", "alpha\tkim", "alpha\nkim", "alpha\u{3000}kim", "alpha\u{00A0}kim"] {
            #expect(Self.found(query, in: track), "\(query.unicodeScalars.map(\.value))")
        }
        let blank = TrackSearch.Query(" \t\u{3000} ")
        #expect(blank.isEmpty && blank.terms.isEmpty)
        #expect(TrackSearch.Query("").isEmpty)
        #expect(blank.matches(Self.track()) && TrackSearch.Query("").matches(key: ""))
        #expect(TrackSearch.Query("Alpha  KIM").terms == ["alpha", "kim"])
    }

    @Test func 암호화된_Spotify_곡은_제목_아티스트_앨범_앨범_아티스트와_파일_이름을_찾지_않는다() {
        let track = Self.track(title: "$A7:v1:암호", artist: "$A7:v1:가수", album: "숨은앨범", albumArtist: "숨은앨범아티스트",
                               composer: "작곡가", comment: "남는 코멘트", path: "spotify:track:abc123")
        #expect(!Self.found("암호", in: track) && !Self.found("가수", in: track))
        #expect(!Self.found("숨은앨범", in: track) && !Self.found("숨은앨범아티스트", in: track))
        #expect(!Self.found("abc123", in: track) && !Self.found("spotify", in: track))
        // 암호화되지 않은 칸은 그대로 찾는다
        #expect(Self.found("작곡가 코멘트", in: track))
    }

    @Test func 스트리밍_곡은_파일_이름이_없고_로컬_곡만_파일_이름을_갖는다() {
        #expect(!Self.found("track", in: Self.track(path: "apple-music:track:42")))
        #expect(Self.found("곡.mp3", in: Self.track()))
        // 폴더 구분자로 끝나는 경로는 파일 이름이 빈 글자다
        #expect(!Self.found("music", in: Self.track(path: "/music/")))
    }

    @Test func TrackRow의_검색_키는_같은_규칙_하나로_만든다() {
        let track = Self.track(title: "T", artist: "A", album: "Blue Hour", path: "/x/밤.mp3".decomposedStringWithCanonicalMapping)
        let row = TrackRow(track: track, cues: [], playCount: 0)
        #expect(row.searchKey == TrackSearch.key(for: track))
        #expect(TrackSearch.Query("blue 밤").matches(key: row.searchKey))
    }

    // MARK: 저장 대기 중인 태그 편집(#376)

    static func draft(of track: Track, _ edit: (inout TagFields) -> Void) -> TagDraft {
        var draft = TagDraft(track: track)
        edit(&draft.fields)
        return draft
    }

    static func found(_ query: String, in track: Track, edits: TrackSearch.DraftEdits) -> Bool {
        TrackSearch.Query(query).matches(row: TrackRow(track: track, cues: [], playCount: 0), edits: edits)
    }

    @Test func 초안이_고친_검색_칸만_편집_값으로_바뀌고_나머지는_곡의_값이다() {
        let track = Self.track(title: "Old", artist: "Kim", album: "Blue", albumArtist: "Lee", genre: "House",
                               composer: "Satie", comment: "memo", path: "/music/file.mp3")
        let draft = Self.draft(of: track) { $0.title = "New"; $0.comment = "" }
        let edits = TrackSearch.edits(of: draft)
        #expect(edits == [.title: "New", .comment: ""])
        let key = TrackSearch.key(for: track, edits: edits)
        // 고친 칸은 편집 값, 비운 칸은 빈 값, 고치지 않은 칸·파일 이름은 곡의 값이다
        #expect(TrackSearch.Query("new kim blue lee house satie file.mp3").matches(key: key))
        #expect(!TrackSearch.Query("old").matches(key: key) && !TrackSearch.Query("memo").matches(key: key))
        #expect(TrackSearch.key(for: track, edits: [:]) == TrackSearch.key(for: track))
    }

    @Test func 검색이_보지_않는_칸만_고친_초안은_편집_값이_없다() {
        let track = Self.track(title: "Old")
        let draft = Self.draft(of: track) { $0.year = "1999"; $0.rating = "3"; $0.trackNumber = "7"; $0.musicalKey = "8A"; $0.color = "2" }
        #expect(TrackSearch.edits(of: draft).isEmpty)
        #expect(TrackSearch.edits(of: ["u1": draft]).isEmpty, "고친 검색 칸이 없는 초안은 사전에 넣지 않는다")
        // 고친 곡만 든다
        let titled = Self.draft(of: track) { $0.title = "New" }
        #expect(TrackSearch.edits(of: ["u1": titled, "u2": draft]) == ["u1": [.title: "New"]])
    }

    @Test func 원래_값으로_되돌린_칸은_고친_것으로_보지_않는다() {
        let track = Self.track(title: "Old", comment: "memo")
        var draft = Self.draft(of: track) { $0.title = "New" }
        draft.fields.title = "Old"
        #expect(TrackSearch.edits(of: draft).isEmpty)
    }

    @Test func 저장된_값_전체나_편집_값_전체로_맞고_둘의_낱말은_섞지_않는다() {
        let track = Self.track(title: "Alpha", artist: "Kim", comment: "OP 1")
        let edits: TrackSearch.DraftEdits = [.title: "Omega", .comment: "정리"]
        #expect(Self.found("omega 정리 kim", in: track, edits: edits), "화면에 보이는 값")
        #expect(Self.found("alpha op kim", in: track, edits: edits), "저장된 값: 편집으로 곡이 목록에서 빠지지 않는다")
        #expect(!Self.found("alpha omega", in: track, edits: edits), "저장된 값과 편집 값의 낱말을 섞지 않는다")
        #expect(!Self.found("omega op", in: track, edits: edits))
        #expect(!Self.found("omega", in: track, edits: [:]) && Self.found("alpha", in: track, edits: [:]))
        #expect(Self.found("  ", in: track, edits: edits), "낱말이 없으면 모두 맞는다")
    }

    @Test func 암호화된_Spotify_곡의_가려진_칸은_편집_값도_찾지_않는다() {
        let track = Self.track(title: "$A7:v1:암호", artist: "$A7:v1:가수", comment: "남는 코멘트", path: "spotify:track:abc")
        let edits: TrackSearch.DraftEdits = [.title: "새제목", .artist: "새가수", .comment: "새코멘트"]
        #expect(!Self.found("새제목", in: track, edits: edits) && !Self.found("새가수", in: track, edits: edits))
        #expect(Self.found("새코멘트", in: track, edits: edits))
    }

    @Test func 편집_값도_NFC_소문자로_맞춰_찾는다() {
        let track = Self.track(title: "곡")
        let edits: TrackSearch.DraftEdits = [.title: "NEW 한글 제목".decomposedStringWithCanonicalMapping]
        #expect(Self.found("new 한글", in: track, edits: edits))
        #expect(Self.found("한글 제목".decomposedStringWithCanonicalMapping, in: track, edits: edits))
    }
}
