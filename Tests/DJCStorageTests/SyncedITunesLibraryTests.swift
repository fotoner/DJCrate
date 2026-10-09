import DJCDomain
@testable import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("iTunes 동기화 목록 읽기")
struct SyncedITunesLibraryTests {
    typealias Playlist = ITunesLibrarySnapshot.Playlist

    @Test func DB를_바꾸지_않는_동기화_선택도_변경을_감지한다() throws {
        let fixture = try RekordboxFixture()
        let sync = fixture.root.appending(path: "playlists3.sync")
        let original = Data("before".utf8)
        try original.write(to: sync)
        #expect(!RekordboxITunesReader.selectionChanged(since: original, directory: fixture.root))
        try Data("after".utf8).write(to: sync)
        #expect(RekordboxITunesReader.selectionChanged(since: original, directory: fixture.root))
        try FileManager.default.removeItem(at: sync)
        #expect(RekordboxITunesReader.selectionChanged(since: original, directory: fixture.root))
        #expect(!RekordboxITunesReader.selectionChanged(since: nil, directory: fixture.root))
    }

    @Test func 빈_환경값은_실제_재정의가_아니다() {
        #expect(!LibrarySnapshot.hasRekordboxDirectoryOverride(in: [:]))
        #expect(!LibrarySnapshot.hasRekordboxDirectoryOverride(in: ["DJC_REKORDBOX_DIR": ""]))
        #expect(LibrarySnapshot.hasRekordboxDirectoryOverride(in: ["DJC_REKORDBOX_DIR": "/synthetic/copy"]))
    }

    func selection(_ nodes: String) throws -> RekordboxITunesSelection {
        try RekordboxITunesSelection.parse(Data("<SYNC_ITUNES_PLAYLIST><PLAYLISTS>\(nodes)</PLAYLISTS></SYNC_ITUNES_PLAYLIST>".utf8))
    }

    @Test func 동기화_선택과_조상만_보존하고_동명_목록과_빈_목록을_구분한다() throws {
        let selected = try selection("""
            <NODE Id="A" ParentId="F" Attribute="0" Lib_Type="1" CheckType="1"/>
            <NODE Id="B" ParentId="F" Attribute="0" Lib_Type="1" CheckType="1"/>
            """)
        let source = [Playlist(id: "F", name: "폴더", isFolder: true),
                      Playlist(id: "C", name: "선택 안 함"),
                      Playlist(id: "A", name: "동명", parentID: "F", paths: ["/a", "/b"]),
                      Playlist(id: "B", name: "동명", parentID: "F")]
        let snapshot = try ITunesLibrarySnapshot.select(selected, from: source)
        #expect(snapshot.playlists.map(\.id) == ["F", "A", "B"])
        #expect(snapshot.playlists[1].paths == ["/a", "/b"])
        #expect(snapshot.playlists[2].paths.isEmpty)
        #expect(try ITunesLibrarySnapshot.select(selection(""), from: source).playlists.isEmpty)
    }

    @Test func 파일_경로로_기존_곡에_연결하고_삭제와_모호한_경로를_제외한다() throws {
        let fixture = try RekordboxFixture()
        for (id, path) in [("1", "/음악/한글.mp3"), ("2", "/b.mp3"), ("3", "/dup.mp3"), ("4", "/dup.mp3"), ("5", "/gone.mp3")] {
            var track = TrackSpec(id: id)
            track.folderPath = path
            try fixture.add(track)
        }
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted=1 WHERE ID='5'")
        let library = try RekordboxLibrary.load(snapshot: fixture.database)
        let snapshot = ITunesLibrarySnapshot(playlists: [
            Playlist(id: "F", name: "폴더", isFolder: true),
            Playlist(id: "A", name: "순서", parentID: "F", paths: ["/b.mp3", "/음악/한글.mp3".decomposedStringWithCanonicalMapping,
                                                                   "/b.mp3", "/dup.mp3", "/gone.mp3", nil]),
        ])
        let view = SyncedITunesLibrary(snapshot: snapshot, tracks: library.allTracks)
        #expect(view.tree.first?.children?.first?.trackIDs == ["2", "1", "2"])
        #expect(view.tree.first?.trackIDs == ["2", "1"])
        #expect(view.tree.first?.children?.first?.unavailableTrackCount == 3)
        #expect(view.tree.first?.children?.first?.unlinked.map(\.reason) == [.ambiguous, .notInCollection, .noLocalFile])
        #expect(view.index["itunes:A"]?.name == "순서")
    }

