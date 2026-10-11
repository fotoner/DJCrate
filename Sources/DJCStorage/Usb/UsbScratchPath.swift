import DJCDomain
import Darwin
import Foundation
import RekordboxKit

/// USB 실험·디스크 이미지 도구가 받는 경로 제한. 임시 폴더 아래만 받아 실물 볼륨·rekordbox 라이브러리에 닿지 않게 한다.
public enum UsbScratchPath {
    public enum Kind: Sendable {
        case existingFile, existingDirectory, newFile
        /// 없거나 비어 있는 폴더
        case outputDirectory
    }

    /// 통과하면 realpath(3)로 푼 경로(끝 성분이 새것이면 부모의 realpath + "/" + 이름)를 돌려준다. 아니면 `UsbError.pathRefused`
    public static func check(_ path: String, as kind: Kind) throws -> String {
        func refuse(_ reason: String) -> UsbError { .pathRefused(path: path, reason: reason) }

        // ① 모양: 끝 성분의 링크를 따라가지 않고 본다.
        var info = stat()
        let exists: Bool
        // 있는 출력 폴더가 비었는지는 ③·④를 통과한 뒤에 본다. 먼저 열면 거부할 폴더(USB 볼륨 맨 위 등)를 열거하게 된다.
        var needsEmptyCheck = false
        let status = lstat(path, &info), code = errno
        if status == 0 {
            exists = true
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { throw refuse("symlink") }
            if type == S_IFCHR || type == S_IFBLK || type == S_IFIFO || type == S_IFSOCK { throw refuse("notRegular") }
            switch kind {
            case .existingFile: if type != S_IFREG { throw refuse("kindMismatch") }
            case .existingDirectory: if type != S_IFDIR { throw refuse("kindMismatch") }
            case .newFile: throw refuse("exists")
            case .outputDirectory:
                if type != S_IFDIR { throw refuse("kindMismatch") }
                needsEmptyCheck = true
            }
        } else if code == ENOENT {
            exists = false
            if kind == .existingFile || kind == .existingDirectory { throw refuse("notFound") }
        } else {
            throw refuse("unreadable")
        }

        // ② 실제 경로
        let resolved: String
        if exists {
            guard let real = realPath(path) else { throw refuse("unreadable") }
            resolved = real
        } else {
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", name != "/" else { throw refuse("badName") }
            let parentPath = (path as NSString).deletingLastPathComponent
            var parentInfo = stat()
            guard let parent = realPath(parentPath.isEmpty ? "." : parentPath),
                  stat(parent, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR
            else { throw refuse("noParent") }
            resolved = (parent == "/" ? "" : parent) + "/" + name
        }

        // ③ 임시 폴더 아래만
        guard UsbScratchRoots.isUnderAllowedRoot(resolved) else { throw refuse("outsideScratch") }
        // ④ 허용 뿌리 안이어도 장치·볼륨·rekordbox 라이브러리는 거부
        if deniedPrefixes().contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) { throw refuse("deniedPrefix") }
        // 출력 폴더는 비어 있어야 한다(허용된 곳만 연다).
        if needsEmptyCheck {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: resolved) else { throw refuse("unreadable") }
            if !items.isEmpty { throw refuse("notEmpty") }
        }
        return resolved
    }

    /// 허용 뿌리 = `UsbScratchRoots.allowedRoots()`
    public static func allowedRoots() -> [String] { UsbScratchRoots.allowedRoots() }

    /// 명시 거부(허용 뿌리 안이어도): "/dev", "/Volumes", realpath(~/Library/Pioneer)
    public static func deniedPrefixes() -> [String] {
        ["/dev", "/Volumes"] + [realPath(NSHomeDirectory() + "/Library/Pioneer")].compactMap { $0 }
    }

    /// = `UsbScratchRoots.realPath`
    public static func realPath(_ path: String) -> String? { UsbScratchRoots.realPath(path) }
}
