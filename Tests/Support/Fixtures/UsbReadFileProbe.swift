import DJCDomain
import Foundation
import RekordboxKit

/// 안전 읽기 입구와 옛 URL 읽기를 구분한다. 모든 파일 연산은 주입한 합성 파일 시스템에만 전달한다.
public final class UsbReadFileProbe: UsbFileSystem, @unchecked Sendable {
    public let base: any UsbFileSystem
    public var onReadFile: ((UsbRoot, String, Int) throws -> UsbFileRead?)?
    public private(set) var anchoredCalls = 0
    public private(set) var urlReads = 0
    public private(set) var urlHashes = 0

    public init(base: any UsbFileSystem) { self.base = base }
    public func readFile(root: UsbRoot, relativePath: String, maxBytes: Int) throws -> UsbFileRead? {
        anchoredCalls += 1
        if let onReadFile { return try onReadFile(root, relativePath, maxBytes) }
        return try base.readFile(root: root, relativePath: relativePath, maxBytes: maxBytes)
    }
    public func read(_ url: URL, maxBytes: Int) throws -> Data { urlReads += 1; return try base.read(url, maxBytes: maxBytes) }
    public func sha256(_ url: URL, uncached: Bool) throws -> String { urlHashes += 1; return try base.sha256(url, uncached: uncached) }
    public func stat(_ url: URL) throws -> UsbFileStat? { try base.stat(url) }
    public func list(_ directory: URL) throws -> [String] { try base.list(directory) }
    public func makeDirectory(_ url: URL) throws { try base.makeDirectory(url) }
    public func writeNew(_ data: Data, to url: URL) throws { try base.writeNew(data, to: url) }
    public func copyDataNew(from source: URL, to url: URL, progress: (Int64) -> Void) throws -> (size: Int64, sha256: String, sha1: String) {
        try base.copyDataNew(from: source, to: url, progress: progress)
    }
    public func setModificationDate(_ url: URL, _ date: Date) throws { try base.setModificationDate(url, date) }
    public func fullSync(_ url: URL) throws { try base.fullSync(url) }
    public func syncDirectory(_ url: URL) throws { try base.syncDirectory(url) }
    public func rename(_ from: URL, to: URL) throws { try base.rename(from, to: to) }
    public func remove(_ url: URL) throws { try base.remove(url) }
    public func removeDirectoryIfEmpty(_ url: URL) throws -> Bool { try base.removeDirectoryIfEmpty(url) }
    public func mountedOn(_ url: URL) throws -> String? { try base.mountedOn(url) }
    public func holdVolume(_ root: URL) throws -> any UsbVolumeHold { try base.holdVolume(root) }
}
