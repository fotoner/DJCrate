import DJCDomain
import Darwin
import Foundation

/// 시험·자가 테스트가 쓰기 도중 강제 종료를 흉내 내려고 훅(`RekordboxWriteHooks.checkpoint`)에서 던진다. 입구는 이 오류를 받으면
/// 되돌리기·기록 정리·준비 폴더 정리를 하나도 하지 않고 그대로 던진다(프로세스가 그 자리에서 끝난 것과 같은 끝 상태).
/// 다른 오류를 던지면 그 자리의 실패로 다룬다(실패 주입).
public struct RekordboxWriteStop: Error, Equatable, Sendable {
    public init() {}
}

/// 쓰기 기록 판정 결과(R11). 관문 포트(`RekordboxJournalVerdict`)로 옮긴다
public enum RekordboxJournalJudgment: Equatable, Sendable {
    /// 기록이 없다(또는 판정이 조용히 지웠다)
    case none
    /// 지금은 판정하지 않는다(라이브 대상의 rekordbox·Agent가 켜져 카운터를 볼 수 없다). 진행 중으로 본다
    case undecided
    /// 중단. 이 대상에 새로 쓰지 않는다(기록으로 복원과 "이대로 둔다"만 된다)
    case interrupted(RekordboxWriteJournal, changedSince: Bool, database: RekordboxFileStamp?)
}

/// 재확인(R10)에서 rekordbox·Agent가 켜진 것을 봤다. 라이브러리를 바꾸기 전이면 롤백·보류, 바꾼 뒤면 기록을 그대로 두고 멈춘다
struct RekordboxRunningSeen: Error {
    var step: RekordboxWriteStep
}

/// 쓰기 한 번(잠금을 쥔 입구 하나)의 기록·재확인·훅. 입구는 잠금을 잡은 뒤 이 값을 만들고, 라이브러리를 처음 바꾸기 직전에 기록을 남기고,
/// 변경이 모두 끝나거나 복구가 끝나면 지운다(R11). 시험 실행(dryRun)은 만들지 않는다(`nil`이면 모든 단계가 할 일이 없다).
final class WriteRun {
    let database: URL
    /// 링크를 푼 master.db(기록 자리·크기·시각을 이 경로로 본다)
    let resolved: URL
    let key: RekordboxWriteLockKey
    let journalURL: URL
    let live: Bool
    let writeGuard: RekordboxWriteGuard
    /// 쓰기 백업 폴더(기록 핀을 둔다)
    let backups: URL?
    /// 시점 스냅샷 폴더(시점 복원의 기록 핀을 둔다)
    var snapshots: URL?
    private let hold: RekordboxWriteLockHold?
    private(set) var journal: RekordboxWriteJournal?
    /// 기록을 남긴 뒤 라이브러리를 실제로 바꿨는지(켜짐을 보면 롤백할지, 기록을 남기고 멈출지 가른다)
    var changed = false

    var hooks: RekordboxWriteHooks { writeGuard.hooks }

    /// 잠금을 잡지 않고 만든다(부르는 쪽이 이미 쥔 잠금 아래에서 판정할 때)
    init(database: URL, guard writeGuard: RekordboxWriteGuard, backups: URL?, snapshots: URL? = nil,
         hold: RekordboxWriteLockHold? = nil) throws {
        self.database = database
        resolved = try RekordboxWriteLocks.resolve(database)
        key = try RekordboxWriteLocks.key(database)
        journalURL = RekordboxWriteJournal.url(resolvedDatabase: resolved)
        live = writeGuard.isLive(database)
        self.writeGuard = writeGuard
        self.backups = backups
        self.snapshots = snapshots
        self.hold = hold
    }

