import Foundation

/// 곡 추가 계획: rekordbox 7.2.18이 파일을 컬렉션에 넣을 때(자동 분석을 끈 상태) 만드는 `djmdContent` 행의 칸 값.
///
/// 2026-09-26 실험(O-Ku-Ri-Mo-No Sunday! 분석 전 추가, 6곡 분석 추가)에서 확인한 규칙:
/// - 제목은 태그, 없으면 확장자를 뺀 파일 이름. 경로·파일 이름은 NFC.
/// - 아티스트·앨범·장르·작곡가는 이름으로 찾고 없으면 새 행(작곡가도 `djmdArtist`).
/// - 분석 칸(BPM·BitRate·BitDepth·SampleRate·KeyID·AnalysisDataPath)은 0이나 빈 값, `Analysed` 0, `ContentLink` 14.
/// - 길이는 초 반올림(분석 뒤에는 rekordbox가 다시 적는다).
/// - `rb_file_id`는 파일 inode, `DateCreated`는 파일을 만든 날, `StockDate`는 넣은 날(둘 다 이 컴퓨터 시간대 날짜).
public struct TrackAddPlan: Sendable, Codable, Equatable {
    public var path: String
    public var fileName: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var comment: String
    public var year: Int
    public var trackNumber: Int
    public var discNumber: Int
    public var isrc: String
    public var lyricist: String
    public var fileType: Int
    public var fileSize: Int
    public var fileID: String
    public var length: Int
    /// AVFoundation이 잰 길이(초). 분석을 붙이면 rekordbox처럼 버림해 적는다.
    public var duration: Double
    public var dateCreated: String
    public var stockDate: String
    /// 내장 아트워크 원본(태그). 분석까지 붙여 넣을 때 rekordbox처럼 아트워크 파일 셋을 만든다(`TrackArtwork`).
    public var artwork: Data?

    public init(path: String, fileName: String, title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, composer: String? = nil, comment: String, year: Int, trackNumber: Int, discNumber: Int, isrc: String,
                lyricist: String, fileType: Int, fileSize: Int, fileID: String, length: Int, duration: Double, dateCreated: String,
                stockDate: String, artwork: Data? = nil) {
        self.path = path
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.composer = composer
        self.comment = comment
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.isrc = isrc
        self.lyricist = lyricist
        self.fileType = fileType
        self.fileSize = fileSize
        self.fileID = fileID
        self.length = length
        self.duration = duration
        self.dateCreated = dateCreated
        self.stockDate = stockDate
        self.artwork = artwork
    }
}
