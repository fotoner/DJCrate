import Foundation
import Testing
@testable import DJCDomain

/// rekordbox XML 가져오기(#72)의 곡 맞추기·차이 계산. 합성 문서만 쓴다.
@Suite("rekordbox XML 가져오기 차이")
struct XMLLibraryDiffTests {
    typealias Doc = XMLLibrary
    typealias Mark = XMLLibrary.Mark

    func track(_ key: String, _ path: String?, title: String = "곡", tags: [TagFields.Key: String] = [:],
               marks: [Mark] = [], tempos: [GridSegment] = []) -> Doc.Track {
        var all = tags
        if all[.title] == nil { all[.title] = title }
        return Doc.Track(key: key, path: path, tags: all, marks: marks, tempos: tempos)
    }

    // MARK: 위치 → 경로

    @Test func 위치는_퍼센트_인코딩을_풀어_경로로() {
        #expect(XMLTrackMatching.path(fromLocation: "file://localhost/Music/%EA%B3%A1%20%26%20%EC%9D%B4%EB%A6%84.mp3") == "/Music/곡 & 이름.mp3")
        #expect(XMLTrackMatching.path(fromLocation: "file:///Music/a%23b.mp3") == "/Music/a#b.mp3")
        // 인코딩하지 않은 글자도 그대로 받는다
        #expect(XMLTrackMatching.path(fromLocation: "file://localhost/Music/a b.mp3") == "/Music/a b.mp3")
        // 파일이 아닌 위치(스트리밍 등)는 nil
        #expect(XMLTrackMatching.path(fromLocation: "apple-music:track:1") == nil)
        #expect(XMLTrackMatching.path(fromLocation: "") == nil)
        // 다른 기계 이름이 적힌 위치는 이 Mac의 경로가 아니다
        #expect(XMLTrackMatching.path(fromLocation: "file://server/Music/a.mp3") == nil)
    }

    // MARK: 곡 맞추기

    @Test func 경로는_NFC로_맞춘다() {
        let nfd = "/Music/한글.mp3".decomposedStringWithCanonicalMapping
        let result = XMLTrackMatching.match(xml: [track("1", nfd)], library: [track("101", "/Music/한글.mp3")])
        #expect(result.matched == ["1": "101"])
        #expect(result.unmatched.isEmpty && result.ambiguous.isEmpty)
    }

    @Test func 대소문자만_다르면_하나뿐일_때만_맞춘다() {
        let single = XMLTrackMatching.match(xml: [track("1", "/music/A.mp3")], library: [track("101", "/Music/a.mp3")])
        #expect(single.matched == ["1": "101"])
        let two = XMLTrackMatching.match(xml: [track("1", "/music/A.mp3")],
                                         library: [track("101", "/Music/a.mp3"), track("102", "/MUSIC/a.mp3")])
        #expect(two.matched.isEmpty && two.ambiguous == ["1"])
    }

    @Test func 못_맞춘_곡과_여러_곡에_맞는_곡은_따로_센다() {
        let library = [track("101", "/a.mp3"), track("102", "/b.mp3"), track("103", "/b.mp3")]
        let xml = [track("1", "/a.mp3"), track("2", "/b.mp3"), track("3", "/c.mp3"), track("4", nil),
                   // XML 안에서 같은 곡을 두 번 적으면 어느 쪽을 따를지 모른다
                   track("5", "/d.mp3"), track("6", "/d.mp3")]
        let result = XMLTrackMatching.match(xml: xml, library: library + [track("104", "/d.mp3")])
        #expect(result.matched == ["1": "101"])
        #expect(result.unmatched == ["3", "4"])
        #expect(result.ambiguous == ["2", "5", "6"])
    }

    // MARK: 큐