    /// 대상의 쓰기 잠금을 잡고(기다린다) 만든다. 하드 링크 master.db는 잠금 키가 갈라져 잡은 직후 거부한다(R9, 기록으로 복원·
    /// "이대로 둔다" 포함). 라이브 사전 확인을 하는 입구(`prepareWrite`·`prepareRestore`)만 `refusesHardLinks: false`로 그 확인 뒤로 미룬다
    /// (라이브 DB의 하드 링크 별칭은 라이브 검사의 이유로 먼저 거절한다). 그 밖의 사전 확인은 잡은 뒤에 한다
    static func locked(_ database: URL, guard writeGuard: RekordboxWriteGuard, backups: URL?, snapshots: URL? = nil,
                       refusesHardLinks: Bool = true) throws -> WriteRun {
        let hold = try writeGuard.locks.lock(try RekordboxWriteLocks.key(database))
        do {
            let run = try WriteRun(database: database, guard: writeGuard, backups: backups, snapshots: snapshots, hold: hold)
            if refusesHardLinks { try RekordboxWriteLocks.refuseHardLinks(run.resolved) }
            return run
        } catch {
            hold.release()
            throw error
        }
    }

    /// 잠금을 푼다(입구 끝에서 `defer`로)
    func close() { hold?.release() }

    /// 잠금을 잡은 뒤의 사전 확인(R9·R11): 라이브면 rekordbox 실행·-wal·버전(`checkLive`), 하드 링크 master.db 거부, 중단 기록 거절.
    /// 쓰기 입구(초안 쓰기·곡 넣기·빼기·iTunes 동기화)가 백업을 뜨기 전에 부른다
    func prepareWrite() throws {
        if live { try writeGuard.checkLive(database, dryRun: false) }
        try RekordboxWriteLocks.refuseHardLinks(resolved)
        try refuseInterrupted()
    }

    /// 잠금을 잡은 뒤의 복원 사전 확인: 라이브면 rekordbox 실행만 본다(비상 복원이라 버전·-wal은 보지 않는다), 하드 링크 거부
    func prepareRestore() throws {
        if live, writeGuard.isRekordboxRunning() {
            throw DJCError.writeRefused(String(ui: "rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 되돌리세요"))
        }
        try RekordboxWriteLocks.refuseHardLinks(resolved)
    }

    // MARK: - 재확인·훅

    /// 그 단계 바로 직전의 rekordbox·Agent 실행 재확인(R10). 라이브 대상만 실제로 보고, 시험은 훅으로 켜짐을 흉내 낸다
    func recheck(_ step: RekordboxWriteStep) throws {
        hooks.timing(.recheck(step), .now)
        try hooks.checkpoint(.recheck(step))
        let running = hooks.isRekordboxRunning?(step) ?? (live && writeGuard.isRekordboxRunning())
        if running { throw RekordboxRunningSeen(step: step) }
    }

    func before(_ step: RekordboxWriteStep) throws { try hooks.checkpoint(.before(step)) }

    func after(_ step: RekordboxWriteStep) throws {
        hooks.timing(.after(step), .now)
        try hooks.checkpoint(.after(step))
    }

    /// 재확인 → 단계 → 끝 훅
    func step<T>(_ step: RekordboxWriteStep, recheck: Bool = true, _ body: () throws -> T) throws -> T {
        if recheck { try self.recheck(step) }
        try before(step)
        let value = try body()
        try after(step)
        return value
    }

    // MARK: - 기록

