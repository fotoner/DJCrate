import DJCDomain
import Foundation

/// 행 하나의 칸 읽기. 행 밖을 읽으면 `UsbError.readFailed`(그 행만 문제 목록에 넣는다).
/// 읽은 문자열의 종류·오프셋은 `strings`에 남겨 통계를 낸다.
struct PdbRowReader {
    struct DecodedString {
        var kind: PdbStringKind
        var offset: Int
        var length: Int
    }

    let data: Data
    private let bytes: [UInt8]
    private(set) var strings: [DecodedString] = []
    /// 먼 오프셋 모양(0x0064·0x0084·0x0684)으로 읽었는지. 왕복 검사가 다시 쓴 파일과 비교할 수 있게 보고서에 센다
    private(set) var farShape = false

    init(_ data: Data) {
        self.data = Data(data)
        bytes = [UInt8](data)
    }

    var count: Int { bytes.count }

    func require(_ length: Int) throws {
        guard bytes.count >= length else { throw UsbError.readFailed(detail: "pdb row \(bytes.count) bytes, needs \(length)") }
    }

    func u8(_ at: Int) throws -> Int {
        try require(at + 1)
        return Int(bytes[at])
    }

    func u16(_ at: Int) throws -> Int {
        try require(at + 2)
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }

    func u32(_ at: Int) throws -> Int64 {
        try require(at + 4)
        return (0..<4).reduce(Int64(0)) { $0 | Int64(bytes[at + $1]) << (8 * $1) }
    }

    /// id 칸(0 = 없음 → nil)
    func reference(_ at: Int) throws -> Int? {
        let value = Int(try u32(at))
        return value == 0 ? nil : value
    }

    mutating func markFarShape() {
        farShape = true
    }

    mutating func string(_ at: Int, isrcAllowed: Bool = false) throws -> (value: String, kind: PdbStringKind) {
        let decoded = try PdbStringDecoder.decode(data, at: at, isrcAllowed: isrcAllowed)
        strings.append(DecodedString(kind: decoded.kind, offset: at, length: decoded.value.utf16.count))
        return (decoded.value, decoded.kind)
    }
}

/// 표별 행 해석. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)로 칸을 정했다. 아티스트·앨범 먼 오프셋 모양(0x0064·0x0084)은
/// rekordbox 7.2.x 경계 실험(2026-10-08)에서 확인했다. 먼 모양 행은 `PdbRowReader.farShape`로 표시한다(My Tag 0x0684는 확인 못 함).
enum PdbRows {
    /// 트랙 행 고정 칸 길이(문자열 오프셋 21개까지)
    static let trackFixedSize = 0x5E + 2 * trackStringCount
    static let trackStringCount = 21
    /// 뜻 모를 트랙 문자열 칸 번호(값을 왕복 검사용으로 남긴다)
    static let trackUnknownStrings = [5, 8, 9, 13, 18]
    /// 참·거짓 트랙 문자열 칸 번호(6 kuvo 공개·7 핫큐 자동 불러오기). "ON"만 참이고, 원래 값을 왕복 검사용으로 남긴다
    static let trackFlagStrings = [6, 7]

    static func track(_ row: inout PdbRowReader) throws -> (UsbTrack, UsbPdbTrackExtras) {
        try row.require(trackFixedSize)
        let subtype = try row.u16(0x00)
        guard subtype == 0x0024 else { throw UsbError.readFailed(detail: String(format: "pdb track subtype 0x%04X", subtype)) }
        var strings: [String] = [], kinds: [PdbStringKind] = []
        for index in 0..<trackStringCount {
            let offset = try row.u16(0x5E + 2 * index)
            guard offset >= trackFixedSize else { throw UsbError.readFailed(detail: "pdb track string \(index) inside fixed fields") }
            let decoded = try row.string(offset, isrcAllowed: index == 0)
            strings.append(decoded.value)
            kinds.append(decoded.kind)
        }
        let rating = try row.u8(0x59), playCount = try row.u16(0x4E)
        let track = UsbTrack(
            id: Int(try row.u32(0x48)), presentIn: [.deviceLibrary], title: strings[17], titleForSearch: nil, subtitle: strings[12],
            bpmx100: Int(try row.u32(0x38)), lengthSeconds: try row.u16(0x54), trackNo: Int(try row.u32(0x34)), discNo: try row.u16(0x4C),
            artistID: try row.reference(0x44), remixerID: try row.reference(0x2C), originalArtistID: try row.reference(0x24),
            composerID: try row.reference(0x0C), lyricistArtistID: nil, lyricist: strings[1],
            albumID: try row.reference(0x40), genreID: try row.reference(0x3C), labelID: try row.reference(0x28), keyID: try row.reference(0x20),
            colorID: try row.u8(0x58), imageID: try row.reference(0x1C),
            comment: strings[16], rating: rating, releaseYear: try row.u16(0x50), releaseDate: strings[11],
            dateCreated: strings[10], dateAdded: strings[15],
            path: strings[20], fileName: strings[19], fileSize: try row.u32(0x10), fileType: try row.u16(0x5A),
            bitrate: Int(try row.u32(0x30)), bitDepth: try row.u16(0x52), sampleRate: Int(try row.u32(0x08)), isrc: strings[0],
            djPlayCount: playCount, hotCueAutoLoad: strings[7] == "ON", kuvoDeliver: strings[6] == "ON", kuvoDeliveryComment: "",
            masterDbId: try row.u32(0x18), masterContentId: try row.u32(0x14), analysisDataPath: strings[14],
            analysedBits: 0, contentLink: 0, hasModified: 0,
            cueUpdateCount: strings[4], analysisDataUpdateCount: strings[3], informationUpdateCount: strings[2],
            deviceFields: [.deviceLibrary: UsbTrackDeviceFields(rating: rating, playCount: playCount, hasModified: nil)])
        let extras = UsbPdbTrackExtras(
            subtype: UInt16(subtype), bitmask: UInt32(try row.u32(0x04)), u5: UInt16(try row.u16(0x56)), u7: UInt16(try row.u16(0x5C)),
            unknownStrings: Dictionary(uniqueKeysWithValues: trackUnknownStrings.map { ($0, strings[$0]) }), stringKinds: kinds,
            flagStrings: Dictionary(uniqueKeysWithValues: trackFlagStrings.map { ($0, strings[$0]) }))
        return (track, extras)
    }

