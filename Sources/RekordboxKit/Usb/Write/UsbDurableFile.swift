import Darwin
import Foundation

/// 맥 쪽 내구 쓰기: 같은 폴더 임시 파일 → 쓰기 → F_FULLFSYNC → rename → 폴더 fsync.
/// 저널·manifest·보고서가 모두 이것을 거친다(끊겨도 옛것 또는 새것만 남는다).
public enum UsbDurableFile {
    public static func write(_ data: Data, to url: URL, fileSystem: any UsbFileSystem = PosixUsbFileSystem()) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = folder.appending(path: "." + url.lastPathComponent + ".tmp-" + UUID().uuidString.prefix(8))
        do {
            try fileSystem.writeNew(data, to: temp)
            try fileSystem.fullSync(temp)
            try fileSystem.rename(temp, to: url)
            try fileSystem.syncDirectory(folder)
        } catch {
            // 임시 파일만 치운다(맥 쪽, 파일 시스템 흉내를 거치지 않는다)
            unlink(temp.path)
            throw error
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL, fileSystem: any UsbFileSystem) throws {
        try write(UsbJournal.encoder().encode(value), to: url, fileSystem: fileSystem)
    }
}
