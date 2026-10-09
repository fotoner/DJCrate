import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 합성 USB 모델(모든 값은 지어낸 것). 곡 1·2·3, 곡 2만 쓰는 아티스트·앨범·그림, 폴더 1·목록 2.
enum WriterSamples {
    static func track(_ id: Int, artist: Int, album: Int?, image: Int?, formats: Set<UsbFormat> = [.oneLibrary]) -> UsbTrack {
        var track = UsbTrack(id: id)
        track.presentIn = formats
        track.title = "시험 곡 \(id)"
        track.bpmx100 = 12800 + id
        track.lengthSeconds = 200 + id
        track.artistID = artist
        track.composerID = id == 1 ? 3 : nil
        track.lyricistArtistID = 0
        track.albumID = album
        track.genreID = 1
        track.keyID = id == 3 ? 2 : 1
        track.colorID = id
        track.imageID = image
        track.comment = id == 1 ? "시험 코멘트" : ""
        track.releaseDate = "2020-01-0\(id)"
        track.dateCreated = "2026-01-01"
        track.dateAdded = "2026-01-02"
        track.path = "/Contents/시험 아티스트/시험 앨범/test\(id).mp3"
        track.fileName = "test\(id).mp3"
        track.fileSize = Int64(1_000 + id)
        track.fileType = 1
        track.bitrate = 320
        track.bitDepth = 16
        track.sampleRate = 44100
        track.isrc = ""
        track.hotCueAutoLoad = true
        track.masterDbId = 424_242
        track.masterContentId = Int64(900_000 + id)
        track.analysisDataPath = String(format: "/PIONEER/USBANLZ/P000/%08X/ANLZ0000.DAT", id)
        track.analysedBits = 105
        track.contentLink = 0x0C0700
        track.cueUpdateCount = "3"
        track.analysisDataUpdateCount = ""
        track.informationUpdateCount = "5"
        track.deviceFields = Dictionary(uniqueKeysWithValues: formats.map {
            ($0, UsbTrackDeviceFields(rating: 0, playCount: 0, hasModified: $0 == .oneLibrary ? 0 : nil))
        })
        return track
    }

    static func model(formats: Set<UsbFormat> = [.oneLibrary]) -> UsbLibrary {
        func perFormat<T>(_ value: T) -> [UsbFormat: T] { Dictionary(uniqueKeysWithValues: formats.map { ($0, value) }) }
        var library = UsbLibrary(formats: formats, property: UsbProperty(
            deviceName: "", dbVersion: "1000", numberOfContents: 3, createdDate: "2026-09-01", backgroundColorType: 0,
            myTagMasterDBID: 4_000_000_000))
        library.tracks = [
            track(1, artist: 1, album: 1, image: 1, formats: formats),
            track(2, artist: 2, album: 2, image: 2, formats: formats),
            track(3, artist: 1, album: 1, image: 3, formats: formats),
        ]
        library.artists = [UsbNamedRow(id: 1, name: "시험 아티스트"), UsbNamedRow(id: 2, name: "시험 아티스트 2"),
                           UsbNamedRow(id: 3, name: "시험 작곡가")]
        library.albums = [UsbAlbum(id: 1, name: "시험 앨범", artistID: 1), UsbAlbum(id: 2, name: "시험 앨범 2", artistID: 2, isCompilation: 1)]
        library.genres = [UsbNamedRow(id: 1, name: "시험 장르")]
        library.keys = [UsbNamedRow(id: 1, name: "1A"), UsbNamedRow(id: 2, name: "2A")]
        library.colors = RekordboxFixture.defaultColorNames.enumerated().map { UsbNamedRow(id: $0.offset + 1, name: $0.element) }
        library.images = (1...3).map { id in
            UsbImage(id: id, oneLibraryPath: formats.contains(.oneLibrary) ? UsbArtworkLayout.oneLibraryPath(imageID: id, folder: 1) : nil,
                     pdbPath: formats.contains(.deviceLibrary) ? UsbArtworkLayout.pdbPath(imageID: id, folder: 1) : nil)
        }
        library.playlists = [
            UsbPlaylist(id: 10, name: "시험 폴더", parentID: 0, attribute: 1, presentIn: formats, sortOrder: perFormat(0), entries: perFormat([])),
            UsbPlaylist(id: 11, name: "시험 목록 1", parentID: 10, attribute: 0, presentIn: formats, sortOrder: perFormat(0),
                        entries: perFormat([1, 2, 3])),
            UsbPlaylist(id: 12, name: "시험 목록 2", parentID: 0, attribute: 0, presentIn: formats, sortOrder: perFormat(1),
                        entries: perFormat([3, 1, 3])),
        ]
        library.myTags = [UsbMyTag(id: 5_000_000_001, parentID: 0, sequenceNo: 0, name: "시험 분류", isCategory: true),
                          UsbMyTag(id: 5_000_000_002, parentID: 5_000_000_001, sequenceNo: 0, name: "시험 태그", isCategory: false)]
        library.menuItems = [UsbMenuItem(id: 1, kind: 257, name: "Genre"), UsbMenuItem(id: 2, kind: 258, name: "Artist"),
                             UsbMenuItem(id: 3, kind: 259, name: "Album")]
        library.categories = [UsbCategory(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true),
                              UsbCategory(id: 2, menuItemID: 2, sequenceNo: 2, isVisible: false)]
        library.sorts = [UsbSort(id: 0, menuItemID: 3, sequenceNo: 0, isVisible: true, isSelectedAsSubColumn: false),
                         UsbSort(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, isSelectedAsSubColumn: true)]
        return library.canonicalized()
    }

