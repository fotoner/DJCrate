import Foundation

/// USB 라이브러리의 곡 하나(형식 중립). OneLibrary `content` 행과 Device Library 트랙 행을 함께 담는다.
/// 어느 칸이 어느 형식에만 있는지는 `UsbFieldFormats`에 있다.
public struct UsbTrack: Sendable, Hashable {
    /// content_id = pdb 트랙 id
    public var id: Int
    public var presentIn: Set<UsbFormat>
    public var title: String
    /// OneLibrary 칸(보통 NULL)
    public var titleForSearch: String?
    /// OneLibrary subtitle = pdb mix_name
    public var subtitle: String
    public var bpmx100: Int
    public var lengthSeconds: Int
    public var trackNo: Int
    public var discNo: Int
    public var artistID: Int?
    public var remixerID: Int?
    public var originalArtistID: Int?
    public var composerID: Int?
    /// OneLibrary artist_id_lyricist
    public var lyricistArtistID: Int?
    /// pdb 작사가 글자(로컬 Lyricist)
    public var lyricist: String
    public var albumID: Int?
    public var genreID: Int?
    public var labelID: Int?
    public var keyID: Int?
    /// 0 = 없음
    public var colorID: Int
    /// OneLibrary image_id = pdb artwork_id
    public var imageID: Int?
    /// djComment = pdb 코멘트
    public var comment: String
    public var rating: Int
    public var releaseYear: Int
    public var releaseDate: String
    public var dateCreated: String
    public var dateAdded: String
    /// "/Contents/…"
    public var path: String
    /// path 끝 성분
    public var fileName: String
    public var fileSize: Int64
    public var fileType: Int
    public var bitrate: Int
    public var bitDepth: Int
    public var sampleRate: Int
    public var isrc: String
    public var djPlayCount: Int
    public var hotCueAutoLoad: Bool
    public var kuvoDeliver: Bool
    public var kuvoDeliveryComment: String
    public var masterDbId: Int64
    public var masterContentId: Int64
    /// "/PIONEER/USBANLZ/P???/????????/ANLZ000N.DAT"
    public var analysisDataPath: String
    public var analysedBits: Int
    public var contentLink: Int
    public var hasModified: Int
    /// 로컬 문자열 그대로("" = NULL). TEXT로 바인드하면 숫자는 INTEGER, ""는 TEXT가 된다
    public var cueUpdateCount: String
    public var analysisDataUpdateCount: String
    public var informationUpdateCount: String
    /// 형식마다 기기가 바꿀 수 있는 칸
    public var deviceFields: [UsbFormat: UsbTrackDeviceFields]

