import Foundation

/// rekordbox 폴더의 `masterPlaylists6.xml` NODE 한 줄(재생 목록·폴더마다 하나, `MasterPlaylistsXML.Node`). 파일 읽기·고치기는 RekordboxKit.
/// `Id`·`ParentId`는 목록 ID의 16진수 대문자(맨 위는 `0`)다.
public struct MasterPlaylistNode: Sendable, Equatable {
    public var id: String
    public var parentID: String
    public var attribute: Int
    public var timestamp: Int64
    public var libType: Int
    public var checkType: Int

    public init(id: String, parentID: String, attribute: Int, timestamp: Int64, libType: Int, checkType: Int) {
        self.id = id
        self.parentID = parentID
        self.attribute = attribute
        self.timestamp = timestamp
        self.libType = libType
        self.checkType = checkType
    }

    /// DB 목록 ID("root" 포함) → NODE의 Id 글자
    public static func hex(_ id: String) -> String? {
        if id == "root" { return "0" }
        return UInt64(id).map { String($0, radix: 16, uppercase: true) }
    }
}
