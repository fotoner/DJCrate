import DJCDomain
import Foundation

/// USB에서 지워도 되는 파일(허용 목록). 목록 밖·열지 않는 경로·심볼릭 링크는 지우지 않는다.
/// 비교는 대소문자·NFC/NFD를 가리지 않는다(FAT가 같은 이름으로 본다).
public enum UsbRemovalPolicy {
    /// 경로 모양만 본다: `Contents/…`, 분석 파일(`PIONEER/USBANLZ/Pxxx/xxxxxxxx/ANLZxxxx.DAT|EXT|2EX`),
    /// 아트워크(`PIONEER/Artwork/nnnnn/[ab]n(_m).jpg`), 동기화 선택 두 파일과 그 짝 `._<이름>`
    public static func allows(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || UsbLayout.isNeverRead(path) { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map { UsbLayout.collisionKey(String($0)) }
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return false }
        guard let first = components.first else { return false }
        if first == "contents" { return components.count >= 2 }
        guard first == "pioneer", components.count >= 2 else { return false }
        let leaf = stripAppleDouble(components.last!)
        switch components[1] {
        case "rekordbox":
            return components.count == 3 && ["playlists3.sync", "playlists3plus.sync"].contains(leaf)
        case "usbanlz":
            guard components.count == 5 else { return false }
            let folder = components[2], track = components[3]
            guard folder.count == 4, folder.hasPrefix("p"), folder.dropFirst().allSatisfy(\.isHexDigit),
                  track.count == 8, track.allSatisfy(\.isHexDigit) else { return false }
            let parts = leaf.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, ["dat", "ext", "2ex"].contains(parts[1]) else { return false }
            let stem = parts[0]
            return stem.count == 8 && stem.hasPrefix("anlz") && stem.dropFirst(4).allSatisfy(\.isHexDigit)
        case "artwork":
            guard components.count == 4 else { return false }
            let folder = components[2]
            guard folder.count == 5, folder.allSatisfy(\.isASCIIDigit) else { return false }
            guard leaf.hasSuffix(".jpg") else { return false }
            var stem = leaf.dropLast(4)
            if stem.hasSuffix("_m") { stem = stem.dropLast(2) }
            guard let kind = stem.first, kind == "a" || kind == "b" else { return false }
            let number = stem.dropFirst()
            return !number.isEmpty && number.allSatisfy(\.isASCIIDigit)
        default:
            return false
        }
    }

    /// 모양 + 실제 파일: 경로 성분 어디에도 심볼릭 링크가 없고 끝이 일반 파일이어야 한다
    public static func allows(_ path: String, root: UsbRoot, fileSystem: any UsbFileSystem) throws -> Bool {
        guard allows(path) else { return false }
        var current = root.url
        let components = path.split(separator: "/")
        for (index, component) in components.enumerated() {
            current = current.appending(path: String(component))
            guard let info = try fileSystem.stat(current) else { return false }
            if info.kind == .symlink { return false }
            if index == components.count - 1 { return info.kind == .file }
            if info.kind != .directory { return false }
        }
        return false
    }

    /// 지운 파일의 짝 AppleDouble: 정확한 이름 하나(패턴으로 쓸지 않는다). 이미 `._`면 nil
    public static func appleDoubleCompanion(of path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard !UsbLayout.isAppleDouble(name) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? UsbLayout.appleDoubleName(for: name) : parent + "/" + UsbLayout.appleDoubleName(for: name)
    }

    private static func stripAppleDouble(_ name: String) -> String {
        UsbLayout.isAppleDouble(name) ? String(name.dropFirst(2)) : name
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