    /// 기록을 남긴다(라이브러리를 처음 바꾸기 직전). 핀을 먼저 두어 기록이 가리키는 백업·시점 스냅샷이 솎이지 않게 한다.
    /// 저장소 잠금을 기다릴 수 있으니 부르는 쪽은 그 뒤 첫 변경 직전에 실행을 다시 본다(S12)
    func begin(_ journal: RekordboxWriteJournal) throws {
        var journal = journal
        if journal.database == nil { journal.database = RekordboxWriter.fileStamp(resolved) }
        try before(.journalWrite)
        // 근거 확인·핀·기록 저장을 저장소 잠금 아래에서 한다(다른 대상의 솎기와 겹치지 않게, S8). 같은 폴더는 한 번만 잡는다(S17)
        let roots = [backups, snapshots].compactMap { $0 }
        let holds = try RekordboxWriteLocks.lockStores(roots)
        defer { holds.forEach { $0.release() } }
        for root in roots {
            for name in RekordboxWriter.referencedFolders(journal, in: root).sorted()
            where !FileManager.default.fileExists(atPath: root.appending(path: name).path) {
                throw DJCError.writeRefused(String(ui: "저장 전 백업 \(name)이 사라져 저장하지 않았습니다. 다른 DJCrate가 백업을 정리하는 중이면 잠시 뒤 다시 시도하세요"))
            }
        }
        try RekordboxWriter.pinJournal(journal, at: journalURL, roots: roots)
        try RekordboxWriter.saveJournal(journal, at: journalURL)
        self.journal = journal
        try after(.journalWrite)
    }

    /// 기록 핀을 둔(둘) 뿌리: 이 실행의 백업·시점 스냅샷 폴더와 기록이 가리키는 백업·시점 스냅샷의 부모 폴더.
    /// 다른 실행이 마친 기록(시점 복원을 기록으로 복원 등)도 처음 둔 핀을 지운다
    func pinRoots(_ journal: RekordboxWriteJournal) -> [URL] {
        let named = [journal.basis.writeBackup, journal.basis.pointSnapshot, journal.pointRestore?.snapshotBeforeRestore].compactMap { $0 }
            .map { URL(filePath: $0).standardizedFileURL.deletingLastPathComponent() }
        var seen = Set<String>(), roots: [URL] = []
        for root in [backups, snapshots].compactMap({ $0?.standardizedFileURL }) + named
        where seen.insert(root.resolvingSymlinksInPath().comparablePath).inserted {
            roots.append(root)
        }
        return roots
    }

    /// 남은 기록을 이어받는다(기록으로 복원·다시 하는 복원)
    func adopt(_ journal: RekordboxWriteJournal) { self.journal = journal }

    /// 기록을 고친다(표시·DB 크기·시각). 기록이 없으면 할 일이 없다
    func update(_ change: (inout RekordboxWriteJournal) -> Void) throws {
        guard var journal else { return }
        change(&journal)
        guard journal != self.journal else { return }
        try before(.journalWrite)
        try RekordboxWriter.saveJournal(journal, at: journalURL)
        self.journal = journal
        try after(.journalWrite)
    }

    /// DB를 바꾼 뒤 그 크기·시각을 적는다(켜짐을 보고 멈출 때는 부르지 않는다). 커밋 직후 상태를 적었으니 최종 카운터는 지운다:
    /// 그 뒤로는 카운터가 같아도 크기·시각이 다르면 경고한다(R11, S13)
    func databaseChanged() throws {
        changed = true
        let stamp = RekordboxWriter.fileStamp(resolved)
        try update {
            $0.database = stamp
            $0.finalCounter = nil
        }
    }

    /// 기록을 지운다(라이브러리 변경이 모두 끝났거나 복구가 끝남). 핀은 뒤에 지운다
    func finish() throws {
        guard let journal else { return }
        try before(.journalRemove)
        try? FileManager.default.removeItem(at: journalURL)
        guard !FileManager.default.fileExists(atPath: journalURL.path) else {
            throw DJCError.writeVerificationFailed(String(ui: "쓰기 기록(master.db.djc-write)을 지우지 못했습니다"))
        }
        self.journal = nil
        RekordboxWriter.unpinJournal(journal, roots: pinRoots(journal))
        try after(.journalRemove)
    }

    // MARK: - 판정·거절