    public init(
        id: Int, presentIn: Set<UsbFormat> = [], title: String = "", titleForSearch: String? = nil, subtitle: String = "",
        bpmx100: Int = 0, lengthSeconds: Int = 0, trackNo: Int = 0, discNo: Int = 0,
        artistID: Int? = nil, remixerID: Int? = nil, originalArtistID: Int? = nil, composerID: Int? = nil,
        lyricistArtistID: Int? = nil, lyricist: String = "",
        albumID: Int? = nil, genreID: Int? = nil, labelID: Int? = nil, keyID: Int? = nil, colorID: Int = 0, imageID: Int? = nil,
        comment: String = "", rating: Int = 0, releaseYear: Int = 0, releaseDate: String = "", dateCreated: String = "", dateAdded: String = "",
        path: String = "", fileName: String = "", fileSize: Int64 = 0, fileType: Int = 0,
        bitrate: Int = 0, bitDepth: Int = 0, sampleRate: Int = 0, isrc: String = "", djPlayCount: Int = 0,
        hotCueAutoLoad: Bool = false, kuvoDeliver: Bool = false, kuvoDeliveryComment: String = "",
        masterDbId: Int64 = 0, masterContentId: Int64 = 0, analysisDataPath: String = "",
        analysedBits: Int = 0, contentLink: Int = 0, hasModified: Int = 0,
        cueUpdateCount: String = "", analysisDataUpdateCount: String = "", informationUpdateCount: String = "",
        deviceFields: [UsbFormat: UsbTrackDeviceFields] = [:]
    ) {
        self.id = id
        self.presentIn = presentIn
        self.title = title
        self.titleForSearch = titleForSearch
        self.subtitle = subtitle
        self.bpmx100 = bpmx100
        self.lengthSeconds = lengthSeconds
        self.trackNo = trackNo
        self.discNo = discNo
        self.artistID = artistID
        self.remixerID = remixerID
        self.originalArtistID = originalArtistID
        self.composerID = composerID
        self.lyricistArtistID = lyricistArtistID
        self.lyricist = lyricist
        self.albumID = albumID
        self.genreID = genreID
        self.labelID = labelID
        self.keyID = keyID
        self.colorID = colorID
        self.imageID = imageID
        self.comment = comment
        self.rating = rating
        self.releaseYear = releaseYear
        self.releaseDate = releaseDate
        self.dateCreated = dateCreated
        self.dateAdded = dateAdded
        self.path = path
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileType = fileType
        self.bitrate = bitrate
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.isrc = isrc
        self.djPlayCount = djPlayCount
        self.hotCueAutoLoad = hotCueAutoLoad
        self.kuvoDeliver = kuvoDeliver
        self.kuvoDeliveryComment = kuvoDeliveryComment
        self.masterDbId = masterDbId
        self.masterContentId = masterContentId
        self.analysisDataPath = analysisDataPath
        self.analysedBits = analysedBits
        self.contentLink = contentLink
        self.hasModified = hasModified
        self.cueUpdateCount = cueUpdateCount
        self.analysisDataUpdateCount = analysisDataUpdateCount
        self.informationUpdateCount = informationUpdateCount
        self.deviceFields = deviceFields
    }
}

/// 기기(CDJ 등)가 USB에서 바꿀 수 있는 칸. 형식마다 따로 둔다.
public struct UsbTrackDeviceFields: Sendable, Hashable {
    public var rating: Int
    public var playCount: Int
    /// OneLibrary hasModified(Device Library에는 없음)
    public var hasModified: Int?

    public init(rating: Int, playCount: Int, hasModified: Int?) {
        self.rating = rating
        self.playCount = playCount
        self.hasModified = hasModified
    }
}

/// pdb 트랙 행의 상수 칸 관찰값(왕복 검사용). Device Library 읽기가 채운다.
/// 뜻 모를 문자열 칸이 비어 있지 않으면 다시 쓸 때 막도록 값을 그대로 둔다.
public struct UsbPdbTrackExtras: Sendable, Hashable {
    /// 행 0x00(0x0024)
    public var subtype: UInt16
    /// 행 0x04
    public var bitmask: UInt32
    /// 행 0x56
    public var u5: UInt16
    /// 행 0x5C
    public var u7: UInt16
    /// 뜻 모를 문자열 칸(번호 5·8·9·13·18) → 값
    public var unknownStrings: [Int: String]
    /// 문자열 21개 각각의 모양(번호 순서)
    public var stringKinds: [PdbStringKind]
    /// 참·거짓 문자열 칸(번호 6 kuvo 공개·7 핫큐 자동 불러오기) → 원래 값. 모델 칸(`kuvoDeliver`·`hotCueAutoLoad`)은 "ON"만 참으로 읽고
    /// 작성기는 "ON"·''만 쓰므로, 다른 값이면 다시 쓸 때 막도록 그대로 둔다
    public var flagStrings: [Int: String]

    public init(subtype: UInt16 = 0, bitmask: UInt32 = 0, u5: UInt16 = 0, u7: UInt16 = 0, unknownStrings: [Int: String] = [:],
                stringKinds: [PdbStringKind] = [], flagStrings: [Int: String] = [:]) {
        self.subtype = subtype
        self.bitmask = bitmask
        self.u5 = u5
        self.u7 = u7
        self.unknownStrings = unknownStrings
        self.stringKinds = stringKinds
        self.flagStrings = flagStrings
    }
}