    @Test func 큐는_종류_위치_이름으로_비교한다() {
        let library = [track("101", "/a.mp3", marks: [Mark(kind: .memory, start: 1, name: ""), Mark(kind: .hot(0), start: 20, name: "A")])]
        // 표기 오차(1ms 미만)는 같은 큐
        let same = [track("1", "/a.mp3", marks: [Mark(kind: .hot(0), start: 20.0004, name: "A"), Mark(kind: .memory, start: 1, name: "")])]
        #expect(XMLLibraryDiff.compute(xml: Doc(tracks: same), library: Doc(tracks: library)).tracks.isEmpty)

        let moved = [track("1", "/a.mp3", marks: [Mark(kind: .memory, start: 1, name: ""), Mark(kind: .hot(0), start: 21, name: "A"),
                                                  Mark(kind: .memory, start: 40, end: 44, name: "루프")])]
        let result = XMLLibraryDiff.compute(xml: Doc(tracks: moved), library: Doc(tracks: library))
        let cues = try! #require(result.tracks.first?.cues)
        // 같은 핫큐 슬롯은 옮긴 것으로 짝짓는다(빼고 더하지 않는다)
        #expect(cues.added == [Mark(kind: .memory, start: 40, end: 44, name: "루프")])
        #expect(cues.removed.isEmpty)
        #expect(cues.modified == [.init(library: Mark(kind: .hot(0), start: 20, name: "A"), xml: Mark(kind: .hot(0), start: 21, name: "A"))])
        #expect(result.counts.cueTracks == 1)
        #expect(result.tracks.first?.libraryKey == "101" && result.tracks.first?.xmlKey == "1")
    }

    @Test func 큐가_없는_XML_곡은_큐를_비교하지_않는다() {
        // POSITION_MARK가 하나도 없는 XML(큐를 내보내지 않는 도구)이 라이브러리 큐를 모두 지우게 하지 않는다
        let library = [track("101", "/a.mp3", marks: [Mark(kind: .hot(1), start: 5, name: "")])]
        let result = XMLLibraryDiff.compute(xml: Doc(tracks: [track("1", "/a.mp3")]), library: Doc(tracks: library))
        #expect(result.tracks.isEmpty)
        #expect(result.counts.xmlWithoutCues == 1 && result.counts.cueTracks == 0)
    }

    @Test func 읽지_못한_위치_표시가_있는_곡은_큐를_비교하지_않는다() {
        let library = [track("101", "/a.mp3", marks: [Mark(kind: .hot(1), start: 5, name: ""), Mark(kind: .hot(2), start: 9, name: "")])]
        var xml = track("1", "/a.mp3", marks: [Mark(kind: .hot(1), start: 5, name: "")])
        xml.unreadableMarks = 1
        let result = XMLLibraryDiff.compute(xml: Doc(tracks: [xml]), library: Doc(tracks: library))
        #expect(result.tracks.isEmpty)
        #expect(result.counts.xmlUnreadableCues == 1)
    }

    @Test func XML에_없는_rekordbox_자동_큐는_빼지_않는다() {
        let library = [track("101", "/a.mp3", marks: [Mark(kind: .memory, start: 0.5, name: "CUE(Auto)"), Mark(kind: .hot(0), start: 5, name: "")])]
        let same = XMLLibraryDiff.compute(xml: Doc(tracks: [track("1", "/a.mp3", marks: [Mark(kind: .hot(0), start: 5, name: "")])]),
                                          library: Doc(tracks: library))
        #expect(same.tracks.isEmpty)
        let added = XMLLibraryDiff.compute(xml: Doc(tracks: [track("1", "/a.mp3", marks: [Mark(kind: .hot(0), start: 5, name: ""),
                                                                                          Mark(kind: .hot(1), start: 9, name: "")])]),
                                           library: Doc(tracks: library))
        #expect(added.tracks.first?.cues?.removed == [])
        #expect(added.tracks.first?.cues?.added.count == 1)
    }

    @Test func 빼기만_있는_곡은_기본_선택에서_뺀다() {
        let library = [track("101", "/a.mp3", marks: [Mark(kind: .hot(0), start: 5, name: ""), Mark(kind: .hot(1), start: 9, name: "")]),
                       track("102", "/b.mp3", marks: [Mark(kind: .hot(0), start: 5, name: "")])]
        let xml = [track("1", "/a.mp3", marks: [Mark(kind: .hot(0), start: 5, name: "")]),
                   track("2", "/b.mp3", marks: [Mark(kind: .hot(0), start: 6, name: "")])]
        let result = XMLLibraryDiff.compute(xml: Doc(tracks: xml), library: Doc(tracks: library))
        #expect(result.tracks.first { $0.libraryKey == "101" }?.cues?.isRemovalOnly == true)
        #expect(XMLImportDrafts.defaultChoice(result)[.cue] == ["102"])
    }