    /// 남은 기록을 판정한다(잠금을 쥔 채). 표시가 없는 카운터 쓰기의 기록이고 지금 카운터가 시작 카운터와 같으면 조용히 지운다
    func judge() throws -> RekordboxJournalJudgment {
        guard let found = try RekordboxWriter.readJournal(at: journalURL) else { return .none }
        let current = RekordboxWriter.fileStamp(resolved)
        var counter: Int?
        // 표시가 있는 기록은 카운터와 상관없이 중단이라 DB 사본을 뜨지 않는다(G14)
        if found.marks.isEmpty, found.kind == .counter, found.startCounter != nil || found.finalCounter != nil {
            // 카운터는 rekordbox가 꺼졌음을 확인한 뒤 스냅샷 사본에서 읽는다(SAFE-6)
            if live, writeGuard.isRekordboxRunning() { return .undecided }
            try before(.counterRead)
            counter = try? RekordboxWriter.snapshotCounter(of: resolved)
        }
        if found.marks.isEmpty, found.kind == .counter, let start = found.startCounter, counter == start {
            try? FileManager.default.removeItem(at: journalURL)
            RekordboxWriter.unpinJournal(found, roots: pinRoots(found))
            return .none
        }
        let recorded = [found.database, found.restoreCopy].compactMap { $0 }
        // 지금 카운터가 이 쓰기의 최종 카운터면 크기·시각 차이는 이 쓰기의 커밋이다(커밋 뒤 크기·시각을 적기 전에 멈췄다)
        let ownCommit = found.marks.isEmpty && found.finalCounter != nil && counter == found.finalCounter
        let changedSince = !ownCommit && !recorded.isEmpty && !recorded.contains { $0 == current }
        return .interrupted(found, changedSince: changedSince, database: current)
    }

    /// 중단 기록이 남았으면 새로 쓰지 않는다(R11·R7: 앱·CLI 공통)
    func refuseInterrupted() throws {
        switch try judge() {
        case .none: return
        case .undecided: throw DJCError.rekordboxRunning
        case .interrupted: throw RekordboxWriter.interruptedRefusal
        }
    }

    /// 켜짐을 보고 멈췄을 때(라이브러리를 바꾼 뒤) 알릴 오류. 기록은 그대로 남아 중단으로 다룬다
    func stoppedError() -> DJCError {
        let reason = String(ui: "저장하는 도중 rekordbox가 켜졌습니다")
        let detail = String(ui: "rekordbox가 켜져 있어 되돌리지 않고 남은 단계를 멈췄습니다. rekordbox를 종료한 뒤 상태 줄에서 저장 전으로 복원하거나 이대로 두세요")
        if journal?.entry == .pointRestore, let before = journal?.pointRestore?.snapshotBeforeRestore {
            return .pointRestoreFailed(reason: reason, restoreError: detail, snapshot: URL(filePath: before).lastPathComponent,
                                       database: live ? nil : database.path)
        }
        return .restoreFailed(reason: reason, restoreError: detail, backup: journal?.basis.writeBackup ?? "", database: live ? nil : database.path)
    }

    /// 자동 복구의 시작(R7·R11): 켜짐부터 다시 보고, 첫 변경 전에 "복구 중"을 적는다. 표시를 남기지 못하면 아무것도 되돌리지 않고
    /// 기록을 그대로 둔 채 복구 실패로 알린다(표시 없이 되돌리다 멈추면 다음 판정이 카운터만 보고 기록을 지워, 바꾼 파일이 남는다).
    /// 그대로 진행하면 nil, 멈출 때는 던질 오류
    func markRecovering(_ failure: any Error) -> (any Error)? {
        do {
            try recheck(.recovery)
            try before(.recovery)
            try update { $0.marks.insert(.recovering) }
            return nil
        } catch {
            if let passed = passThrough(error) { return passed }
            let detail = String(ui: "복구 중 표시를 남기지 못해 되돌리지 않았습니다: \(DJCError.reason(of: error))")
            // 시점 복원은 기록이 받는 복원 직전 시점을 안내한다(표시 폴더는 백업 복원이 거절한다, G11)
            if journal?.entry == .pointRestore, let before = journal?.pointRestore?.snapshotBeforeRestore {
                return DJCError.pointRestoreFailed(reason: DJCError.reason(of: failure), restoreError: detail,
                                                   snapshot: URL(filePath: before).lastPathComponent, database: live ? nil : database.path)
            }
            return DJCError.restoreFailed(reason: DJCError.reason(of: failure), restoreError: detail,
                                          backup: journal?.basis.writeBackup ?? "", database: live ? nil : database.path)
        }
    }

