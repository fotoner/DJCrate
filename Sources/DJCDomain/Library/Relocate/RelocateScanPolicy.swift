import Foundation

/// 후보 폴더를 훑을 때 건너뛸 것(#62). 입출력 없는 판정만 둔다(훑는 쪽은 `DJCStorage.RelocateScanner`).
public enum RelocateScanPolicy {
    /// rekordbox가 읽는 형식(`StagedTrack.supportedExtensions`와 같다)
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "wav", "aif", "aiff", "flac", "alac"]

    /// USB 루트의 rekordbox 폴더. 안은 내보낸 DB·분석 파일이라 음원 후보가 아니고, `extracted`·`CDP`는 열지 않는 규칙이다.
    /// 이름은 대소문자를 가리지 않는다(FAT USB에서는 `Pioneer`로 보일 수 있다). 소문자로 적는다.
    public static let skippedDirectoryNames: Set<String> = ["pioneer"]
    public static let skippedFileNames: Set<String> = ["djprofile.nxs"]

    /// 숨은 파일·폴더(`.`으로 시작, `._*` AppleDouble 포함)
    public static func skipsName(_ name: String) -> Bool { name.hasPrefix(".") }

    public static func skipsDirectory(named name: String) -> Bool { skipsName(name) || skippedDirectoryNames.contains(folded(name)) }

    public static func skipsFile(named name: String) -> Bool { skipsName(name) || skippedFileNames.contains(folded(name)) }

    /// 경로의 어느 구성 요소든 `PIONEER`(대소문자 무시)인지. 이런 폴더는 후보 폴더로 고를 수 없다(하위의 `extracted`·`CDP`를 열거하게 된다).
    public static func isInsideUsbLibraryFolder(_ path: String) -> Bool {
        components(path).contains { skippedDirectoryNames.contains(folded($0)) }
    }

    public static func isAudio(fileName: String) -> Bool {
        audioExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// `path`가 `root`와 같거나 그 안에 있는지. 구성 요소 단위로 비교하고(`Pioneer DJ`는 `Pioneer` 안이 아니다),
    /// NFC·NFD와 임시 폴더의 `/private/tmp`·`/private/var`·`/private/etc` 표기 차이를 같게 본다.
    public static func isInside(_ path: String, root: String) -> Bool {
        let path = components(path), root = components(root)
        return path.count >= root.count && Array(path.prefix(root.count)) == root
    }

    /// `path`가 `root` 안에 있으면 `root` 기준 상대 경로(`/`로 이은 구성 요소, 이름은 NFC), 아니면 nil. 표기 차이는 `isInside`와 같게 본다.
    public static func relativePath(of path: String, in root: String) -> String? {
        let path = components(path), root = components(root)
        guard path.count > root.count, Array(path.prefix(root.count)) == root else { return nil }
        return path.dropFirst(root.count).joined(separator: "/")
    }

    /// 보호 폴더(rekordbox 라이브러리·DJCrate 데이터) 안이거나 그 자체인지. 이런 폴더는 후보 폴더로 고를 수 없다.
    public static func isProtected(_ path: String, protectedRoots: [String]) -> Bool {
        protectedRoots.contains { isInside(path, root: $0) }
    }

    /// 고른 폴더 안에 보호 폴더가 들어 있는지(예: 홈 폴더). 이때는 고를 수 있고, 훑을 때 보호 폴더만 건너뛴다.
    public static func containsProtected(_ path: String, protectedRoots: [String]) -> Bool {
        protectedRoots.contains { isInside($0, root: path) && !isInside(path, root: $0) }
    }

    private static func folded(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    private static func components(_ path: String) -> [String] {
        var normalized = path.precomposedStringWithCanonicalMapping
        for alias in ["/tmp", "/var", "/etc"] where normalized == "/private" + alias || normalized.hasPrefix("/private" + alias + "/") {
            normalized = String(normalized.dropFirst("/private".count))
            break
        }
        return normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
