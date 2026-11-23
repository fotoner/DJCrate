import DJCDomain
import Darwin
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

    /// 분석·앨범아트 폴더 하나를 바꿔 끼우는 상태. 임시 폴더 이름은 미리 정해 쓰기 기록에 적는다(R11)
    struct FolderSwap {
        var target: URL
        /// 새 내용을 클론할 자리(`.djc-restore-*`, 대상 옆)
        var stagedPath: URL
        /// 지금 내용을 옮겨 둘 자리(`.djc-old-*`, 대상 옆)
        var oldPath: URL
        /// 스냅샷에서 클론한 새 내용(스냅샷에 없던 폴더면 nil)
        var staged: URL?
        /// 옮겨 둔 지금 내용(지금 없던 폴더면 nil)
        var old: URL?
        var swapped = false

        init(target: URL) {
            self.target = target
            let parent = target.deletingLastPathComponent(), id = UUID().uuidString
            stagedPath = parent.appending(path: ".djc-restore-\(id)-\(target.lastPathComponent)")
            oldPath = parent.appending(path: ".djc-old-\(id)-\(target.lastPathComponent)")
        }

        var temporaryFolders: [String] { [stagedPath.path, oldPath.path] }

        /// 쓰기 기록에 적는 폴더 역할("이대로 둔다"가 빈 자리를 이 역할로 채운다)
        var role: RekordboxWriteJournal.PointRestore.Folder { .init(target: target.path, staged: stagedPath.path, old: oldPath.path) }
    }

    /// 분석·앨범아트 폴더마다 바꿔 끼울 상태(임시 폴더 이름까지 정한다)
    static func pointSwaps(share: URL) -> [FolderSwap] {
        RekordboxPointSnapshot.shareFolders.map { FolderSwap(target: share.appending(path: $0)) }
    }

    /// 고른 시점 스냅샷으로 rekordbox 라이브러리를 되돌린다. 대상 DB·share·폴더는 부르는 쪽이 적는다(라이브 기본 인자 없음).
    /// 버전·DB 구조는 보지 않는다(쓰기 전으로 복원과 같은 비상구). rekordbox 실행만 막는다.
    @discardableResult
    public static func restore(pointSnapshot: URL, to database: URL, shareRoot: URL?, snapshots: URL, backups: URL,
                               autoDays: Int, now: Date = .now, guard writeGuard: RekordboxWriteGuard = .system) throws -> PointRestoreReport {
        let share = try RekordboxPointSnapshot.resolvedShare(database, shareRoot: shareRoot, guard: writeGuard)
        let live = writeGuard.isLive(database)
        // 쓰기 잠금(R9)을 잡은 뒤 실행을 본다. 중단 기록이 남았으면 그 기록으로 다시 하는 복원만 받는다(R11): 기록의 시점이나,
        // 복원 실패 안내대로 그 복원 직전 시점. 다른 시점·백업으로 복원하는 것은 기록이 남은 동안 막는다
        let run = try WriteRun.locked(database, guard: writeGuard, backups: backups, snapshots: snapshots,
                                      refusesHardLinks: false)
        defer { run.close() }
        try run.prepareRestore()
        switch try run.judge() {
        case .none: break
        case .undecided: throw DJCError.rekordboxRunning
        case let .interrupted(journal, _, _):
            // 링크로 가리켜도 같은 시점이면 같다고 본다. 다시 하는 복원은 일치한 기록의 실제 스냅샷 경로로 한다(별칭을 기록에 적지 않는다, S18)
            let requested = pointSnapshot.standardizedFileURL.resolvingSymlinksInPath().comparablePath
            guard journal.entry == .pointRestore, let point = journal.pointRestore,
                  let matched = [journal.basis.pointSnapshot, point.snapshotBeforeRestore].compactMap({ $0 })
                    .first(where: { URL(filePath: $0).standardizedFileURL.resolvingSymlinksInPath().comparablePath == requested }) else {
                throw interruptedRefusal
            }
            let target = URL(filePath: matched)
            let restored = try validPointSnapshot(target)
            run.adopt(journal)
            _ = try restoreByJournal(journal, run: run, backups: backups, shareRoot: share, now: now, pointTarget: target)
            guard let before = RekordboxPointSnapshot.metadata(in: URL(filePath: point.snapshotBeforeRestore))
                    .map({ RekordboxPointSnapshot.Entry(url: URL(filePath: point.snapshotBeforeRestore), metadata: $0) }) else {
                throw journalBasisMissing
            }
            return PointRestoreReport(restored: restored, beforeRestore: before)
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
        // 첫 변경 직전에 실행을 다시 보고 파일 쓰기 기록을 남긴다(R10·R11): 복원 직전 스냅샷과 만들 임시 폴더 이름까지 적는다.
        // 기록으로 복원은 같은 시점으로 다시 하고, 이 복원 직전 스냅샷을 다시 쓴다(새로 뜨지 않는다)
        var swaps = pointSwaps(share: share)
        do {
            try run.recheck(.databaseReplace)
            try run.begin(RekordboxWriteJournal(operationID: UUID().uuidString, kind: .files, entry: .pointRestore,
                                                basis: .init(writeBackup: marker.path, pointSnapshot: entry.url.path),
                                                pointRestore: .init(snapshotBeforeRestore: before.url.path,
                                                                    temporaryFolders: swaps.flatMap(\.temporaryFolders), folders: swaps.map(\.role))))
        } catch {
            // 강제 종료 흉내는 아무것도 치우지 않는다(기록이 이미 남았으면 그 스냅샷을 가리킨다)
            if !(error is RekordboxWriteStop) {
                try? FileManager.default.removeItem(at: marker)
                try? FileManager.default.removeItem(at: before.url)
            }
            throw run.abandon(error)
        }
        do {
            try stagePointFolders(&swaps, from: entry.url)
            // 링크로 가리킨 DB면 링크를 파일로 바꾸지 않게 링크를 푼 자리를 바꾼다
            try replaceLibraryFiles(from: entry.url, to: run.resolved, run: run)
            try swapPointFolders(&swaps, run: run)
            try run.step(.verify, recheck: false) { try verifyPointRestore(entry, database: run.resolved, share: share) }
        } catch {
            if error is RekordboxWriteStop { throw error }
            // 아직 아무것도 바꾸지 않았으면(클론을 만든 뒤 켜짐 등) 클론·표시·복원 직전 스냅샷과 기록을 치우고 보류·실패로 끝낸다
            if !run.changed {
                for swap in swaps { if let staged = swap.staged { try? FileManager.default.removeItem(at: staged) } }
                try? FileManager.default.removeItem(at: marker)
                try? FileManager.default.removeItem(at: before.url)
                throw run.abandon(error)
            }
            if let passed = run.passThrough(error) { throw passed }
            throw rollbackPointRestore(error, before: before, database: database, swaps: swaps, marker: marker, live: live, run: run)
        }
        for swap in swaps { if let old = swap.old { try? FileManager.default.removeItem(at: old) } }
        try finishRun(run, backup: marker, backups: backups, list: nil, now: now)
        RekordboxPointSnapshot.prune(in: snapshots, autoDays: autoDays, now: now)
        return PointRestoreReport(restored: entry, beforeRestore: before)
    }

    /// 중단된 시점 복원을 기록으로 다시 한다(R11). 기록에 적힌 복원 직전 스냅샷을 다시 쓰고(새로 뜨지 않는다), 목표는 기록의 시점이나
    /// (복원 실패 안내대로) 그 복원 직전 시점이다. 이미 목표 상태면 끝난 것으로 본다. 기록에 적힌 임시 폴더는 다시 한 복원의 검증이 끝난 뒤
    /// 지운다. 다시 한 복원이 실패하면 되돌리지 않고 기록을 남겨 같은 목표로 다시 할 수 있게 한다.
    static func redoPointRestore(_ journal: RekordboxWriteJournal, to snapshot: URL, run: WriteRun, shareRoot: URL?) throws -> JournalRestoreResult {
        guard let point = journal.pointRestore else { throw journalBasisMissing }
        let share = try RekordboxPointSnapshot.resolvedShare(run.database, shareRoot: shareRoot, guard: run.writeGuard)
        let entry = try validPointSnapshot(snapshot)
        func removeTemporaryFolders() throws {
            let recorded = run.journal?.pointRestore?.temporaryFolders ?? point.temporaryFolders
            // 검사한 URL로만 지운다(기록의 글자를 그대로 쓰지 않는다, S1)
            for folder in recorded.compactMap({ pointTemporaryFolder($0, share: share) }) where FileManager.default.fileExists(atPath: folder.path) {
                // 임시 폴더는 분석 루트 안이라 지우기 직전에도 실행을 다시 본다
                try run.recheck(.fileReplace)
                try FileManager.default.removeItem(at: folder)
            }
        }
        // DB와 그 곁 파일(재생 목록·iTunes 동기화 파일, -wal·-shm)까지 시점과 같고 폴더도 같아야 끝난 것으로 본다
        // (DB만 바꾸고 멈춘 복원이 "이미 복원됨"이 되지 않게). 파일 비교를 먼저 한다
        if try libraryFilesMatch(entry.url, database: run.resolved),
           (try? verifyPointRestore(entry, database: run.resolved, share: share)) != nil {
            try removeTemporaryFolders()
            return .alreadyRestored
        }
        var swaps = pointSwaps(share: share)
        let added = swaps
        try run.update {
            guard var point = $0.pointRestore else { return }
            point.temporaryFolders += added.flatMap(\.temporaryFolders)
            point.folders = (point.folders ?? []) + added.map(\.role)
            $0.pointRestore = point
        }
        try stagePointFolders(&swaps, from: entry.url)
        try replaceLibraryFiles(from: entry.url, to: run.resolved, run: run)
        try swapPointFolders(&swaps, run: run)
        try run.step(.verify, recheck: false) { try verifyPointRestore(entry, database: run.resolved, share: share) }
        try removeTemporaryFolders()
        return .restored(URL(filePath: point.snapshotBeforeRestore))
    }

    // MARK: - 확인

    /// 정보·DB·담은 항목이 멀쩡하고 링크가 없는 스냅샷만 받는다.
    static func validPointSnapshot(_ folder: URL) throws -> RekordboxPointSnapshot.Entry {
        func refuse(_ reason: String) -> DJCError {
            .writeRefused(String(ui: "복원 시점으로 복원할 수 없습니다: \(reason). 목록에서 다른 복원 시점을 고르세요"))
        }
        guard (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeDirectory,
              let metadata = RekordboxPointSnapshot.metadata(in: folder) else {
            throw refuse(String(ui: "복원 시점 정보(snapshot.json)가 없거나 손상됨"))
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
    static func stagePointFolders(_ swaps: inout [FolderSwap], from snapshot: URL) throws {
        let fm = FileManager.default
        do {
            for index in swaps.indices {
                let target = swaps[index].target
                let source = snapshot.appending(path: "share").appending(path: target.deletingLastPathComponent().lastPathComponent)
                    .appending(path: target.lastPathComponent)
                if fm.fileExists(atPath: source.path) {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: swaps[index].stagedPath)
                    swaps[index].staged = swaps[index].stagedPath
                }
            }
        } catch {
            for index in swaps.indices {
                if let staged = swaps[index].staged { try? fm.removeItem(at: staged) }
                swaps[index].staged = nil
            }
            throw error
        }
    }

    /// 스냅샷의 `master.db`로 바꾸고(곁 `-wal`·`-shm`은 지운다) 재생 목록 파일·iTunes 동기화 파일을 스냅샷 것으로 쓴다.
    /// 스냅샷에 없던 파일은 지금 것을 그대로 둔다(그 시점에 rekordbox가 아직 만들지 않은 파일).
    /// 쓰기 기록(`run`)이 있으면 DB 교체·`-wal`·`-shm` 삭제·파일 바꾸기 바로 직전마다 실행을 다시 보고(R10), DB 교체 전에 준비 사본의
    /// 크기·시각을, 바꾼 뒤 master.db 크기·시각을 기록에 적는다(R11).
    static func replaceLibraryFiles(from snapshot: URL, to database: URL, run: WriteRun? = nil) throws {
        let fm = FileManager.default
        let partial = URL(filePath: database.path + ".djc-restore")
        try? fm.removeItem(at: partial)
        try fm.copyItem(at: snapshot.appending(path: "master.db"), to: partial)
        do {
            if let run { try run.update { $0.restoreCopy = fileStamp(partial) } }
            try run?.recheck(.databaseReplace)
            try run?.before(.databaseReplace)
            run?.changed = true
            _ = try fm.replaceItemAt(database, withItemAt: partial)
        } catch {
            // 바꾸지 못했으면(켜짐·실패) 준비 사본(클라우드 토큰이 든다)을 남기지 않는다. 강제 종료 흉내는 그대로 둔다
            if !(error is RekordboxWriteStop) { try? fm.removeItem(at: partial) }
            throw error
        }
        try run?.databaseChanged()
        try run?.after(.databaseReplace)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: database.path + suffix) {
            try run?.recheck(.sidecarRemove)
            try run?.before(.sidecarRemove)
            run?.changed = true
            try fm.removeItem(atPath: database.path + suffix)
            try run?.after(.sidecarRemove)
        }
        for name in RekordboxPointSnapshot.adjacentFiles {
            let source = snapshot.appending(path: name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let data = try Data(contentsOf: source), target = database.deletingLastPathComponent().appending(path: name)
            if (try? Data(contentsOf: target)) != data {
                try run?.recheck(.fileReplace)
                try run?.before(.fileReplace)
                run?.changed = true
                try data.write(to: target, options: .atomic)
                try run?.after(.fileReplace)
            }
        }
    }

    /// DB·재생 목록 파일·iTunes 동기화 파일이 시점과 같은지, -wal·-shm이 남지 않았는지(복원은 둘을 지운다).
    /// 시점에 없던 곁 파일은 복원이 그대로 두므로 보지 않는다
    static func libraryFilesMatch(_ snapshot: URL, database: URL) throws -> Bool {
        let fm = FileManager.default
        for name in RekordboxPointSnapshot.adjacentFiles {
            let source = snapshot.appending(path: name)
            guard fm.fileExists(atPath: source.path) else { continue }
            guard try sameContents(database.deletingLastPathComponent().appending(path: name), source) else { return false }
        }
        guard try sameSidecar(of: database, as: snapshot.appending(path: "master.db")),
              !fm.fileExists(atPath: database.path + "-shm") else { return false }
        return try sameContents(database, snapshot.appending(path: "master.db"))
    }

    /// 지금 폴더를 준비한 폴더와 바꿔 끼운다(같은 폴더 안 이름 바꾸기). 폴더 하나마다 그 앞에서만 실행을 다시 본다(R10, `run`이 있을 때):
    /// 둘 다 있으면 한 번에 맞바꾸고(`renamex_np` `RENAME_SWAP`, 옛 내용은 준비 자리에 남는다), 안 되면 옮기기 둘을 사이 재확인 없이 잇는다.
    /// 그래서 켜짐을 보고 멈춰도 폴더 자리가 비지 않는다.
    static func swapPointFolders(_ swaps: inout [FolderSwap], run: WriteRun? = nil) throws {
        let fm = FileManager.default
        for index in swaps.indices {
            let target = swaps[index].target
            let exists = fm.fileExists(atPath: target.path)
            guard exists || swaps[index].staged != nil else { swaps[index].swapped = true; continue }
            try run?.recheck(.fileReplace)
            try run?.before(.fileReplace)
            run?.changed = true
            if exists, let staged = swaps[index].staged, renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
                swaps[index].old = staged
                swaps[index].staged = nil
                swaps[index].swapped = true
            } else {
                if exists {
                    try fm.moveItem(at: target, to: swaps[index].oldPath)
                    swaps[index].old = swaps[index].oldPath
                }
                swaps[index].swapped = true
                if let staged = swaps[index].staged {
                    try fm.moveItem(at: staged, to: target)
                    swaps[index].staged = nil
                }
            }
            try run?.after(.fileReplace)
        }
    }

    /// 다시 읽어 확인: DB 무결성·라이브러리 ID, 분석·앨범아트 폴더의 파일 목록과 크기가 스냅샷과 같은지.
    static func verifyPointRestore(_ entry: RekordboxPointSnapshot.Entry, database: URL, share: URL) throws {
        try checkIntegrity(of: database)
        if let expected = entry.metadata.libraryID, libraryID(of: database) != expected {
            throw DJCError.writeVerificationFailed(String(ui: "복원한 라이브러리 ID가 복원 시점과 다릅니다"))
        }
        for folder in RekordboxPointSnapshot.shareFolders {
            let restored = RekordboxPointSnapshot.fileStamps(share.appending(path: folder))
            let expected = RekordboxPointSnapshot.fileStamps(entry.url.appending(path: "share").appending(path: folder))
            guard restored == expected else {
                throw DJCError.writeVerificationFailed(String(ui: "복원한 \(folder) 폴더의 파일이 복원 시점과 다릅니다"))
            }
        }
    }

    // MARK: - 되돌리기

    /// 복원 도중 실패: DB·파일은 복원 직전 스냅샷에서, 폴더는 옮겨 둔 지금 내용으로 돌린다(`putBack`). 표시도 지운다.
    /// 그것도 못 하면 복원 직전 스냅샷으로 되돌릴 명령을 준다.
    /// 쓰기 기록(`run`)이 있으면 켜짐부터 다시 보고(켜졌으면 기록을 그대로 둔 채 멈춘다), 첫 변경 전에 "복구 중"을 적고, 다 돌리면 기록을 지우고,
    /// 못 돌리면 "복구 실패"로 남긴다(R7·R11).
    static func rollbackPointRestore(_ failure: any Error, before: RekordboxPointSnapshot.Entry, database: URL,
                                     swaps: [FolderSwap], marker: URL, live: Bool, run: WriteRun? = nil) -> any Error {
        let fm = FileManager.default
        if let run, let refused = run.markRecovering(failure) { return refused }
        do {
            try replaceLibraryFiles(from: before.url, to: run?.resolved ?? database, run: run)
            for swap in swaps.reversed() {
                if let staged = swap.staged { try? fm.removeItem(at: staged) }
                guard swap.swapped else { continue }
                try run?.recheck(.fileReplace)
                try putBack(swap)
            }
            try run?.after(.recovery)
            try run?.finish()
            try? fm.removeItem(at: marker)
            return failure
        } catch {
            if let run, let passed = run.passThrough(error) { return passed }
            if let run { try? run.update { $0.marks.insert(.recoveryFailed) } }
            return DJCError.pointRestoreFailed(reason: DJCError.reason(of: failure), restoreError: DJCError.reason(of: error),
                                               snapshot: before.id, database: live ? nil : database.path)
        }
    }

    /// 바꿔 끼운 폴더 자리를 복원 전 내용으로 되돌린다(S16). 둘 다 있으면 한 번에 맞바꾸고(`RENAME_SWAP`: 사이에 멈춰도 자리가 비지 않는다)
    /// 옛 자리로 간 복원 내용을 지운다. 복원 전 내용이 없어졌으면 지금 폴더를 지우지 않고 실패한다. 맞바꾸지 못하는 볼륨은 지우고 옮긴다
    /// (사이에 멈추면 자리가 빈다: "이대로 둔다"가 기록의 폴더 역할로 복원 전 내용을 되돌린다). 복원 전에 없던 폴더는 끼운 폴더를 지운다
    static func putBack(_ swap: FolderSwap) throws {
        let fm = FileManager.default, target = swap.target
        guard let old = swap.old else {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            return
        }
        guard fm.fileExists(atPath: old.path) else {
            throw DJCError.writeVerificationFailed(String(ui: "복원 전 \(target.lastPathComponent) 폴더를 찾지 못해 그 폴더를 되돌리지 않았습니다"))
        }
        if fm.fileExists(atPath: target.path) {
            if renamex_np(old.path, target.path, UInt32(RENAME_SWAP)) == 0 {
                try fm.removeItem(at: old)
                return
            }
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: old, to: target)
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
        return String(ui: "이 백업 뒤에 복원 시점으로 복원해서 저장 전 백업으로는 분석 파일까지 맞출 수 없습니다. rekordbox › 복원 시점…에서 ‘복원 직전’ 복원 시점이나 그 전 시점을 고르세요")
    }
}