    @Test func 루프_끝과_이름이_다르면_차이다() {
        let library = [track("101", "/a.mp3", marks: [Mark(kind: .memory, start: 4, end: 8, name: "x")])]
        for other in [Mark(kind: .memory, start: 4, end: 9, name: "x"), Mark(kind: .memory, start: 4, end: 8, name: "y"),
                      Mark(kind: .memory, start: 4, name: "x")] {
            let result = XMLLibraryDiff.compute(xml: Doc(tracks: [track("1", "/a.mp3", marks: [other])]), library: Doc(tracks: library))
            #expect(result.tracks.first?.cues != nil, "\(other)")
        }
    }

    // MARK: 그리드

    @Test func 그리드는_첫_박을_앞으로_당겨_맞춘_뒤_비교한다() {
        let library = [track("101", "/a.mp3", tempos: [GridSegment(start: 0.025, bpm: 120, firstBeatNumber: 1)])]
        // 다른 도구가 같은 그리드를 2박 뒤부터 적어도 같다(0.025 + 1.0 = 3박째)
        let shifted = [track("1", "/a.mp3", tempos: [GridSegment(start: 1.025, bpm: 120, firstBeatNumber: 3)])]
        #expect(XMLLibraryDiff.compute(xml: Doc(tracks: shifted), library: Doc(tracks: library)).tracks.isEmpty)

        let other = [track("1", "/a.mp3", tempos: [GridSegment(start: 0.030, bpm: 120, firstBeatNumber: 1)])]
        let result = XMLLibraryDiff.compute(xml: Doc(tracks: other), library: Doc(tracks: library))
        #expect(result.tracks.first?.grid?.xml == [GridSegment(start: 0.030, bpm: 120, firstBeatNumber: 1)])
        #expect(result.counts.gridTracks == 1)

        let bpm = [track("1", "/a.mp3", tempos: [GridSegment(start: 0.025, bpm: 120.5, firstBeatNumber: 1)])]
        #expect(XMLLibraryDiff.compute(xml: Doc(tracks: bpm), library: Doc(tracks: library)).tracks.first?.grid != nil)
        let beat = [track("1", "/a.mp3", tempos: [GridSegment(start: 0.025, bpm: 120, firstBeatNumber: 2)])]
        #expect(XMLLibraryDiff.compute(xml: Doc(tracks: beat), library: Doc(tracks: library)).tracks.first?.grid != nil)
    }

