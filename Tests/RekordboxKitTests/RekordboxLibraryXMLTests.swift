import DJCDomain
import DJCEnvironment
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 라이브러리 전체 XML 내보내기(#72). 합성 라이브러리의 값을 칸 단위로 확인한다(rekordbox가 만든 XML과의 비교는 사용자 실험 몫).
@Suite("rekordbox XML 전체 내보내기")
struct RekordboxLibraryXMLTests {
    // MARK: 합성 라이브러리

    /// 곡 101(모든 칸·큐 종류·그리드), 104(변속 그리드·모르는 큐), 105(분석 없음·칸 거의 없음), 102(삭제 행), 103(스트리밍),
    /// 재생 목록(폴더 중첩·중복 곡·지운 곡·스트리밍 곡 항목·인텔리전트).
    func makeLibrary() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        for (table, id, name) in [("djmdArtist", "ar1", "아티스트"), ("djmdArtist", "ar2", "작곡가"), ("djmdArtist", "ar3", "리믹서"),
                                  ("djmdGenre", "g1", "Anime"), ("djmdLabel", "lb1", "레이블")] {
            try fixture.insert(table, ["ID": .text(id), "Name": .text(name)])
        }
        try fixture.insert("djmdAlbum", ["ID": .text("al1"), "Name": .text("앨범")])
        try fixture.insert("djmdKey", ["ID": .text("k1"), "ScaleName": .text("8B")])

        var full = TrackSpec(id: "101", uuid: "uuid-101")
        full.title = #"제목 "따옴표" <꺾쇠>"#
        full.folderPath = "/Music/곡 & 이름 (TV).mp3"
        full.length = 200
        full.bpm100 = 17450
        full.analysisDataPath = "/PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT"
        var loop = CueSpec(id: "c4", kind: 0, inMsec: 40_000)
        loop.outMsec = 44_000; loop.comment = "루프"
        var hotLoop = CueSpec(id: "c5", kind: 2, inMsec: 50_000)
        hotLoop.outMsec = 52_000
        var named = CueSpec(id: "c3", kind: 5, inMsec: 30_000)
        named.comment = "후렴"
        full.cues = [.autoCue(at: 1000), CueSpec(id: "c2", kind: 1, inMsec: 20_000), named, loop, hotLoop,
                     CueSpec(id: "c6", kind: 4, inMsec: 60_000)]
        try fixture.add(full)
        try fixture.putAnalysis(for: full, dat: AnlzBuilder.dat(beats: AnlzBuilder.beats(bpm: 174.5, first: 25, count: 300)), ext: nil)
        try fixture.execute("""
            UPDATE djmdContent SET ArtistID = 'ar1', ComposerID = 'ar2', AlbumID = 'al1', GenreID = 'g1', KeyID = 'k1',
                RemixerID = 'ar3', LabelID = 'lb1', Commnt = '코멘트 & <1>', ReleaseYear = 2024, TrackNo = 3, DiscNo = 2,
                FileSize = 12345678, SampleRate = 44100, DJPlayCount = 7, StockDate = '2025-03-04' WHERE ID = '101'
            """)

        var variable = TrackSpec(id: "104", uuid: "uuid-104")
        variable.title = "변속 곡"
        variable.folderPath = "/Music/변속.m4a"
        variable.bpm100 = 13500
        variable.analysisDataPath = "/PIONEER/USBANLZ/P001/0000ABCE/ANLZ0000.DAT"
        variable.cues = [CueSpec(id: "v1", kind: 4, inMsec: 5000)]
        try fixture.add(variable)
        let beats = AnlzBuilder.beats(bpm: 120, first: 100, count: 16) + AnlzBuilder.beats(bpm: 150, first: 8100, count: 16, firstNumber: 3)
        try fixture.putAnalysis(for: variable, dat: AnlzBuilder.dat(beats: beats), ext: nil)

        var bare = TrackSpec(id: "105", uuid: "uuid-105")
        bare.title = "분석 없는 곡"
        bare.folderPath = "/Music/분석 없음.wav"
        bare.bpm100 = 0
        bare.bitRate = 0
        bare.analysed = 0
        try fixture.add(bare)

        var deleted = TrackSpec(id: "102", uuid: "uuid-102")
        deleted.title = "지운 곡"
        try fixture.add(deleted)
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '102'")
        var streaming = TrackSpec(id: "103", uuid: "uuid-103")
        streaming.title = "스트리밍 곡"
        streaming.folderPath = "apple-music:track:123"
        try fixture.add(streaming)

        for (id, name, parent, attribute, seq) in [("f1", "폴더", "root", 1, 1), ("f2", "빈 폴더", "f1", 1, 1), ("p1", "셋 A", "f1", 0, 2),
                                                   ("p3", "맨 위", "root", 0, 0), ("p4", "인텔리전트", "root", 4, 5)] {
            try fixture.insert("djmdPlaylist", ["ID": .text(id), "Name": .text(name), "ParentID": .text(parent),
                                                "Attribute": .int(attribute), "Seq": .int(seq)])
        }
        try fixture.execute("UPDATE djmdPlaylist SET SmartList = '<NODE/>' WHERE ID = 'p4'")
        for (id, playlist, content, no) in [("s1", "p1", "101", 1), ("s2", "p1", "104", 2), ("s3", "p1", "101", 3), ("s4", "p1", "102", 4),
                                            ("s5", "p1", "103", 5), ("s6", "p3", "104", 1), ("s7", "p3", "101", 2), ("s8", "p4", "101", 1)] {
            try fixture.insert("djmdSongPlaylist", ["ID": .text(id), "PlaylistID": .text(playlist), "ContentID": .text(content),
                                                    "TrackNo": .int(no)])
        }
        return fixture
    }

    func collection(_ fixture: RekordboxFixture, progress: (@Sendable (RekordboxLibraryXML.Progress) -> Void)? = nil) throws
        -> RekordboxLibraryXML.Collection {
        try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot, progress: progress)
    }

    // MARK: 시험용 XML 읽기

    final class Element {
        let name: String
        let attributes: [String: String]
        /// 파일에 적힌 속성 순서
        let attributeOrder: [String]
        var children: [Element] = []
        init(name: String, attributes: [String: String], order: [String]) {
            self.name = name; self.attributes = attributes; attributeOrder = order
        }
        func first(_ name: String) -> Element? { children.first { $0.name == name } }
        func all(_ name: String) -> [Element] { children.filter { $0.name == name } }
    }

    final class Reader: NSObject, XMLParserDelegate {
        var root: Element?
        private var stack: [Element] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let element = Element(name: name, attributes: attributes, order: [])
            if let parent = stack.last { parent.children.append(element) } else { root = element }
            stack.append(element)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }

    func parse(_ xml: String) throws -> Element {
        let parser = XMLParser(data: Data(xml.utf8))
        let reader = Reader()
        parser.delegate = reader
        #expect(parser.parse(), "XML 파싱 실패: \(String(describing: parser.parserError))")
        return try #require(reader.root)
    }

    /// TRACK 속성이 파일에 적힌 순서(XMLParser는 사전이라 순서를 주지 않는다)
    func attributeOrder(of trackID: String, in xml: String) -> [String] {
        guard let line = xml.split(separator: "\n").first(where: { $0.contains(#"<TRACK TrackID="\#(trackID)""#) }) else { return [] }
        var names: [String] = []
        var rest = Substring(line)
        while let equals = rest.firstIndex(of: "=") {
            let name = rest[..<equals].split(separator: " ").last.map(String.init) ?? ""
            names.append(name)
            guard let open = rest.index(equals, offsetBy: 2, limitedBy: rest.endIndex),
                  let close = rest[open...].firstIndex(of: "\"") else { break }
            rest = rest[rest.index(after: close)...]
        }
        return names
    }

    func tracks(_ root: Element) throws -> [String: Element] {
        let collection = try #require(root.first("COLLECTION"))
        return Dictionary(uniqueKeysWithValues: collection.all("TRACK").compactMap { track in track.attributes["TrackID"].map { ($0, track) } })
    }

    // MARK: 문서 구조

    @Test func 문서는_DJ_PLAYLISTS_구조이고_삭제_행과_스트리밍_곡은_컬렉션에_넣지_않는다() throws {
        let fixture = try makeLibrary()
        let xml = RekordboxLibraryXML.document(try collection(fixture))
        #expect(xml.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"))
        let root = try parse(xml)
        #expect(root.name == "DJ_PLAYLISTS" && root.attributes["Version"] == "1.0.0")
        #expect(root.first("PRODUCT")?.attributes["Name"] == "DJCrate")
        let collection = try #require(root.first("COLLECTION"))
        #expect(collection.attributes["Entries"] == "3")
        #expect(collection.all("TRACK").compactMap { $0.attributes["TrackID"] } == ["101", "104", "105"], "ContentID 순서")
        #expect(root.children.map(\.name) == ["PRODUCT", "COLLECTION", "PLAYLISTS"])
    }

    @Test func 곡_칸은_DB_값을_칸_단위로_옮긴다() throws {
        let fixture = try makeLibrary()
        let xml = RekordboxLibraryXML.document(try collection(fixture))
        let track = try #require(try tracks(try parse(xml))["101"])
        let expected: [(String, String)] = [
            ("TrackID", "101"), ("Name", #"제목 "따옴표" <꺾쇠>"#), ("Artist", "아티스트"), ("Composer", "작곡가"), ("Album", "앨범"),
            ("Genre", "Anime"), ("Kind", "MP3 File"), ("Size", "12345678"), ("TotalTime", "200"), ("DiscNumber", "2"),
            ("TrackNumber", "3"), ("Year", "2024"), ("AverageBpm", "174.50"), ("DateAdded", "2025-03-04"), ("BitRate", "320"),
            ("SampleRate", "44100"), ("Comments", "코멘트 & <1>"), ("PlayCount", "7"),
            ("Location", "file://localhost/Music/%EA%B3%A1%20&%20%EC%9D%B4%EB%A6%84%20(TV).mp3"),
            ("Remixer", "리믹서"), ("Tonality", "8B"), ("Label", "레이블"),
        ]
        #expect(Set(track.attributes.keys) == Set(expected.map(\.0)), "넣지 않기로 한 칸이 새어 들어가지 않는다")
        for (name, value) in expected { #expect(track.attributes[name] == value, "\(name)") }
        #expect(attributeOrder(of: "101", in: xml) == expected.map(\.0), "rekordbox 형식 문서의 칸 순서")
    }

    @Test func 칸이_없는_곡은_rekordbox처럼_0과_빈_글자를_쓰고_모르는_값은_뺀다() throws {
        let fixture = try makeLibrary()
        let track = try #require(try tracks(try parse(RekordboxLibraryXML.document(try collection(fixture))))["105"])
        #expect(track.attributes["Name"] == "분석 없는 곡")
        for name in ["Artist", "Composer", "Album", "Genre", "Comments"] { #expect(track.attributes[name] == "", "\(name)") }
        for name in ["DiscNumber", "TrackNumber", "Year", "PlayCount"] { #expect(track.attributes[name] == "0", "\(name)") }
        #expect(track.attributes["Kind"] == "WAV File")
        for name in ["AverageBpm", "BitRate", "Tonality", "Remixer", "Label", "Size"] { #expect(track.attributes[name] == nil, "\(name)") }
        // StockDate가 비면 행을 만든 날로 대신한다
        #expect(track.attributes["DateAdded"] == "2026-01-01")
        #expect(track.first("TEMPO") == nil, "분석 파일이 없으면 TEMPO를 쓰지 않는다")
    }

    // MARK: 큐

    @Test func 큐는_메모리_핫큐_루프를_POSITION_MARK로_쓰고_모르는_종류는_뺀다() throws {
        let fixture = try makeLibrary()
        let track = try #require(try tracks(try parse(RekordboxLibraryXML.document(try collection(fixture))))["101"])
        let marks = track.all("POSITION_MARK").map(\.attributes)
        let expected: [[String: String]] = [
            ["Name": "1.1Bars", "Type": "0", "Start": "1.000", "Num": "-1"],
            ["Name": "", "Type": "0", "Start": "20.000", "Num": "0"],
            ["Name": "후렴", "Type": "0", "Start": "30.000", "Num": "3"],
            ["Name": "루프", "Type": "4", "Start": "40.000", "End": "44.000", "Num": "-1"],
            ["Name": "", "Type": "4", "Start": "50.000", "End": "52.000", "Num": "1"],
        ]
        #expect(marks == expected)
        // 핫큐 색(Red·Green·Blue)은 rekordbox 색 번호와 XML 색의 대응을 확인하기 전이라 쓰지 않는다
        #expect(marks.allSatisfy { $0["Red"] == nil && $0["Green"] == nil && $0["Blue"] == nil })
    }

    @Test func 큐가_모두_모르는_종류면_POSITION_MARK가_없다() throws {
        let fixture = try makeLibrary()
        let track = try #require(try tracks(try parse(RekordboxLibraryXML.document(try collection(fixture))))["104"])
        #expect(track.all("POSITION_MARK").isEmpty)
    }

    // MARK: 그리드

    @Test func 한_템포_그리드는_TEMPO_하나로_첫_박_시각과_저장된_BPM을_쓴다() throws {
        let fixture = try makeLibrary()
        let track = try #require(try tracks(try parse(RekordboxLibraryXML.document(try collection(fixture))))["101"])
        let tempos = track.all("TEMPO").map(\.attributes)
        #expect(tempos == [["Inizio": "0.025", "Bpm": "174.50", "Metro": "4/4", "Battito": "1"]])
    }

    @Test func 변속_그리드는_구간마다_TEMPO를_쓴다() throws {
        let fixture = try makeLibrary()
        let track = try #require(try tracks(try parse(RekordboxLibraryXML.document(try collection(fixture))))["104"])
        let tempos = track.all("TEMPO").map(\.attributes)
        #expect(tempos == [["Inizio": "0.100", "Bpm": "120.00", "Metro": "4/4", "Battito": "1"],
                           ["Inizio": "8.100", "Bpm": "150.00", "Metro": "4/4", "Battito": "3"]])
        // TEMPO는 POSITION_MARK보다 앞에 둔다(rekordbox 형식)
        #expect(track.children.map(\.name).filter { $0 == "TEMPO" || $0 == "POSITION_MARK" } == ["TEMPO", "TEMPO"])
    }

    // MARK: 재생 목록

    @Test func 재생_목록은_폴더_트리와_곡_순서를_그대로_쓰고_컬렉션에_없는_항목은_뺀다() throws {
        let fixture = try makeLibrary()
        let root = try parse(RekordboxLibraryXML.document(try collection(fixture)))
        let playlists = try #require(root.first("PLAYLISTS"))
        let top = try #require(playlists.first("NODE"))
        #expect(top.attributes == ["Type": "0", "Name": "ROOT", "Count": "2"])
        #expect(top.all("NODE").map { $0.attributes["Name"] } == ["맨 위", "폴더"], "Seq 순서, 인텔리전트 목록은 넣지 않는다")
        let first = top.all("NODE")[0]
        #expect(first.attributes == ["Name": "맨 위", "Type": "1", "KeyType": "0", "Entries": "2"])
        #expect(first.all("TRACK").map { $0.attributes["Key"] } == ["104", "101"])
        let folder = top.all("NODE")[1]
        #expect(folder.attributes == ["Name": "폴더", "Type": "0", "Count": "2"])
        let inner = folder.all("NODE")
        #expect(inner.map { $0.attributes["Name"] } == ["빈 폴더", "셋 A"])
        #expect(inner[0].attributes == ["Name": "빈 폴더", "Type": "0", "Count": "0"] && inner[0].children.isEmpty)
        #expect(inner[1].attributes == ["Name": "셋 A", "Type": "1", "KeyType": "0", "Entries": "3"])
        #expect(inner[1].all("TRACK").map { $0.attributes["Key"] } == ["101", "104", "101"], "같은 곡 두 번을 그대로 두고 지운 곡·스트리밍 곡 항목은 뺀다")
        // 모든 항목은 COLLECTION에 있는 TrackID를 가리킨다
        let known = Set(try tracks(root).keys)
        func keys(_ node: Element) -> [String] { node.all("TRACK").compactMap { $0.attributes["Key"] } + node.all("NODE").flatMap(keys) }
        #expect(Set(keys(top)).isSubset(of: known))
    }

    /// 상위 폴더가 없는 목록은 rekordbox 트리(ROOT에서 닿는 곳)에 없으므로 루트에 지어 붙이지 않고, 조용히 사라지지 않게 센다.
    @Test func 없는_폴더를_가리키는_재생_목록은_빼고_센다() throws {
        let fixture = try makeLibrary()
        for (id, name, parent, attribute) in [("o1", "고아 목록", "없는폴더", 0), ("o2", "고아 폴더", "없는폴더", 1), ("o3", "고아 폴더 속 목록", "o2", 0)] {
            try fixture.insert("djmdPlaylist", ["ID": .text(id), "Name": .text(name), "ParentID": .text(parent),
                                                "Attribute": .int(attribute), "Seq": .int(1)])
        }
        try fixture.insert("djmdSongPlaylist", ["ID": .text("s9"), "PlaylistID": .text("o1"), "ContentID": .text("101"), "TrackNo": .int(1)])
        let source = try collection(fixture)
        let summary = source.summary
        #expect(summary.folders == 2 && summary.playlists == 2 && summary.playlistEntries == 5, "닿는 트리만 센다")
        #expect(summary.omitted.orphanedPlaylists == 3, "고아 목록·고아 폴더·그 안의 목록")
        let xml = RekordboxLibraryXML.document(source)
        #expect(!xml.contains("고아"))
    }

    @Test func 서로를_가리키는_폴더도_빼고_센다() {
        func list(_ id: String, parent: String, folder: Bool = false) -> RekordboxPlaylist {
            RekordboxPlaylist(id: id, name: id, parentID: parent, seq: 1, isFolder: folder, trackIDs: [])
        }
        var omitted = RekordboxLibraryXML.Omitted()
        let tree = RekordboxLibraryXML.listTree([list("a", parent: "b", folder: true), list("b", parent: "a", folder: true),
                                                 list("c", parent: "root")], keys: [:], omitted: &omitted)
        #expect(tree.map(\.name) == ["c"] && omitted.orphanedPlaylists == 2)
    }

    @Test func 재생_목록이_없으면_빈_ROOT를_쓴다() throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let root = try parse(RekordboxLibraryXML.document(try collection(fixture)))
        #expect(root.first("PLAYLISTS")?.first("NODE")?.attributes == ["Type": "0", "Name": "ROOT", "Count": "0"])
    }

    // MARK: 요약

    @Test func 요약은_내보낸_것과_뺀_것을_센다() throws {
        let fixture = try makeLibrary()
        let summary = try collection(fixture).summary
        #expect(summary.tracks == 3 && summary.marks == 5 && summary.tracksWithGrid == 2 && summary.tracksWithoutGrid == 1)
        #expect(summary.folders == 2 && summary.playlists == 2 && summary.playlistEntries == 5)
        #expect(summary.omitted.streamingTracks == 1 && summary.omitted.intelligentPlaylists == 1)
        #expect(summary.omitted.unknownCues == 2 && summary.omitted.playlistEntries == 2)
    }

    // MARK: 읽기만

    @Test func 사본_DB와_분석_파일을_바꾸지_않는다() throws {
        let fixture = try makeLibrary()
        let analysis = fixture.analysisURL(for: TrackSpec(id: "101", uuid: "x").with(path: "/PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT"))
        let before = (try Data(contentsOf: fixture.database), try Data(contentsOf: analysis))
        let out = fixture.root.appending(path: "library.xml")
        _ = try RekordboxLibraryXML.export(snapshot: fixture.database, shareRoot: fixture.shareRoot, to: out)
        #expect(try Data(contentsOf: fixture.database) == before.0 && (try Data(contentsOf: analysis)) == before.1)
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func 내보낸_파일은_문서와_같고_임시_파일을_남기지_않는다() throws {
        let fixture = try makeLibrary()
        let folder = fixture.root.appending(path: "out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appending(path: "library.xml")
        try Data("옛 내용".utf8).write(to: out)
        let summary = try RekordboxLibraryXML.export(snapshot: fixture.database, shareRoot: fixture.shareRoot, to: out)
        #expect(summary.tracks == 3)
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text == RekordboxLibraryXML.document(try collection(fixture)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["library.xml"], "지정한 파일만 남는다")
    }

    // MARK: 왕복(내보내기 → 읽기 → 같은 값)

    /// 내보낸 XML을 모델로 되읽어 원래 컬렉션과 같은지 본다.
    @Test func 내보낸_XML을_읽으면_컬렉션의_값과_같다() throws {
        let fixture = try makeLibrary()
        let source = try collection(fixture)
        let root = try parse(RekordboxLibraryXML.document(source))
        let read = try tracks(root)
        #expect(Set(read.keys) == Set(source.entries.map { String($0.trackKey) }))
        for entry in source.entries {
            let element = try #require(read[String(entry.trackKey)])
            #expect(element.attributes["Name"] == entry.track.title)
            #expect(element.attributes["TotalTime"] == String(entry.track.lengthSeconds))
            // Location을 되읽으면 원래 경로
            let location = try #require(element.attributes["Location"])
            #expect(location.hasPrefix("file://localhost"))
            #expect(String(location.dropFirst("file://localhost".count)).removingPercentEncoding == entry.track.folderPath)
            // 큐 시각을 되읽으면 원래 ms
            let starts = element.all("POSITION_MARK").map { Int((Double($0.attributes["Start"] ?? "") ?? -1) * 1000 + 0.5) }
            #expect(starts == entry.marks.map { Int($0.start * 1000 + 0.5) })
            // TEMPO를 되읽으면 같은 구간
            let tempos = element.all("TEMPO").map { ($0.attributes["Inizio"].flatMap(Double.init), $0.attributes["Bpm"].flatMap(Double.init),
                                                     $0.attributes["Battito"].flatMap(Int.init)) }
            #expect(tempos.count == entry.tempos.count)
            for (read, original) in zip(tempos, entry.tempos) {
                #expect(abs((read.0 ?? -1) - original.start) < 0.0005 && abs((read.1 ?? -1) - original.bpm) < 0.005 && read.2 == original.firstBeatNumber)
            }
        }
    }

    // MARK: 속성 연결 자리(#65)

    @Test func 별점_곡_색_같은_추가_속성은_Location_뒤에_붙는다() throws {
        let fixture = try makeLibrary()
        var source = try collection(fixture)
        source.entries[0].extraAttributes = [.init(name: "Rating", value: "204"), .init(name: "Colour", value: "0xFF007F")]
        let xml = RekordboxLibraryXML.document(source)
        let track = try #require(try tracks(try parse(xml))["101"])
        #expect(track.attributes["Rating"] == "204" && track.attributes["Colour"] == "0xFF007F")
        #expect(Array(attributeOrder(of: "101", in: xml).suffix(2)) == ["Rating", "Colour"])
    }

    // MARK: 값 이스케이프

    @Test func 제어_문자와_XML에_못_쓰는_글자는_걸러_파싱이_깨지지_않는다() throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "1")
        spec.title = "A\u{1}B\u{FFFE}C&D\n줄"
        try fixture.add(spec)
        let root = try parse(RekordboxLibraryXML.document(try collection(fixture)))
        #expect(try tracks(root)["1"]?.attributes["Name"] == "ABC&D\n줄")
    }

    // MARK: 진행·취소

    @Test func 진행은_읽기_그리드_쓰기_순으로_끝까지_알린다() throws {
        let fixture = try makeLibrary()
        let events = Lock<[RekordboxLibraryXML.Progress]>([])
        let source = try collection(fixture) { event in events.withLock { $0.append(event) } }
        let grids = events.withLock { $0 }.filter { $0.phase == .readingGrids }
        #expect(grids.last == .init(phase: .readingGrids, done: 3, total: 3))
        #expect(grids.map(\.done) == grids.map(\.done).sorted())
        let written = Lock<[RekordboxLibraryXML.Progress]>([])
        var out = ""
        try RekordboxLibraryXML.write(source, progress: { event in written.withLock { $0.append(event) } }) { out += $0 }
        #expect(written.withLock { $0 }.last == .init(phase: .writing, done: 3, total: 3))
        #expect(out == RekordboxLibraryXML.document(source))
    }

    @Test func 취소하면_읽다_멈춘다() async throws {
        let fixture = try makeLibrary()
        let task = Task.detached {
            try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: 큰 라이브러리

    @Test func 곡이_많아도_모두_내보낸다() throws {
        let fixture = try RekordboxFixture()
        try fixture.add(tracks: (1...1500).map { n in
            var spec = TrackSpec(id: String(100_000 + n))
            spec.title = "곡 \(n)"
            spec.folderPath = "/Music/곡 \(n).mp3"
            return spec
        })
        let source = try collection(fixture)
        #expect(source.summary.tracks == 1500)
        let root = try parse(RekordboxLibraryXML.document(source))
        #expect(root.first("COLLECTION")?.all("TRACK").count == 1500)
    }

    // MARK: Location 인코딩

    /// `#`·`%`는 퍼센트 인코딩하고, NFD 한글은 정규화하지 않고 그 바이트 그대로 인코딩한다(되읽으면 원래 경로).
    @Test func Location은_샵_퍼센트_NFD_한글을_인코딩하고_되읽으면_원래_경로다() throws {
        let nfd = "한글".decomposedStringWithCanonicalMapping
        #expect(nfd.unicodeScalars.count == 6)
        let path = "/Music/50% #1 \(nfd).mp3"
        let location = RekordboxXML.location(forPath: path)
        #expect(location == "file://localhost/Music/50%25%20%231%20%E1%84%92%E1%85%A1%E1%86%AB%E1%84%80%E1%85%B3%E1%86%AF.mp3")
        let back = try #require(String(location.dropFirst("file://localhost".count)).removingPercentEncoding)
        #expect(Array(back.unicodeScalars) == Array(path.unicodeScalars), "NFD를 NFC로 바꾸지 않는다")

        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "1")
        spec.folderPath = path
        try fixture.add(spec)
        let root = try parse(RekordboxLibraryXML.document(try collection(fixture)))
        #expect(try tracks(root)["1"]?.attributes["Location"] == location)
    }

    // MARK: 출력 경로

    @Test func 출력_경로는_xml_파일만_받고_rekordbox_폴더와_연동_파일은_거부한다() throws {
        let fixture = try RekordboxFixture()
        let ok = fixture.root.appending(path: "library.xml")
        #expect(throws: Never.self) { try RekordboxLibraryXML.checkOutput(ok) }
        // 확장자가 xml이 아니면(예: master.db) 거부
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(fixture.root.appending(path: "master.db")) }
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(fixture.root.appending(path: "library")) }
        // 폴더·없는 상위 폴더
        let folder = fixture.root.appending(path: "dir.xml")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(folder) }
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(fixture.root.appending(path: "없는/library.xml")) }
        // 실제 rekordbox 폴더(경로 판단에만 쓰고 쓰지 않는다)와 연동 XML 파일
        let real = LibrarySnapshot.realRekordboxDirectory
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(real.appending(path: "library.xml")) }
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(real.appending(path: "share/library.xml")) }
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(real.deletingLastPathComponent().appending(path: "library.xml")) }
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(DJCIdentity.linkedXMLFile) }
    }

    @Test func rekordbox_폴더_사본_안과_그곳을_가리키는_링크도_거부한다() throws {
        let fixture = try RekordboxFixture()
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        #expect(throws: RekordboxLibraryXML.OutputError.self) {
            try RekordboxLibraryXML.checkOutput(fixture.root.appending(path: "library.xml"), environment: environment)
        }
        let other = try RekordboxFixture()
        let link = other.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(link.appending(path: "library.xml"), environment: environment) }
        // 대소문자만 다른 표기도 같은 폴더로 본다
        let shouting = URL(filePath: fixture.root.path.uppercased()).appending(path: "library.xml")
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(shouting, environment: environment) }
    }

    /// DJCrate 데이터 폴더(`DJC_HOME`·지원 폴더) 안은 거부한다. 백업의 masterPlaylists6.xml을 덮으면 "쓰기 전으로 복원"이 그것을 라이브로 옮긴다.
    @Test func DJCrate_데이터_폴더_안은_거부한다() throws {
        let home = try RekordboxFixture()
        let environment = ["DJC_HOME": home.root.path]
        let backup = home.root.appending(path: "rekordbox-backups/2026-10-01")
        let usb = home.root.appending(path: "usb-backups/x/PIONEER")
        for folder in [backup, usb] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for out in [home.root.appending(path: "library.xml"), backup.appending(path: "masterPlaylists6.xml"), usb.appending(path: "a.xml")] {
            #expect(throws: RekordboxLibraryXML.OutputError(reason: RekordboxLibraryXML.protectedOutputReason)) {
                try RekordboxLibraryXML.checkOutput(out, environment: environment)
            }
        }
        // 그곳을 가리키는 링크, 대소문자만 다른 표기
        let other = try RekordboxFixture()
        let link = other.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: backup)
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(link.appending(path: "m.xml"), environment: environment) }
        let shouting = URL(filePath: backup.path.uppercased()).appending(path: "m.xml")
        #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(shouting, environment: environment) }
        // DJC_HOME을 주지 않아도 앱의 지원 폴더(시험 프로세스에서는 임시 폴더)와 실제 사용자 폴더는 막는다
        let support = DJCIdentity.supportDirectory.appending(path: "rekordbox-backups")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        #expect(throws: RekordboxLibraryXML.OutputError(reason: RekordboxLibraryXML.protectedOutputReason)) {
            try RekordboxLibraryXML.checkOutput(support.appending(path: "m.xml"), environment: [:])
        }
        #expect(throws: RekordboxLibraryXML.OutputError(reason: RekordboxLibraryXML.protectedOutputReason)) {
            try RekordboxLibraryXML.checkOutput(DJCIdentity.userSupportDirectory.appending(path: "rekordbox-backups/x/m.xml"), environment: [:])
        }
        // 이웃 폴더는 받는다
        #expect(throws: Never.self) { try RekordboxLibraryXML.checkOutput(other.root.appending(path: "library.xml"), environment: environment) }
    }

    /// USB의 PIONEER 폴더 아래(rekordbox·CDJ가 읽는 자리)는 대소문자와 상관없이 거부한다.
    @Test func USB의_PIONEER_폴더_아래는_거부한다() throws {
        for path in ["/Volumes/DJCTEST/PIONEER/rekordbox.xml", "/Volumes/DJCTEST/PIONEER/rekordbox/a.xml",
                     "/volumes/djctest/pioneer/a.xml", "/Volumes/USB 이름/Pioneer/a.xml"] {
            #expect(throws: RekordboxLibraryXML.OutputError(reason: RekordboxLibraryXML.protectedOutputReason), "\(path)") {
                try RekordboxLibraryXML.checkOutput(URL(filePath: path), environment: [:])
            }
        }
        // USB 루트·다른 폴더는 이 이유로 막지 않는다(여기서는 없는 폴더라 다른 이유로 막힌다)
        for path in ["/Volumes/DJCTEST/library.xml", "/Volumes/DJCTEST/PIONEERS/a.xml", "/Volumes/DJCTEST/backup/PIONEER/a.xml"] {
            #expect(throws: RekordboxLibraryXML.OutputError.self) { try RekordboxLibraryXML.checkOutput(URL(filePath: path), environment: [:]) }
            #expect(!RekordboxLibraryXML.isUsbPioneerPath(path), "\(path)")
        }
        #expect(RekordboxLibraryXML.isUsbPioneerPath("/Volumes/X/PIONEER/a.xml") && RekordboxLibraryXML.isUsbPioneerPath("/VOLUMES/x/pioneer/a/b.xml"))
    }

    @Test func 거부된_출력은_아무것도_쓰지_않는다() throws {
        let fixture = try makeLibrary()
        let real = LibrarySnapshot.realRekordboxDirectory
        let before = try Data(contentsOf: fixture.database)
        #expect(throws: RekordboxLibraryXML.OutputError.self) {
            _ = try RekordboxLibraryXML.export(snapshot: fixture.database, shareRoot: fixture.shareRoot, to: real.appending(path: "library.xml"))
        }
        #expect(throws: RekordboxLibraryXML.OutputError.self) {
            _ = try RekordboxLibraryXML.export(snapshot: fixture.database, shareRoot: fixture.shareRoot, to: fixture.root.appending(path: "master.db"))
        }
        #expect(try Data(contentsOf: fixture.database) == before)
    }
}

private extension TrackSpec {
    func with(path: String) -> TrackSpec {
        var copy = self
        copy.analysisDataPath = path
        return copy
    }
}

/// 진행 콜백이 다른 스레드에서 부를 수 있어 값을 잠가 둔다.
final class Lock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
