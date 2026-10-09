import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// rekordbox XML 가져오기(#72): 다른 도구·rekordbox가 만든 XML을 읽어 라이브러리와 비교한다. 합성 XML·`RekordboxFixture`만 쓴다.
@Suite("rekordbox XML 가져오기 읽기")
struct RekordboxXMLReaderTests {
    func read(_ xml: String) throws -> XMLLibrary { try RekordboxXMLReader.read(data: Data(xml.utf8)) }

    func document(tracks: String, playlists: String = #"<NODE Type="0" Name="ROOT" Count="0"/>"#) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <PRODUCT Name="rekordbox" Version="7.2.18" Company="AlphaTheta"/>
          <COLLECTION Entries="2">
        \(tracks)
          </COLLECTION>
          <PLAYLISTS>
        \(playlists)
          </PLAYLISTS>
        </DJ_PLAYLISTS>
        """
    }

    @Test func 곡_칸과_큐_그리드를_읽는다() throws {
        let library = try read(document(tracks: """
            <TRACK TrackID="7" Name="제목 &amp; &quot;x&quot;" Artist="A" Composer="C" Album="Al" Genre="G" Kind="MP3 File" Size="1"
                   TotalTime="200" DiscNumber="0" TrackNumber="3" Year="2024" AverageBpm="128.00" DateAdded="2025-01-01" BitRate="320"
                   SampleRate="44100" Comments="줄&#10;바꿈" PlayCount="2" Rating="153" Location="file://localhost/Music/%EA%B3%A1%20a.mp3"
                   Remixer="" Tonality="Am" Label="" Mix="" Grouping="">
              <TEMPO Inizio="0.025" Bpm="128.00" Metro="4/4" Battito="1"/>
              <TEMPO Inizio="60.025" Bpm="130.00" Metro="4/4" Battito="3"/>
              <POSITION_MARK Name="" Type="0" Start="1.000" Num="-1"/>
              <POSITION_MARK Name="훅" Type="0" Start="20.500" Num="2" Red="40" Green="226" Blue="20"/>
              <POSITION_MARK Name="루프" Type="4" Start="40.000" End="44.000" Num="-1"/>
            </TRACK>
            """))
        #expect(library.tracks.count == 1)
        let track = try #require(library.tracks.first)
        #expect(track.key == "7" && track.path == "/Music/곡 a.mp3")
        #expect(track.tags == [.title: #"제목 & "x""#, .artist: "A", .composer: "C", .album: "Al", .genre: "G", .trackNumber: "3",
                               .year: "2024", .comment: "줄\n바꿈", .musicalKey: "Am", .rating: "3"])
        #expect(track.tempos == [GridSegment(start: 0.025, bpm: 128, firstBeatNumber: 1), GridSegment(start: 60.025, bpm: 130, firstBeatNumber: 3)])
        #expect(track.marks == [XMLLibrary.Mark(kind: .memory, start: 1, name: ""), XMLLibrary.Mark(kind: .hot(2), start: 20.5, name: "훅"),
                                XMLLibrary.Mark(kind: .memory, start: 40, end: 44, name: "루프")])
        #expect(library.skipped.isEmpty)
    }

    @Test func 모르는_칸과_모양은_건너뛰고_센다() throws {
        let library = try read(document(tracks: """
            <TRACK TrackID="1" Name="a" Year="몰라" Colour="0xFF0000" Location="file://localhost/a.mp3">
              <TEMPO Inizio="0.1" Bpm="120" Metro="3/4" Battito="1"/>
              <POSITION_MARK Name="" Type="1" Start="1.0" Num="-1"/>
              <POSITION_MARK Name="" Type="0" Start="2.0" Num="9"/>
              <POSITION_MARK Name="" Type="0" Start="x" Num="0"/>
              <POSITION_MARK Name="" Type="0" Start="3.0" Num="1"/>
              <EXTRA/>
            </TRACK>
            <TRACK TrackID="2" Name="b" Location="apple-music:track:1">
              <TEMPO Inizio="0.1" Bpm="120" Metro="4/4" Battito="1"/>
              <TEMPO Inizio="z" Bpm="120" Metro="4/4" Battito="1"/>
            </TRACK>
            """, playlists: """
            <NODE Type="0" Name="ROOT" Count="2">
              <NODE Name="L" Type="1" KeyType="0" Entries="2"><TRACK Key="1"/><TRACK Key="99"/></NODE>
              <NODE Name="이상한" Type="7"><NODE Name="안" Type="1" KeyType="0" Entries="0"/></NODE>
            </NODE>
            """))
        let first = library.tracks[0]
        #expect(first.tags[.year] == nil, "숫자가 아닌 연도는 읽지 않는다")
        #expect(first.tempos.isEmpty, "4/4가 아닌 그리드는 읽지 않는다")
        #expect(first.marks == [XMLLibrary.Mark(kind: .hot(1), start: 3, name: "")])
        #expect(library.tracks[1].path == nil)
        #expect(library.tracks[1].tempos.isEmpty, "읽지 못한 TEMPO가 있으면 그 곡 그리드는 통째로 읽지 않는다")
        #expect(library.lists == [XMLLibrary.Node(name: "L", entries: ["1"])])
        #expect(library.skipped == [.invalidValue: 3, .unverifiedColour: 1, .unsupportedMeter: 1, .unknownMarkType: 1,
                                    .hotCueOutOfRange: 1, .unknownElement: 1, .nonFileLocation: 1, .missingTrackReference: 1,
                                    .unknownNodeType: 1])
    }

    @Test func 곡마다_읽지_못한_위치_표시와_곡_길이를_담는다() throws {
        let library = try read(document(tracks: """
            <TRACK TrackID="1" Name="a" TotalTime="215" Location="file://localhost/a.mp3">
              <POSITION_MARK Name="" Type="1" Start="1.0" Num="-1"/>
              <POSITION_MARK Name="" Type="0" Start="2.0" Num="9"/>
              <POSITION_MARK Name="" Type="0" Start="x" Num="0"/>
              <POSITION_MARK Name="" Type="0" Start="3.0" Num="1"/>
            </TRACK>
            <TRACK TrackID="2" Name="b" Location="file://localhost/b.mp3"/>
            """))
        // 큐·루프가 아닌 표시(Type 1)는 큐 비교에 들지 않으니 세지 않는다
        #expect(library.tracks[0].unreadableMarks == 2 && library.tracks[0].duration == 215)
        #expect(library.tracks[1].unreadableMarks == 0 && library.tracks[1].marks.isEmpty && library.tracks[1].duration == nil)
    }

    @Test func 범위_밖_박_번호는_읽지_못한_값이고_그_곡_그리드는_읽지_않는다() throws {
        let library = try read(document(tracks: """
            <TRACK TrackID="1" Name="a" Location="file://localhost/a.mp3">
              <TEMPO Inizio="0.1" Bpm="120" Metro="4/4" Battito="7"/>
            </TRACK>
            """))
        #expect(library.tracks[0].tempos.isEmpty)
        #expect(library.skipped == [.invalidValue: 1])
    }

    @Test func 같은_TrackID가_둘이면_세고_두_곡_모두_모호하다() throws {
        let library = try read(document(tracks: """
            <TRACK TrackID="5" Name="a" Location="file://localhost/a.mp3"><POSITION_MARK Name="" Type="0" Start="10.0" Num="0"/></TRACK>
            <TRACK TrackID="5" Name="b" Location="file://localhost/b.mp3"><POSITION_MARK Name="" Type="0" Start="20.0" Num="0"/></TRACK>
            """, playlists: """
            <NODE Type="0" Name="ROOT" Count="1">
              <NODE Name="L" Type="1" KeyType="0" Entries="1"><TRACK Key="5"/></NODE>
            </NODE>
            """))
        #expect(library.skipped == [.duplicateTrackID: 1])
        let current = XMLLibrary(tracks: [.init(key: "LA", path: "/a.mp3", tags: [.title: "a"], marks: [.init(kind: .hot(0), start: 10, name: "")]),
                                          .init(key: "LB", path: "/b.mp3", tags: [.title: "b"], marks: [.init(kind: .hot(0), start: 20, name: "")])])
        let diff = XMLLibraryDiff.compute(xml: library, library: current)
        #expect(diff.tracks.isEmpty && diff.matches.matched.isEmpty && diff.matching.ambiguous == 2)
        #expect(diff.playlists.first?.unmatchedEntries == 1)
    }

    @Test func 위치로_적은_목록_항목도_읽는다() throws {
        let library = try read(document(tracks: """
            <TRACK TrackID="1" Name="a" Location="file://localhost/Music/a%20b.mp3"/>
            """, playlists: """
            <NODE Type="0" Name="ROOT" Count="1">
              <NODE Name="F" Type="0" Count="1">
                <NODE Name="L" Type="1" KeyType="1" Entries="2"><TRACK Key="file://localhost/Music/a%20b.mp3"/><TRACK Key="file://localhost/x.mp3"/></NODE>
              </NODE>
            </NODE>
            """))
        #expect(library.lists == [XMLLibrary.Node(name: "F", children: [XMLLibrary.Node(name: "L", entries: ["1"])])])
        #expect(library.skipped == [.missingTrackReference: 1])
    }

    @Test func rekordbox_XML이_아니면_이유와_함께_막는다() throws {
        #expect(throws: RekordboxXMLReader.ReadError.self) { try read("<plist/>") }
        #expect(throws: RekordboxXMLReader.ReadError.self) { try read("<DJ_PLAYLISTS><COLLECTION>") }
    }

    @Test func 파일에서_흘려_읽는다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "xml-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = (1...2000).map { #"<TRACK TrackID="\#($0)" Name="곡 \#($0)" Location="file://localhost/m/\#($0).mp3"/>"# }
        let file = folder.appending(path: "big.xml")
        try Data(document(tracks: rows.joined(separator: "\n")).utf8).write(to: file)
        let library = try RekordboxXMLReader.read(url: file)
        #expect(library.tracks.count == 2000 && library.tracks.last?.path == "/m/2000.mp3")
    }

    // MARK: 내보내기 → 가져오기

    @Test func 내보낸_XML을_다시_읽으면_차이가_없다() throws {
        let fixture = try RekordboxLibraryXMLTests().makeLibrary()
        let collection = try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        let exported = try read(RekordboxLibraryXML.document(collection))
        let library = RekordboxXMLImport.library(from: collection, hasGrids: true)
        let diff = XMLLibraryDiff.compute(xml: exported, library: library)
        #expect(diff.isEmpty, "\(diff.tracks) \(diff.playlists)")
        #expect(diff.matching == .init(xmlTracks: 3, matched: 3, unmatched: 0, ambiguous: 0))
        #expect(exported.skipped.isEmpty)
        // 라이브러리 쪽 목록에는 ID가 있다(초안을 만들 때 쓴다)
        #expect(library.lists.first?.id == "p3")
    }

    @Test func 분석_파일은_XML에_TEMPO가_있는_곡만_읽는다() throws {
        let fixture = try RekordboxLibraryXMLTests().makeLibrary()
        let collection = try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        let full = try read(RekordboxLibraryXML.document(collection))
        let withGrid = Set(full.tracks.filter { !$0.tempos.isEmpty }.map(\.path))
        #expect(!withGrid.isEmpty)
        let stripped = try read(RekordboxLibraryXML.document(collection)
            .replacingOccurrences(of: #"<TEMPO [^>]*/>"#, with: "", options: .regularExpression))
        let none = try RekordboxXMLImport.library(snapshot: fixture.database, shareRoot: fixture.shareRoot, gridsFor: stripped)
        #expect(none.tracks.allSatisfy { $0.tempos.isEmpty })
        let some = try RekordboxXMLImport.library(snapshot: fixture.database, shareRoot: fixture.shareRoot, gridsFor: full)
        #expect(Set(some.tracks.filter { !$0.tempos.isEmpty }.map(\.path)) == withGrid)
        #expect(some.tracks.allSatisfy { $0.duration != nil })
    }

    @Test func 라이브러리를_읽어_고친_XML과_비교한다() throws {
        let fixture = try RekordboxLibraryXMLTests().makeLibrary()
        let collection = try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        var xml = RekordboxLibraryXML.document(collection)
        xml = xml.replacingOccurrences(of: #"Start="20.000" Num="0""#, with: #"Start="21.000" Num="0""#)
        xml = xml.replacingOccurrences(of: #"Name="변속 곡""#, with: #"Name="새 이름""#)
        xml = xml.replacingOccurrences(of: #"<TEMPO Inizio="0.025" Bpm="174.50""#, with: #"<TEMPO Inizio="0.030" Bpm="174.50""#)
        let library = try RekordboxXMLImport.library(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        let diff = XMLLibraryDiff.compute(xml: try read(xml), library: library)
        #expect(diff.counts.cueTracks == 1 && diff.counts.tagTracks == 1 && diff.counts.gridTracks == 1)
        #expect(diff.tracks.map(\.libraryKey) == ["101", "104"])
        #expect(diff.tracks[1].tags == [.init(key: .title, library: "변속 곡", xml: "새 이름")])
    }
}
