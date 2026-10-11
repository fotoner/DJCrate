import DJCDomain
import Foundation

/// 시점 스냅샷으로 복원(#225). 스냅샷은 DJCrate가 쓰는 파일 전체(DB·재생 목록 파일·분석·앨범아트 폴더)를 담으므로
/// 쓰기 전 백업처럼 뒤 백업을 차례로 되돌릴(#222 연쇄) 필요가 없다. 고른 스냅샷 하나로 DB와 분석 파일이 같은 시점을 가리킨다.
///
/// 순서: 대상 확인(시험의 실제 라이브러리 거부) → rekordbox 꺼짐 → 스냅샷 확인(정보·링크·담은 항목·같은 라이브러리·무결성)
/// → 복원 직전 시점 스냅샷 → 쓰기 전 백업 사슬에 복원 표시 → 분석·앨범아트 폴더를 같은 폴더에 클론으로 준비
/// → DB·`masterPlaylists6.xml`·`playlists3.sync` 바꾸기 → 폴더 이름 바꿔 끼우기 → 다시 읽어 검증(무결성·라이브러리 ID·폴더 목록).
/// 바꾸는 도중 실패하면 DB·파일·폴더를 복원 전으로 돌리고, 그것도 못 하면 복원 직전 스냅샷으로 되돌릴 명령을 알린다.
extension RekordboxWriter {
    public typealias PointRestoreReport = RekordboxPointRestoreReport

    /// 쓰기 전 백업 폴더에 남기는 복원 표시(이 시점보다 옛 쓰기 전 백업은 연쇄로 분석 파일을 맞출 수 없다)
    static let pointRestoreMarkerName = "point-restore.json"

    struct PointRestoreMarker: Codable {
        var snapshot: String
        var beforeRestore: String
    }

    /// 분석·앨범아트 폴더 하나를 바꿔 끼우는 상태
    struct FolderSwap {
        var target: URL
        /// 스냅샷에서 클론한 새 내용(스냅샷에 없던 폴더면 nil)
        var staged: URL?
        /// 옮겨 둔 지금 내용(지금 없던 폴더면 nil)
        var old: URL?
        var swapped = false
    }

    /// 고른 시점 스냅샷으로 rekordbox 라이브러리를 되돌린다. 대상 DB·share·폴더는 부르는 쪽이 적는다(라이브 기본 인자 없음).
    /// 버전·DB 구조는 보지 않는다(쓰기 전으로 복원과 같은 비상구). rekordbox 실행만 막는다.
    @discardableResult
    public static func restore(pointSnapshot: URL, to database: URL, shareRoot: URL?, snapshots: URL, backups: URL,
                               autoDays: Int, now: Date = .now, guard writeGuard: RekordboxWriteGuard = .system) throws -> PointRestoreReport {
        let share = try RekordboxPointSnapshot.resolvedShare(database, shareRoot: shareRoot, guard: writeGuard)
        let live = writeGuard.isLive(database)
        if live, writeGuard.isRekordboxRunning() {
            throw DJCError.writeRefused(String(ui: "rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 되돌리세요"))
        }
        let entry = try validPointSnapshot(pointSnapshot)
        try checkSameLibrary(backup: entry.url.appending(path: "master.db"), target: database)
        try checkIntegrity(of: entry.url.appending(path: "master.db"))
        for name in RekordboxPointSnapshot.adjacentFiles {
            try writeGuard.checkAdjacentFile(database.deletingLastPathComponent().appending(path: name), database: database)
        }
        // 여기까지 아무것도 바꾸지 않았다. 복원 직전 상태를 남기지 못하면(rekordbox 켜짐·WAL 등) 복원하지 않는다.
        let before = try RekordboxPointSnapshot.take(name: "", kind: .beforeRestore, database: database, shareRoot: share, in: snapshots,
                                                     now: now, guard: writeGuard, restoredFrom: entry.displayName)
        let marker: URL
        do {
            marker = try writePointRestoreMarker(PointRestoreMarker(snapshot: entry.id, beforeRestore: before.id), in: backups, now: now)
        } catch {
            try? FileManager.default.removeItem(at: before.url)
            throw error
        }
        var swaps: [FolderSwap] = []
        do {
            swaps = try stagePointFolders(from: entry.url, share: share)
            try replaceLibraryFiles(from: entry.url, to: database)
            try swapPointFolders(&swaps)
            try verifyPointRestore(entry, database: database, share: share)
        } catch {
            throw rollbackPointRestore(error, before: before, database: database, swaps: swaps, marker: marker, live: live)
        }
        for swap in swaps { if let old = swap.old { try? FileManager.default.removeItem(at: old) } }
        prune(backups)
        RekordboxPointSnapshot.prune(in: snapshots, autoDays: autoDays, now: now)
        return PointRestoreReport(restored: entry, beforeRestore: before)
    }

