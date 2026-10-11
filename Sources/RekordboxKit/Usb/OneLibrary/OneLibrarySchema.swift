import Foundation

/// USB OneLibrary(`PIONEER/rekordbox/exportLibrary.db`)의 표 구성.
/// 철자(`isComplation`, `OutFileOffsetInBlock`)도 그대로 둔다.
/// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
public enum OneLibrarySchema {
    public struct Column: Sendable, Hashable {
        public let name: String
        /// "integer" 또는 "varchar"(선언 그대로 소문자)
        public let type: String
        /// `integer primary key`(rowid 별칭)
        public let primaryKey: Bool

        public init(name: String, type: String, primaryKey: Bool) {
            self.name = name
            self.type = type
            self.primaryKey = primaryKey
        }
    }

    public struct Table: Sendable {
        public let name: String
        public let columns: [Column]

        public init(name: String, columns: [Column]) {
            self.name = name
            self.columns = columns
        }
    }

    public struct Index: Sendable {
        public let name: String
        public let table: String
        public let column: String

        public init(name: String, table: String, column: String) {
            self.name = name
            self.table = table
            self.column = column
        }
    }

    /// 만드는 순서 그대로
    public static let tables: [Table] = [
        table("content", """
            content_id integer primary key, title varchar, titleForSearch varchar, subtitle varchar, bpmx100 integer, length integer, \
            trackNo integer, discNo integer, artist_id_artist integer, artist_id_remixer integer, artist_id_originalArtist integer, \
            artist_id_composer integer, artist_id_lyricist integer, album_id integer, genre_id integer, label_id integer, key_id integer, \
            color_id integer, image_id integer, djComment varchar, rating integer, releaseYear integer, releaseDate varchar, \
            dateCreated varchar, dateAdded varchar, path varchar, fileName varchar, fileSize integer, fileType integer, bitrate integer, \
            bitDepth integer, samplingRate integer, isrc varchar, djPlayCount integer, isHotCueAutoLoadOn integer, \
            isKuvoDeliverStatusOn integer, kuvoDeliveryComment varchar, masterDbId integer, masterContentId integer, \
            analysisDataFilePath varchar, analysedBits integer, contentLink integer, hasModified integer, cueUpdateCount integer, \
            analysisDataUpdateCount integer, informationUpdateCount integer
            """),
        table("genre", "genre_id integer primary key, name varchar"),
        table("artist", "artist_id integer primary key, name varchar, nameForSearch varchar"),
        table("album", "album_id integer primary key, name varchar, artist_id integer, image_id integer, isComplation integer, nameForSearch varchar"),
        table("label", "label_id integer primary key, name varchar"),
        table("key", "key_id integer primary key, name varchar"),
        table("color", "color_id integer primary key, name varchar"),
        table("playlist", "playlist_id integer primary key, sequenceNo integer, name varchar, image_id integer, attribute integer, playlist_id_parent integer"),
        table("playlist_content", "playlist_id integer, content_id integer, sequenceNo integer"),
        table("hotCueBankList", """
            hotCueBankList_id integer primary key, sequenceNo integer, name varchar, image_id integer, attribute integer, \
            hotCueBankList_id_parent integer
            """),
        table("hotCueBankList_cue", "hotCueBankList_id integer, cue_id integer, sequenceNo integer"),
        table("history", "history_id integer primary key, sequenceNo integer, name varchar, attribute integer, history_id_parent integer"),
        table("history_content", "history_id integer, content_id integer, sequenceNo integer"),
        table("image", "image_id integer primary key, path varchar"),
        table("cue", """
            cue_id integer primary key, content_id integer, kind integer, colorTableIndex integer, cueComment varchar, isActiveLoop integer, \
            beatLoopNumerator integer, beatLoopDenominator integer, inUsec integer, outUsec integer, in150FramePerSec integer, \
            out150FramePerSec integer, inMpegFrameNumber integer, outMpegFrameNumber integer, inMpegAbs integer, outMpegAbs integer, \
            inDecodingStartFramePosition integer, outDecodingStartFramePosition integer, inFileOffsetInBlock integer, \
            OutFileOffsetInBlock integer, inNumberOfSampleInBlock integer, outNumberOfSampleInBlock integer
            """),
        table("menuItem", "menuItem_id integer primary key, kind integer, name varchar"),
        table("category", "category_id integer primary key, menuItem_id integer, sequenceNo integer, isVisible integer"),
        table("sort", "sort_id integer primary key, menuItem_id integer, sequenceNo integer, isVisible integer, isSelectedAsSubColumn integer"),
        table("property", """
            deviceName varchar, dbVersion varchar, numberOfContents integer, createdDate varchar, backGroundColorType integer, \
            myTagMasterDBID integer
            """),
        table("recommendedLike", "content_id_1 integer, content_id_2 integer, rating integer, createdDate integer"),
        table("myTag", "myTag_id integer primary key, sequenceNo integer, name varchar, attribute integer, myTag_id_parent integer"),
        table("myTag_content", "myTag_id integer, content_id integer"),
    ]

    public static let indexes: [Index] = [
        Index(name: "index_playlist_content_playlist_id", table: "playlist_content", column: "playlist_id"),
        Index(name: "index_myTag_content_myTag_id", table: "myTag_content", column: "myTag_id"),
        Index(name: "index_myTag_content_content_id", table: "myTag_content", column: "content_id"),
        Index(name: "index_hotCueBankList_cue_hotCueBankList_id", table: "hotCueBankList_cue", column: "hotCueBankList_id"),
    ]

    /// "CREATE TABLE <t>(<c> <type>[ primary key], …)" / "CREATE INDEX <i> on <t>(<c>)".
    /// rekordbox가 만든 `sqlite_master.sql`과 글자까지 같은 모양(끝 ";" 없음)
    public static func ddl() -> [String] {
        tables.map(statement) + indexes.map(statement)
    }

    static func statement(_ table: Table) -> String {
        "CREATE TABLE \(table.name)("
            + table.columns.map { "\($0.name) \($0.type)" + ($0.primaryKey ? " primary key" : "") }.joined(separator: ", ") + ")"
    }

    static func statement(_ index: Index) -> String {
        "CREATE INDEX \(index.name) on \(index.table)(\(index.column))"
    }

    public static func table(named name: String) -> Table? {
        tables.first { $0.name == name }
    }

    /// "이름 자료형[ primary key], …" → 표
    private static func table(_ name: String, _ columns: String) -> Table {
        Table(name: name, columns: columns.components(separatedBy: ", ").map { declaration in
            let words = declaration.split(separator: " ").map(String.init)
            return Column(name: words[0], type: words[1], primaryKey: words.dropFirst(2).joined(separator: " ") == "primary key")
        })
    }
}
