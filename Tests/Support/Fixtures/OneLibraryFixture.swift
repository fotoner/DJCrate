import DJCDomain
import Foundation
import RekordboxKit

/// 시험용 USB OneLibrary(`exportLibrary.db`).
///
/// `OneLibrarySchema.ddl()`(또는 넘긴 문장)로 같은 키의 암호화 DB를 새로 만들고 합성 행을 넣는다.
/// 모든 값은 지어낸 것이다. 시험이 끝나면 임시 폴더째 지운다.
public final class OneLibraryFixture {
    public enum JournalMode: String, Sendable { case wal = "WAL", delete = "DELETE" }

    public let folder: URL
    public var url: URL { folder.appending(path: "exportLibrary.db") }
    /// 행을 넣는 연결(열 때마다 키 유도가 느려 하나를 계속 쓴다). 파일을 복사하기 전에는 `close()`로 닫는다.
    private var writer: CipherDatabase?

    /// - Parameters:
    ///   - statements: 표를 만들 문장(기본 `OneLibrarySchema.ddl()`)
    ///   - property: 기본 property 행을 넣을지
    public init(journalMode: JournalMode = .wal, statements: [String]? = nil, property: Bool = true) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "djc-onelib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .create)
        writer = db
        try db.execute("PRAGMA journal_mode = \(journalMode.rawValue)")
        for sql in statements ?? OneLibrarySchema.ddl() { try db.execute(sql) }
        if property {
            try db.run("""
                INSERT INTO property (deviceName, dbVersion, numberOfContents, createdDate, backGroundColorType, myTagMasterDBID)
                VALUES ('', '1000', 0, '2026-01-01', 0, 123456789)
                """, [])
        }
    }

    deinit {
        writer?.close()
        try? FileManager.default.removeItem(at: folder)
    }

    /// 넣는 연결을 닫는다(WAL을 파일에 합치고 -wal·-shm을 지운다). 파일을 복사하기 전에 부른다.
    public func close() {
        writer?.close()
        writer = nil
    }

    /// 시험 리소스의 스키마 문장(끝 ";" 뗌)
    public static func resourceStatements() throws -> [String] {
        let text = try String(contentsOf: TestResources.url("onelibrary-7.2.18-schema.sql"), encoding: .utf8)
        return text.split(separator: "\n").map { line in
            var line = String(line)
            if line.hasSuffix(";") { line.removeLast() }
            return line
        }
    }

    public func open(_ mode: OpenMode = .readWrite) throws -> CipherDatabase {
        try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: mode)
    }

    public func execute(_ sql: String, _ values: [CipherDatabase.Value] = []) throws {
        if writer == nil { writer = try open() }
        try writer!.run(sql, values)
    }

    /// 아무 표에나 행 하나
    public func insert(_ table: String, _ values: [String: CipherDatabase.Value]) throws {
        let keys = values.keys.sorted()
        try execute("INSERT INTO \(table) (\(keys.joined(separator: ", "))) VALUES (\(keys.map { _ in "?" }.joined(separator: ", ")))",
                    keys.map { values[$0]! })
    }

    /// 질의 결과를 칸 이름 → 글자로(NULL은 "NULL")
    public func rows(_ sql: String) throws -> [[String: String]] {
        let db = try open(.readOnly)
        defer { db.close() }
        var out: [[String: String]] = []
        try db.query(sql) { r in
            var row: [String: String] = [:]
            for i in 0..<r.count { row[r.name(Int32(i))] = r.string(Int32(i)) ?? "NULL" }
            out.append(row)
        }
        return out
    }

    public func add(track: OneLibraryTrackSpec) throws {
        let columns: [(String, CipherDatabase.Value)] = [
            ("content_id", .int(track.id)), ("title", .optional(track.title)), ("titleForSearch", .optional(track.titleForSearch)),
            ("subtitle", .optional(track.subtitle)), ("bpmx100", .int(track.bpmx100)), ("length", .int(track.length)),
            ("trackNo", .int(track.trackNo)), ("discNo", .int(track.discNo)),
            ("artist_id_artist", .optional(track.artistID)), ("artist_id_remixer", .optional(track.remixerID)),
            ("artist_id_originalArtist", .optional(track.originalArtistID)), ("artist_id_composer", .optional(track.composerID)),
            ("artist_id_lyricist", .optional(track.lyricistArtistID)), ("album_id", .optional(track.albumID)),
            ("genre_id", .optional(track.genreID)), ("label_id", .optional(track.labelID)), ("key_id", .optional(track.keyID)),
            ("color_id", .optional(track.colorID)), ("image_id", .optional(track.imageID)), ("djComment", .optional(track.djComment)),
            ("rating", .int(track.rating)), ("releaseYear", .int(track.releaseYear)), ("releaseDate", .optional(track.releaseDate)),
            ("dateCreated", .optional(track.dateCreated)), ("dateAdded", .optional(track.dateAdded)), ("path", .text(track.path)),
            ("fileName", .text(track.fileName)), ("fileSize", .int(track.fileSize)), ("fileType", .int(track.fileType)),
            ("bitrate", .int(track.bitrate)), ("bitDepth", .int(track.bitDepth)), ("samplingRate", .int(track.samplingRate)),
            ("isrc", .optional(track.isrc)), ("djPlayCount", .int(track.djPlayCount)),
            ("isHotCueAutoLoadOn", .int(track.isHotCueAutoLoadOn)), ("isKuvoDeliverStatusOn", .int(track.isKuvoDeliverStatusOn)),
            ("kuvoDeliveryComment", .optional(track.kuvoDeliveryComment)), ("masterDbId", .int(track.masterDbId)),
            ("masterContentId", .int(track.masterContentId)), ("analysisDataFilePath", .optional(track.analysisDataFilePath)),
            ("analysedBits", .int(track.analysedBits)), ("contentLink", .int(track.contentLink)), ("hasModified", .int(track.hasModified)),
            ("cueUpdateCount", track.cueUpdateCount), ("analysisDataUpdateCount", track.analysisDataUpdateCount),
            ("informationUpdateCount", track.informationUpdateCount),
        ]
        try execute("INSERT INTO content (\(columns.map(\.0).joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
                    columns.map(\.1))
    }

    /// 목록 하나와 항목(content_id 순서대로 sequenceNo 1부터)
    public func add(playlist id: Int, name: String, parentID: Int = 0, attribute: Int = 0, sequenceNo: Int = 1, imageID: Int? = nil,
                    entries: [Int] = []) throws {
        try insert("playlist", ["playlist_id": .int(id), "sequenceNo": .int(sequenceNo), "name": .text(name), "image_id": .optional(imageID),
                                "attribute": .int(attribute), "playlist_id_parent": .int(parentID)])
        for (index, content) in entries.enumerated() {
            try insert("playlist_content", ["playlist_id": .int(id), "content_id": .int(content), "sequenceNo": .int(index + 1)])
        }
    }

    /// My Tag 행. `isCategory`면 attribute 1(분류), 아니면 0
    public func add(myTag id: Int64, name: String, parentID: Int64 = 0, sequenceNo: Int = 0, isCategory: Bool = false) throws {
        try insert("myTag", ["myTag_id": .int(Int(id)), "sequenceNo": .int(sequenceNo), "name": .text(name),
                             "attribute": .int(isCategory ? 1 : 0), "myTag_id_parent": .int(Int(parentID))])
    }

    public func link(myTag id: Int64, content: Int) throws {
        try insert("myTag_content", ["myTag_id": .int(Int(id)), "content_id": .int(content)])
    }

    public func add(menuItem id: Int, kind: Int, name: String) throws {
        try insert("menuItem", ["menuItem_id": .int(id), "kind": .int(kind), "name": .text(name)])
    }

    public func add(category id: Int, menuItemID: Int, sequenceNo: Int, isVisible: Bool = true) throws {
        try insert("category", ["category_id": .int(id), "menuItem_id": .int(menuItemID), "sequenceNo": .int(sequenceNo),
                                "isVisible": .int(isVisible ? 1 : 0)])
    }

    public func add(sort id: Int, menuItemID: Int, sequenceNo: Int, isVisible: Bool = true, isSelectedAsSubColumn: Bool = false) throws {
        try insert("sort", ["sort_id": .int(id), "menuItem_id": .int(menuItemID), "sequenceNo": .int(sequenceNo),
                            "isVisible": .int(isVisible ? 1 : 0), "isSelectedAsSubColumn": .int(isSelectedAsSubColumn ? 1 : 0)])
    }

    /// property 행을 바꾼다(없으면 넣는다)
    public func setProperty(deviceName: String = "", dbVersion: String = "1000", numberOfContents: Int = 0, createdDate: String = "2026-01-01",
                            backgroundColorType: Int = 0, myTagMasterDBID: Int64 = 123_456_789) throws {
        try execute("DELETE FROM property")
        try insert("property", ["deviceName": .text(deviceName), "dbVersion": .text(dbVersion), "numberOfContents": .int(numberOfContents),
                                "createdDate": .text(createdDate), "backGroundColorType": .int(backgroundColorType),
                                "myTagMasterDBID": .int(Int(myTagMasterDBID))])
    }
}

