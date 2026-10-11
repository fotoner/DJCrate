import DJCDomain
import Foundation

/// USB OneLibrary(`exportLibrary.db`) → `UsbLibrary`(formats = [.oneLibrary]).
/// USB 원본은 열지 않는다. `UsbSnapshot`으로 뜬 사본만 연다.
public enum OneLibraryReader {
    /// 모델에 담지 않는 표(행이 있으면 수만 `unknownRows`에 남긴다)
    static let unmodeledTables = ["hotCueBankList", "hotCueBankList_cue", "cue", "recommendedLike"]
    static let fileName = "exportLibrary.db"

    /// 사본 파일만 연다. 호출 전 `UsbSnapshot`으로 뜬 사본이어야 한다.
    public static func read(copyAt url: URL) throws -> UsbLibrary {
        let db = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readOnly)
        defer { db.close() }
        return try read(connection: db)
    }

    /// 이미 연 연결에서 읽는다(작성기가 쓰기 트랜잭션 안에서 다시 읽을 때). 호환 검사도 한다.
    static func read(connection db: CipherDatabase) throws -> UsbLibrary {
        try OneLibraryCompatibility.check(db)
        var library = UsbLibrary(formats: [.oneLibrary], property: try property(db))
        library.tracks = try tracks(db)
        library.artists = try named(db, "SELECT artist_id, name, nameForSearch FROM artist ORDER BY artist_id")
        library.genres = try named(db, "SELECT genre_id, name, NULL FROM genre ORDER BY genre_id")
        library.keys = try named(db, "SELECT key_id, name, NULL FROM key ORDER BY key_id")
        library.labels = try named(db, "SELECT label_id, name, NULL FROM label ORDER BY label_id")
        library.colors = try named(db, "SELECT color_id, name, NULL FROM color ORDER BY color_id")
        try db.query("SELECT album_id, name, artist_id, image_id, isComplation, nameForSearch FROM album ORDER BY album_id") { row in
            library.albums.append(UsbAlbum(id: row.int(0) ?? 0, name: row.string(1) ?? "", artistID: row.int(2), imageID: row.int(3),
                                           isCompilation: row.int(4) ?? 0, nameForSearch: row.string(5)))
        }
        try db.query("SELECT image_id, path FROM image ORDER BY image_id") { row in
            library.images.append(UsbImage(id: row.int(0) ?? 0, oneLibraryPath: row.string(1), pdbPath: nil))
        }
        library.playlists = try playlists(db)
        try db.query("SELECT myTag_id, sequenceNo, name, attribute, myTag_id_parent FROM myTag ORDER BY myTag_id") { row in
            library.myTags.append(UsbMyTag(id: Int64(row.int(0) ?? 0), parentID: Int64(row.int(4) ?? 0), sequenceNo: row.int(1) ?? 0,
                                           name: row.string(2) ?? "", isCategory: row.int(3) == 1))
        }
        try db.query("SELECT myTag_id, content_id FROM myTag_content ORDER BY myTag_id, content_id") { row in
            library.myTagLinks.append(UsbMyTagLink(myTagID: Int64(row.int(0) ?? 0), contentID: row.int(1) ?? 0, presentIn: [.oneLibrary]))
        }
        try db.query("SELECT menuItem_id, kind, name FROM menuItem ORDER BY menuItem_id") { row in
            library.menuItems.append(UsbMenuItem(id: row.int(0) ?? 0, kind: row.int(1) ?? 0, name: unwrapMenuName(row.string(2) ?? "")))
        }
        try db.query("SELECT category_id, menuItem_id, sequenceNo, isVisible FROM category ORDER BY category_id") { row in
            library.categories.append(UsbCategory(id: row.int(0) ?? 0, menuItemID: row.int(1) ?? 0, sequenceNo: row.int(2) ?? 0,
                                                  isVisible: (row.int(3) ?? 0) != 0, infoOrder: nil, disable: nil))
        }
        try db.query("SELECT sort_id, menuItem_id, sequenceNo, isVisible, isSelectedAsSubColumn FROM sort ORDER BY sort_id") { row in
            library.sorts.append(UsbSort(id: row.int(0) ?? 0, menuItemID: row.int(1) ?? 0, sequenceNo: row.int(2) ?? 0,
                                         isVisible: (row.int(3) ?? 0) != 0, isSelectedAsSubColumn: (row.int(4) ?? 0) != 0, disable: nil))
        }
        library.histories = try histories(db)
        for (index, table) in OneLibrarySchema.tables.map(\.name).enumerated() where unmodeledTables.contains(table) {
            let count = try db.scalarInt("SELECT count(*) FROM \(table)")
            if count > 0 {
                library.unknownRows.append(UsbUnknownRows(format: .oneLibrary, file: fileName, tableType: index, liveRows: count))
            }
        }
        return library.canonicalized()
    }

    /// 메뉴 이름을 감싼 U+FFFA·U+FFFB를 뗀다
    static func unwrapMenuName(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter { $0 != "\u{FFFA}" && $0 != "\u{FFFB}" }))
    }

    private static func property(_ db: CipherDatabase) throws -> UsbProperty {
        var property = UsbProperty()
        // 호환 검사가 행이 하나뿐임을 이미 확인했다
        try db.query("""
            SELECT deviceName, dbVersion, numberOfContents, createdDate, backGroundColorType, myTagMasterDBID FROM property LIMIT 1
            """) { row in
            property = UsbProperty(deviceName: row.string(0) ?? "", dbVersion: row.string(1) ?? "", numberOfContents: row.int(2) ?? 0,
                                   createdDate: row.string(3) ?? "", backgroundColorType: row.int(4) ?? 0,
                                   myTagMasterDBID: Int64(row.int(5) ?? 0), pdbDate: nil, pdbDeviceName: nil)
        }
        return property
    }

    private static func tracks(_ db: CipherDatabase) throws -> [UsbTrack] {
        var tracks: [UsbTrack] = []
        try db.query("""
            SELECT content_id, title, titleForSearch, subtitle, bpmx100, length, trackNo, discNo,
                   artist_id_artist, artist_id_remixer, artist_id_originalArtist, artist_id_composer, artist_id_lyricist,
                   album_id, genre_id, label_id, key_id, color_id, image_id, djComment, rating, releaseYear, releaseDate, dateCreated,
                   dateAdded, path, fileName, fileSize, fileType, bitrate, bitDepth, samplingRate, isrc, djPlayCount, isHotCueAutoLoadOn,
                   isKuvoDeliverStatusOn, kuvoDeliveryComment, masterDbId, masterContentId, analysisDataFilePath, analysedBits,
                   contentLink, hasModified, cueUpdateCount, analysisDataUpdateCount, informationUpdateCount
            FROM content ORDER BY content_id
            """) { row in
            let rating = row.int(20) ?? 0, playCount = row.int(33) ?? 0, hasModified = row.int(42) ?? 0
            tracks.append(UsbTrack(
                id: row.int(0) ?? 0, presentIn: [.oneLibrary], title: row.string(1) ?? "", titleForSearch: row.string(2),
                subtitle: row.string(3) ?? "", bpmx100: row.int(4) ?? 0, lengthSeconds: row.int(5) ?? 0,
                trackNo: row.int(6) ?? 0, discNo: row.int(7) ?? 0,
                artistID: row.int(8), remixerID: row.int(9), originalArtistID: row.int(10), composerID: row.int(11),
                lyricistArtistID: row.int(12), lyricist: "",
                albumID: row.int(13), genreID: row.int(14), labelID: row.int(15), keyID: row.int(16),
                colorID: row.int(17) ?? 0, imageID: row.int(18),
                comment: row.string(19) ?? "", rating: rating, releaseYear: row.int(21) ?? 0,
                releaseDate: row.string(22) ?? "", dateCreated: row.string(23) ?? "", dateAdded: row.string(24) ?? "",
                path: row.string(25) ?? "", fileName: row.string(26) ?? "", fileSize: Int64(row.int(27) ?? 0), fileType: row.int(28) ?? 0,
                bitrate: row.int(29) ?? 0, bitDepth: row.int(30) ?? 0, sampleRate: row.int(31) ?? 0, isrc: row.string(32) ?? "",
                djPlayCount: playCount, hotCueAutoLoad: (row.int(34) ?? 0) != 0, kuvoDeliver: (row.int(35) ?? 0) != 0,
                kuvoDeliveryComment: row.string(36) ?? "",
                masterDbId: Int64(row.int(37) ?? 0), masterContentId: Int64(row.int(38) ?? 0),
                analysisDataPath: row.string(39) ?? "", analysedBits: row.int(40) ?? 0, contentLink: row.int(41) ?? 0, hasModified: hasModified,
                // INTEGER는 10진 글자, TEXT ''는 "", NULL은 ""
                cueUpdateCount: row.string(43) ?? "", analysisDataUpdateCount: row.string(44) ?? "",
                informationUpdateCount: row.string(45) ?? "",
                deviceFields: [.oneLibrary: UsbTrackDeviceFields(rating: rating, playCount: playCount, hasModified: hasModified)]))
        }
        return tracks
    }

    private static func named(_ db: CipherDatabase, _ sql: String) throws -> [UsbNamedRow] {
        var rows: [UsbNamedRow] = []
        try db.query(sql) { rows.append(UsbNamedRow(id: $0.int(0) ?? 0, name: $0.string(1) ?? "", nameForSearch: $0.string(2))) }
        return rows
    }

    /// 목록마다 항목을 sequenceNo 순으로. 항목이 없는 목록(폴더 등)도 빈 항목을 둔다.
    private static func playlists(_ db: CipherDatabase) throws -> [UsbPlaylist] {
        var entries: [Int: [Int]] = [:]
        try db.query("SELECT playlist_id, content_id FROM playlist_content ORDER BY playlist_id, sequenceNo, rowid") { row in
            entries[row.int(0) ?? 0, default: []].append(row.int(1) ?? 0)
        }
        var playlists: [UsbPlaylist] = []
        try db.query("SELECT playlist_id, sequenceNo, name, image_id, attribute, playlist_id_parent FROM playlist ORDER BY playlist_id") { row in
            let id = row.int(0) ?? 0
            playlists.append(UsbPlaylist(id: id, name: row.string(2) ?? "", parentID: row.int(5) ?? 0, attribute: row.int(4) ?? 0,
                                         imageID: row.int(3), presentIn: [.oneLibrary], sortOrder: [.oneLibrary: row.int(1) ?? 0],
                                         entries: [.oneLibrary: entries[id] ?? []]))
        }
        return playlists
    }

    private static func histories(_ db: CipherDatabase) throws -> [UsbHistory] {
        var entries: [Int: [Int]] = [:]
        try db.query("SELECT history_id, content_id FROM history_content ORDER BY history_id, sequenceNo, rowid") { row in
            entries[row.int(0) ?? 0, default: []].append(row.int(1) ?? 0)
        }
        var histories: [UsbHistory] = []
        try db.query("SELECT history_id, name FROM history ORDER BY history_id") { row in
            let id = row.int(0) ?? 0
            histories.append(UsbHistory(format: .oneLibrary, id: id, name: row.string(1) ?? "", entries: entries[id] ?? []))
        }
        return histories
    }
}
