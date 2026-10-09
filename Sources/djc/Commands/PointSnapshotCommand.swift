import DJCApplication
import DJCDomain
import Foundation

/// `djc snapshot-point`: 시점 스냅샷(#224) 만들기·목록·고정·지우기. 라이브러리 읽기 사본을 뜨는 `djc snapshot`과 다르다.
/// 대상은 `--db <사본.db>`(그 옆 `point-snapshots/`에 둔다) 또는 `--live`(rekordbox 라이브러리, DJCrate 데이터 폴더의 `point-snapshots/`).
enum PointSnapshotCommand {
    static let command = Command("snapshot-point",
                                 String(ui: "create [--name 이름] | list | diff|restore|pin|unpin|delete <ID> — (--db <사본.db> [--share <폴더>] | --live)"),
                                 String(ui: "시점 스냅샷(DB·분석 파일·앨범아트를 한 시점으로) 만들기·목록·비교·복원·고정")) { args in
        print(try await run(args))
    }

    /// 대상 라이브러리와 스냅샷 폴더
    struct Target {
        var database: URL
        var share: URL?
        var snapshots: URL
        var backups: URL
        var live: Bool

        init(_ args: [String]) throws {
            live = args.contains("--live")
            // 다른 쓰기 명령과 달리 --live와 --db를 함께 주면 거부한다.
            guard !(live && value(after: "--db", in: args) != nil), let target = RekordboxWriteTarget.cli(args) else { throw UsageError() }
            database = target.database
            share = target.shareRoot
            backups = target.backups
            snapshots = live ? CLIComposition.pointSnapshotsDirectory : database.deletingLastPathComponent().appending(path: "point-snapshots")
        }

        var writeTarget: RekordboxWriteTarget { RekordboxWriteTarget(database: database, shareRoot: share, backups: backups) }
    }

    /// 자동 스냅샷 보관 일수는 앱 설정(설정 › 저장 공간)을 따른다. 앱이 데이터 폴더의 공유 파일에 적어 둔 값을 읽는다.
    /// 만들기·목록·비교·고정·지우기는 앱 창과 같은 유스케이스(`PointSnapshots`), 복원은 같은 반영 세션이다.
    /// - Parameters:
    ///   - files: 시점 스냅샷 파일(시험은 라이브 판정을 바꾼 실제 구현). nil이면 조립 지점의 것
    ///   - gate: 복원의 쓰기 관문(시험은 라이브 판정을 바꾼 관문). nil이면 조립 지점의 것
    @MainActor
    static func run(_ args: [String], now: Date = .now, files: PointSnapshotFiles? = nil, gate: RekordboxWriteGate? = nil,
                    sharedSettings: URL? = nil) async throws -> String {
        guard args.count > 1 else { throw UsageError() }
        let target = try Target(args)
        let composition = CLIComposition.live
        let points = composition.pointSnapshots(target.writeTarget, directory: target.snapshots, files: files)
        let autoDays = CLIComposition.pointSnapshotAutoDays(sharedSettings: sharedSettings)
        switch args[1] {
        case "create":
            let entry = try await points.create(name: value(after: "--name", in: args) ?? "", autoDays: autoDays, now: now)
            var lines = [String(ui: "시점 스냅샷을 남겼습니다: \(entry.id)")]
            if entry.metadata.cloned == false {
                lines.append(String(ui: "다른 디스크라 클론이 아니라 전체 복사했습니다(공간을 그만큼 씁니다)."))
            }
            return lines.joined(separator: "\n")
        case "list":
            return listText(points)
        case "diff":
            let entry = try entry(args, in: points)
            return diffText(try await points.compare(entry), entry: entry)
        case "restore":
            // 플래그가 곧 동의다(CLI는 묻지 않는다). 복원 직전 상태는 시점 스냅샷으로 남는다. 앱과 같은 반영 세션으로 되돌린다.
            let entry = try entry(args, in: points)
            let report = try await composition.reflection(gate: gate)
                .restorePointSnapshot(entry.url, snapshots: target.snapshots, autoDays: autoDays, now: now, changedTracks: [], to: target.writeTarget)
            return [String(ui: "‘\(entry.displayName)’ 시점으로 복원했습니다."),
                    String(ui: "복원 전으로 돌리려면: \(DJCError.pointRestoreCommand(snapshot: report.beforeRestore.id, database: target.live ? nil : target.database.path))")]
                .joined(separator: "\n")
        case "pin", "unpin":
            let entry = try entry(args, in: points)
            try points.setPinned(args[1] == "pin", entry)
            return args[1] == "pin" ? String(ui: "고정했습니다: \(entry.id)") : String(ui: "고정을 풀었습니다: \(entry.id)")
        case "delete":
            let entry = try entry(args, in: points)
            try await points.delete(entry)
            return String(ui: "지웠습니다: \(entry.id)")
        default:
            throw UsageError()
        }
    }

    /// `pin <ID>`처럼 하위 명령 바로 뒤의 ID(폴더 이름 또는 겹치지 않는 이름)
    static func entry(_ args: [String], in points: PointSnapshots) throws -> RekordboxPointSnapshotEntry {
        guard args.count > 2, !args[2].hasPrefix("--") else { throw UsageError() }
        return try points.find(args[2])
    }

    /// 복원하면 바뀌는 것(요약과 이름). 내용 값·경로는 찍지 않는다.
    static func diffText(_ diff: RekordboxPointSnapshotDiff, entry: RekordboxPointSnapshotEntry) -> String {
        guard !diff.isEmpty else { return String(ui: "‘\(entry.displayName)’과 지금 라이브러리가 같습니다.") }
        var lines = [String(ui: "‘\(entry.displayName)’ 시점으로 복원하면:")] + diff.summary.map { "  " + $0 }
        for group in diff.details() {
            lines.append(group.title + ":")
            lines += group.items.map { "  • " + $0 }
        }
        if diff.cloudSyncedSince(entry) { lines.append(RekordboxPointSnapshotDiff.cloudSyncNote) }
        return lines.joined(separator: "\n")
    }

    /// 시점 스냅샷과 쓰기 전 백업을 함께(따로 정리되며, 쓰기 전 백업은 `djc rekordbox-restore`로 되돌린다)
    static func listText(_ points: PointSnapshots) -> String {
        let entries = points.entries()
        var lines = [String(ui: "시점 스냅샷 \(entries.count)개 (\(points.directory.path))")]
        for entry in entries {
            let size = points.files.size(entry.url).formatted(.byteCount(style: .file).locale(UIStrings.locale))
            var parts = [entry.id, entry.metadata.kind.title]
            if !entry.metadata.name.isEmpty { parts.append("‘\(entry.metadata.name)’") }
            parts.append(entry.metadata.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let tracks = entry.metadata.trackCount { parts.append(String(ui: "\(tracks)곡")) }
            parts.append(size)
            if entry.metadata.pinned { parts.append(String(ui: "고정")) }
            lines.append("  " + parts.joined(separator: " · "))
        }
        let backups = points.writeBackups()
        lines.append(String(ui: "쓰기 전 백업 \(backups.count)개 (\(points.backupDirectory.path))"))
        for backup in backups {
            let titles = backup.titles.prefix(3).joined(separator: ", ")
            lines.append("  " + [backup.url.lastPathComponent, backup.isWrite ? String(ui: "쓰기 전 백업") : String(ui: "복원 직전 백업"), titles]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }
}
