import DJCDomain
import Foundation

/// 백업 정리: 볼륨마다 최근 다섯 개만 남긴다. 다만 닫히지 않은 저널이 가리키는 백업, 마지막 verified 쓰기의 백업,
/// 더 새 verified가 없는 마지막 needsReplan 백업은 남긴다. 판정은 백업 폴더의 journal.json으로 한다(저널 파일은 다음 세션이 덮는다).
extension UsbWriter {
    public static let backupsToKeep = 5

    /// 이 볼륨의 백업 폴더(manifest.json이 있는 것), 최근 것부터
    public static func backups(paths: UsbWritePaths, volumeKey: String) -> [URL] {
        let folder = paths.backups.appending(path: volumeKey)
        let decoder = UsbJournal.decoder()
        let found = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { url -> (url: URL, created: Date)? in
                guard let data = try? Data(contentsOf: url.appending(path: "manifest.json")),
                      let manifest = try? decoder.decode(UsbManifest.self, from: data) else { return nil }
                return (url, manifest.createdAt)
            }
        return found.sorted { ($0.created, $0.url.lastPathComponent) > ($1.created, $1.url.lastPathComponent) }.map(\.url)
    }

    public static func prune(paths: UsbWritePaths, volumeKey: String, keep: Int = backupsToKeep) {
        let folder = paths.backups.appending(path: volumeKey)
        let ordered = backups(paths: paths, volumeKey: volumeKey)
        let all = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var pinned: Set<String> = []
        if let open = pendingJournal(paths: paths, volumeKey: volumeKey), let backup = open.backupDirectory {
            pinned.insert((backup as NSString).lastPathComponent)
        }
        let decoder = UsbJournal.decoder()
        let states = ordered.map { url in
            (try? Data(contentsOf: url.appending(path: "journal.json"))).flatMap { try? decoder.decode(UsbJournal.self, from: $0) }?.state
        }
        let lastVerified = states.firstIndex(of: .verified)
        if let lastVerified { pinned.insert(ordered[lastVerified].lastPathComponent) }
        if let replan = states.firstIndex(of: .needsReplan), lastVerified.map({ replan < $0 }) ?? true {
            pinned.insert(ordered[replan].lastPathComponent)
        }
        for (index, url) in ordered.enumerated() where index >= keep && !pinned.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        // manifest가 없는 폴더(백업 도중 끊긴 것)는 가리키는 저널이 없으면 지운다
        let listed = Set(ordered.map(\.lastPathComponent))
        for url in all where !listed.contains(url.lastPathComponent) && !pinned.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