    @Test func 누락된_선택은_알리고_순환_계층은_거부한다() throws {
        let selected = try selection("<NODE Id='A' ParentId='0' Attribute='0' Lib_Type='1' CheckType='1'/>")
        #expect(try ITunesLibrarySnapshot.select(selected, from: []).unavailablePlaylistCount == 1)
        #expect(throws: (any Error).self) {
            try ITunesLibrarySnapshot.select(selected, from: [Playlist(id: "A", name: "순환", parentID: "B", isFolder: true),
                                                              Playlist(id: "B", name: "순환", parentID: "A", isFolder: true)])
        }
    }

    @Test func 스냅샷_옆의_사본만_읽고_원본_변경을_섞지_않는다() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-itunes-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appending(path: "master.db")
        #expect(ITunesLibrarySnapshot.load(for: db).status == .notCaptured)
        let snapshot = ITunesLibrarySnapshot(playlists: [Playlist(id: "A", name: "사본", paths: ["/a"])])
        try snapshot.save(for: db)
        #expect(ITunesLibrarySnapshot.load(for: db).playlists == snapshot.playlists)
        try Data("broken".utf8).write(to: ITunesLibrarySnapshot.url(for: db))
        #expect(ITunesLibrarySnapshot.load(for: db).status == .unavailable)
    }

    @Test func XML_방식도_폴더와_곡_순서를_보존한다() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Tracks": ["1": ["Location": "file://localhost/a%20b.mp3"], "2": ["Location": "https://example.com/stream"]],
            "Playlists": [["Playlist Persistent ID": "F", "Name": "폴더", "Folder": true],
                          ["Playlist Persistent ID": "A", "Name": "곡", "Parent Persistent ID": "F", "Playlist Items": [["Track ID": 2], ["Track ID": 1], ["Track ID": 3]]]],
        ], format: .xml, options: 0)
        let lists = try ITunesLibrarySnapshot.parseLibraryXML(data)
        #expect(lists[0].isFolder)
        #expect(lists[1].parentID == "F")
        #expect(lists[1].paths == [nil, "/a b.mp3", nil])
    }

    @Test func 루트_ID를_실제_폴더로_받아_재귀하지_않는다() {
        #expect(throws: (any Error).self) {
            try ITunesLibrarySnapshot.validate([Playlist(id: "0", name: "루트", isFolder: true)])
        }
    }

    @Test func XML_읽기_설정을_따르고_모르는_설정에서는_전체_목록을_읽지_않는다() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-itunes-source-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appending(path: "settings.xml"), xml = directory.appending(path: "music.xml")
        try Data("<SYNC_ITUNES_PLAYLIST><PLAYLISTS><NODE Id='A' ParentId='0' Attribute='0' Lib_Type='1' CheckType='1'/></PLAYLISTS></SYNC_ITUNES_PLAYLIST>".utf8)
            .write(to: directory.appending(path: "playlists3.sync"))
        let library: [String: Any] = ["Tracks": [String: String](), "Playlists": [["Playlist Persistent ID": "A", "Name": "선택"], ["Playlist Persistent ID": "B", "Name": "제외"]]]
        try PropertyListSerialization.data(fromPropertyList: library, format: .xml, options: 0).write(to: xml)
        try Data("<PROPERTIES><VALUE name='MusicAppLoadingType' val='0'/><VALUE name='itunesLibraryFile' val='\(xml.path)'/></PROPERTIES>".utf8).write(to: settings)
        let snapshot = RekordboxITunesReader.capture(directory: directory, settings: settings)
        #expect(snapshot.status == .ready && snapshot.playlists.map(\.name) == ["선택"])
        #expect(snapshot.sourcePlaylists?.map(\.name) == ["선택", "제외"])
        try FileManager.default.removeItem(at: directory.appending(path: "playlists3.sync"))
        let unselected = RekordboxITunesReader.capture(directory: directory, settings: settings)
        #expect(unselected.status == .ready && unselected.playlists.isEmpty)
        #expect(unselected.sourcePlaylists?.count == 2)
        for values in ["<VALUE name='MusicAppLoadingType' val='unknown'/>",
                       "<VALUE name='MusicAppLoadingType' val='0'/>", ""] {
            try Data("<PROPERTIES>\(values)</PROPERTIES>".utf8).write(to: settings)
            #expect(RekordboxITunesReader.capture(directory: directory, settings: settings).status == .unavailable)
        }
    }

    /// 10진·16진 숫자참조 하나씩(같은 금지 문자 판정을 지난다)
    @Test(arguments: ["&#2;", "&#x05;"], [false, true])
    func 무관한_설정의_금지_숫자참조는_XML_목록_읽기를_막지_않는다(reference: String, inName: Bool) throws {
        let fixture = try RekordboxFixture()
        let settings = fixture.root.appending(path: "settings.xml")
        let xml = fixture.root.appending(path: "음악 & 목록.xml")
        let library: [String: Any] = ["Tracks": [String: String](), "Playlists": [["Playlist Persistent ID": "A", "Name": "합성 목록"]]]
        try PropertyListSerialization.data(fromPropertyList: library, format: .xml, options: 0).write(to: xml)
        let sync = fixture.root.appending(path: "playlists3.sync")
        try Data("<SYNC_ITUNES_PLAYLIST><PLAYLISTS><NODE Id='A' ParentId='0' Attribute='0' Lib_Type='1' CheckType='1'/></PLAYLISTS></SYNC_ITUNES_PLAYLIST>".utf8).write(to: sync)
        let original = Data("""
            <PROPERTIES><VALUE name="MusicAppLoadingType" val="0"/>
            <VALUE val='\(inName ? "unchanged" : reference)' name='unrelated\(inName ? reference : "")'/>
            <VALUE name="itunesLibraryFile" val="\(xml.path.replacingOccurrences(of: "&", with: "&amp;"))"/>
            <VALUE name="another\(inName ? reference : "")" val="\(inName ? "unchanged" : reference)"/></PROPERTIES>
            """.utf8)
        try Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: reference, with: "").utf8).write(to: settings)
        #expect(RekordboxITunesReader.capture(directory: fixture.root, settings: settings).status == .ready)
        try original.write(to: settings)
        let before = try [settings, sync, xml, fixture.database].map { try Data(contentsOf: $0) }
        let snapshot = RekordboxITunesReader.capture(directory: fixture.root, settings: settings)
        #expect(snapshot.status == .ready)
        #expect(snapshot.playlists.map(\.name) == ["합성 목록"])
        #expect(try [settings, sync, xml, fixture.database].map { try Data(contentsOf: $0) } == before)
    }

    @Test(arguments: [
        "<VALUE name='unrelated' val='&#2;'/>",
        "<VALUE name='MusicAppLoadingType' val='0&#2;'/>",
        "<VALUE name='MusicAppLoadingType&#5;' val='0'/>",
        "<VALUE name='MusicAppLoadingTyp&#101;' val='0&#2;'/>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='unrelated' name='itunesLibraryFile' val='&#2;'/>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='itunesLibraryFile' val='/a&#x05;b'/>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='unrelated' val='&#2;'></BROKEN>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='unrelated' val='&am&#2;p;'/>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='unrelated' val='&&#5;#48;'/>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='MusicAppLoadingType&#5;' val='1'/>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='MusicAppLoadingTyp&#101;&#2;' val='1'/>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='itunesLibrary&#2;File' val='/synthetic.xml'/>",
        "<VALUE name='MusicAppLoadingType' val='0'/><VALUE name='unrelated&am&#2;p;' val='ok'/>",
    ])
    func 필수_설정_손상과_깨진_구조는_복구하지_않는다(values: String) {
        #expect(throws: (any Error).self) {
            try RekordboxITunesReader.configuration(Data("<PROPERTIES>\(values)</PROPERTIES>".utf8))
        }
    }

    @Test func 정상_참조와_경로를_보존하고_외부_엔티티는_받지_않는다() throws {
        let config = try RekordboxITunesReader.configuration(Data("""
            <PROPERTIES><!-- <VALUE name='unrelated' val='&#2;'/> -->
            <VALUE name='MusicAppLoadingTyp&#101;' val='&#48;'/>
            <VALUE name='itunesLibraryFile' val='/음악/A&amp;B&quot;&apos;&#x20;목록.xml'/>
            <VALUE name='unrelated' val='&#9;&#10;&#13;&#32;'/></PROPERTIES>
            """.utf8))
        #expect(config.method == "0")
        #expect(config.xmlPath == "/음악/A&B\"' 목록.xml")
        #expect(throws: (any Error).self) {
            try RekordboxITunesReader.configuration(Data("""
                <!DOCTYPE PROPERTIES [<!ENTITY external SYSTEM 'file:///nonexistent-synthetic-settings'>]>
                <PROPERTIES><VALUE name='MusicAppLoadingType' val='&external;'/></PROPERTIES>
                """.utf8))
        }
    }

    @Test func 오래된_DB를_정리할_때_iTunes_사본도_정리한다() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-itunes-prune-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appending(path: "master-2026-01-01T000000.db"), latest = directory.appending(path: "master-2026-01-02T000000.db")
        for db in [old, latest] { try Data().write(to: db); try ITunesLibrarySnapshot().save(for: db) }
        LibrarySnapshot.prune(keeping: 1, in: directory)
        #expect(!FileManager.default.fileExists(atPath: ITunesLibrarySnapshot.url(for: old).path))
        #expect(FileManager.default.fileExists(atPath: ITunesLibrarySnapshot.url(for: latest).path))
    }

    @Test func 사본을_다시_뜰_때_목록도_복사하고_같은_초의_낡은_목록은_남기지_않는다() throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "snapshots")
        let lists = ITunesLibrarySnapshot(playlists: [Playlist(id: "A", name: "함께 복사")])
        try lists.save(for: fixture.database)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true, now: now)
        #expect(ITunesLibrarySnapshot.load(for: first).playlists == lists.playlists)
        try FileManager.default.removeItem(at: ITunesLibrarySnapshot.url(for: fixture.database))
        try lists.save(for: first)
        let second = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true, now: now)
        #expect(ITunesLibrarySnapshot.load(for: second).status == .notCaptured)
    }
}
