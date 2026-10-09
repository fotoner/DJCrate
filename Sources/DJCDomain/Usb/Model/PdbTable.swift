import Foundation

/// `export.pdb` 표 번호(파일 머리 표 포인터의 type)
public enum PdbTableType: Int, CaseIterable, Sendable {
    case tracks = 0, genres = 1, artists = 2, albums = 3, labels = 4, keys = 5, colors = 6,
         playlistTree = 7, playlistEntries = 8, unknown9 = 9, unknown10 = 10,
         historyPlaylists = 11, historyEntries = 12, artwork = 13, unknown14 = 14, unknown15 = 15,
         columns = 16, category = 17, sort = 18, history19 = 19

    /// 보고서·lab 출력에 쓰는 이름
    public var name: String {
        switch self {
        case .tracks: "tracks"
        case .genres: "genres"
        case .artists: "artists"
        case .albums: "albums"
        case .labels: "labels"
        case .keys: "keys"
        case .colors: "colors"
        case .playlistTree: "playlist_tree"
        case .playlistEntries: "playlist_entries"
        case .unknown9: "unknown9"
        case .unknown10: "unknown10"
        case .historyPlaylists: "history_playlists"
        case .historyEntries: "history_entries"
        case .artwork: "artwork"
        case .unknown14: "unknown14"
        case .unknown15: "unknown15"
        case .columns: "columns"
        case .category: "category"
        case .sort: "sort"
        case .history19: "history19"
        }
    }
}

/// `exportExt.pdb` 표 번호
public enum PdbExtTableType: Int, CaseIterable, Sendable {
    case unknown0 = 0, unknown1, unknown2, tags = 3, tagTracks = 4, unknown5, unknown6, myTagProperty = 7, unknown8

    public var name: String {
        switch self {
        case .tags: "tags"
        case .tagTracks: "tag_tracks"
        case .myTagProperty: "my_tag_property"
        default: "unknown\(rawValue)"
        }
    }
}

/// Device Library 파일 둘
public enum PdbFileKind: String, Sendable, Hashable {
    case export, exportExt

    public var fileName: String {
        switch self {
        case .export: "export.pdb"
        case .exportExt: "exportExt.pdb"
        }
    }

    /// 파일 머리 num_tables. 이 수가 아니면 읽지 않는다
    public var tableCount: Int {
        switch self {
        case .export: PdbTableType.allCases.count
        case .exportExt: PdbExtTableType.allCases.count
        }
    }

    /// 보고서 표 이름. exportExt 표는 "exportExt." 접두어를 붙여 export 표와 섞이지 않게 한다
    public func tableName(_ type: UInt32) -> String {
        switch self {
        case .export: PdbTableType(rawValue: Int(type))?.name ?? "type\(type)"
        case .exportExt: "exportExt." + (PdbExtTableType(rawValue: Int(type))?.name ?? "type\(type)")
        }
    }

    /// 행 0x00 subtype·0x02 index_shift가 있는 표(index_shift는 자리 × 0x20이라 해석에 쓰지 않는다)
    public func rowHasIndexShift(_ type: UInt32) -> Bool {
        switch self {
        case .export: [PdbTableType.tracks, .artists, .albums, .history19].map { UInt32($0.rawValue) }.contains(type)
        case .exportExt: [PdbExtTableType.tags, .myTagProperty].map { UInt32($0.rawValue) }.contains(type)
        }
    }

    package init?(tableCount: UInt32) {
        switch Int(tableCount) {
        case PdbFileKind.export.tableCount: self = .export
        case PdbFileKind.exportExt.tableCount: self = .exportExt
        default: return nil
        }
    }
}

/// DeviceSQL 문자열 모양
public enum PdbStringKind: String, Sendable, Hashable, CaseIterable {
    /// 첫 바이트 홀수 `((n+1)<<1)+1` + ASCII n바이트(끝 표시 없음)
    case shortASCII
    /// `40`, u16 길이(머리 4 포함), `00`, ASCII
    case longASCII
    /// `90`, u16 길이(머리 4 포함), `00`, UTF-16LE
    case utf16LE
    /// `90`, u16 길이, `00`, `03`, ASCII, `00`(트랙 ISRC 칸에만)
    case isrc
}