/// 합성 곡 행(content). 모든 값은 지어낸 것이다.
public struct OneLibraryTrackSpec: Sendable {
    public var id: Int
    public var title: String?
    public var titleForSearch: String?
    public var subtitle: String? = ""
    public var bpmx100 = 12800
    public var length = 200
    public var trackNo = 0
    public var discNo = 0
    public var artistID: Int?
    public var remixerID: Int?
    public var originalArtistID: Int?
    public var composerID: Int?
    public var lyricistArtistID: Int? = 0
    public var albumID: Int?
    public var genreID: Int?
    public var labelID: Int?
    public var keyID: Int?
    public var colorID: Int? = 0
    public var imageID: Int?
    public var djComment: String? = ""
    public var rating = 0
    public var releaseYear = 0
    public var releaseDate: String? = ""
    public var dateCreated: String? = "2026-01-01"
    public var dateAdded: String? = "2026-01-02"
    public var path: String
    public var fileName: String
    public var fileSize = 1_000_000
    public var fileType = 1
    public var bitrate = 320
    public var bitDepth = 16
    public var samplingRate = 44100
    public var isrc: String? = ""
    public var djPlayCount = 0
    public var isHotCueAutoLoadOn = 1
    public var isKuvoDeliverStatusOn = 0
    public var kuvoDeliveryComment: String? = ""
    public var masterDbId = 1_000_001
    public var masterContentId: Int
    public var analysisDataFilePath: String?
    public var analysedBits = 0
    public var contentLink = 0
    public var hasModified = 0
    public var cueUpdateCount: CipherDatabase.Value = .int(0)
    public var analysisDataUpdateCount: CipherDatabase.Value = .int(0)
    public var informationUpdateCount: CipherDatabase.Value = .int(0)

    public init(id: Int) {
        self.id = id
        title = "시험 곡 \(id)"
        fileName = "test\(id).mp3"
        path = "/Contents/시험 아티스트/시험 앨범/test\(id).mp3"
        masterContentId = 900_000 + id
        analysisDataFilePath = String(format: "/PIONEER/USBANLZ/P000/%08X/ANLZ0000.DAT", id)
    }
}

extension CipherDatabase.Value {
    static func optional(_ value: String?) -> Self { value.map { .text($0) } ?? .null }
    static func optional(_ value: Int?) -> Self { value.map { .int($0) } ?? .null }
}