    /// 라이브러리를 바꾸기 전에 멈춘 실패: 강제 종료 흉내는 그대로 던지고(아무것도 치우지 않는다), 그 밖은 이 쓰기가 남긴 기록을 지운 뒤
    /// 켜짐이면 보류(`rekordboxRunning`), 아니면 그 오류로 끝낸다. 바꾼 뒤면 기록을 남긴다
    func abandon(_ error: any Error) -> any Error {
        if error is RekordboxWriteStop { return error }
        if !changed { try? finish() }
        return passThrough(error) ?? error
    }

    /// 실패를 어떻게 던질지 고른다: 강제 종료 흉내는 그대로, 켜짐은 바꾸기 전이면 보류(`rekordboxRunning`), 바꾼 뒤면 멈춤(기록을 남긴다)
    func passThrough(_ error: any Error) -> (any Error)? {
        if error is RekordboxWriteStop { return error }
        if error is RekordboxRunningSeen { return changed ? stoppedError() : DJCError.rekordboxRunning }
        return nil
    }
}

extension RekordboxWriter {
    /// 중단 기록이 남은 대상에 새로 쓰려 할 때
    static var interruptedRefusal: DJCError {
        .writeRefused(String(ui: "이 라이브러리에 끝나지 않은 저장 기록이 남아 있어 저장하지 않았습니다. DJCrate 상태 줄에서 기록으로 복원하거나 이대로 두세요"))
    }

    /// 작업 ID가 파일 이름으로 안전한지(기록 핀·미정리 목록의 파일 이름이 된다): 글자·숫자와 `-`·`_`·`.`만(경로 구분자·NUL 없음),
    /// 점으로 시작하지 않고(`.`·`..` 없음) `<ID>.json`이 파일 이름 한도에 들게 UTF-8 200바이트까지
    static func isSafeOperationID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && !id.hasPrefix(".")
            && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    static var invalidOperationID: DJCError {
        .writeRefused(String(ui: "작업 ID를 파일 이름으로 쓸 수 없어 저장하지 않았습니다. 다시 저장하세요"))
    }

    // MARK: - 기록 파일

