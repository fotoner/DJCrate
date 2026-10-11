import Foundation

/// USB DB 파일·사이드카의 지문. 읽은 뒤 USB가 바뀌었는지 보고 저널에 남기는 데 쓴다.
public struct UsbFingerprint: Codable, Hashable, Sendable {
    public struct Stamp: Codable, Hashable, Sendable {
        public var size: Int64
        public var mtime: Date
        public var sha256: String

        public init(size: Int64, mtime: Date, sha256: String) {
            self.size = size
            self.mtime = mtime
            self.sha256 = sha256
        }
    }

    /// USB 루트 기준 상대 경로 → 지문
    public var files: [String: Stamp]

    public init(files: [String: Stamp]) {
        self.files = files
    }

    /// 크기·SHA-256만 비교한다(mtime은 FAT 2초 단위·복원 때 바뀔 수 있어 뺀다)
    public func sameContent(as other: UsbFingerprint) -> Bool {
        guard Set(files.keys) == Set(other.files.keys) else { return false }
        return files.allSatisfy { path, stamp in
            other.files[path].map { $0.size == stamp.size && $0.sha256 == stamp.sha256 } ?? false
        }
    }
}