    /// 두 형식을 합친 모델: pdb 전용 값, Device Library에만 있는 목록, 형식마다 항목이 다른 목록
    static func merged() -> UsbLibrary {
        var library = model(formats: UsbFormat.defaultSet)
        library.tracks[0].lyricist = "시험 작사"
        library.categories[0].infoOrder = 2
        library.categories[0].disable = 1
        library.sorts[1].disable = 2
        library.property.pdbDate = "2026-09-01"
        library.playlists[2].entries[.deviceLibrary] = [3, 1]
        library.playlists.append(UsbPlaylist(id: 13, name: "시험 기기 목록", parentID: 0, attribute: 0, presentIn: [.deviceLibrary],
                                             sortOrder: [.deviceLibrary: 2], entries: [.deviceLibrary: [2]]))
        return library.canonicalized()
    }
}

/// 한 시험 동안만 있는 폴더
final class TemporaryFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "djc-onelib-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var database: URL { url.appending(path: "exportLibrary.db") }
    func contents() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }
}

/// 단계 클로저가 받은 모델을 시험이 보려고 담는다
final class ModelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UsbLibrary] = []
    func append(_ library: UsbLibrary) { lock.withLock { stored.append(library) } }
    var all: [UsbLibrary] { lock.withLock { stored } }
}