    /// 파일의 크기·수정 시각(나노초). 없으면 nil
    static func fileStamp(_ url: URL) -> RekordboxFileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return RekordboxFileStamp(size: Int64(info.st_size), modifiedNanoseconds: nanoseconds)
    }

    /// 기록을 읽는다. 없으면 nil, 읽지 못하면 던진다(모르는 판·깨진 내용도 중단처럼 쓰기를 막는다)
    static func readJournal(at url: URL) throws -> RekordboxWriteJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try RekordboxWriteJournal.decode(Data(contentsOf: url))
        } catch {
            throw DJCError.writeRefused(String(ui: "쓰기 기록(master.db.djc-write)을 읽지 못해 저장하지 않았습니다. 이 DJCrate가 모르는 형식이면 DJCrate를 업데이트한 뒤 다시 시도하세요"))
        }
    }

    /// 기록을 원자적으로 적는다(같은 폴더의 `.part`를 거쳐 이름을 바꾼다)
    static func saveJournal(_ journal: RekordboxWriteJournal, at url: URL) throws {
        let data = try RekordboxWriteJournal.encoder.encode(journal)
        let partial = URL(filePath: url.path + ".part")
        try? FileManager.default.removeItem(at: partial)
        try data.write(to: partial)
        let handle = try FileHandle(forWritingTo: partial)
        try? handle.synchronize()
        try? handle.close()
        guard rename(partial.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw DJCError.writeVerificationFailed(String(ui: "쓰기 기록(master.db.djc-write)을 남기지 못했습니다: \(String(cString: strerror(errno)))"))
        }
    }

    /// master.db 사본에서 변경 카운터를 읽는다(SAFE-6: 라이브 DB를 열지 않는다). 사본은 곧바로 지운다(클라우드 토큰이 든다, SAFE-15)
    static func snapshotCounter(of database: URL) throws -> Int {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "djc-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appending(path: "master.db")
        try fm.copyItem(at: database, to: copy)
        let wal = URL(filePath: database.path + "-wal")
        if let size = (try? fm.attributesOfItem(atPath: wal.path))?[.size] as? Int, size > 0 {
            try fm.copyItem(at: wal, to: URL(filePath: copy.path + "-wal"))
            try CipherDatabase.mergeWriteAheadLog(ofCopyAt: copy.path, key: RekordboxKey.derive())
        }
        let db = try CipherDatabase(path: copy.path, key: RekordboxKey.derive())
        defer { db.close() }
        guard let value = try scalar(db, "SELECT int_1 FROM agentRegistry WHERE registry_id = 'localUpdateCount'", []) else {
            throw DJCError.writeRefused(String(ui: "rekordbox 변경 카운터를 찾지 못했습니다"))
        }
        return value
    }

    // MARK: - 기록 핀(솎기·삭제 보호)

    /// 백업·시점 스냅샷 폴더의 기록 핀 폴더(점으로 시작해 백업·스냅샷 목록에 들지 않는다)
    static let journalPinFolder = ".djc-journal-pins"

    struct JournalPin: Codable {
        var journal: String
        var operationID: String
        /// 핀을 둘 때 그 기록이 가리킨 이 뿌리 바로 아래 폴더(기록을 읽지 못하거나 기록의 볼륨이 빠져도 지킨다)
        var folders: [String]?
    }

    /// 중단 기록이 남은 동안 그 기록이 가리키는 쓰기 전 백업·시점 스냅샷을 솎기와 삭제에서 빼려고, 그 폴더 뿌리에 핀을 둔다(R11).
    /// 다른 대상이 같은 백업 폴더에 쓰며 솎을 때도 핀을 본다. 기록이 사라진 핀은 무시한다
    static func pinJournal(_ journal: RekordboxWriteJournal, at url: URL, roots: [URL]) throws {
        guard isSafeOperationID(journal.operationID) else { throw invalidOperationID }
        for root in roots {
            let pin = JournalPin(journal: url.path, operationID: journal.operationID, folders: referencedFolders(journal, in: root).sorted())
            let folder = root.appending(path: journalPinFolder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(pin).write(to: folder.appending(path: journal.operationID + ".json"), options: .atomic)
        }
    }

    /// 기록이 가리키는 그 뿌리 바로 아래 폴더 이름(근거·연쇄 복원의 뒤 백업·파일 원본·시점 복원의 스냅샷)
    static func referencedFolders(_ journal: RekordboxWriteJournal, in root: URL) -> Set<String> {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().comparablePath + "/"
        let paths = [journal.basis.writeBackup, journal.basis.pointSnapshot, journal.basis.iTunesSyncBefore,
                     journal.pointRestore?.snapshotBeforeRestore].compactMap { $0 } + (journal.basis.chain ?? [])
            + journal.files.compactMap(\.original)
        var names = Set<String>()
        for path in paths {
            let spelled = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().comparablePath
            guard spelled.hasPrefix(base), let first = spelled.dropFirst(base.count).split(separator: "/").first else { continue }
            names.insert(String(first))
        }
        return names
    }

    static func unpinJournal(_ journal: RekordboxWriteJournal, roots: [URL]) {
        // 파일 이름으로 안전하지 않은 작업 ID의 핀은 둔 적이 없다(그 이름으로 뿌리 밖을 지우지 않는다)
        guard isSafeOperationID(journal.operationID) else { return }
        for root in roots {
            let folder = root.appending(path: journalPinFolder, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: folder.appending(path: journal.operationID + ".json"))
            // 비었을 때만 지운다(rmdir): 다른 기록이 사이에 둔 핀을 함께 지우지 않게
            rmdir(folder.path)
        }
    }

    /// 그 뿌리(백업 폴더·시점 스냅샷 폴더)에서 남은 중단 기록이 가리키는 바로 아래 폴더 이름. 기록이 그대로 있으면 기록으로,
    /// 기록을 읽지 못하거나 기록이 있던 폴더째 보이지 않으면(볼륨이 빠짐) 핀에 적어 둔 폴더로 지킨다. 기록이 사라졌거나 다른 작업의 것이면 무시한다
    static func journalFolders(in root: URL) -> Set<String> {
        let folder = root.appending(path: journalPinFolder, directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var names = Set<String>()
        for file in files {
            guard let pin = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(JournalPin.self, from: $0) }) else { continue }
            let url = URL(filePath: pin.journal)
            let recorded = Set(pin.folders ?? [])
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    guard let journal = try readJournal(at: url), journal.operationID == pin.operationID else { continue }
                    names.formUnion(referencedFolders(journal, in: root).union(recorded))
                } catch {
                    names.formUnion(recorded)
                }
            } else if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                names.formUnion(recorded)
            }
        }
        return names
    }
}

