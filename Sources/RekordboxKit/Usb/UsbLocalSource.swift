import DJCDomain
import Foundation

/// USB 라이브러리를 만들 로컬 재료(색·메뉴·My Tag·곡 행)를 로컬 스냅샷 **사본**에서 읽는다.
/// 라이브 master.db를 연 연결이면 읽지 않는다(`UsbExportCandidates`와 같은 판정).
public struct UsbLocalSource {
    let database: CipherDatabase
    let liveDatabase: URL

    public init(database: CipherDatabase) {
        self.init(database: database, liveDatabase: UsbExportCandidates.liveDatabase)
    }

    /// 시험만 라이브 경로를 바꿔 넘긴다.
    init(database: CipherDatabase, liveDatabase: URL) {
        self.database = database
        self.liveDatabase = liveDatabase
    }

    /// djmdProperty.DBID(64비트)
    public func localDBID() throws -> Int64 {
        try refuseLive()
        var values: [String] = []
        try database.query("SELECT DBID FROM djmdProperty") { values.append($0.string(0) ?? "") }
        guard values.count == 1, let dbid = Int64(values[0]) else {
            // USB가 아니라 로컬 스냅샷 문제다(USB를 다시 연결해도 풀리지 않는다)
            throw UsbError.writeRefused([UsbBlock(code: "localDBID", scope: .volume,
                                                  message: String(ui: "로컬 라이브러리 정보를 읽지 못했습니다. 새 스냅샷을 뜬 뒤 다시 내보내세요"))])
        }
        return dbid
    }

    /// 지우지 않은 djmdColor 전부. id = ID, name = Commnt
    public func colors() throws -> [UsbNamedRow] {
        try refuseLive()
        var rows: [UsbNamedRow] = []
        try database.query("SELECT ID, Commnt FROM djmdColor WHERE rb_local_deleted = 0") { row in
            rows.append(UsbNamedRow(id: Self.intID(row.string(0)), name: row.string(1) ?? "", nameForSearch: nil))
        }
        return rows.sorted { $0.id < $1.id }
    }

    /// djmdMenuItems 전부. kind = Class + 256
    public func menuItems() throws -> [UsbMenuItem] {
        try refuseLive()
        var rows: [UsbMenuItem] = []
        try database.query("SELECT ID, Class, Name FROM djmdMenuItems") { row in
            rows.append(UsbMenuItem(id: Self.intID(row.string(0)), kind: (row.int(1) ?? 0) + 256, name: row.string(2) ?? ""))
        }
        return rows.sorted { $0.id < $1.id }
    }

    /// 지우지 않은 djmdCategory. 보임 = Disable ≠ 1. InfoOrder·Disable은 Device Library 칸으로 남긴다
    public func categories() throws -> [UsbCategory] {
        try refuseLive()
        var rows: [UsbCategory] = []
        try database.query("SELECT ID, MenuItemID, Seq, Disable, InfoOrder FROM djmdCategory WHERE rb_local_deleted = 0") { row in
            rows.append(UsbCategory(id: Self.intID(row.string(0)), menuItemID: Self.intID(row.string(1)), sequenceNo: row.int(2) ?? 0,
                                    isVisible: row.int(3) != 1, infoOrder: row.int(4), disable: row.int(3)))
        }
        return rows.sorted { $0.id < $1.id }
    }

    /// 지우지 않은 djmdSort. 보임 = Disable ≠ 1, 보조 칸 = Disable 2
    public func sorts() throws -> [UsbSort] {
        try refuseLive()
        var rows: [UsbSort] = []
        try database.query("SELECT ID, MenuItemID, Seq, Disable FROM djmdSort WHERE rb_local_deleted = 0") { row in
            rows.append(UsbSort(id: Self.intID(row.string(0)), menuItemID: Self.intID(row.string(1)), sequenceNo: row.int(2) ?? 0,
                                isVisible: row.int(3) != 1, isSelectedAsSubColumn: row.int(3) == 2, disable: row.int(3)))
        }
        return rows.sorted { $0.id < $1.id }
    }

    /// 지우지 않은 djmdMyTag. 순서 = Seq − 1, 부모 "root" → 0, 분류 = Attribute 1
    public func myTags() throws -> [UsbMyTag] {
        try refuseLive()
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
        var rows: [UsbMyTag] = []
        try database.query("SELECT ID, Seq, Name, Attribute, ParentID FROM djmdMyTag WHERE rb_local_deleted = 0") { row in
            let parent = row.string(4)
            rows.append(UsbMyTag(id: Int64(row.string(0) ?? "") ?? 0, parentID: parent == "root" ? 0 : Int64(parent ?? "") ?? 0,
                                 sequenceNo: (row.int(1) ?? 1) - 1, name: row.string(2) ?? "", isCategory: row.int(3) == 1))
        }
        return rows.sorted { $0.id < $1.id }
    }

