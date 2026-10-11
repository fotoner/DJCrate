import DJCDomain
import Darwin
import Foundation

/// 열어 둔 일반 파일 fd에서 읽은 바이트와 상태. 실제 파일 정체도 비교해 같은 크기의 교체를 놓치지 않는다.
public struct UsbFileRead: Sendable, Equatable {
    public let data: Data
    public let stat: UsbFileStat
    let identity: [UInt64]?

    /// 메모리 파일 시스템은 주입한 상태로 읽기 결과를 만든다.
    public init(data: Data, stat: UsbFileStat) {
        self.data = data
        self.stat = stat
        identity = nil
    }

    init(data: Data, stat: UsbFileStat, identity: [UInt64]) {
        self.data = data
        self.stat = stat
        self.identity = identity
    }
}

/// URL 재검사와 open 사이에 부모가 바뀌어도 루트 밖 파일을 열지 않는다.
enum UsbAnchoredFileReader {
    static func read(root: UsbRoot, relativePath: String, maxBytes: Int,
                     beforeOpen: ((String) throws -> Void)? = nil,
                     willRead: ((Int32) throws -> Void)? = nil) throws -> UsbFileRead? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard maxBytes > 0, !relativePath.contains("\0"), !relativePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !UsbLayout.isNeverRead(relativePath) else { throw UsbSyncSelectionFile.ParseError.unsafePath }
        // /tmp·/var 별칭의 실제 경로를 캡처하고, /의 fd에서 모든 성분을 링크 없이 연다.
        guard root.url.isFileURL, root.url.path.hasPrefix("/"), !root.url.path.contains("\0"),
              let canonicalRoot = UsbScratchRoots.realPath(root.url.path) else {
            throw UsbSyncSelectionFile.ParseError.unsafePath
        }
        let pathForOpen = rootPathForOpen(root.url.path)
        var rootInfo = Darwin.stat(), suppliedInfo = Darwin.stat()
        guard lstat(canonicalRoot, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              lstat(pathForOpen, &suppliedInfo) == 0, suppliedInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_dev == suppliedInfo.st_dev, rootInfo.st_ino == suppliedInfo.st_ino else {
            throw UsbSyncSelectionFile.ParseError.unsafePath
        }
        try beforeOpen?("")
        let rootDescriptor = try openRoot(pathForOpen, beforeOpen: beforeOpen)
        defer { close(rootDescriptor) }
        func checkRoot() throws {
            var actual = Darwin.stat()
            guard fstat(rootDescriptor, &actual) == 0, actual.st_mode & S_IFMT == S_IFDIR,
                  actual.st_dev == rootInfo.st_dev, actual.st_ino == rootInfo.st_ino,
                  descriptorPath(rootDescriptor) == canonicalRoot else {
                throw UsbSyncSelectionFile.ParseError.unsafePath
            }
        }
        try checkRoot()
        var directory = rootDescriptor
        defer { if directory != rootDescriptor { close(directory) } }
        for component in components.dropLast() {
            try beforeOpen?(component)
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT { try checkRoot(); return nil }
                throw UsbSyncSelectionFile.ParseError.unsafePath
            }
            if directory != rootDescriptor { close(directory) }
            directory = next
            var info = Darwin.stat()
            guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw UsbSyncSelectionFile.ParseError.unsafePath
            }
        }
        let name = components.last!
        try beforeOpen?(name)
        // FIFO로 바뀌어도 open에서 기다리지 않게 하고, 읽기 전에 실제 fd의 종류를 확인한다.
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { try checkRoot(); return nil }
            throw UsbSyncSelectionFile.ParseError.unsafePath
        }
        defer { close(descriptor) }
        // 열린 부모가 이름째 옮겨졌다면 openat은 옛 폴더를 열 수 있다. 바이트를 읽기 전에 루트 경로도 대조한다.
        try checkRoot()
        let before = try stamp(descriptor)
        guard before.kind == .file, before.size > 0, before.size <= Int64(maxBytes) else {
            throw UsbSyncSelectionFile.ParseError.unsafePath
        }
        func bytes() throws -> Data {
            var data = Data(), buffer = [UInt8](repeating: 0, count: min(maxBytes, 1 << 20))
            while data.count < maxBytes {
                try willRead?(descriptor)
                let want = min(buffer.count, maxBytes - data.count)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, want) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw UsbSyncSelectionFile.ParseError.changedDuringRead
                }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
        let data = try bytes()
        guard try stamp(descriptor) == before, data.count == Int(before.size),
              lseek(descriptor, 0, SEEK_SET) == 0 else { throw UsbSyncSelectionFile.ParseError.changedDuringRead }
        guard try bytes() == data, try stamp(descriptor) == before else { throw UsbSyncSelectionFile.ParseError.changedDuringRead }
        try checkRoot()
        let stat = UsbFileStat(kind: .file, size: before.size,
            modificationDate: Date(timeIntervalSince1970: Double(before.modifiedSeconds) + Double(before.modifiedNanos) / 1e9))
        return UsbFileRead(data: data, stat: stat,
            identity: [UInt64(truncatingIfNeeded: rootInfo.st_dev), UInt64(rootInfo.st_ino), before.device, before.inode,
                       UInt64(truncatingIfNeeded: before.changedSeconds), UInt64(truncatingIfNeeded: before.changedNanos)])
    }

    private static func rootPathForOpen(_ suppliedPath: String) -> String {
        // 시스템 뿌리의 정해진 별칭만 치환한다. realpath가 푼 임의의 사용자 부모 링크는 따라가지 않는다.
        for (alias, target) in [("/tmp", "/private/tmp"), ("/var", "/private/var"), ("/etc", "/private/etc")] {
            if suppliedPath == alias || suppliedPath.hasPrefix(alias + "/") {
                return target + String(suppliedPath.dropFirst(alias.count))
            }
        }
        return suppliedPath
    }

    private static func openRoot(_ pathForOpen: String, beforeOpen: ((String) throws -> Void)?) throws -> Int32 {
        guard pathForOpen.hasPrefix("/"), !pathForOpen.contains("\0") else {
            throw UsbSyncSelectionFile.ParseError.unsafePath
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UsbSyncSelectionFile.ParseError.unsafePath }
        do {
            var path = ""
            for component in pathForOpen.split(separator: "/") {
                guard component != ".", component != ".." else { throw UsbSyncSelectionFile.ParseError.unsafePath }
                path += "/" + String(component)
                try beforeOpen?(path)
                let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw UsbSyncSelectionFile.ParseError.unsafePath }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func descriptorPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private struct Stamp: Equatable {
        let kind: UsbFileStat.Kind
        let size: Int64
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }

    private static func stamp(_ descriptor: Int32) throws -> Stamp {
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw UsbSyncSelectionFile.ParseError.changedDuringRead }
        return Stamp(kind: info.st_mode & S_IFMT == S_IFREG ? .file : .other, size: Int64(info.st_size),
            device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino),
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
}