    @Test func 구간_나누는_방식만_다른_그리드는_같다() {
        // 120BPM 한 구간과, 같은 박을 97번째 박(48.5초, 1박)에서 나눠 적은 두 구간은 박이 같다
        var libraryTrack = track("101", "/a.mp3", tempos: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        libraryTrack.duration = 120
        let split = [track("1", "/a.mp3", tempos: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1),
                                                   GridSegment(start: 48.5, bpm: 120, firstBeatNumber: 1)])]
        #expect(XMLLibraryDiff.compute(xml: Doc(tracks: split), library: Doc(tracks: [libraryTrack])).tracks.isEmpty)
        // 나눈 자리에서 박 번호가 어긋나면 차이다
        let shifted = [track("1", "/a.mp3", tempos: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1),
                                                     GridSegment(start: 48.5, bpm: 120, firstBeatNumber: 2)])]
        #expect(XMLLibraryDiff.compute(xml: Doc(tracks: shifted), library: Doc(tracks: [libraryTrack])).tracks.first?.grid != nil)
    }

    @Test func XML에_그리드가_없으면_비교하지_않는다() {
        let library = [track("101", "/a.mp3", tempos: [GridSegment(start: 0.025, bpm: 120, firstBeatNumber: 1)])]
        let result = XMLLibraryDiff.compute(xml: Doc(tracks: [track("1", "/a.mp3")]), library: Doc(tracks: library))
        #expect(result.tracks.isEmpty)
        #expect(result.counts.xmlWithoutGrid == 1)
    }

    @Test func 라이브러리_그리드를_읽지_않았으면_그리드를_비교하지_않는다() {
        var library = Doc(tracks: [track("101", "/a.mp3")])
        library.hasGrids = false
        let xml = Doc(tracks: [track("1", "/a.mp3", tempos: [GridSegment(start: 0.025, bpm: 120, firstBeatNumber: 1)])])
        #expect(XMLLibraryDiff.compute(xml: xml, library: library).tracks.isEmpty)
        // 읽었는데 없으면 차이(분석 파일이 없는 곡)
        let analysed = XMLLibraryDiff.compute(xml: xml, library: Doc(tracks: [track("101", "/a.mp3")]))
        #expect(analysed.tracks.first?.grid?.library == [])
    }

    // MARK: 태그

    @Test func 태그는_XML에_있는_칸만_비교한다() {
        let library = [track("101", "/a.mp3", title: "제목", tags: [.artist: "A", .genre: "Anime", .year: "", .musicalKey: "8A",
                                                                    .comment: "c", .rating: "3"])]
        // 칸이 없으면(앨범·평점) 비교하지 않고, 0 연도는 빈칸, 키는 표기가 달라도 같은 키면 같다
        let same = [track("1", "/a.mp3", title: "제목", tags: [.artist: "A", .genre: "Anime", .year: "0", .musicalKey: "Am", .comment: "c"])]
        #expect(XMLLibraryDiff.compute(xml: Doc(tracks: same), library: Doc(tracks: library)).tracks.isEmpty)

        let changed = [track("1", "/a.mp3", title: "새 제목", tags: [.artist: "B", .rating: "5", .musicalKey: "9A"])]
        let result = XMLLibraryDiff.compute(xml: Doc(tracks: changed), library: Doc(tracks: library))
        let tags = result.tracks.first?.tags ?? []
        #expect(tags == [.init(key: .title, library: "제목", xml: "새 제목"), .init(key: .artist, library: "A", xml: "B"),
                         .init(key: .musicalKey, library: "8A", xml: "9A"), .init(key: .rating, library: "3", xml: "5")])
        #expect(result.counts.tagTracks == 1)
    }

    @Test func 태그_글자는_NFC로_비교한다() {
        let library = [track("101", "/a.mp3", title: "Café 한글")]
        let xml = [track("1", "/a.mp3", title: "Café 한글".decomposedStringWithCanonicalMapping)]
        #expect(XMLLibraryDiff.compute(xml: Doc(tracks: xml), library: Doc(tracks: library)).tracks.isEmpty)
    }

    // MARK: 재생 목록

    func node(_ name: String, id: String? = nil, _ entries: [String]) -> Doc.Node { Doc.Node(name: name, id: id, entries: entries) }
    func folder(_ name: String, id: String? = nil, _ children: [Doc.Node]) -> Doc.Node { Doc.Node(name: name, id: id, children: children) }

    @Test func 없는_목록과_곡이_다른_목록() {
        let tracks = [track("101", "/a.mp3"), track("102", "/b.mp3"), track("103", "/c.mp3")]
        let library = Doc(tracks: tracks, lists: [folder("셋", id: "f1", [node("A", id: "p1", ["101", "102"]), node("같음", id: "p2", ["103"])]),
                                                  node("라이브러리만", id: "p3", ["101"])])
        let xml = Doc(tracks: [track("1", "/a.mp3"), track("2", "/b.mp3"), track("3", "/c.mp3"), track("9", "/없음.mp3")],
                      lists: [folder("셋", [node("A", ["2", "1", "9"]), node("같음", ["3"]), folder("새 폴더", [node("B", ["1"])])]),
                              node("새 목록", ["3", "9"])])
        let result = XMLLibraryDiff.compute(xml: xml, library: library)
        #expect(result.playlists.map(\.path) == [["셋", "A"], ["셋", "새 폴더", "B"], ["새 목록"]])
        let changed = result.playlists[0]
        #expect(changed.kind == .changed && changed.libraryID == "p1")
        #expect(changed.xmlEntries == ["102", "101"] && changed.libraryEntries == ["101", "102"] && changed.unmatchedEntries == 1)
        #expect(result.playlists[1].kind == .missing && result.playlists[1].xmlEntries == ["101"])
        #expect(result.playlists[2].kind == .missing && result.playlists[2].unmatchedEntries == 1)
        #expect(result.counts.missingPlaylists == 2 && result.counts.changedPlaylists == 1)
        // 라이브러리에만 있는 목록은 차이가 아니다(가져오기는 지우지 않는다)
        #expect(result.counts.libraryOnlyPlaylists == 1)
    }

    @Test func 이름이_같은_목록이_둘이면_건너뛴다() {
        let library = Doc(tracks: [track("101", "/a.mp3")], lists: [node("A", id: "p1", []), node("A", id: "p2", [])])
        let xml = Doc(tracks: [track("1", "/a.mp3")], lists: [node("A", ["1"])])
        let result = XMLLibraryDiff.compute(xml: xml, library: library)
        #expect(result.playlists.isEmpty && result.counts.ambiguousPlaylists == 1)
    }

    @Test func 모호한_곡은_목록_항목에서도_뺀다() {
        let library = Doc(tracks: [track("101", "/a.mp3"), track("102", "/a.mp3")], lists: [node("A", id: "p1", [])])
        let xml = Doc(tracks: [track("1", "/a.mp3")], lists: [node("A", ["1"])])
        let result = XMLLibraryDiff.compute(xml: xml, library: library)
        #expect(result.playlists.isEmpty)
        #expect(result.matching.ambiguous == 1)
    }

    @Test func 같은_TrackID가_둘이면_두_곡_모두_모호하고_그_키의_목록_항목도_못_맞춘다() {
        // 둘째 곡이 첫째의 맞춤을 덮으면 a의 큐·제목이 b에 들어간다
        let xml = Doc(tracks: [track("5", "/m/a.mp3", title: "A 제목", marks: [Mark(kind: .hot(0), start: 10, name: "")]),
                               track("5", "/m/b.mp3", title: "B 제목", marks: [Mark(kind: .hot(0), start: 20, name: "")])],
                      lists: [node("셋", ["5"])])
        let library = Doc(tracks: [track("LA", "/m/a.mp3", title: "A 제목", marks: [Mark(kind: .hot(0), start: 10, name: "")]),
                                   track("LB", "/m/b.mp3", title: "B 제목", marks: [Mark(kind: .hot(0), start: 20, name: "")])],
                          lists: [node("셋", id: "p1", [])])
        let result = XMLLibraryDiff.compute(xml: xml, library: library)
        #expect(result.matches.matched.isEmpty)
        #expect(result.matches.ambiguous == ["5"])
        #expect(result.matching.ambiguous == 2)
        #expect(result.tracks.isEmpty)
        #expect(result.playlists.isEmpty, "못 맞춘 항목만 있는 목록은 라이브러리와 곡이 같다")
        let missing = XMLLibraryDiff.compute(xml: xml, library: Doc(tracks: library.tracks))
        #expect(missing.playlists.first?.unmatchedEntries == 1 && missing.playlists.first?.xmlEntries == [])
    }

    // MARK: 같은 문서

    @Test func 같은_내용이면_차이가_없다() {
        let marks = [Mark(kind: .memory, start: 1, name: ""), Mark(kind: .hot(7), start: 3, end: 5, name: "H")]
        let tempos = [GridSegment(start: 0.1, bpm: 128, firstBeatNumber: 1), GridSegment(start: 30.1, bpm: 130, firstBeatNumber: 3)]
        let library = Doc(tracks: [track("101", "/a.mp3", tags: [.artist: "A"], marks: marks, tempos: tempos)],
                          lists: [folder("F", id: "f", [node("L", id: "l", ["101", "101"])])])
        let xml = Doc(tracks: [track("7", "/a.mp3", tags: [.artist: "A"], marks: marks.reversed(), tempos: tempos)],
                      lists: [folder("F", [node("L", ["7", "7"])])])
        let result = XMLLibraryDiff.compute(xml: xml, library: library)
        #expect(result.tracks.isEmpty && result.playlists.isEmpty)
        #expect(result.matching.matched == 1)
        #expect(result.isEmpty)
    }
}
