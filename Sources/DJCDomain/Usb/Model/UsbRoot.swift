import Foundation

/// USB 라이브러리의 맨 위 폴더(마운트 지점 또는 디스크 이미지·사본 폴더).
/// 상대 경로를 URL로 바꾸는 `url(for:)`는 링크를 lstat으로 확인하므로 RekordboxKit에 있다.
public struct UsbRoot: Sendable, Hashable {
    public let url: URL

    public init(_ url: URL) {
        self.url = url
    }
}

public struct UsbTreeEntry: Hashable, Sendable {
    /// NFC
    public var relativePath: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64

    public init(relativePath: String, isDirectory: Bool, isSymlink: Bool, size: Int64) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
    }
}

public struct UsbTreeStamp: Codable, Hashable, Sendable {
    public var size: Int64
    public var sha256: String?

    public init(size: Int64, sha256: String?) {
        self.size = size
        self.sha256 = sha256
    }
}