@Suite("OneLibrary 작성")
struct OneLibraryWriterTests {
    /// 읽기 연결도 쓰기 가능하게 열고 query_only로 막는다. 읽기 전용 연결은 WAL 모양 파일 옆에 -wal·-shm을 남긴다
    static func open(_ url: URL, _ mode: OpenMode = .readOnly) throws -> CipherDatabase {
        let db = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: mode == .readOnly ? .readWrite : mode)
        if mode == .readOnly { try db.execute("PRAGMA query_only = ON") }
        return db
    }

    static func read(_ url: URL) throws -> UsbLibrary {
        let db = try open(url)
        defer { db.close() }
        return try OneLibraryReader.read(connection: db)
    }

    /// 표 전체를 rowid 순으로 (rowid, typeof·quote 칸…)
    static func dump(_ url: URL, _ table: String) throws -> [[String]] {
        let db = try open(url)
        defer { db.close() }
        guard let columns = OneLibrarySchema.table(named: table)?.columns.map(\.name) else { return [] }
        var rows: [[String]] = []
        let select = (["rowid"] + columns.flatMap { ["typeof(\($0))", "quote(\($0))"] }).joined(separator: ", ")
        try db.query("SELECT \(select) FROM \(table) ORDER BY rowid") { row in
            rows.append((0..<row.count).map { row.string(Int32($0)) ?? "NULL" })
        }
        return rows
    }

    static func rows(_ url: URL, _ sql: String) throws -> [[String]] {
        let db = try open(url)
        defer { db.close() }
        var rows: [[String]] = []
        try db.query(sql) { row in rows.append((0..<row.count).map { row.string(Int32($0)) ?? "NULL" }) }
        return rows
    }

    static func differences(_ url: URL, _ expected: UsbLibrary) throws -> [UsbLibraryDiff.Difference] {
        let reread = try read(url)
        return UsbLibraryDiff.compare(reread, expected.projected(to: .oneLibrary), options: .init(formats: [.oneLibrary])).differences
    }

    /// 한 편집 단계
    static func step(_ id: Int, _ edit: @escaping @Sendable (inout UsbLibrary) throws -> Void) -> OneLibraryEditStep {
        OneLibraryEditStep(id: id) { library in
            var library = library
            try edit(&library)
            return library.canonicalized()
        }
    }

    struct StepFailure: Error {}

    // MARK: - 만들기

    @Test("스키마 = 시험 리소스(sqlite_master.sql 글자 그대로)")
    func schemaEqualsResource() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        let sql = try Self.rows(folder.database, "SELECT sql FROM sqlite_master ORDER BY rowid").map { $0[0] }
        #expect(sql == (try OneLibraryFixture.resourceStatements()))
        let db = try Self.open(folder.database)
        defer { db.close() }
        try OneLibraryCompatibility.check(db)
    }

    @Test("WAL 모양(journal_mode = wal)이고 -wal·-shm이 남지 않는다")
    func headerWalAndNoSidecars() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        #expect(try folder.contents() == ["exportLibrary.db"])
        #expect(try Self.rows(folder.database, "PRAGMA journal_mode") == [["wal"]])
        #expect(try OneLibraryWriter.verify(folder.database, expected: WriterSamples.model()) == [])
        #expect(try folder.contents() == ["exportLibrary.db"])
    }

    @Test("무결성 검사 통과, 사이드카가 있으면 문제로 보고")
    func integrityOK() throws {
        let folder = try TemporaryFolder()
        let model = WriterSamples.model()
        try OneLibraryWriter.create(model, at: folder.database)
        #expect(try Self.rows(folder.database, "PRAGMA integrity_check") == [["ok"]])
        #expect(try Self.rows(folder.database, "PRAGMA cipher_integrity_check").isEmpty)
        #expect(try OneLibraryWriter.verify(folder.database, expected: model) == [])

        let journal = URL(filePath: folder.database.path + "-journal")
        try Data().write(to: journal)
        #expect(try OneLibraryWriter.verify(folder.database, expected: model).isEmpty == false)
        try FileManager.default.removeItem(at: journal)
        // 모델과 다르면 문제
        var other = model
        other.tracks[0].title = "다른 제목"
        #expect(try OneLibraryWriter.verify(folder.database, expected: other).isEmpty == false)
    }

    @Test("이미 있는 파일에는 만들지 않는다")
    func createRefusesExistingFile() throws {
        let folder = try TemporaryFolder()
        try Data("x".utf8).write(to: folder.database)
        #expect(throws: (any Error).self) { try OneLibraryWriter.create(WriterSamples.model(), at: folder.database) }
        #expect(try Data(contentsOf: folder.database) == Data("x".utf8))
    }

    @Test("기기 기록이 든 모델은 만들지 않는다")
    func createRefusesDeviceRows() throws {
        let folder = try TemporaryFolder()
        var model = WriterSamples.model()
        model.histories = [UsbHistory(format: .oneLibrary, id: 1, name: "시험 기록", entries: [1])]
        #expect(throws: UsbError.self) { try OneLibraryWriter.create(model, at: folder.database) }
        #expect(try folder.contents().isEmpty)
    }

    @Test("큐·기록·추천·핫큐 뱅크·My Tag 연결 표는 비운다(로컬에 큐가 있어도)")
    func emptyTablesEmpty() throws {
        let fixture = try RekordboxFixture()
        let track = try UsbLibraryBuilderTests.addTrack(fixture, id: "101")
        try fixture.addCue(track: track, kind: 1, inMsec: 1_000)
        try fixture.addCue(track: track, kind: 0, inMsec: 2_000)
        let model = try UsbLibraryBuilderTests.build(fixture, ids: ["101"]).model.library
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(model, at: folder.database)
        for table in ["cue", "history", "history_content", "recommendedLike", "hotCueBankList", "hotCueBankList_cue", "myTag_content"] {
            #expect(try Self.rows(folder.database, "SELECT count(*) FROM \(table)") == [["0"]], "\(table)")
        }
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM content") == [["1"]])
    }

    @Test("목록: 형제 순번은 모델 값(새 USB 0부터), 항목은 1부터, rowid는 목록·순번 순서")
    func playlistRowsSiblingZeroEntriesOneBased_rowidOrder() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        #expect(try Self.rows(folder.database, "SELECT playlist_id, sequenceNo, image_id FROM playlist ORDER BY rowid")
            == [["10", "0", "NULL"], ["11", "0", "NULL"], ["12", "1", "NULL"]])
        #expect(try Self.rows(folder.database, "SELECT rowid, playlist_id, content_id, sequenceNo FROM playlist_content ORDER BY rowid") == [
            ["1", "11", "1", "1"], ["2", "11", "2", "2"], ["3", "11", "3", "3"],
            ["4", "12", "3", "1"], ["5", "12", "1", "2"], ["6", "12", "3", "3"],
        ])
    }

    @Test("폴더는 attribute 1, 맨 위 부모는 0")
    func folderAttribute1() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        #expect(try Self.rows(folder.database, "SELECT playlist_id, attribute, playlist_id_parent FROM playlist ORDER BY playlist_id")
            == [["10", "1", "0"], ["11", "0", "10"], ["12", "0", "0"]])
    }

    @Test("property 한 행: dbVersion '1000', deviceName '', 배경 0, myTagMasterDBID 그대로")
    func propertyRow() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        #expect(try Self.rows(folder.database, """
            SELECT quote(deviceName), quote(dbVersion), numberOfContents, quote(createdDate), backGroundColorType, myTagMasterDBID FROM property
            """) == [["''", "'1000'", "3", "'2026-09-01'", "0", "4000000000"]])
    }

    @Test("My Tag ID는 64비트 그대로")
    func myTag64BitID() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        #expect(try Self.rows(folder.database, "SELECT myTag_id, sequenceNo, attribute, myTag_id_parent FROM myTag ORDER BY rowid")
            == [["5000000001", "0", "1", "0"], ["5000000002", "0", "0", "5000000001"]])
        #expect(try Self.rows(folder.database, "SELECT rowid FROM myTag ORDER BY rowid") == [["5000000001"], ["5000000002"]])
    }

    @Test("메뉴 이름은 U+FFFA·U+FFFB로 감싼다")
    func menuNameWrapped() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        #expect(try Self.rows(folder.database, "SELECT name FROM menuItem WHERE menuItem_id = 1") == [["\u{FFFA}Genre\u{FFFB}"]])
    }

    @Test("다시 읽은 모델 = 빌더 모델의 OneLibrary 투영")
    func readBackEqualsModel() throws {
        let fixture = try RekordboxFixture()
        try fixture.addColorDefaults()
        try fixture.addMenuDefaults()
        try fixture.addCategory(id: "1", menuItemID: "1", seq: 1, disable: 1, infoOrder: 3)
        try fixture.addSort(id: "0", menuItemID: "2", seq: 0, disable: 2)
        try fixture.addMyTag(id: "5000000001", name: "시험 분류", seq: 1, attribute: 1)
        try fixture.addArtist(id: "1", name: "시험 아티스트")
        try fixture.addAlbum(id: "30", name: "시험 앨범", albumArtistID: "1")
        let first = try UsbLibraryBuilderTests.addTrack(fixture, id: "101", artist: "1", album: "30")
        try UsbLibraryBuilderTests.addTrack(fixture, id: "102", artwork: false)
        try fixture.setContent(track: first, ["Lyricist": .text("시험 작사"), "CueUpdated": .text("")])
        let playlists = [UsbPlaylistInput(localID: "p1", name: "시험 목록", parentLocalID: nil, attribute: 0, trackLocalIDs: ["102", "101"])]
        let model = try UsbLibraryBuilderTests.build(fixture, ids: ["101", "102"], playlists: playlists).model.library
        #expect(model.tracks[0].lyricist == "시험 작사")

        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(model, at: folder.database)
        #expect(try Self.differences(folder.database, model).isEmpty)
        #expect(try OneLibraryReader.read(copyAt: folder.database) == model.projected(to: .oneLibrary))
    }

    // MARK: - 고치기(apply)

    @Test("합친 모델로 고쳐도 OneLibrary 투영과 비교해 COMMIT, pdb 전용 값은 applied에 남는다")
    func applyVerifiesAgainstOneLibraryProjection() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.merged()
        try OneLibraryWriter.create(current, at: folder.database)
        let rename = Self.step(1) { library in
            let index = try #require(library.playlists.firstIndex { $0.id == 12 })
            library.playlists[index].name = "시험 새 이름"
        }
        let result = try OneLibraryWriter.apply(from: current, steps: [rename], database: folder.database)
        #expect(result.skipped.isEmpty)
        #expect(try OneLibraryWriter.verify(folder.database, expected: result.applied) == [])
        #expect(try Self.rows(folder.database, "SELECT name FROM playlist WHERE playlist_id = 12") == [["시험 새 이름"]])
        // pdb 전용 값과 Device Library에만 있는 목록은 그대로
        let applied = result.applied
        #expect(applied.tracks[0].lyricist == "시험 작사")
        #expect(applied.categories[0].infoOrder == 2)
        #expect(applied.categories[0].disable == 1)
        #expect(applied.sorts[1].disable == 2)
        #expect(applied.property.pdbDate == "2026-09-01")
        #expect(applied.playlists.contains { $0.id == 13 && $0.presentIn == [.deviceLibrary] })
        #expect(applied.playlists.first { $0.id == 12 }?.entries[.deviceLibrary] == [3, 1])
        #expect(try folder.contents() == ["exportLibrary.db"])

        // 대조: 투영 없이 합친 모델과 바로 비교하면 늘 차이가 난다
        let reread = try Self.read(folder.database)
        #expect(!UsbLibraryDiff.compare(reread, applied, options: .init()).differences.isEmpty)
        #expect(UsbLibraryDiff.compare(reread, applied.projected(to: .oneLibrary), options: .init(formats: [.oneLibrary])).differences.isEmpty)

        // SQL 뒤에 OneLibrary 칸 하나를 몰래 바꾸면 투영 비교가 잡아 전체를 되돌린다
        let before = try Self.dump(folder.database, "content")
        let retitle = Self.step(2) { library in library.playlists[0].name = "시험 다른 이름" }
        #expect(throws: UsbError.self) {
            try OneLibraryWriter.apply(from: applied, steps: [retitle], database: folder.database, stopOnFailure: false) { db in
                try db.execute("UPDATE content SET title = 'x' WHERE content_id = 1")
            }
        }
        #expect(try Self.dump(folder.database, "content") == before)
        #expect(try Self.rows(folder.database, "SELECT name FROM playlist WHERE playlist_id = 10") == [["시험 폴더"]])
        #expect(try folder.contents() == ["exportLibrary.db"])
    }

    @Test("곡 더하기·빼기: 다른 행의 rowid·값은 그대로, 이 편집으로 고아가 된 행만 지운다")
    func applyAddRemoveKeepsOtherRowsRowid() throws {
        let folder = try TemporaryFolder()
        var current = WriterSamples.model()
        // 곡이 쓰지 않던 아티스트(rekordbox가 남긴 행)는 그대로 둔다
        current.artists.append(UsbNamedRow(id: 99, name: "시험 남은 아티스트"))
        try OneLibraryWriter.create(current, at: folder.database)
        let tables = ["content", "artist", "album", "image", "playlist", "playlist_content", "genre", "key", "color", "myTag"]
        let before = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try Self.dump(folder.database, $0)) })

        let edit = Self.step(1) { library in
            library.tracks.removeAll { $0.id == 2 }
            for index in library.playlists.indices {
                for format in library.playlists[index].entries.keys { library.playlists[index].entries[format]?.removeAll { $0 == 2 } }
            }
            var added = WriterSamples.track(4, artist: 5, album: nil, image: 4)
            added.genreID = 1
            library.tracks.append(added)
            library.artists.append(UsbNamedRow(id: 5, name: "시험 새 아티스트"))
            library.images.append(UsbImage(id: 4, oneLibraryPath: UsbArtworkLayout.oneLibraryPath(imageID: 4, folder: 1)))
            library.property.numberOfContents = 3
        }
        let result = try OneLibraryWriter.apply(from: current, steps: [edit], database: folder.database)
        #expect(result.skipped.isEmpty)
        let applied = result.applied
        // 곡 2만 쓰던 아티스트·앨범·그림은 지우고, 원래 떠 있던 아티스트 99는 남긴다
        #expect(applied.artists.map(\.id) == [1, 3, 5, 99])
        #expect(applied.albums.map(\.id) == [1])
        #expect(applied.images.map(\.id) == [1, 3, 4])
        #expect(try Self.differences(folder.database, applied).isEmpty)

        let after = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try Self.dump(folder.database, $0)) })
        func kept(_ table: String, _ rowids: Set<String>) -> Bool {
            before[table]!.filter { rowids.contains($0[0]) } == after[table]!.filter { rowids.contains($0[0]) }
        }
        #expect(kept("content", ["1", "3"]))
        #expect(after["content"]!.map { $0[0] } == ["1", "3", "4"])
        #expect(kept("artist", ["1", "3", "99"]))
        #expect(after["artist"]!.map { $0[0] } == ["1", "3", "5", "99"])
        #expect(kept("image", ["1", "3"]))
        #expect(after["album"] == before["album"]!.filter { $0[0] == "1" })
        for table in ["playlist", "genre", "key", "color", "myTag"] { #expect(after[table] == before[table], "\(table)") }
        // 곡 2가 빠진 목록은 1..N으로 다시 넣는다
        #expect(try Self.rows(folder.database, "SELECT playlist_id, content_id, sequenceNo FROM playlist_content ORDER BY rowid")
            == [["12", "3", "1"], ["12", "1", "2"], ["12", "3", "3"], ["11", "1", "1"], ["11", "3", "2"]])
        #expect(try Self.rows(folder.database, "SELECT numberOfContents FROM property") == [["3"]])
    }

    @Test("기기 행(기록)과 기기 칸(rating·djPlayCount·hasModified)은 건드리지 않는다")
    func applyPreservesDeviceRows() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        do {
            let db = try Self.open(folder.database, .readWrite)
            defer { db.close() }
            try db.execute("UPDATE content SET rating = 3, djPlayCount = 7, hasModified = 1 WHERE content_id = 1")
            try db.execute("INSERT INTO history VALUES (1, 1, '시험 기록', 0, 0)")
            try db.execute("INSERT INTO history_content VALUES (1, 1, 1), (1, 3, 2)")
        }
        let current = try Self.read(folder.database)
        let historyBefore = try Self.dump(folder.database, "history") + (try Self.dump(folder.database, "history_content"))

        let edit = Self.step(1) { library in
            library.tracks[0].title = "시험 새 제목"
            // 로컬 값으로 다시 만든 곡처럼 기기 칸이 달라도 USB 값을 지킨다
            library.tracks[0].rating = 0
            library.tracks[0].djPlayCount = 0
            library.tracks[0].hasModified = 0
            library.tracks[0].deviceFields[.oneLibrary] = UsbTrackDeviceFields(rating: 0, playCount: 0, hasModified: 0)
        }
        let result = try OneLibraryWriter.apply(from: current, steps: [edit], database: folder.database)
        #expect(result.skipped.isEmpty)
        #expect(try Self.rows(folder.database, "SELECT title, rating, djPlayCount, hasModified FROM content WHERE content_id = 1")
            == [["시험 새 제목", "3", "7", "1"]])
        #expect(result.applied.tracks[0].rating == 3)
        #expect(result.applied.tracks[0].deviceFields[.oneLibrary] == UsbTrackDeviceFields(rating: 3, playCount: 7, hasModified: 1))
        #expect(try Self.dump(folder.database, "history") + (try Self.dump(folder.database, "history_content")) == historyBefore)
        #expect(result.applied.histories == current.histories)
    }

    @Test("롤백 모양(journal_mode = delete) USB는 고친 뒤에도, 되돌린 뒤에도 그 모양")
    func applyRollbackHeaderStays1_1() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        do {
            let db = try Self.open(folder.database, .readWrite)
            defer { db.close() }
            try db.execute("PRAGMA journal_mode = DELETE")
        }
        #expect(try Self.rows(folder.database, "PRAGMA journal_mode") == [["delete"]])
        let rename = Self.step(1) { library in library.playlists[1].name = "시험 새 이름" }
        let result = try OneLibraryWriter.apply(from: current, steps: [rename], database: folder.database)
        #expect(try Self.rows(folder.database, "PRAGMA journal_mode") == [["delete"]])
        #expect(try folder.contents() == ["exportLibrary.db"])

        let before = try Self.dump(folder.database, "playlist")
        let again = Self.step(2) { library in library.playlists[2].name = "시험 또 다른 이름" }
        #expect(throws: UsbError.self) {
            try OneLibraryWriter.apply(from: result.applied, steps: [again], database: folder.database, stopOnFailure: false) { db in
                try db.execute("UPDATE genre SET name = 'x'")
            }
        }
        #expect(try Self.dump(folder.database, "playlist") == before)
        #expect(try Self.rows(folder.database, "PRAGMA journal_mode") == [["delete"]])
        #expect(try folder.contents() == ["exportLibrary.db"])
    }

    @Test("항목을 바꾼 목록만 1..N으로 다시 넣는다")
    func applyPlaylistRenumbers() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        let edit = Self.step(1) { library in library.playlists[1].entries[.oneLibrary] = [3, 1] }
        _ = try OneLibraryWriter.apply(from: current, steps: [edit], database: folder.database)
        #expect(try Self.rows(folder.database, "SELECT rowid, playlist_id, content_id, sequenceNo FROM playlist_content ORDER BY rowid") == [
            ["4", "12", "3", "1"], ["5", "12", "1", "2"], ["6", "12", "3", "3"], ["7", "11", "3", "1"], ["8", "11", "1", "2"],
        ])
    }

    /// 단계 셋: 첫째 목록 이름, 둘째 실패(클로저가 던지거나 같은 ID 곡 둘 → INSERT 제약 위반), 셋째 곡 제목
    static func threeSteps(secondThrows: Bool, box: ModelBox) -> [OneLibraryEditStep] {
        [
            step(1) { library in library.playlists[1].name = "시험 첫째" },
            step(2) { library in
                if secondThrows { throw StepFailure() }
                var added = WriterSamples.track(50, artist: 1, album: 1, image: nil)
                added.title = "시험 둘째"
                library.tracks += [added, added]
            },
            OneLibraryEditStep(id: 3) { library in
                box.append(library)
                var library = library
                library.tracks[0].title = "시험 셋째"
                return library
            },
        ]
    }

    @Test("실패한 편집만 SAVEPOINT로 되돌리고 나머지는 COMMIT", arguments: [true, false])
    func applySavepointSkipsFailedEdit(secondThrows: Bool) throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        let box = ModelBox()
        let result = try OneLibraryWriter.apply(from: current, steps: Self.threeSteps(secondThrows: secondThrows, box: box),
                                                database: folder.database)
        #expect(Array(result.skipped.keys) == [2])
        var expected = current
        expected.playlists[1].name = "시험 첫째"
        expected.tracks[0].title = "시험 셋째"
        #expect(result.applied == expected)
        #expect(try Self.differences(folder.database, expected).isEmpty)
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM content WHERE content_id = 50") == [["0"]])
        #expect(try OneLibraryWriter.verify(folder.database, expected: result.applied) == [])
    }

    @Test("다시 읽기 비교 기준은 건너뛴 편집을 뺀 모델이다(원래 목표와는 다르다)")
    func applyComparesAgainstAcceptedTarget() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        let box = ModelBox()
        let steps = Self.threeSteps(secondThrows: false, box: box)
        // 모든 편집을 적용한 원래 목표
        var target = current
        for step in steps { target = try step.target(target) }
        let result = try OneLibraryWriter.apply(from: current, steps: steps, database: folder.database)
        #expect(!(try Self.differences(folder.database, target)).isEmpty)
        #expect(try Self.differences(folder.database, result.applied).isEmpty)
    }

    @Test("셋째 단계는 둘째 편집이 빠진 모델 위에 적용된다")
    func applyThirdStepBuildsOnAccepted() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        let box = ModelBox()
        _ = try OneLibraryWriter.apply(from: current, steps: Self.threeSteps(secondThrows: false, box: box), database: folder.database)
        let received = try #require(box.all.first)
        #expect(box.all.count == 1)
        #expect(!received.tracks.contains { $0.id == 50 })
        #expect(received.playlists[1].name == "시험 첫째")
    }

    @Test("단계 하나 편의 함수: 실패하면 전체를 되돌리고 던진다")
    func applySingleTargetRollsBackOnFailure() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        var target = current
        target.playlists[1].name = "시험 새 이름"
        try OneLibraryWriter.apply(from: current, to: target, database: folder.database)
        #expect(try Self.differences(folder.database, target).isEmpty)

        let before = try Self.dump(folder.database, "content")
        var broken = target
        var added = WriterSamples.track(50, artist: 1, album: 1, image: nil)
        added.title = "시험 둘"
        broken.tracks += [added, added]
        broken.playlists[1].name = "시험 되돌릴 이름"
        #expect(throws: (any Error).self) { try OneLibraryWriter.apply(from: target, to: broken, database: folder.database) }
        #expect(try Self.dump(folder.database, "content") == before)
        #expect(try Self.rows(folder.database, "SELECT name FROM playlist WHERE playlist_id = 11") == [["시험 새 이름"]])
    }

    @Test("기기가 남긴 큐가 가리키는 곡을 빼는 편집은 건너뛴다")
    func applySkipsRemovingTrackWithDeviceCues() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        do {
            let db = try Self.open(folder.database, .readWrite)
            defer { db.close() }
            try db.execute("INSERT INTO cue (cue_id, content_id, kind) VALUES (1, 2, 0)")
        }
        let current = try Self.read(folder.database)
        #expect(current.unknownRows.count == 1)
        let remove = Self.step(1) { library in
            library.tracks.removeAll { $0.id == 2 }
            for index in library.playlists.indices { library.playlists[index].entries[.oneLibrary]?.removeAll { $0 == 2 } }
        }
        let rename = Self.step(2) { library in library.playlists[2].name = "시험 새 이름" }
        let result = try OneLibraryWriter.apply(from: current, steps: [remove, rename], database: folder.database)
        #expect(Array(result.skipped.keys) == [1])
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM content WHERE content_id = 2") == [["1"]])
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM cue") == [["1"]])
        #expect(try Self.rows(folder.database, "SELECT name FROM playlist WHERE playlist_id = 12") == [["시험 새 이름"]])
    }

    /// 곡 2를 빼는 단계(목록 항목도 뺀다)
    static let removeTrack2 = step(1) { library in
        library.tracks.removeAll { $0.id == 2 }
        for index in library.playlists.indices { library.playlists[index].entries[.oneLibrary]?.removeAll { $0 == 2 } }
    }

    @Test("기기 기록이 가리키는 곡을 빼는 편집은 건너뛴다")
    func applySkipsRemovingTrackInDeviceHistory() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        do {
            let db = try Self.open(folder.database, .readWrite)
            defer { db.close() }
            try db.execute("INSERT INTO history VALUES (1, 1, '시험 기록', 0, 0)")
            try db.execute("INSERT INTO history_content VALUES (1, 2, 1)")
        }
        let current = try Self.read(folder.database)
        let historyBefore = try Self.dump(folder.database, "history_content")
        let rename = Self.step(2) { library in library.playlists[2].name = "시험 새 이름" }
        let result = try OneLibraryWriter.apply(from: current, steps: [Self.removeTrack2, rename], database: folder.database)
        #expect(Array(result.skipped.keys) == [1])
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM content WHERE content_id = 2") == [["1"]])
        #expect(try Self.dump(folder.database, "history_content") == historyBefore)
        #expect(try Self.rows(folder.database, "SELECT name FROM playlist WHERE playlist_id = 12") == [["시험 새 이름"]])
    }

    @Test("뺀 곡을 가리키는 항목이 남은 목록이 있으면 그 편집은 건너뛴다(항목을 고치지 않은 목록도)")
    func applySkipsRemovingTrackStillInPlaylist() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        let remove = Self.step(1) { library in
            library.tracks.removeAll { $0.id == 2 }
            library.property.numberOfContents = 2
        }
        let rename = Self.step(2) { library in library.playlists[2].name = "시험 새 이름" }
        let result = try OneLibraryWriter.apply(from: current, steps: [remove, rename], database: folder.database)
        #expect(Array(result.skipped.keys) == [1])
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM content WHERE content_id = 2") == [["1"]])
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM playlist_content WHERE content_id NOT IN (SELECT content_id FROM content)")
            == [["0"]])
        #expect(try Self.rows(folder.database, "SELECT name FROM playlist WHERE playlist_id = 12") == [["시험 새 이름"]])
    }

    @Test("모델에 담지 않는 핫큐 뱅크가 가리키는 그림을 지우는 편집은 건너뛴다")
    func applySkipsRemovingImageInHotCueBank() throws {
        let folder = try TemporaryFolder()
        try OneLibraryWriter.create(WriterSamples.model(), at: folder.database)
        do {
            let db = try Self.open(folder.database, .readWrite)
            defer { db.close() }
            try db.execute("INSERT INTO hotCueBankList VALUES (1, 0, '시험 뱅크', 2, 0, 0)")
        }
        let current = try Self.read(folder.database)
        #expect(current.unknownRows.count == 1)
        let rename = Self.step(2) { library in library.playlists[2].name = "시험 새 이름" }
        let result = try OneLibraryWriter.apply(from: current, steps: [Self.removeTrack2, rename], database: folder.database)
        #expect(Array(result.skipped.keys) == [1])
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM image WHERE image_id = 2") == [["1"]])
        #expect(try Self.rows(folder.database, "SELECT count(*) FROM hotCueBankList WHERE image_id NOT IN (SELECT image_id FROM image)")
            == [["0"]])
        #expect(try Self.rows(folder.database, "SELECT name FROM playlist WHERE playlist_id = 12") == [["시험 새 이름"]])
    }

    @Test("numberOfContents는 단계 모델 값이 아니라 OneLibrary 곡 수로 쓴다")
    func applyCountsOneLibraryTracks() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        // 곡을 빼면서 numberOfContents는 그대로 둔 단계
        let result = try OneLibraryWriter.apply(from: current, steps: [Self.removeTrack2], database: folder.database)
        #expect(result.skipped.isEmpty)
        #expect(result.applied.property.numberOfContents == 2)
        #expect(try Self.rows(folder.database, "SELECT numberOfContents, (SELECT count(*) FROM content) FROM property") == [["2", "2"]])

        // 합친 모델: Device Library에만 있는 곡은 세지 않는다
        let other = try TemporaryFolder()
        var both = WriterSamples.merged()
        both.tracks.append(WriterSamples.track(4, artist: 1, album: 1, image: nil, formats: [.deviceLibrary]))
        both.canonicalize()
        try OneLibraryWriter.create(both, at: other.database)
        let bump = Self.step(1) { library in library.property.numberOfContents = 99 }
        let again = try OneLibraryWriter.apply(from: both, steps: [bump], database: other.database)
        #expect(again.applied.property.numberOfContents == 3)
        #expect(try Self.rows(other.database, "SELECT numberOfContents FROM property") == [["3"]])
    }

    @Test("COMMIT 뒤 확인이 실패하면 되돌렸다고 하지 않는다(사본은 이미 고쳐졌다)")
    func applyFailureAfterCommitIsNotRollback() throws {
        let folder = try TemporaryFolder()
        let current = WriterSamples.model()
        try OneLibraryWriter.create(current, at: folder.database)
        let rename = Self.step(1) { library in library.playlists[1].name = "시험 새 이름" }
        var caught: (any Error)?
        do {
            _ = try OneLibraryWriter.apply(from: current, steps: [rename], database: folder.database, stopOnFailure: false,
                                           afterSteps: nil) { db in
                try db.execute("UPDATE genre SET name = 'x'")
            }
        } catch {
            caught = error
        }
        let error = try #require(caught)
        #expect(error is OneLibraryCommittedCopyError)
        if case UsbError.writeRolledBack = error { Issue.record("되돌림 오류로 던졌다") }
        #expect(!error.localizedDescription.contains("genre"))
        // 편집은 이미 COMMIT됐다
        #expect(try Self.rows(folder.database, "SELECT name FROM playlist WHERE playlist_id = 11") == [["시험 새 이름"]])
    }

    @Test("확인은 사이드카가 있으면 DB를 열지 않는다(남은 -wal·본 파일 바이트 그대로)")
    func verifyLeavesStaleWal() throws {
        let folder = try TemporaryFolder()
        let model = WriterSamples.model()
        try OneLibraryWriter.create(model, at: folder.database)
        let original = try Data(contentsOf: folder.database)
        let wal = URL(filePath: folder.database.path + "-wal")
        // 체크포인트 전의 -wal을 떠 두고, 본 파일은 고치기 전으로 되돌린다(병합되지 않은 -wal이 남은 모양)
        var staleWal = Data()
        do {
            let db = try Self.open(folder.database, .readWrite)
            try db.execute("PRAGMA wal_autocheckpoint = 0")
            try db.execute("UPDATE genre SET name = '시험 바뀐 장르'")
            staleWal = try Data(contentsOf: wal)
            db.close()
        }
        try original.write(to: folder.database)
        try staleWal.write(to: wal)
        #expect(!staleWal.isEmpty)

        let problems = try OneLibraryWriter.verify(folder.database, expected: model)
        #expect(problems.contains("sidecar -wal"))
        #expect(try Data(contentsOf: folder.database) == original)
        #expect(try Data(contentsOf: wal) == staleWal)
        #expect(try folder.contents() == ["exportLibrary.db", "exportLibrary.db-wal"])
    }

    @Test("realpath가 /Volumes 아래면 USB 볼륨으로 본다")
    func volumePathDetection() {
        for path in ["/Volumes", "/Volumes/TEST USB/PIONEER/rekordbox", "/volumes/test"] {
            #expect(OneLibraryWriter.isOnVolumes(path), "\(path)")
        }
        for path in ["/VolumesX", "/private/tmp/Volumes/test", "/", ""] {
            #expect(!OneLibraryWriter.isOnVolumes(path), "\(path)")
        }
        #expect(!OneLibraryWriter.isOnVolumes(nil))
    }

    @Test("USB 볼륨 위의 DB는 만들기·고치기·확인 모두 열기 전에 거부한다")
    func refusesVolumePath() throws {
        let folder = try TemporaryFolder()
        // /Volumes를 가리키는 링크 아래 경로: realpath가 /Volumes라 파일을 건드리기 전에 거부해야 한다
        let link = folder.url.appending(path: "usb")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes")
        let database = link.appending(path: "exportLibrary.db")
        let model = WriterSamples.model()
        #expect(usbRefusedCodes { try OneLibraryWriter.create(model, at: database) } == ["libraryOnVolume"])
        #expect(usbRefusedCodes { _ = try OneLibraryWriter.apply(from: model, steps: [], database: database) } == ["libraryOnVolume"])
        #expect(usbRefusedCodes { try OneLibraryWriter.apply(from: model, to: model, database: database) } == ["libraryOnVolume"])
        #expect(usbRefusedCodes { _ = try OneLibraryWriter.verify(database, expected: model) } == ["libraryOnVolume"])
    }

    @Test("모르는 모양의 USB DB는 고치지 않는다")
    func applyRefusesUnknownSchema() throws {
        let fixture = try OneLibraryFixture(statements: OneLibrarySchema.ddl() + ["CREATE TABLE extra(x integer)"])
        fixture.close()
        let rename = Self.step(1) { library in library.property.numberOfContents = 1 }
        #expect(throws: UsbError.self) { try OneLibraryWriter.apply(from: .empty, steps: [rename], database: fixture.url) }
    }
}
