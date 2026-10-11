import DJCDomain
import Darwin
import DJCEnvironment
import Foundation
import RekordboxKit

/// 캐시 종류별 용량 보기와 비우기(#215). 지우는 것은 `DJCCacheKind`의 자리 안에서 아래 규칙에 맞는 것뿐이다.
/// - 파형·분석: 하위 폴더까지 일반 파일만 지우고 폴더는 남긴다(앱이 그 자리에 다시 쓴다)
/// - 라이브러리 읽기 사본: 가장 새 사본과 `keepingSnapshots`(앱이 연 사본)는 남기고, 뜨는 중인 `.part`는 건드리지 않는다
/// - USB 읽기 사본: `<볼륨키>/<시각>/`만, 볼륨마다 가장 새 것은 남긴다. 쓰기 세션 사본(`local-`·`usb-`·`info-`)은 건드리지 않고,
///   USB 쓰기 잠금이 잡혀 있거나 닫히지 않은 저널이 있으면 이 종류는 통째로 건너뛴다
/// 용량은 논리 크기 합이다(APFS 클론은 실제 디스크 사용보다 크게 보일 수 있다).
public enum DJCCache {
    public typealias Usage = DJCCacheUsage
    public typealias Outcome = DJCCacheOutcome
    public typealias BackupUsage = DJCBackupUsage

    /// 쓰기 전 백업(`rekordbox-backups/<시각>-<이름>/`)·시점 스냅샷(`point-snapshots/<시각>-<종류>/`, #224)·USB 백업
    /// (`usb-backups/<볼륨키>/<시각>-<이름>/`). 읽기만 한다. 뜨는 중인 시점 스냅샷(`.partial-…`)은 세지 않는다.
    public static func backupUsage(root: URL) -> [BackupUsage] {
        func folders(_ url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        func usage(_ kind: BackupUsage.Kind, _ backups: [URL]) -> BackupUsage {
            BackupUsage(kind: kind, count: backups.count,
                        bytes: backups.reduce(0) { $0 + regularFiles(under: $1).reduce(0) { $0 + $1.size } })
        }
        return [usage(.rekordboxBackups, folders(root.appending(path: "rekordbox-backups"))),
                usage(.pointSnapshots, folders(root.appending(path: "point-snapshots"))),
                usage(.usbBackups, folders(root.appending(path: "usb-backups")).flatMap(folders))]
    }

    public static func usage(paths: DJCCachePaths = .current) -> [Usage] {
        DJCCacheKind.allCases.map { kind in
            let files = regularFiles(under: paths.location(of: kind))
            return Usage(kind: kind, bytes: files.reduce(0) { $0 + $1.size }, files: files.count)
        }
    }

    public static func clear(_ kinds: [DJCCacheKind], paths: DJCCachePaths = .current,
                             keepingSnapshots: [URL] = [], dryRun: Bool = false) -> [Outcome] {
        DJCCacheKind.allCases.filter(kinds.contains).map { kind in
            var outcome = Outcome(kind: kind)
            let targets: [URL]
            switch kind {
            case .waveforms, .analysis:
                targets = regularFiles(under: paths.location(of: kind)).map(\.url)
            case .loudness, .previewWaveforms:
                targets = [paths.location(of: kind)]
            case .snapshots:
                (targets, outcome.keptItems) = snapshotTargets(in: paths.snapshots, keeping: keepingSnapshots)
            case .usbSnapshots:
                if let reason = usbBusyReason(sessions: paths.root.appending(path: "usb-sessions")) {
                    outcome.skipped = reason
                    return outcome
                }
                (targets, outcome.keptItems) = usbSnapshotTargets(in: paths.usbSnapshots)
            }
            for target in targets {
                let files = regularFiles(under: target)
                guard !files.isEmpty else { continue }
                if !dryRun {
                    do { try FileManager.default.removeItem(at: target) } catch { continue }
                }
                outcome.freedBytes += files.reduce(0) { $0 + $1.size }
                outcome.removedFiles += files.count
            }
            return outcome
        }
    }

    // MARK: 자리별 규칙

    /// 이름 순으로 가장 새 `.db` 하나와 앱이 연 사본을 남긴다(`LibrarySnapshot.prune`과 같은 순서). 지울 사본의 곁 파일도 함께.
    static func snapshotTargets(in folder: URL, keeping: [URL]) -> (targets: [URL], kept: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let databases = names.filter { $0.hasSuffix(".db") }.sorted(by: >)
        let opened = Set(keeping.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        var keep = Set(databases.prefix(1))
        keep.formUnion(databases.filter { opened.contains(folder.appending(path: $0).standardizedFileURL.resolvingSymlinksInPath().path) })
        let removable = databases.filter { !keep.contains($0) }
        let targets = removable.flatMap { name in
            [name, name + "-wal", name + "-shm", name + ".itunes.json"].filter(names.contains).map { folder.appending(path: $0) }
        }
        return (targets, keep.count)
    }

    /// `<볼륨키>/<시각>/` 폴더 중 볼륨마다 가장 새 것을 뺀 나머지. 시각 모양이 아닌 항목·세션 사본은 고르지 않는다.
    static func usbSnapshotTargets(in folder: URL) -> (targets: [URL], kept: Int) {
        let fm = FileManager.default
        var targets: [URL] = [], kept = 0
        for volume in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where !["local-", "usb-", "info-"].contains(where: volume.hasPrefix) {
            let base = folder.appending(path: volume)
            let copies = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
                .filter { $0.range(of: #"^[0-9]{8}T[0-9]{6}(-[0-9]+)?$"#, options: .regularExpression) != nil }
                .sorted { lhs, rhs in
                    let (a, b) = (lhs.split(separator: "-"), rhs.split(separator: "-"))
                    if a[0] != b[0] { return a[0] < b[0] }
                    return (a.count > 1 ? Int(a[1]) ?? 0 : 1) < (b.count > 1 ? Int(b[1]) ?? 0 : 1)
                }
            guard !copies.isEmpty else { continue }
            kept += 1
            targets += copies.dropLast().map { base.appending(path: $0) }
        }
        return (targets, kept)
    }

    /// USB 쓰기·회복·되돌리기가 도는 중(볼륨 잠금이 잡힘)이거나 끝나지 않은 쓰기(닫히지 않은 저널)가 있으면 이유
    static func usbBusyReason(sessions: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: sessions.appending(path: name)),
                  let journal = try? UsbJournal.decoder().decode(UsbJournal.self, from: data), journal.isClosed else {
                return String(ui: "끝나지 않은 USB 쓰기가 있어 USB 읽기 사본은 비우지 않았습니다. USB를 연결해 회복한 뒤 다시 비우세요")
            }
        }
        for name in names where name.hasSuffix(".lock") && isLocked(sessions.appending(path: name)) {
            return String(ui: "USB에 쓰는 중이라 USB 읽기 사본은 비우지 않았습니다. 쓰기가 끝난 뒤 다시 비우세요")
        }
        return nil
    }

    /// `UsbVolumeLock`(flock)이 잡혀 있는지. 공유 잠금을 잠깐 걸어 보고 바로 푼다.
    static func isLocked(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// 파일이면 그 하나, 폴더면 하위까지 일반 파일(심볼릭 링크는 따라가지 않고 세지 않는다)
    static func regularFiles(under url: URL) -> [(url: URL, size: Int64)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return [] }
        if values.isRegularFile == true { return [(url, Int64(values.fileSize ?? 0))] }
        guard values.isDirectory == true,
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return [] }
        var files: [(url: URL, size: Int64)] = []
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            files.append((file, Int64(values.fileSize ?? 0)))
        }
        return files
    }
}
