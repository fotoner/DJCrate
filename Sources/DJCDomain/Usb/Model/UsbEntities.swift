import Foundation

/// 지운 ID 종류(예 "content"). pdb 죽은 행 ID를 종류별로 모은다.
public typealias UsbIDKindKey = String

/// 이름만 있는 표(artist·genre·key·label·color)의 행
public struct UsbNamedRow: Sendable, Hashable {
    public var id: Int
    public var name: String
    /// OneLibrary artist.nameForSearch
    public var nameForSearch: String?

    public init(id: Int, name: String, nameForSearch: String? = nil) {
        self.id = id
        self.name = name
        self.nameForSearch = nameForSearch
    }
}

public struct UsbAlbum: Sendable, Hashable {
    public var id: Int
    public var name: String
    public var artistID: Int?
    /// OneLibrary만
    public var imageID: Int?
    /// OneLibrary `isComplation`
    public var isCompilation: Int
    public var nameForSearch: String?

    public init(id: Int, name: String, artistID: Int? = nil, imageID: Int? = nil, isCompilation: Int = 0, nameForSearch: String? = nil) {
        self.id = id
        self.name = name
        self.artistID = artistID
        self.imageID = imageID
        self.isCompilation = isCompilation
        self.nameForSearch = nameForSearch
    }
}

/// 아트워크. 두 형식이 같은 id로 다른 파일 이름을 가리킨다.
public struct UsbImage: Sendable, Hashable {
    public var id: Int
    /// "/PIONEER/Artwork/%05d/b%d.jpg"
    public var oneLibraryPath: String?
    /// ".../a%d.jpg"
    public var pdbPath: String?

    public init(id: Int, oneLibraryPath: String? = nil, pdbPath: String? = nil) {
        self.id = id
        self.oneLibraryPath = oneLibraryPath
        self.pdbPath = pdbPath
    }
}

public struct UsbPlaylist: Sendable, Hashable {
    /// 한 형식 모델에서는 그 형식 DB의 목록 번호. 두 형식을 합친 모델에서는 대표 번호다(OneLibrary 번호, Device Library에만 있는
    /// 목록은 그 번호, 그 번호가 OneLibrary에서 쓰이면 음수 −번호). 형식 번호는 `id(in:)`
    public var id: Int
    public var name: String
    /// 0 = 맨 위. 합친 모델에서는 부모의 대표 번호
    public var parentID: Int
    /// 0 목록, 1 폴더, 4 스마트
    public var attribute: Int
    /// OneLibrary만
    public var imageID: Int?
    public var presentIn: Set<UsbFormat>
    /// OneLibrary playlist.sequenceNo / pdb playlist_tree sort_order
    public var sortOrder: [UsbFormat: Int]
    /// content_id 순서(sequenceNo·entry_index 순)
    public var entries: [UsbFormat: [Int]]
    /// 형식 DB의 목록 번호가 `id`와 다를 때만 그 형식 번호(합친 모델 전용, 투영하면 비운다).
    /// rekordbox는 새 목록 번호로 Device Library는 빈 번호를 다시 쓰고 OneLibrary는 가장 큰 값+1을 써서 두 형식 번호가 갈린다(#233)
    public var formatIDs: [UsbFormat: Int]

    public init(id: Int, name: String, parentID: Int = 0, attribute: Int = 0, imageID: Int? = nil, presentIn: Set<UsbFormat> = [],
                sortOrder: [UsbFormat: Int] = [:], entries: [UsbFormat: [Int]] = [:], formatIDs: [UsbFormat: Int] = [:]) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.attribute = attribute
        self.imageID = imageID
        self.presentIn = presentIn
        self.sortOrder = sortOrder
        self.entries = entries
        self.formatIDs = formatIDs
    }

    /// 그 형식 DB의 목록 번호
    public func id(in format: UsbFormat) -> Int { formatIDs[format] ?? id }
}

public struct UsbMyTag: Sendable, Hashable {
    /// 2³¹을 넘을 수 있다
    public var id: Int64
    /// 0 = 분류
    public var parentID: Int64
    /// 0부터
    public var sequenceNo: Int
    public var name: String
    public var isCategory: Bool

    public init(id: Int64, parentID: Int64, sequenceNo: Int, name: String, isCategory: Bool) {
        self.id = id
        self.parentID = parentID
        self.sequenceNo = sequenceNo
        self.name = name
        self.isCategory = isCategory
    }
}

public struct UsbMyTagLink: Sendable, Hashable {
    public var myTagID: Int64
    public var contentID: Int
    public var presentIn: Set<UsbFormat>

    public init(myTagID: Int64, contentID: Int, presentIn: Set<UsbFormat>) {
        self.myTagID = myTagID
        self.contentID = contentID
        self.presentIn = presentIn
    }
}

public struct UsbMenuItem: Sendable, Hashable {
    public var id: Int
    /// Class + 256
    public var kind: Int
    /// U+FFFA/U+FFFB 없이
    public var name: String

    public init(id: Int, kind: Int, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

public struct UsbCategory: Sendable, Hashable {
    public var id: Int
    public var menuItemID: Int
    public var sequenceNo: Int
    public var isVisible: Bool
    /// Device Library만
    public var infoOrder: Int?
    /// Device Library만
    public var disable: Int?

    public init(id: Int, menuItemID: Int, sequenceNo: Int, isVisible: Bool, infoOrder: Int? = nil, disable: Int? = nil) {
        self.id = id
        self.menuItemID = menuItemID
        self.sequenceNo = sequenceNo
        self.isVisible = isVisible
        self.infoOrder = infoOrder
        self.disable = disable
    }
}

public struct UsbSort: Sendable, Hashable {
    public var id: Int
    public var menuItemID: Int
    public var sequenceNo: Int
    public var isVisible: Bool
    public var isSelectedAsSubColumn: Bool
    /// Device Library만
    public var disable: Int?

    public init(id: Int, menuItemID: Int, sequenceNo: Int, isVisible: Bool, isSelectedAsSubColumn: Bool, disable: Int? = nil) {
        self.id = id
        self.menuItemID = menuItemID
        self.sequenceNo = sequenceNo
        self.isVisible = isVisible
        self.isSelectedAsSubColumn = isSelectedAsSubColumn
        self.disable = disable
    }
}

/// 기기가 남긴 재생 기록(형식마다 따로)
public struct UsbHistory: Sendable, Hashable {
    public var format: UsbFormat
    public var id: Int
    public var name: String
    public var entries: [Int]

    public init(format: UsbFormat, id: Int, name: String, entries: [Int]) {
        self.format = format
        self.id = id
        self.name = name
        self.entries = entries
    }
}

/// 읽었지만 모델에 담지 않는 표의 산 행 수. 쓸 때 조용히 지우지 않도록 남긴다.
/// OneLibrary는 `file` = "exportLibrary.db", `tableType` = `OneLibrarySchema.tables` 안 위치다.
public struct UsbUnknownRows: Sendable, Hashable {
    public var format: UsbFormat
    public var file: String
    public var tableType: Int
    public var liveRows: Int

    public init(format: UsbFormat, file: String, tableType: Int, liveRows: Int) {
        self.format = format
        self.file = file
        self.tableType = tableType
        self.liveRows = liveRows
    }
}
