import CryptoKit
import DJCDomain
import Darwin
import Foundation
import RekordboxKit
import Testing

@Suite("USB 파일 시스템(POSIX)")
struct PosixUsbFileSystemTests {
    let fs = PosixUsbFileSystem()

    /// 임시 APFS 폴더 하나를 만들고 끝나면 지운다.
    func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-posixfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    @Test("새 파일만 만든다(있으면 실패)")
    func writeNewExclusive() throws {
        try withFolder { folder in
            let file = folder.appending(path: "a.bin")
            try fs.writeNew(Data("one".utf8), to: file)
            #expect(try Data(contentsOf: file) == Data("one".utf8))
            #expect(throws: (any Error).self) { try fs.writeNew(Data("two".utf8), to: file) }
            #expect(try Data(contentsOf: file) == Data("one".utf8))
        }
    }

    @Test("데이터만 복사한다(확장 속성은 옮기지 않음)")
    func copyDataNoXattr() throws {
        try withFolder { folder in
            let source = folder.appending(path: "src.mp3")
            let payload = Data((0..<300_000).map { UInt8($0 % 251) })
            try payload.write(to: source)
            let value = Data("x".utf8)
            let status = value.withUnsafeBytes { setxattr(source.path, "com.djc.test", $0.baseAddress, value.count, 0, 0) }
            #expect(status == 0)
            let copy = folder.appending(path: "copy.mp3")
            var reported: Int64 = 0
            let result = try fs.copyDataNew(from: source, to: copy) { reported = $0 }
            #expect(result.size == Int64(payload.count))
            #expect(reported == Int64(payload.count))
            #expect(result.sha256 == hex(SHA256.hash(data: payload)))
            #expect(result.sha1 == hex(Insecure.SHA1.hash(data: payload)))
            #expect(try Data(contentsOf: copy) == payload)
            #expect(getxattr(copy.path, "com.djc.test", nil, 0, 0, 0) < 0)
            // 이미 있으면 덮지 않는다.
            #expect(throws: (any Error).self) { _ = try fs.copyDataNew(from: source, to: copy) { _ in } }
        }
    }

    @Test func setModificationDate() throws {
        try withFolder { folder in
            let file = folder.appending(path: "a.bin")
            try fs.writeNew(Data("a".utf8), to: file)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try fs.setModificationDate(file, date)
            #expect(try fs.stat(file)?.modificationDate == date)
        }
    }

    @Test("rename은 대상이 있으면 덮는다")
    func renameOverwrites() throws {
        try withFolder { folder in
            let a = folder.appending(path: "a"), b = folder.appending(path: "b")
            try fs.writeNew(Data("new".utf8), to: a)
            try fs.writeNew(Data("old".utf8), to: b)
            try fs.rename(a, to: b)
            #expect(try fs.stat(a) == nil)
            #expect(try Data(contentsOf: b) == Data("new".utf8))
            try fs.fullSync(b)
            try fs.syncDirectory(folder)
        }
    }

    @Test func sha256Uncached() throws {
        try withFolder { folder in
            let file = folder.appending(path: "a.bin")
            let payload = Data((0..<2_500_000).map { UInt8($0 % 13) })
            try fs.writeNew(payload, to: file)
            let expected = hex(SHA256.hash(data: payload))
            #expect(try fs.sha256(file, uncached: true) == expected)
            #expect(try fs.sha256(file, uncached: false) == expected)
            #expect(try fs.read(file, maxBytes: 10) == payload.prefix(10))
        }
    }

    @Test func removeDirectoryIfEmpty() throws {
        try withFolder { folder in
            let dir = folder.appending(path: "d")
            try fs.makeDirectory(dir)
            #expect(throws: (any Error).self) { try fs.makeDirectory(dir) }
            try fs.writeNew(Data("x".utf8), to: dir.appending(path: "f"))
            #expect(try fs.removeDirectoryIfEmpty(dir) == false)
            try fs.remove(dir.appending(path: "f"))
            #expect(try fs.list(dir).isEmpty)
            #expect(try fs.removeDirectoryIfEmpty(dir) == true)
            #expect(try fs.stat(dir) == nil)
            #expect(try fs.removeDirectoryIfEmpty(dir) == false)
        }
    }

    @Test("stat은 심볼릭 링크를 따라가지 않는다")
    func statNoFollow() throws {
        try withFolder { folder in
            let file = folder.appending(path: "f")
            try fs.writeNew(Data("12345".utf8), to: file)
            let link = folder.appending(path: "l")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
            #expect(try fs.stat(file)?.kind == .file)
            #expect(try fs.stat(file)?.size == 5)
            #expect(try fs.stat(link)?.kind == .symlink)
            #expect(try fs.stat(folder)?.kind == .directory)
            #expect(try fs.stat(folder.appending(path: "none")) == nil)
            #expect(try fs.list(folder).sorted() == ["f", "l"])
            // 링크를 통해 파일을 읽지 않는다.
            #expect(throws: (any Error).self) { _ = try fs.sha256(link, uncached: false) }
        }
    }

    @Test("마운트 지점은 statfs 값(realpath 모양)")
    func mountedOnIsRealPath() throws {
        try withFolder { folder in
            let mount = try #require(try fs.mountedOn(folder))
            #expect(mount.hasPrefix("/"))
            #expect(!mount.hasPrefix("/tmp/"))
        }
    }
}