    // MARK: - 확인

    /// 정보·DB·담은 항목이 멀쩡하고 링크가 없는 스냅샷만 받는다.
    static func validPointSnapshot(_ folder: URL) throws -> RekordboxPointSnapshot.Entry {
        func refuse(_ reason: String) -> DJCError {
            .writeRefused(String(ui: "시점 스냅샷을 복원할 수 없습니다: \(reason). 목록에서 다른 스냅샷을 고르세요"))
        }
        guard (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeDirectory,
              let metadata = RekordboxPointSnapshot.metadata(in: folder) else {
            throw refuse(String(ui: "스냅샷 정보(snapshot.json)가 없거나 손상됨"))
        }
        try validateBackupFile(folder.appending(path: "master.db"), under: folder, required: true)
        for name in RekordboxPointSnapshot.adjacentFiles {
            try validateBackupFile(folder.appending(path: name), under: folder, required: metadata.items.contains(name))
        }
        for item in RekordboxPointSnapshot.shareFolders.map({ "share/" + $0 }) {
            let url = folder.appending(path: item)
            let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            if metadata.items.contains(item) {
                guard type == .typeDirectory else { throw refuse(String(ui: "담았다고 적힌 \(item) 폴더가 없거나 링크임")) }
                try RekordboxPointSnapshot.rejectLinks(in: url)
            } else if type != nil {
                throw refuse(String(ui: "정보에 없는 \(item) 폴더가 있음"))
            }
        }
        return RekordboxPointSnapshot.Entry(url: folder, metadata: metadata)
    }

    // MARK: - 바꾸기

    /// 스냅샷의 분석·앨범아트 폴더를 대상 폴더 옆(같은 볼륨)에 클론으로 준비한다. 아직 지금 폴더는 그대로다.
    static func stagePointFolders(from snapshot: URL, share: URL) throws -> [FolderSwap] {
        let fm = FileManager.default
        var swaps: [FolderSwap] = []
        do {
            for folder in RekordboxPointSnapshot.shareFolders {
                let target = share.appending(path: folder)
                let source = snapshot.appending(path: "share").appending(path: folder)
                var swap = FolderSwap(target: target)
                if fm.fileExists(atPath: source.path) {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let staged = target.deletingLastPathComponent().appending(path: ".djc-restore-\(UUID().uuidString)-\(target.lastPathComponent)")
                    try fm.copyItem(at: source, to: staged)
                    swap.staged = staged
                }
                swaps.append(swap)
            }
        } catch {
            for swap in swaps { if let staged = swap.staged { try? fm.removeItem(at: staged) } }
            throw error
        }
        return swaps
    }

    /// 스냅샷의 `master.db`로 바꾸고(곁 `-wal`·`-shm`은 지운다) 재생 목록 파일·iTunes 동기화 파일을 스냅샷 것으로 쓴다.
    /// 스냅샷에 없던 파일은 지금 것을 그대로 둔다(그 시점에 rekordbox가 아직 만들지 않은 파일).
    static func replaceLibraryFiles(from snapshot: URL, to database: URL) throws {
        let fm = FileManager.default
        let partial = URL(filePath: database.path + ".djc-restore")
        try? fm.removeItem(at: partial)
        try fm.copyItem(at: snapshot.appending(path: "master.db"), to: partial)
        _ = try fm.replaceItemAt(database, withItemAt: partial)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: database.path + suffix) {
            try fm.removeItem(atPath: database.path + suffix)
        }
        for name in RekordboxPointSnapshot.adjacentFiles {
            let source = snapshot.appending(path: name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let data = try Data(contentsOf: source), target = database.deletingLastPathComponent().appending(path: name)
            if (try? Data(contentsOf: target)) != data { try data.write(to: target, options: .atomic) }
        }
    }

    /// 지금 폴더를 옆으로 옮기고 준비한 폴더를 그 이름으로 바꾼다(같은 폴더 안 이름 바꾸기).
    static func swapPointFolders(_ swaps: inout [FolderSwap]) throws {
        let fm = FileManager.default
        for index in swaps.indices {
            let target = swaps[index].target
            if fm.fileExists(atPath: target.path) {
                let old = target.deletingLastPathComponent().appending(path: ".djc-old-\(UUID().uuidString)-\(target.lastPathComponent)")
                try fm.moveItem(at: target, to: old)
                swaps[index].old = old
            }
            swaps[index].swapped = true
            if let staged = swaps[index].staged {
                try fm.moveItem(at: staged, to: target)
                swaps[index].staged = nil
            }
        }
    }

    /// 다시 읽어 확인: DB 무결성·라이브러리 ID, 분석·앨범아트 폴더의 파일 목록과 크기가 스냅샷과 같은지.
    static func verifyPointRestore(_ entry: RekordboxPointSnapshot.Entry, database: URL, share: URL) throws {
        try checkIntegrity(of: database)
        if let expected = entry.metadata.libraryID, libraryID(of: database) != expected {
            throw DJCError.writeVerificationFailed(String(ui: "복원한 라이브러리 ID가 스냅샷과 다릅니다"))
        }
        for folder in RekordboxPointSnapshot.shareFolders {
            let restored = RekordboxPointSnapshot.fileStamps(share.appending(path: folder))
            let expected = RekordboxPointSnapshot.fileStamps(entry.url.appending(path: "share").appending(path: folder))
            guard restored == expected else {
                throw DJCError.writeVerificationFailed(String(ui: "복원한 \(folder) 폴더의 파일이 스냅샷과 다릅니다"))
            }
        }
    }

    // MARK: - 되돌리기

    /// 복원 도중 실패: DB·파일은 복원 직전 스냅샷에서, 폴더는 옮겨 둔 지금 내용으로 돌린다. 표시도 지운다.
    /// 그것도 못 하면 복원 직전 스냅샷으로 되돌릴 명령을 준다.
    static func rollbackPointRestore(_ failure: any Error, before: RekordboxPointSnapshot.Entry, database: URL,
                                     swaps: [FolderSwap], marker: URL, live: Bool) -> any Error {
        let fm = FileManager.default
        do {
            try replaceLibraryFiles(from: before.url, to: database)
            for swap in swaps.reversed() {
                if let staged = swap.staged { try? fm.removeItem(at: staged) }
                guard swap.swapped else { continue }
                if fm.fileExists(atPath: swap.target.path) { try fm.removeItem(at: swap.target) }
                if let old = swap.old { try fm.moveItem(at: old, to: swap.target) }
            }
            try? fm.removeItem(at: marker)
            return failure
        } catch {
            return DJCError.pointRestoreFailed(reason: DJCError.reason(of: failure), restoreError: DJCError.reason(of: error),
                                               snapshot: before.id, database: live ? nil : database.path)
        }
    }

    // MARK: - 쓰기 전 백업 사슬

    /// 쓰기 전 백업 폴더에 시점 복원 표시를 남긴다(이름의 시각 = 쓰기 전 백업과 같은 모양이라 순서가 맞는다).
    static func writePointRestoreMarker(_ marker: PointRestoreMarker, in directory: URL, now: Date) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        var name = formatter.string(from: now) + "-point-restore", suffix = 2
        while fm.fileExists(atPath: directory.appending(path: name).path) {
            name = formatter.string(from: now) + "-point-restore-\(suffix)"
            suffix += 1
        }
        let folder = directory.appending(path: name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: folder.appending(path: pointRestoreMarkerName), options: .atomic)
        return folder
    }

    static func isPointRestoreMarker(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: pointRestoreMarkerName).path)
    }

    /// 고른 쓰기 전 백업 뒤에 시점 스냅샷 복원이 있었으면 그 이유(없으면 nil). 쓰기 전 백업은 그 쓰기가 바꾼 파일만 담아,
    /// 시점 복원이 폴더째 바꾼 분석 파일을 사슬로 되돌릴 수 없다. 그 시점은 복원 직전 시점 스냅샷이 전체를 담고 있다.
    public static func pointRestoreRefusal(after backup: URL, in directory: URL) -> String? {
        let selected = backup.standardizedFileURL
        let markers = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { isPointRestoreMarker($0) && isNewer($0, than: selected) }
        guard !markers.isEmpty else { return nil }
        return String(ui: "이 백업 뒤에 시점 스냅샷으로 복원해서 쓰기 전 백업으로는 분석 파일까지 맞출 수 없습니다. rekordbox › 시점 스냅샷…에서 ‘복원 직전’ 스냅샷이나 그 전 시점을 고르세요")
    }
}
