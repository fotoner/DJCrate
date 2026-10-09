import CryptoKit
import DJCDomain
import Darwin
import Foundation

extension UsbRoot {
    /// 상대 경로 → URL. 열지 않는 경로·".."·절대 경로면 던진다.
    /// 심볼릭 링크를 거쳐 가는 경로(끝 성분이 링크인 경로 포함)도 던진다. 문자열 검사만으로는 링크를 통해
    /// 열지 않는 경로에 닿을 수 있어서다. 이미 있는 성분만 lstat으로 보고, 없는 성분부터는(새 파일 자리) 보지 않는다.
    public func url(for relativePath: String) throws -> URL {
        if relativePath.hasPrefix("/") { throw refused(relativePath, "absolutePath") }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") { throw refused(relativePath, "parentReference") }
        if UsbLayout.isNeverRead(relativePath) { throw refused(relativePath, "neverRead") }
        var current = url.path
        for component in components where component != "." {
            current += "/" + String(component)
            var info = stat()
            guard lstat(current, &info) == 0 else {
                let code = errno
                if code == ENOENT { break }
                throw refused(relativePath, "lstat: \(String(cString: strerror(code)))")
            }
            if info.st_mode & S_IFMT == S_IFLNK { throw refused(relativePath, "symlink") }
        }
        return components.reduce(url) { $0.appending(path: String($1)) }
    }

    private func refused(_ path: String, _ reason: String) -> UsbError {
        .readFailed(detail: "refused relative path (\(reason)): \(path)")
    }
}

/// USB 트리 순회·지문. 자격 증명·프로필 경로(`UsbLayout.neverRead`)는 이름만 보고 건너뛴다 — stat·open하지 않는다.
public enum UsbTree {
    /// 순회: neverRead로 내려가지 않고 열지 않는다. systemIgnored 제외. 심볼릭 링크는 따라가지 않고 항목으로만.
    /// 결과는 경로(UTF-8 바이트) 순이다.
    public static func walk(_ root: UsbRoot, under relative: String = "") throws -> [UsbTreeEntry] {
        try found(root, under: relative).map(\.entry)
    }

    /// 상대 경로(NFC) → 크기·SHA-256. AppleDouble("._*")은 hashAppleDouble=false면 세기만 한다.
    /// 심볼릭 링크는 크기만 남기고(해시 nil) 대상을 읽지 않는다.
    public static func fingerprint(_ root: UsbRoot, hashing: Bool = true, hashAppleDouble: Bool = false) throws
        -> (files: [String: UsbTreeStamp], appleDoubleCount: Int) {
        var files: [String: UsbTreeStamp] = [:]
        var appleDoubleCount = 0
        for (entry, path) in try found(root, under: "") where !entry.isDirectory {
            let name = entry.relativePath.split(separator: "/").last.map(String.init) ?? entry.relativePath
            if UsbLayout.isAppleDouble(name) {
                appleDoubleCount += 1
                if !hashAppleDouble { continue }
            }
            let hash = hashing && !entry.isSymlink ? try sha256(atPath: path, relative: entry.relativePath) : nil
            files[entry.relativePath] = UsbTreeStamp(size: entry.size, sha256: hash)
        }
        return (files, appleDoubleCount)
    }

    /// `lab usb-tree` 출력 형식: "<sha256>  <size>  <path>" 경로 순, 마지막 줄 "# appledouble <n>". 시각은 적지 않는다.
    public static func render(_ fingerprint: (files: [String: UsbTreeStamp], appleDoubleCount: Int)) -> String {
        let lines = fingerprint.files
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .map { "\($0.value.sha256 ?? "-")  \($0.value.size)  \($0.key)" }
        return (lines + ["# appledouble \(fingerprint.appleDoubleCount)"]).joined(separator: "\n")
    }

    /// 순회 결과와 그 항목의 실제 경로(readdir가 준 이름 그대로)를 경로(UTF-8 바이트) 순으로
    private static func found(_ root: UsbRoot, under relative: String) throws -> [(entry: UsbTreeEntry, path: String)] {
        let start = try root.url(for: relative)
        let prefix = relative.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        var found: [(entry: UsbTreeEntry, path: String)] = []
        try walk(directory: start.path, relative: UsbLayout.nfc(prefix), into: &found)
        return found.sorted { $0.entry.relativePath.utf8.lexicographicallyPrecedes($1.entry.relativePath.utf8) }
    }

    /// 한 폴더를 읽는다. 파일 시스템 접근은 readdir가 준 이름 그대로, 결과 경로는 NFC(msdos는 NFD로 돌려준다).
    /// 폴더는 O_NOFOLLOW로 연다. 확인한 뒤 링크로 바뀌어도 따라가지 않는다.
    private static func walk(directory: String, relative: String, into entries: inout [(entry: UsbTreeEntry, path: String)]) throws {
        func failure() -> UsbError {
            .readFailed(detail: "opendir \(relative.isEmpty ? "." : relative): \(String(cString: strerror(errno)))")
        }
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        guard let handle = fdopendir(descriptor) else {
            let error = failure()
            close(descriptor)
            throw error
        }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        closedir(handle)

        for name in names {
            let path = relative.isEmpty ? UsbLayout.nfc(name) : relative + "/" + UsbLayout.nfc(name)
            // 이름만 보고 거른다. 열지 않는 경로는 lstat도 하지 않는다.
            if UsbLayout.isNeverRead(path) || UsbLayout.isSystemIgnored(path) { continue }
            let full = directory + "/" + name
            var info = stat()
            guard lstat(full, &info) == 0 else {
                throw UsbError.readFailed(detail: "lstat \(path): \(String(cString: strerror(errno)))")
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                entries.append((UsbTreeEntry(relativePath: path, isDirectory: true, isSymlink: false, size: 0), full))
                try walk(directory: full, relative: path, into: &entries)
            case S_IFLNK:
                entries.append((UsbTreeEntry(relativePath: path, isDirectory: false, isSymlink: true, size: Int64(info.st_size)), full))
            case S_IFREG:
                entries.append((UsbTreeEntry(relativePath: path, isDirectory: false, isSymlink: false, size: Int64(info.st_size)), full))
            default:
                // 장치·FIFO·소켓은 USB 라이브러리에 없다. 열면 멈출 수 있어 넣지 않는다.
                continue
            }
        }
    }

    private static func sha256(atPath path: String, relative: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw UsbError.readFailed(detail: "open \(relative): \(String(cString: strerror(errno)))")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