    /// genres·labels·history_playlists·artwork: u32 id, 문자열 @0x04
    static func idName(_ row: inout PdbRowReader) throws -> (id: Int, name: String) {
        (Int(try row.u32(0)), try row.string(0x04).value)
    }

    /// 가까운 모양 0x0060: u8 이름 오프셋 @0x09, 먼 모양 0x0064: u16 @0x0A
    static func artist(_ row: inout PdbRowReader) throws -> UsbNamedRow {
        let subtype = try row.u16(0)
        let offset: Int
        switch subtype {
        case 0x0060: offset = try row.u8(0x09)
        case 0x0064:
            offset = try row.u16(0x0A)
            row.markFarShape()
        default: throw UsbError.readFailed(detail: String(format: "pdb artist subtype 0x%04X", subtype))
        }
        return UsbNamedRow(id: Int(try row.u32(0x04)), name: try row.string(offset).value)
    }

    /// 가까운 모양 0x0080: u8 이름 오프셋 @0x15, 먼 모양 0x0084: u16 @0x16
    static func album(_ row: inout PdbRowReader) throws -> UsbAlbum {
        let subtype = try row.u16(0)
        let offset: Int
        switch subtype {
        case 0x0080: offset = try row.u8(0x15)
        case 0x0084:
            offset = try row.u16(0x16)
            row.markFarShape()
        default: throw UsbError.readFailed(detail: String(format: "pdb album subtype 0x%04X", subtype))
        }
        return UsbAlbum(id: Int(try row.u32(0x0C)), name: try row.string(offset).value, artistID: try row.reference(0x08))
    }

    /// u32 id, u32 id(같은 값), 문자열 @0x08
    static func key(_ row: inout PdbRowReader) throws -> UsbNamedRow {
        UsbNamedRow(id: Int(try row.u32(0)), name: try row.string(0x08).value)
    }

    /// u32 0, u8 id, u16 id, u8 0, 문자열 @0x08
    static func color(_ row: inout PdbRowReader) throws -> UsbNamedRow {
        UsbNamedRow(id: try row.u16(0x05), name: try row.string(0x08).value)
    }

    struct PlaylistNode {
        var id: Int
        var name: String
        var parentID: Int
        var sortOrder: Int
        var isFolder: Bool
    }

    /// u32 parent_id, u32 0, u32 sort_order, u32 id, u32 is_folder, 문자열 @0x14
    static func playlistTree(_ row: inout PdbRowReader) throws -> PlaylistNode {
        PlaylistNode(id: Int(try row.u32(0x0C)), name: try row.string(0x14).value, parentID: Int(try row.u32(0)),
                     sortOrder: Int(try row.u32(0x08)), isFolder: try row.u32(0x10) != 0)
    }

    /// 목록 항목 u32 entry_index, u32 track_id, u32 playlist_id
    static func playlistEntry(_ row: PdbRowReader) throws -> (index: Int, trackID: Int, playlistID: Int) {
        (Int(try row.u32(0)), Int(try row.u32(4)), Int(try row.u32(8)))
    }

    /// 기록 항목 u32 track_id, u32 playlist_id, u32 entry_index
    static func historyEntry(_ row: PdbRowReader) throws -> (index: Int, trackID: Int, playlistID: Int) {
        (Int(try row.u32(8)), Int(try row.u32(0)), Int(try row.u32(4)))
    }

    /// u16 id, u16 code, 문자열 @0x04(U+FFFA … U+FFFB로 감쌈)
    static func column(_ row: inout PdbRowReader) throws -> UsbMenuItem {
        UsbMenuItem(id: try row.u16(0), kind: try row.u16(2), name: OneLibraryReader.unwrapMenuName(try row.string(0x04).value))
    }

