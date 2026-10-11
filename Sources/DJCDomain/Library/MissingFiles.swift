import Foundation

/// 파일이 없는 곡(#126). 파일 확인은 넘겨받은 함수로만 한다(여기는 입출력 없음).
/// 스트리밍 곡은 로컬 파일이 없으니 세지 않는다. 연결되지 않은 외장 디스크는 볼륨째 묶어 곡마다 확인하지 않는다.
public struct MissingFiles: Sendable, Equatable {
    /// 연결되지 않은 외장 디스크(`/Volumes/<이름>`)와 그 디스크에 있던 곡 수
    public struct Volume: Sendable, Equatable, Identifiable {
        public let path: String
        public let trackCount: Int
        public var name: String { (path as NSString).lastPathComponent }
        public var id: String { path }

        public init(path: String, trackCount: Int) {
            self.path = path
            self.trackCount = trackCount
        }
    }

    /// 파일이 없는 곡(ContentID)
    public let trackIDs: Set<String>
    /// 연결되지 않은 외장 디스크(곡이 많은 것부터)
    public let unmountedVolumes: [Volume]

    public init(trackIDs: Set<String> = [], unmountedVolumes: [Volume] = []) {
        self.trackIDs = trackIDs
        self.unmountedVolumes = unmountedVolumes
    }

    public static func scan(_ tracks: [Track], exists: (String) -> Bool) -> MissingFiles {
        var mounted: [String: Bool] = [:]
        var missing = Set<String>()
        var unmounted: [String: Int] = [:]
        for track in tracks where !track.isStreaming {
            if let root = volumeRoot(of: track.folderPath) {
                let isMounted = mounted[root] ?? exists(root)
                mounted[root] = isMounted
                if !isMounted {
                    missing.insert(track.id)
                    unmounted[root, default: 0] += 1
                    continue
                }
            }
            if !exists(track.folderPath) { missing.insert(track.id) }
        }
        let volumes = unmounted.map { Volume(path: $0.key, trackCount: $0.value) }
            .sorted { ($0.trackCount, $1.path) > ($1.trackCount, $0.path) }
        return MissingFiles(trackIDs: missing, unmountedVolumes: volumes)
    }

    /// `/Volumes/<이름>/…` 경로의 볼륨 뿌리. 시동 디스크의 경로는 nil.
    public static func volumeRoot(of path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
        return prefix + rest[..<slash]
    }
}