    /// 곡 한 행과 이름들(지운 곡·없는 곡은 던진다)
    public func track(_ contentID: String) throws -> UsbLocalTrackRow {
        try refuseLive()
        var found: UsbLocalTrackRow?
        try database.query("""
            SELECT c.ID, c.Title, c.Subtitle, c.BPM, c.Length, c.TrackNo, c.DiscNo,
                c.ArtistID, c.RemixerID, c.OrgArtistID, c.ComposerID, ar.Name, rm.Name, oa.Name, co.Name, c.Lyricist,
                c.AlbumID, al.Name, al.AlbumArtistID, aa.Name, al.Compilation,
                c.GenreID, g.Name, c.LabelID, l.Name, c.KeyID, k.ScaleName,
                c.ColorID, c.Commnt, c.Rating, c.ReleaseYear, c.ReleaseDate, c.DateCreated, c.StockDate,
                c.FolderPath, c.FileNameL, c.FileSize, c.FileType, c.BitRate, c.BitDepth, c.SampleRate, c.ISRC, c.DJPlayCount,
                c.HotCueAutoLoad, c.DeliveryControl, c.DeliveryComment, c.MasterDBID, c.MasterSongID, c.AnalysisDataPath, c.ImagePath,
                c.Analysed, c.ContentLink, c.CueUpdated, c.AnalysisUpdated, c.TrackInfoUpdated
            FROM djmdContent c
            LEFT JOIN djmdArtist ar ON ar.ID = c.ArtistID
            LEFT JOIN djmdArtist rm ON rm.ID = c.RemixerID
            LEFT JOIN djmdArtist oa ON oa.ID = c.OrgArtistID
            LEFT JOIN djmdArtist co ON co.ID = c.ComposerID
            LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
            LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID
            LEFT JOIN djmdGenre g ON g.ID = c.GenreID
            LEFT JOIN djmdLabel l ON l.ID = c.LabelID
            LEFT JOIN djmdKey k ON k.ID = c.KeyID
            WHERE c.ID = ? AND c.rb_local_deleted = 0
            """, [.text(contentID)]) { row in
            func text(_ column: Int32) -> String? { row.string(column) }
            func int(_ column: Int32) -> Int? { row.int(column) }
            found = UsbLocalTrackRow(
                id: text(0) ?? contentID, title: text(1), subtitle: text(2), bpm: int(3), length: int(4), trackNo: int(5), discNo: int(6),
                artistID: text(7), remixerID: text(8), orgArtistID: text(9), composerID: text(10),
                artistName: text(11), remixerName: text(12), orgArtistName: text(13), composerName: text(14), lyricist: text(15),
                albumID: text(16), albumName: text(17), albumArtistID: text(18), albumArtistName: text(19), albumCompilation: int(20),
                genreID: text(21), genreName: text(22), labelID: text(23), labelName: text(24), keyID: text(25), keyName: text(26),
                colorID: text(27), comment: text(28), rating: int(29), releaseYear: int(30),
                releaseDate: text(31), dateCreated: text(32), stockDate: text(33),
                folderPath: text(34), fileNameL: text(35), fileSize: int(36).map(Int64.init), fileType: int(37), bitRate: int(38),
                bitDepth: int(39), sampleRate: int(40), isrc: text(41), djPlayCount: int(42),
                hotCueAutoLoad: text(43), deliveryControl: text(44), deliveryComment: text(45),
                masterDBID: text(46), masterSongID: text(47), analysisDataPath: text(48), imagePath: text(49),
                analysed: int(50), contentLink: int(51), cueUpdated: text(52), analysisUpdated: text(53), trackInfoUpdated: text(54))
        }
        guard let found else {
            throw UsbError.writeRefused([UsbBlock(code: "localTrackMissing", scope: .track(contentID),
                                                  message: String(ui: "스냅샷에서 이 곡을 찾지 못했습니다. 새 스냅샷을 뜬 뒤 다시 내보내세요"))])
        }
        return found
    }

    private func refuseLive() throws {
        try UsbExportCandidates.refuseLive(database, liveDatabase: liveDatabase)
    }

    /// 로컬 ID 글자 → 정수(숫자가 아니면 0)
    static func intID(_ text: String?) -> Int {
        Int(text ?? "") ?? 0
    }
}