/// 앱 쓰기의 정리 할 일(R11·R22). 관문이 묶음에 실린 초안의 판과 작업 ID로 만들어 입구에 넘긴다(CLI·시험은 nil).
/// 입구는 쓰기 기록에 초안의 판과 초안 저장소 위치를 적고, 라이브러리 변경을 마친 뒤 기록을 지우기 직전에 미정리 목록을 적는다.
public struct RekordboxDraftRecord<Report>: Sendable {
    /// 작업 ID(쓰기 기록·미정리 목록이 같은 값을 쓴다)
    public var operationID: String
    /// 쓰기 기록에 적을 초안(이 쓰기에 든 초안의 판과 초안 저장소 위치)
    public var drafts: RekordboxWriteJournal.Drafts?
    /// 쓴 결과로 미정리 목록을 만든다. 대상 키·백업 폴더는 입구가 채운다. nil이면 적지 않는다
    public var cleanupList: @Sendable (Report) -> DraftCleanupList?

    public init(operationID: String, drafts: RekordboxWriteJournal.Drafts?, cleanupList: @escaping @Sendable (Report) -> DraftCleanupList?) {
        self.operationID = operationID
        self.drafts = drafts
        self.cleanupList = cleanupList
    }
}

extension RekordboxWriter {
    // MARK: - 미정리 목록(R22)

    /// 백업 폴더의 미정리 목록을 모두 읽는다(최근 작업 ID 차례). 읽지 못하는 목록이 있으면 던진다
    public static func cleanupLists(in backups: URL) throws -> [DraftCleanupList] {
        let folder = backups.appending(path: DraftCleanupList.folderName, directoryHint: .isDirectory)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { file in
            do {
                return try DraftCleanupList.decode(Data(contentsOf: file))
            } catch {
                throw DJCError.writeRefused(String(ui: "초안 정리 목록(\(file.lastPathComponent))을 읽지 못했습니다. 이 DJCrate가 모르는 형식이면 DJCrate를 업데이트한 뒤 다시 시도하세요"))
            }
        }
    }

