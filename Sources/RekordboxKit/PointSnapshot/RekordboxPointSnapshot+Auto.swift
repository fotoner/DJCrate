import DJCDomain
import Foundation

/// 하루 한 번 자동 시점 스냅샷(#228). 앱이 돌아가는 동안 뒤에서 불러, 남길 때가 됐을 때만 조용히 뜬다.
/// - rekordbox·rekordboxAgent가 꺼져 있고 WAL이 비었을 때만(자동은 사본이어도 rekordbox가 켜져 있으면 뜨지 않는다)
/// - 그날(달력 기준) 자동 스냅샷이 이미 있으면 뜨지 않는다
/// - 마지막 스냅샷(종류 상관없이) 뒤 `master.db` 크기·수정 시각이 그대로면 뜨지 않는다(도장 없는 옛 스냅샷은 그 안의 DB 파일로 견준다)
/// - 클론이 안 되면(DJCrate 데이터 폴더가 다른 디스크) 큰 복사를 몰래 하지 않게 뜨지 않는다
/// - 뜨든 안 뜨든 보존 정리를 한다(수동·고정·복원 직전은 일수와 상관없다)
extension RekordboxPointSnapshot {
    public typealias SourceStamp = RekordboxPointSnapshotSourceStamp

    public typealias AutoSkip = RekordboxPointSnapshotAutoSkip
    public typealias AutoOutcome = RekordboxPointSnapshotAutoOutcome

    public static func sourceStamp(of database: URL) -> SourceStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: database.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date else { return nil }
        return SourceStamp(size: Int64(size), modified: modified.timeIntervalSince1970)
    }

    /// 남길 때가 됐는지(파일 정보만 보는 규칙, 시각·달력은 주입). nil이면 뜬다.
    public static func autoSkip(entries: [Entry], current: SourceStamp?, now: Date, calendar: Calendar) -> AutoSkip? {
        guard let current else { return .noDatabase }
        if entries.contains(where: { $0.metadata.kind == .auto && calendar.isDate($0.metadata.createdAt, inSameDayAs: now) }) {
            return .alreadyToday
        }
        if let latest = entries.max(by: { $0.metadata.createdAt < $1.metadata.createdAt }), recordedStamp(of: latest) == current {
            return .unchanged
        }
        return nil
    }

    /// 그 스냅샷을 뜰 때 원본 `master.db`의 도장. 도장이 없는 옛 스냅샷(#224)은 스냅샷 안의 `master.db` 크기·수정 시각으로 견준다
    /// (복사·클론은 수정 시각을 그대로 둔다). 안의 DB를 읽지 못하는 등 견줄 수 없으면 nil이라 "바뀐 것"으로 보고 뜬다(안전한 쪽).
    static func recordedStamp(of entry: Entry) -> SourceStamp? {
        entry.metadata.source ?? sourceStamp(of: entry.url.appending(path: "master.db"))
    }

    /// 때가 됐으면 자동 시점 스냅샷을 뜨고 보존 정리를 한다. 대상은 부르는 쪽이 적는다(라이브 기본 인자 없음).
    /// 뜨는 도중 rekordbox가 켜지거나 DB가 바뀌면 버리고 오류를 던진다(다음 기회에 다시 본다).
    public static func takeAutoIfDue(database: URL, shareRoot: URL?, in directory: URL, autoDays: Int, now: Date = .now,
                                     calendar: Calendar = .current,
                                     canClone cloneCheck: (URL, URL) -> Bool = { canClone(from: $0, to: $1) },
                                     guard writeGuard: RekordboxWriteGuard) throws -> AutoOutcome {
        // 시험 프로세스의 실제 라이브러리는 여기서 거부된다(#182)
        _ = try resolvedShare(database, shareRoot: shareRoot, guard: writeGuard)
        let outcome = try autoOutcome(database: database, shareRoot: shareRoot, in: directory, now: now, calendar: calendar,
                                      cloneCheck: cloneCheck, guard: writeGuard)
        if FileManager.default.fileExists(atPath: directory.path) { prune(in: directory, autoDays: autoDays, now: now) }
        return outcome
    }

    private static func autoOutcome(database: URL, shareRoot: URL?, in directory: URL, now: Date, calendar: Calendar,
                                    cloneCheck: (URL, URL) -> Bool, guard writeGuard: RekordboxWriteGuard) throws -> AutoOutcome {
        if writeGuard.isRekordboxRunning() { return .skipped(.rekordboxRunning) }
        if let size = (try? FileManager.default.attributesOfItem(atPath: database.path + "-wal"))?[.size] as? Int, size > 0 {
            return .skipped(.walPending)
        }
        if let skip = autoSkip(entries: list(in: directory), current: sourceStamp(of: database), now: now, calendar: calendar) {
            return .skipped(skip)
        }
        guard cloneCheck(database.deletingLastPathComponent(), directory) else { return .skipped(.noClone) }
        return .took(try take(name: "", kind: .auto, database: database, shareRoot: shareRoot, in: directory, now: now, guard: writeGuard))
    }
}
