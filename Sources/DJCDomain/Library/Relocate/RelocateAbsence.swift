import Foundation

/// 파일 없는 곡이 왜 없는지(#62). 외장 디스크가 연결되지 않아 없는 곡도 후보 찾기에서 빼지 않고,
/// 화면에 디스크 이름을 붙여 사람이 판단하게 한다(디스크를 연결하면 옛 경로 그대로 찾을 수도 있다).
/// 연결된 볼륨 목록은 넘겨받는다(여기는 입출력 없음).
public enum RelocateAbsence: Sendable, Equatable {
    /// 경로의 외장 디스크(`/Volumes/<이름>`)가 지금 연결돼 있지 않다.
    case volumeNotMounted(name: String)
    /// 디스크는 연결돼 있는데(시동 디스크 포함) 파일이 없다.
    case fileMissing

    public var unmountedVolumeName: String? {
        if case let .volumeNotMounted(name) = self { return name }
        return nil
    }

    /// `mountedVolumes`: 연결된 볼륨의 경로("/", "/Volumes/X" 등). 끝 빗금·유니코드 정규화 차이는 무시한다.
    public static func of(path: String, mountedVolumes: some Sequence<String>) -> RelocateAbsence {
        of(path: path, mounted: normalized(mountedVolumes))
    }

    /// 곡마다(ContentID → 이유). 볼륨 목록은 한 번만 다듬는다.
    public static func classify(_ targets: [RelocateTarget], mountedVolumes: some Sequence<String>) -> [String: RelocateAbsence] {
        let mounted = normalized(mountedVolumes)
        return Dictionary(targets.map { ($0.id, of(path: $0.oldPath, mounted: mounted)) }, uniquingKeysWith: { first, _ in first })
    }

    private static func of(path: String, mounted: Set<String>) -> RelocateAbsence {
        // 볼륨 뿌리는 파일 없음 모아 보기와 같은 기준으로 자른다.
        guard let root = MissingFiles.volumeRoot(of: path) else { return .fileMissing }
        let key = root.precomposedStringWithCanonicalMapping
        guard !mounted.contains(key) else { return .fileMissing }
        return .volumeNotMounted(name: (key as NSString).lastPathComponent)
    }

    private static func normalized(_ volumes: some Sequence<String>) -> Set<String> {
        Set(volumes.map { path in
            var trimmed = Substring(path)
            while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
            return String(trimmed).precomposedStringWithCanonicalMapping
        })
    }
}