/// 로컬 djmdContent 한 곡(빌더 입력). 글자 칸은 로컬 값 그대로(NULL → nil), 정수 칸은 NULL → nil.
/// 이름 칸은 조인해서 채운다: artist·remixer·orgArtist·composer = djmdArtist.Name, album = djmdAlbum.Name,
/// albumArtist = djmdAlbum.AlbumArtistID의 djmdArtist.Name, genre = djmdGenre.Name, label = djmdLabel.Name, key = djmdKey.ScaleName.
public struct UsbLocalTrackRow: Sendable, Hashable {
    public var id: String
    public var title: String?
    public var subtitle: String?
    /// 이미 ×100
    public var bpm: Int?
    /// 초
    public var length: Int?
    public var trackNo: Int?
    public var discNo: Int?
    public var artistID: String?
    public var remixerID: String?
    public var orgArtistID: String?
    public var composerID: String?
    public var artistName: String?
    public var remixerName: String?
    public var orgArtistName: String?
    public var composerName: String?
    /// 자유 글자
    public var lyricist: String?
    public var albumID: String?
    public var albumName: String?
    public var albumArtistID: String?
    public var albumArtistName: String?
    public var albumCompilation: Int?
    public var genreID: String?
    public var genreName: String?
    public var labelID: String?
    public var labelName: String?
    public var keyID: String?
    /// djmdKey.ScaleName
    public var keyName: String?
    public var colorID: String?
    /// Commnt
    public var comment: String?
    public var rating: Int?
    public var releaseYear: Int?
    public var releaseDate: String?
    public var dateCreated: String?
    public var stockDate: String?
    public var folderPath: String?
    public var fileNameL: String?
    public var fileSize: Int64?
    public var fileType: Int?
    public var bitRate: Int?
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var isrc: String?
    public var djPlayCount: Int?
    public var hotCueAutoLoad: String?
    public var deliveryControl: String?
    public var deliveryComment: String?
    /// 글자 그대로(정수 변환은 빌더가)
    public var masterDBID: String?
    public var masterSongID: String?
    public var analysisDataPath: String?
    public var imagePath: String?
    public var analysed: Int?
    public var contentLink: Int?
    /// 글자 그대로(TEXT로 바인드한다)
    public var cueUpdated: String?
    public var analysisUpdated: String?
    public var trackInfoUpdated: String?

    public init(id: String, title: String? = nil, subtitle: String? = nil, bpm: Int? = nil, length: Int? = nil, trackNo: Int? = nil,
                discNo: Int? = nil, artistID: String? = nil, remixerID: String? = nil, orgArtistID: String? = nil, composerID: String? = nil,
                artistName: String? = nil, remixerName: String? = nil, orgArtistName: String? = nil, composerName: String? = nil,
                lyricist: String? = nil, albumID: String? = nil, albumName: String? = nil, albumArtistID: String? = nil,
                albumArtistName: String? = nil, albumCompilation: Int? = nil, genreID: String? = nil, genreName: String? = nil,
                labelID: String? = nil, labelName: String? = nil, keyID: String? = nil, keyName: String? = nil, colorID: String? = nil,
                comment: String? = nil, rating: Int? = nil, releaseYear: Int? = nil, releaseDate: String? = nil,
                dateCreated: String? = nil, stockDate: String? = nil, folderPath: String? = nil, fileNameL: String? = nil,
                fileSize: Int64? = nil, fileType: Int? = nil, bitRate: Int? = nil, bitDepth: Int? = nil, sampleRate: Int? = nil,
                isrc: String? = nil, djPlayCount: Int? = nil, hotCueAutoLoad: String? = nil, deliveryControl: String? = nil,
                deliveryComment: String? = nil, masterDBID: String? = nil, masterSongID: String? = nil, analysisDataPath: String? = nil,
                imagePath: String? = nil, analysed: Int? = nil, contentLink: Int? = nil, cueUpdated: String? = nil,
                analysisUpdated: String? = nil, trackInfoUpdated: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.bpm = bpm
        self.length = length
        self.trackNo = trackNo
        self.discNo = discNo
        self.artistID = artistID
        self.remixerID = remixerID
        self.orgArtistID = orgArtistID
        self.composerID = composerID
        self.artistName = artistName
        self.remixerName = remixerName
        self.orgArtistName = orgArtistName
        self.composerName = composerName
        self.lyricist = lyricist
        self.albumID = albumID
        self.albumName = albumName
        self.albumArtistID = albumArtistID
        self.albumArtistName = albumArtistName
        self.albumCompilation = albumCompilation
        self.genreID = genreID
        self.genreName = genreName
        self.labelID = labelID
        self.labelName = labelName
        self.keyID = keyID
        self.keyName = keyName
        self.colorID = colorID
        self.comment = comment
        self.rating = rating
        self.releaseYear = releaseYear
        self.releaseDate = releaseDate
        self.dateCreated = dateCreated
        self.stockDate = stockDate
        self.folderPath = folderPath
        self.fileNameL = fileNameL
        self.fileSize = fileSize
        self.fileType = fileType
        self.bitRate = bitRate
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.isrc = isrc
        self.djPlayCount = djPlayCount
        self.hotCueAutoLoad = hotCueAutoLoad
        self.deliveryControl = deliveryControl
        self.deliveryComment = deliveryComment
        self.masterDBID = masterDBID
        self.masterSongID = masterSongID
        self.analysisDataPath = analysisDataPath
        self.imagePath = imagePath
        self.analysed = analysed
        self.contentLink = contentLink
        self.cueUpdated = cueUpdated
        self.analysisUpdated = analysisUpdated
        self.trackInfoUpdated = trackInfoUpdated
    }
}
