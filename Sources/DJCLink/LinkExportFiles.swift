import Darwin
import Foundation

/// 서버에는 세션 사본의 개별 파일 번호만 등록한다. 변환기는 확장자가 있는 같은 사본을 읽는다.
final class LinkExportFiles: Sendable {
    let directory: String
    let tracks: [LinkExportTrack]
    let originalByAlias: [String: String]
    let audioPaths: [UInt32: String]

    typealias Clone = @Sendable (_ source: Int32, _ destination: String) -> Int32

    init(tracks input: [LinkExportTrack], shareRoot: String, protected: [String],
         temporaryDirectory: URL = FileManager.default.temporaryDirectory, clone: Clone = cloneFile,
         allowsAudio: (String) -> Bool) throws {
        let directory = temporaryDirectory.appending(path: "djc-link-" + UUID().uuidString).path
        guard mkdir(directory, 0o700) == 0 else { throw LinkExportError.unsafeFile }
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(atPath: directory) } }
        var tracks: [LinkExportTrack] = []
        var copies: [String: (alias: String, path: String)] = [:]
        var audioPaths: [UInt32: String] = [:]
        let share = Self.comparablePath(shareRoot)
        func allowed(_ path: String) -> Bool { Self.allowsLocalAudio(path, protected: protected) && allowsAudio(path) }
        for (row, original) in input.enumerated() {
            if copies[original.path] == nil {
                let ext = (original.path as NSString).pathExtension
                let copy = directory + "/audio-\(row)." + ext
                guard allowed(original.path),
                      Self.copyRegularFile(original.path, to: copy, allows: allowed, clone: clone) else { continue }
                guard let alias = Self.fileReference(copy) else {
                    unlink(copy)
                    continue
                }
                copies[original.path] = (alias, copy)
            }
            guard let copy = copies[original.path] else { continue }
            var track = original
            track.path = copy.alias
            track.analysisPath = Self.stageAsset(track.analysisPath, analysis: true, row: row, share: share, directory: directory, clone: clone)
            track.artworkPath = Self.stageAsset(track.artworkPath, analysis: false, row: row, share: share, directory: directory, clone: clone)
            audioPaths[track.id] = copy.path
            tracks.append(track)
        }
        guard !tracks.isEmpty, LinkExportServer.exportRoots(trackPaths: tracks.map(\.path)).isEmpty else {
            throw LinkExportError.unsafeFile
        }
        self.directory = directory
        self.tracks = tracks
        self.audioPaths = audioPaths
        originalByAlias = Dictionary(uniqueKeysWithValues: copies.map { ($0.value.alias, $0.key) })
        keep = true
    }

    deinit { try? FileManager.default.removeItem(atPath: directory) }

    /// 공개 API를 직접 불러도 이 실행의 데이터 폴더·Library를 내어 주지 않는다.
    static func protectedDirectories() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        return [URL.libraryDirectory.path, environment["DJC_HOME"], environment["DJC_REKORDBOX_DIR"]]
            .compactMap { $0 }.filter { !$0.isEmpty }.flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] }
            .map { comparablePath($0).lowercased() }
    }

    static func allowsLocalAudio(_ path: String, protected: [String]) -> Bool {
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.contains("\\"), !path.utf8.contains(0),
              !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") }),
              ["mp3", "aac", "m4a", "mp4", "flac", "wav", "aif", "aiff"].contains((path as NSString).pathExtension.lowercased())
        else { return false }
        let folders = parts.dropLast().map { $0.lowercased() }
        guard folders.first != "library", folders.first != "system",
              !(folders.first == "users" && folders.dropFirst(2).first == "library") else { return false }
        let lower = comparablePath(path).lowercased()
        guard !["/pioneer/extracted/", "/pioneer/cdp/", "/pioneer/djprofile.nxs/"].contains(where: lower.contains) else { return false }
        return !protected.contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }

    /// macOS의 /tmp·/var 두 표기만 맞춘다. 캐시·share 안에 사용자가 만든 링크는 따라가지 않는다.
    static func comparablePath(_ path: String) -> String {
        for root in ["/tmp", "/var"] where path == root || path.hasPrefix(root + "/") {
            return "/private" + path
        }
        return path
    }

    func convertedWAV(_ path: String, cache: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let expected = Self.comparablePath(cache) + "/" + url.lastPathComponent
        let copy = directory + "/converted-" + UUID().uuidString + ".wav"
        guard url.pathExtension.lowercased() == "wav", Self.comparablePath(path) == expected,
              Self.copyRegularFile(path, to: copy, allows: { Self.comparablePath($0) == expected }, clone: Self.cloneFile) else { return nil }
        return copy
    }

    private static func cloneFile(_ fd: Int32, _ destination: String) -> Int32 {
        fclonefileat(fd, AT_FDCWD, destination, UInt32(CLONE_NOOWNERCOPY)) == 0 ? 0 : errno
    }

    /// 경로 확인 뒤 같은 열린 일반 파일에서 복제한다. 볼륨이 다르거나 복제를 지원하지 않으면 같은 FD로 내용을 복사한다.
    private static func copyRegularFile(_ path: String, to destination: String, allows: (String) -> Bool, clone: Clone) -> Bool {
        guard !path.utf8.contains(0), let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard allows(canonical) else { return false }
        let fd = open(canonical, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        var actual = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, fcntl(fd, F_GETPATH, &actual) == 0 else { return false }
        let opened = String(decoding: actual.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        guard comparablePath(opened) == comparablePath(canonical), allows(opened) else { return false }
        // 잠긴 파일 속성을 사본에 물려주면 종료 때 지울 수 없다. 그때는 내용만 복사한다.
        let locked = info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) != 0
        let error = locked ? ENOTSUP : clone(fd, destination)
        if error == 0 {
            if chmod(destination, 0o400) == 0 { return true }
            unlink(destination)
            return false
        }
        guard error == EXDEV || error == ENOTSUP else { return false }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { return false }
        var final = stat()
        let copied = fcopyfile(fd, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
            && fchmod(output, 0o400) == 0 && futimens(output, [info.st_atimespec, info.st_mtimespec]) == 0
            && fstat(fd, &final) == 0 && final.st_size == info.st_size
            && final.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec && final.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
        let closed = close(output) == 0
        if !copied || !closed { unlink(destination); return false }
        return true
    }

    /// 소유한 사본을 세 단계 경로로 가리켜 DJLinkKit이 개별 파일로 등록하게 한다.
    private static func fileReference(_ copy: String) -> String? {
        var info = stat(), check = stat()
        guard lstat(copy, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let reference = "/.vol/\(info.st_dev)/\(info.st_ino)"
        guard stat(reference, &check) == 0, check.st_dev == info.st_dev, check.st_ino == info.st_ino else { return nil }
        return reference
    }

    /// DJLinkKit이 함께 읽는 분석 형제 파일과 크기별 그림도 각각 확인해 세션에 넣는다.
    private static func stageAsset(_ relative: String, analysis: Bool, row: Int, share: String, directory: String, clone: Clone) -> String {
        let subtree = analysis ? "PIONEER/USBANLZ" : "PIONEER/Artwork"
        let path = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        guard share.hasPrefix("/"), share != "/", path.hasPrefix(subtree + "/"), !path.contains("\\"), !path.utf8.contains(0),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.hasPrefix(".") }) else { return "" }
        let ext = (path as NSString).pathExtension
        guard analysis ? ext.uppercased() == "DAT" : ["jpg", "jpeg", "png"].contains(ext.lowercased()) else { return "" }
        let stem = (path as NSString).deletingPathExtension
        let suffixes = analysis ? ["." + ext, ".EXT", ".2EX"] : ["." + ext, "_s." + ext, "_m." + ext]
        let prefix = "assets/\(row)/" + (analysis ? "analysis" : "art")
        var staged = false
        for suffix in suffixes {
            let source = share + "/" + stem + suffix
            let dest = URL(fileURLWithPath: directory + "/" + prefix + suffix)
            guard (try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { continue }
            if copyRegularFile(source, to: dest.path, allows: { comparablePath($0) == source }, clone: clone) { staged = true }
        }
        return staged ? "/" + prefix + "." + ext : ""
    }
}
