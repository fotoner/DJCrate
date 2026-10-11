import Foundation

extension URL {
    /// 경로를 비교할 때 쓰는 표기. macOS의 `/tmp`·`/var`·`/etc`는 `/private/…`를 가리키는 링크라 같은 폴더가 두 표기로 불린다.
    /// Foundation(`standardizedFileURL`·`resolvingSymlinksInPath`)은 경로가 있을 때만 `/private`를 떼므로, 있는 폴더와
    /// 아직 없는 파일이나 다른 표기로 받은 경로를 그대로 비교하면 어긋난다(#136). 비교하는 양쪽을 이 표기로 맞춘다.
    var comparablePath: String { Self.comparablePath(path) }

    static func comparablePath(_ path: String) -> String {
        for alias in ["/tmp", "/var", "/etc"] where path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}
