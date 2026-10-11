import Darwin
import Foundation

/// 실험 도구·디스크 이미지 쓰기가 받을 수 있는 임시 폴더 뿌리.
/// 경로 비교는 realpath(3) 결과끼리만 한다. Foundation 경로 정규화(`resolvingSymlinksInPath`·`standardizedFileURL`)는
/// `/private/tmp`를 `/tmp`로 바꿔 statfs 마운트 지점(`/private/...`)과 어긋나므로 쓰지 않는다.
public enum UsbScratchRoots {
    /// Darwin.realpath(3)을 감싼다. 없는 경로·오류면 nil
    public static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 허용 뿌리(모두 realpath 결과, 중복 제거): macOS 임시 폴더, /private/tmp, /private/var/folders
    public static func allowedRoots() -> [String] {
        var roots: [String] = []
        for candidate in [NSTemporaryDirectory(), "/private/tmp", "/private/var/folders"] {
            if let root = realPath(candidate), !roots.contains(root) { roots.append(root) }
        }
        return roots
    }

    /// realPath가 허용 뿌리 중 하나와 같거나 "뿌리/"로 시작하면 참. 문자열 비교만 한다(입력은 이미 realpath 결과여야 한다)
    public static func isUnderAllowedRoot(_ realPath: String) -> Bool {
        allowedRoots().contains { realPath == $0 || realPath.hasPrefix($0 + "/") }
    }

    /// statfs(2)의 f_mntonname(커널이 준 그대로 — realpath 모양). 실패하면 nil
    public static func mountedOn(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_mntonname) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
