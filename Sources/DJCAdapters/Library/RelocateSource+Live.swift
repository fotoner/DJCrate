import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension RelocateSource {
    /// 사본 DB의 파일 크기(`TrackFileSizes`), 폴더 훑기(`RelocateScanner`), 이 Mac에 연결된 볼륨
    public static let live = RelocateSource(
        targets: { try RelocateScanner.targets(for: $0, snapshot: $1) },
        scan: { try await RelocateScanner.scan(targets: $0, folder: $1, progress: $2) },
        mountedVolumes: { mountedVolumes() })

    /// 연결된 볼륨 경로. 시동 디스크는 `/Volumes` 아래에 "/"로 가는 링크로도 있어, 연결된 볼륨으로 가는 링크도 더한다.
    static func mountedVolumes() -> [String] {
        let files = FileManager.default
        var paths = Set((files.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).map(\.standardizedFileURL.path))
        for name in (try? files.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let link = "/Volumes/" + name
            guard (try? files.destinationOfSymbolicLink(atPath: link)) != nil else { continue }
            if paths.contains(URL(filePath: link).resolvingSymlinksInPath().path) { paths.insert(link) }
        }
        return paths.sorted()
    }
}