    /// u16 menuItemID, u16 id, u8 InfoOrder, u8 Disable, u16 Seq
    static func category(_ row: PdbRowReader) throws -> UsbCategory {
        let disable = try row.u8(5)
        return UsbCategory(id: try row.u16(2), menuItemID: try row.u16(0), sequenceNo: try row.u16(6), isVisible: disable != 1,
                           infoOrder: try row.u8(4), disable: disable)
    }

    /// u16 menuItemID, u16 id, u8 Disable, u8 Seq, u16 0
    static func sort(_ row: PdbRowReader) throws -> UsbSort {
        let disable = try row.u8(4)
        return UsbSort(id: try row.u16(2), menuItemID: try row.u16(0), sequenceNo: try row.u8(5), isVisible: disable != 1,
                       isSelectedAsSubColumn: disable == 2, disable: disable)
    }

    struct PropertyRow {
        var count: Int
        var date: String
        var version: String
        var name: String
    }

    /// 표 19(subtype 0x0280): u32 곡 수 @0x04, 날짜 @0x0C, u8 버전 오프셋 @0x17, u8 두 번째 문자열 오프셋 @0x18
    static func property(_ row: inout PdbRowReader) throws -> PropertyRow {
        let subtype = try row.u16(0)
        guard subtype == 0x0280 else { throw UsbError.readFailed(detail: String(format: "pdb property subtype 0x%04X", subtype)) }
        let versionOffset = try row.u8(0x17), nameOffset = try row.u8(0x18)
        return PropertyRow(count: Int(try row.u32(0x04)), date: try row.string(0x0C).value, version: try row.string(versionOffset).value,
                           name: try row.string(nameOffset).value)
    }

    /// 먼 모양 태그 행에서 문자열이 시작할 수 있는 가장 앞 자리(u16 오프셋 두 칸 뒤)
    static let farTagFixedSize = 0x22

    /// exportExt tags. 가까운 모양 0x0680: u8 0x03 @0x1C, u8 이름 오프셋 @0x1D, u8 두 번째 @0x1E.
    /// 먼 모양 0x0684는 아티스트·앨범 먼 모양과 같은 규칙으로 u16 0x0003 @0x1C, u16 이름 @0x1E, u16 두 번째 @0x20이다
    /// (Deep Symmetry 분석 문서·rekordcrate가 같은 자리, #189). 골든에 없어 rekordbox로 확인하지 못했으므로, 오프셋 순서가 맞지 않으면
    /// 틀린 이름을 조용히 읽지 않도록 행을 버리고, 읽은 행도 읽는 쪽이 구조 문제로 남긴다.
    static func tag(_ row: inout PdbRowReader) throws -> UsbMyTag {
        let subtype = try row.u16(0)
        let offset: Int
        switch subtype {
        case 0x0680: offset = try row.u8(0x1D)
        case 0x0684:
            offset = try row.u16(0x1E)
            let second = try row.u16(0x20)
            guard offset >= farTagFixedSize, offset < second else {
                throw UsbError.readFailed(detail: "pdb far tag row offsets \(offset)/\(second)")
            }
            _ = try PdbStringDecoder.decode(row.data, at: second)
            row.markFarShape()
        default: throw UsbError.readFailed(detail: String(format: "pdb tag subtype 0x%04X", subtype))
        }
        return UsbMyTag(id: try row.u32(0x14), parentID: try row.u32(0x0C), sequenceNo: Int(try row.u32(0x10)),
                        name: try row.string(offset).value, isCategory: try row.u8(0x1B) == 1)
    }

    /// u32 0, u32 track_id, u32 tag_id, u32 3
    static func tagTrack(_ row: PdbRowReader) throws -> UsbMyTagLink {
        UsbMyTagLink(myTagID: try row.u32(8), contentID: Int(try row.u32(4)), presentIn: [.deviceLibrary])
    }

    /// exportExt 표 7(subtype 0x0700): u32 myTagMasterDBID @0x18
    static func myTagProperty(_ row: PdbRowReader) throws -> Int64 {
        let subtype = try row.u16(0)
        guard subtype == 0x0700 else { throw UsbError.readFailed(detail: String(format: "pdb my tag property subtype 0x%04X", subtype)) }
        return try row.u32(0x18)
    }

    /// 죽은 행의 id(지운 ID 재사용 금지용). 모델 표 이름과 id 칸 자리. 해석되지 않으면 nil
    static func deadID(_ table: PdbTableType, _ row: PdbRowReader) -> (kind: UsbIDKindKey, id: Int)? {
        let found: (UsbIDKindKey, Int64?)
        switch table {
        case .tracks: found = ("content", row.count >= trackFixedSize && (try? row.u16(0)) == 0x0024 ? try? row.u32(0x48) : nil)
        case .artists: found = ("artist", try? row.u32(0x04))
        case .albums: found = ("album", try? row.u32(0x0C))
        case .genres: found = ("genre", try? row.u32(0))
        case .keys: found = ("key", try? row.u32(0))
        case .labels: found = ("label", try? row.u32(0))
        case .artwork: found = ("image", try? row.u32(0))
        case .playlistTree: found = ("playlist", try? row.u32(0x0C))
        default: return nil
        }
        guard let id = found.1, id != 0 else { return nil }
        return (found.0, Int(id))
    }
}
