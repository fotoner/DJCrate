import CryptoKit
import Darwin
import DJCDomain
import Foundation
import RekordboxKit

/// 원문·경로를 오류에 담지 않는다. 스냅샷에는 클라우드 토큰이 들어 있다.
public enum UsbSyncSnapshotError: Error { case unavailable, changed, unsafePath }

/// 출처 값(`UsbSyncSnapshotProvenance`)은 DJCDomain. 여기서는 파일을 읽어 지문을 뜨고 같은 파일인지 확인한다.
extension UsbSyncSnapshotProvenance {
    public static func capture(_ source: URL) throws -> Self {
        try refuseLive(source)
        let fingerprint = try readFingerprint(source)
        let namedTime = LibrarySnapshot.takenAt(source)
        // 이름에 시각이 없으면 mtime. 쓰기 단계(`UsbSnapshotTime.parse`)가 읽도록 날짜·시간대까지 적는다
        let time = namedTime?.formatted(.iso8601) ?? fingerprint.modified.formatted(.iso8601.year().month().day()
            .time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        return Self(sourceURL: source, snapshotTime: time, fingerprint: fingerprint)
    }

    func matches(_ source: URL) throws -> Bool {
        try Self.readFingerprint(source, expected: fingerprint) == fingerprint
    }

    func matchesCopy(_ copy: URL) throws -> Bool {
        let copied = try Self.readFingerprint(copy)
        return copied.size == fingerprint.size && copied.digest == fingerprint.digest
    }

    func copy(to destination: URL) throws {
        let fd = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UsbSyncSnapshotError.unavailable }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = Darwin.stat(), after = Darwin.stat()
        guard fstat(fd, &before) == 0, Self.matchesMetadata(before, fingerprint) else { throw UsbSyncSnapshotError.changed }
        try Self.refuseLive(sourceURL, opened: before)
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw UsbSyncSnapshotError.unavailable }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
            try output.write(contentsOf: data)
        }
        guard fstat(fd, &after) == 0, Self.sameFile(before, after), Data(hash.finalize()) == fingerprint.digest else {
            throw UsbSyncSnapshotError.changed
        }
        try output.close()
    }

    private static func matchesMetadata(_ info: Darwin.stat, _ fingerprint: Fingerprint) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_dev == fingerprint.device && info.st_ino == fingerprint.inode
            && info.st_size == fingerprint.size && modified(info) == fingerprint.modified
    }

    private static func modified(_ info: Darwin.stat) -> Date {
        Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func readFingerprint(_ source: URL, expected: Fingerprint? = nil) throws -> Fingerprint {
        let fm = FileManager.default
        // WAL을 합치는 새 쓰기 경로는 만들지 않는다. 화면이 읽은 완결된 스냅샷만 받는다.
        for suffix in ["-wal", "-journal"] {
            if let attrs = try? fm.attributesOfItem(atPath: source.path + suffix),
               (attrs[.type] as? FileAttributeType != .typeRegular || (attrs[.size] as? NSNumber)?.int64Value != 0) {
                throw UsbSyncSnapshotError.unavailable
            }
        }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UsbSyncSnapshotError.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var before = Darwin.stat(), after = Darwin.stat(), named = Darwin.stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw UsbSyncSnapshotError.unsafePath }
        if let expected, !matchesMetadata(before, expected) { throw UsbSyncSnapshotError.changed }
        try refuseLive(source, opened: before)
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard fstat(fd, &after) == 0, lstat(source.path, &named) == 0,
              sameFile(before, after), sameFile(after, named) else { throw UsbSyncSnapshotError.changed }
        return Fingerprint(device: before.st_dev, inode: before.st_ino, size: before.st_size,
                           modified: modified(before),
                           digest: Data(hash.finalize()))
    }

    private static func sameFile(_ a: Darwin.stat, _ b: Darwin.stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    /// DB를 열기 전에 경로·inode로 거부한다. live DB로 되돌아가는 기본 인자는 없다.
    private static func refuseLive(_ source: URL, opened: Darwin.stat? = nil) throws {
        let live = [LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db"),
                    LibrarySnapshot.rekordboxDirectory.appending(path: "master.db")]
        var mine = Darwin.stat()
        let exists: Bool
        if let opened { mine = opened; exists = true }
        else { exists = lstat(source.path, &mine) == 0 }
        for database in live {
            var other = Darwin.stat()
            if source.path == database.path
                || (exists && stat(database.path, &other) == 0 && mine.st_dev == other.st_dev && mine.st_ino == other.st_ino)
                || (UsbScratchRoots.realPath(source.path) != nil
                    && UsbScratchRoots.realPath(source.path) == UsbScratchRoots.realPath(database.path)) {
                throw UsbSyncSnapshotError.unsafePath
            }
        }
    }
}

/// 사본 소유권(`UsbSyncSnapshotLease`)은 DJCDomain. 여기서는 사본을 뜨고, 놓으면 그 폴더를 지운다.
extension UsbSyncSnapshotLease {
    public static var defaultDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let home = environment["DJC_HOME"], !home.isEmpty { return URL(filePath: home).appending(path: "usb-sync-snapshots") }
        return FileManager.default.temporaryDirectory.appending(path: "djc-usb-sync-snapshots")
    }

    public static func capture(_ provenance: UsbSyncSnapshotProvenance, directory: URL = defaultDirectory) throws -> UsbSyncSnapshotLease {
        try capture(provenance, directory: directory, afterCopy: {})
    }

    /// 합성 시험이 복사·재검사 사이의 교체와 취소를 주입한다.
    static func capture(_ provenance: UsbSyncSnapshotProvenance, directory: URL,
                        afterCopy: () throws -> Void) throws -> UsbSyncSnapshotLease {
        let fm = FileManager.default
        try checkDirectory(directory)
        guard try provenance.matches(provenance.sourceURL) else { throw UsbSyncSnapshotError.changed }
        // 앱이 죽으면 deinit이 돌지 않는다. 다음 실행의 청소(`DJCTempCleanup`)가 주인이 없는 사본만 지우도록 pid를 앞에 둔다.
        let root = directory.appending(path: "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? fm.removeItem(at: root) } }
        let copy = root.appending(path: provenance.sourceURL.lastPathComponent)
        try Task.checkCancellation()
        // 검증한 inode의 열린 핸들에서 복사한다. 경로 교체 뒤 다른 DB를 여는 fallback은 없다.
        try provenance.copy(to: copy)
        try afterCopy()
        guard try provenance.matches(provenance.sourceURL), try provenance.matchesCopy(copy) else { throw UsbSyncSnapshotError.changed }
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copy.path)
        try Task.checkCancellation()
        keep = true
        return UsbSyncSnapshotLease(database: copy, provenance: provenance, id: UUID(), release: { try? FileManager.default.removeItem(at: root) })
    }

    private static func checkDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        guard directory.isFileURL, !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".") else {
            throw UsbSyncSnapshotError.unsafePath
        }
        // 아직 없는 끝 폴더는 부모를 찾아 realpath로 검사한 뒤 만든다.
        var ancestor = directory
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        var roots = [fm.temporaryDirectory]
        if let home = ProcessInfo.processInfo.environment["DJC_HOME"], !home.isEmpty { roots.append(URL(filePath: home)) }
        guard let real = UsbScratchRoots.realPath(ancestor.path), roots.contains(where: {
            guard let root = UsbScratchRoots.realPath($0.path) else { return false }
            return real == root || real.hasPrefix(root + "/")
        }) else { throw UsbSyncSnapshotError.unsafePath }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

}