    /// 미정리 목록을 원자적으로 적는다
    static func saveCleanupList(_ list: DraftCleanupList, in backups: URL) throws {
        guard isSafeOperationID(list.operationID) else { throw invalidOperationID }
        let url = DraftCleanupList.url(backups: backups, operationID: list.operationID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try DraftCleanupList.encoder.encode(list).write(to: url, options: .atomic)
    }

    /// 정리를 마친 목록을 지운다(쓰기 잠금을 잡지 않는다: "이대로 둔다"의 일 안에서도 부른다). 목록 폴더가 비면 그것도 지운다
    public static func removeCleanupList(operationID: String, in backups: URL) throws {
        // 안전하지 않은 작업 ID의 목록은 적은 적이 없다(그 이름으로 백업 폴더 밖을 지우지 않는다)
        guard isSafeOperationID(operationID) else { return }
        let url = DraftCleanupList.url(backups: backups, operationID: operationID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let folder = url.deletingLastPathComponent()
        // 비었을 때만 지운다(rmdir): 다른 실행이 사이에 적은 목록을 함께 지우지 않게
        rmdir(folder.path)
    }

    /// 라이브러리 변경을 모두 마친 쓰기의 끝(R11·R22): 미정리 목록을 적고(앱의 쓰기), 쓰기 기록을 지우고, 백업을 솎는다.
    /// 목록을 적지 못하면 초안을 정리하지 않게 던지고 기록을 남긴다(중단으로 다룬다)
    static func finishRun(_ run: WriteRun, backup: URL, backups: URL, list: DraftCleanupList?, now: Date) throws {
        try handOff(run, backup: backup, backups: backups, list: list)
        prune(backups, now: now)
    }

    /// 백업 보호를 기록 핀에서 미정리 목록으로 넘긴다(S8): 목록 게시와 기록 지우기를 그 백업 폴더의 저장소 잠금 아래에서 해서, 솎기가
    /// 목록을 읽은 뒤 기록 핀만 사라진 틈에 그 백업을 지우지 않게 한다. 목록이 있는데 잠금을 잡지 못하면 게시도 기록 지우기도 하지 않고
    /// 멈춘다(기록이 남아 중단으로 다룬다). 목록이 없으면 넘길 보호가 없어 잠금 없이도 기록을 지운다
    private static func handOff(_ run: WriteRun, backup: URL, backups: URL, list: DraftCleanupList?) throws {
        func listNotSaved(_ error: any Error) -> DJCError {
            .restoreFailed(reason: String(ui: "초안 정리 목록을 남기지 못했습니다: \(DJCError.reason(of: error))"),
                           restoreError: String(ui: "rekordbox에는 저장했지만 정리 목록이 없어 초안을 정리하지 않고 쓰기 기록을 남겼습니다. 상태 줄에서 이대로 두거나 저장 전으로 복원하세요"),
                           backup: backup.path, database: run.live ? nil : run.database.path)
        }
        var hold: RekordboxWriteLockHold?
        do {
            hold = try RekordboxWriteLocks.lockStore(backups)
        } catch {
            if list != nil { throw listNotSaved(error) }
        }
        defer { hold?.release() }
        if var list {
            list.target = run.key
            list.backupFolder = backup.lastPathComponent
            do {
                try run.before(.cleanupListWrite)
                try saveCleanupList(list, in: backups)
                try run.after(.cleanupListWrite)
            } catch let stop as RekordboxWriteStop {
                throw stop
            } catch {
                throw listNotSaved(error)
            }
        }
        do {
            try run.finish()
        } catch let stop as RekordboxWriteStop {
            throw stop
        } catch {
            throw DJCError.restoreFailed(reason: String(ui: "쓰기 기록을 지우지 못했습니다: \(DJCError.reason(of: error))"),
                                         restoreError: String(ui: "rekordbox에는 저장했지만 쓰기 기록이 남아 다음 저장을 막습니다. 상태 줄에서 이대로 두세요"),
                                         backup: backup.path, database: run.live ? nil : run.database.path)
        }
    }
}
