import CryptoKit
import DJCDomain
import DJCEnvironment
import Foundation

/// USB에 쓰는 유일한 길. 형식(OneLibrary·pdb)을 모르는 채로 변경 묶음(`UsbChangeSet`)을 파일 단위로 쓴다.
///
/// 단계(`UsbWriter+*`): A 막힘 확인(부작용 없음) → B 준비·저널 → C 맥에 백업 → D 파일(음원 → 분석 → 아트워크 → 그 밖)
/// → E DB 교체(exportLibrary.db → export.pdb → exportExt.pdb, 커밋 지점)·동기화 선택 확정 → F 지우기 → G 검증 → I 끝.
/// D 이후 실패·취소·검증 실패는 H(백업으로 되돌리기). 저널은 맥에 두고 바꿀 때마다 내구 쓰기로 내린 뒤 다음 USB 연산을 한다.
/// 파일은 늘 같은 폴더의 임시 이름(`UsbLayout.tempName`)에 쓰고 fsync한 뒤 rename한다. 단계마다 볼륨이 아직 붙어 있는지 보고,
/// 사라졌으면 되돌리지 않고 멈춘다(분리된 마운트 지점 폴더에 쓰면 USB가 아니라 맥에 쓰게 된다) — 다음에 붙으면 회복이 이어 판정한다.
public enum UsbWriter {
    public static func write(_ changes: UsbChangeSet, root: UsbRoot, paths: UsbWritePaths, guard writeGuard: UsbWriteGuard,
                             fileSystem: any UsbFileSystem = PosixUsbFileSystem(),
                             verifiers: [any UsbWriteVerifier] = [UsbFingerprintVerifier()],
                             inspectors: [any UsbWriteInspector] = [], options: UsbWriteOptions = .init(),
                             ppthReader: (@Sendable (Data) -> String?)? = nil,
                             now: Date = .now,
                             progress: @escaping @Sendable (UsbProgress) -> Void = { _ in },
                             isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> UsbWriteReport {
        let run = try UsbWriteRun.open(root: root, paths: paths, guard: writeGuard, fileSystem: fileSystem, ppthReader: ppthReader,
                                       now: now, progress: progress, expectedVolumeUUID: options.expectedVolumeUUID)
        defer { run.close() }
        return try run.write(changes, verifiers: verifiers, inspectors: inspectors, options: options, isCancelled: isCancelled)
    }

    /// 끝나지 않은 쓰기를 마치거나 되돌린다. 대상(DB)을 먼저 보고 방향을 정한다. 쓰기와 같은 확인(관문 포함)을 먼저 거친다.
    /// 보고서의 session이 빈 문자열이면 회복할 저널이 없었다(임시 파일만 알리거나 `discardTemp`로 지웠다)
    public static func recover(root: UsbRoot, paths: UsbWritePaths, guard writeGuard: UsbWriteGuard,
                               fileSystem: any UsbFileSystem = PosixUsbFileSystem(), ppthReader: (@Sendable (Data) -> String?)? = nil,
                               discardTemp: Bool = false, confirmName: String? = nil,
                               expectedVolumeUUID: String? = nil) throws -> UsbWriteReport {
        let run = try UsbWriteRun.open(root: root, paths: paths, guard: writeGuard, fileSystem: fileSystem, ppthReader: ppthReader,
                                       now: .now, progress: { _ in }, expectedVolumeUUID: expectedVolumeUUID)
        defer { run.close() }
        return try run.recover(discardTemp: discardTemp, confirmName: confirmName)
    }

    /// 끝난 쓰기를 그 쓰기의 백업으로 되돌린다(`usb-restore`). backup이 nil이면 이 볼륨의 가장 최근 백업
    public static func restore(root: UsbRoot, paths: UsbWritePaths, backup: URL?, guard writeGuard: UsbWriteGuard,
                               fileSystem: any UsbFileSystem = PosixUsbFileSystem(), discardDeviceChanges: Bool = false,
                               confirmName: String? = nil, dryRun: Bool = false,
                               expectedVolumeUUID: String? = nil) throws -> UsbWriteReport {
        let run = try UsbWriteRun.open(root: root, paths: paths, guard: writeGuard, fileSystem: fileSystem, ppthReader: nil,
                                       now: .now, progress: { _ in }, expectedVolumeUUID: expectedVolumeUUID)
        defer { run.close() }
        return try run.restore(backup: backup, discardDeviceChanges: discardDeviceChanges, confirmName: confirmName, dryRun: dryRun)
    }

    /// 볼륨의 닫히지 않은 저널(닫혔거나 없거나 읽지 못하면 nil). 읽지 못한 저널은 `journalStatus`가 `.corrupt`로 알린다
    public static func pendingJournal(paths: UsbWritePaths, volumeKey: String) -> UsbJournal? {
        if case let .open(journal) = journalStatus(paths: paths, volumeKey: volumeKey) { return journal }
        return nil
    }

    /// USB DB 파일(사이드카 포함)의 지금 지문. 수정 계획의 base로 쓰고, 쓰기 전 확인이 같은 함수로 다시 떠 비교한다
    public static func databaseFingerprint(root: UsbRoot, fileSystem: any UsbFileSystem = PosixUsbFileSystem()) throws -> UsbFingerprint {
        var files: [String: UsbFingerprint.Stamp] = [:]
        for path in databaseFamily {
            let url = root.url.appending(path: path)
            guard let info = try fileSystem.stat(url), info.kind == .file else { continue }
            files[path] = .init(size: info.size, mtime: info.modificationDate, sha256: try fileSystem.sha256(url, uncached: true))
        }
        return UsbFingerprint(files: files)
    }

    // MARK: - 공용

    /// 교체 순서
    static let databaseOrder = [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb]
    /// 지문에 넣는 DB 파일과 사이드카
    static let databaseFamily = [UsbLayout.oneLibrary] + UsbLayout.oneLibrarySidecarSuffixes.map { UsbLayout.oneLibrary + $0 }
        + [UsbLayout.exportPdb, UsbLayout.exportExtPdb]
    /// 백업하는 DB 쪽 파일(있는 것만)
    static let databaseBackupFiles = databaseFamily + [UsbLayout.exportPdb + ".bak"]
    /// 임시 파일을 찾는 우리 폴더
    static let ourFolders = [UsbLayout.rekordboxDir, UsbLayout.analysisRoot, UsbLayout.artworkRoot, UsbLayout.contents]

    /// 우리 폴더의 `.djc-part-*`(이름만 보고 찾는다. 열지 않는 경로로 내려가지 않는다)
    static func tempFiles(root: UsbRoot, fileSystem: any UsbFileSystem) throws -> [String] {
        var found: [String] = []
        func walk(_ relative: String) throws {
            let url = root.url.appending(path: relative)
            guard let info = try fileSystem.stat(url), info.kind == .directory else { return }
            for name in try fileSystem.list(url) {
                let child = relative + "/" + name
                if UsbLayout.isTemp(name) {
                    found.append(UsbLayout.nfc(child))
                    continue
                }
                if UsbLayout.isAppleDouble(name) || UsbLayout.isNeverRead(child) { continue }
                if try fileSystem.stat(root.url.appending(path: child))?.kind == .directory { try walk(child) }
            }
        }
        for folder in ourFolders { try walk(folder) }
        return found.sorted()
    }

    static func sha256(_ data: Data) -> String { PosixUsbFileSystem.hex(SHA256.hash(data: data)) }

    /// 볼륨 저널 파일의 상태. 쓰기·되돌리기·회복과 앱이 같은 판정을 쓴다
    public enum JournalStatus: Equatable, Sendable {
        case missing
        /// 끝나지 않은 쓰기(회복해야 다음 쓰기를 한다)
        case open(UsbJournal)
        case closed(UsbJournal)
        /// 파일은 있으나 읽지 못함. 쓰기·되돌리기·회복 모두 `journalUnreadable`로 막는다(usb-sessions를 사람이 봐야 한다)
        case corrupt
    }

    static func journalURL(paths: UsbWritePaths, volumeKey: String) -> URL {
        paths.sessions.appending(path: volumeKey + ".json")
    }

    public static func journalStatus(paths: UsbWritePaths, volumeKey: String) -> JournalStatus {
        let url = journalURL(paths: paths, volumeKey: volumeKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let journal = try? UsbJournal.decoder().decode(UsbJournal.self, from: data) else {
            return .corrupt
        }
        return journal.isClosed ? .closed(journal) : .open(journal)
    }

    static var journalUnreadableBlock: UsbBlock {
        UsbBlock(code: "journalUnreadable", scope: .volume,
                 message: String(ui: "회복 기록 파일을 읽지 못했습니다. DJCrate 데이터 폴더의 usb-sessions를 확인하세요"))
    }

    /// 되돌리기가 끝난 백업 폴더의 표지(같은 백업으로 다시 되돌리면 "이미 되돌렸다"고 알린다)
    static let restoredMarkerName = "restored.json"
}

/// 상대 경로 도우미
enum UsbPath {
    static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
    static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }
    static func isAnalysis(_ path: String) -> Bool { UsbLayout.collisionKey(path).hasPrefix(UsbLayout.collisionKey(UsbLayout.analysisRoot) + "/") }
    static func isArtwork(_ path: String) -> Bool { UsbLayout.collisionKey(path).hasPrefix(UsbLayout.collisionKey(UsbLayout.artworkRoot) + "/") }
    static func isAudio(_ path: String) -> Bool { UsbLayout.collisionKey(path).hasPrefix(UsbLayout.collisionKey(UsbLayout.contents) + "/") }
}

/// 쓰기 절차 안에서만 쓰는 실패(밖으로는 `UsbError`로 바꿔 던진다)
enum UsbWriteFailure: Error, CustomStringConvertible {
    case volumeLost
    case cancelled
    case rekordboxRunning
    case failed(String)

    var description: String {
        switch self {
        case .volumeLost: "volume lost"
        case .cancelled: "cancelled"
        case .rekordboxRunning: "rekordbox running"
        case let .failed(message): message
        }
    }
}

/// 한 번의 쓰기·회복·되돌리기. 볼륨 잠금을 쥐고 있는 동안만 산다
final class UsbWriteRun {
    let root: UsbRoot
    let paths: UsbWritePaths
    let writeGuard: UsbWriteGuard
    let fs: any UsbFileSystem
    let ppthReader: (@Sendable (Data) -> String?)?
    let now: Date
    let progress: @Sendable (UsbProgress) -> Void
    /// 가드와 무관한 첫 확인에서 얻은 기준 마운트 지점(realpath)
    let mountPoint: String
    let volume: UsbVolumeInfo
    let volumeKey: String
    private let lock: UsbVolumeLock
    /// 열 때 붙잡은 루트(같은 마운트 지점에 다른 볼륨이 붙었는지 본다)
    private let hold: any UsbVolumeHold
    /// 한 번이라도 정체가 어긋나면 참으로 남는다(그 뒤 모든 확인이 실패한다)
    private(set) var identityLost = false

    var journal: UsbJournal!
    var manifest: UsbManifest?
    var backupFolder: URL?
    var report = UsbWriteReport(outcome: .written, session: "")
    var options = UsbWriteOptions()

    private init(root: UsbRoot, paths: UsbWritePaths, writeGuard: UsbWriteGuard, fs: any UsbFileSystem,
                 ppthReader: (@Sendable (Data) -> String?)?, now: Date, progress: @escaping @Sendable (UsbProgress) -> Void,
                 mountPoint: String, volume: UsbVolumeInfo, volumeKey: String, lock: UsbVolumeLock, hold: any UsbVolumeHold) {
        self.root = root
        self.paths = paths
        self.writeGuard = writeGuard
        self.fs = fs
        self.ppthReader = ppthReader
        self.now = now
        self.progress = progress
        self.mountPoint = mountPoint
        self.volume = volume
        self.volumeKey = volumeKey
        self.lock = lock
        self.hold = hold
    }

    /// usb-internals 7.2의 1 가드와 무관한 확인 → 루트 붙잡기 → 2 볼륨 정보(+ 사용자가 확인한 볼륨인지) → 3 잠금. 여기서 막히면 잠금 파일도 만들지 않는다
    static func open(root: UsbRoot, paths: UsbWritePaths, guard writeGuard: UsbWriteGuard, fileSystem: any UsbFileSystem,
                     ppthReader: (@Sendable (Data) -> String?)?, now: Date,
                     progress: @escaping @Sendable (UsbProgress) -> Void, expectedVolumeUUID: String? = nil) throws -> UsbWriteRun {
        let mountPoint = try scratchAndMountCheck(root, fileSystem, gate: writeGuard.gate)
        // 볼륨 정보를 읽기 전에 루트를 붙잡는다: 읽은 정보가 붙잡은 볼륨의 것인지 아래에서 다시 본다
        let hold = try fileSystem.holdVolume(root.url)
        var keep = false
        defer { if !keep { hold.release() } }
        // 임시 폴더 밖이면 가드가 디스크 이미지라고 해도 실물로 판정한다(실물 관문·확인 안 된 규칙을 건너뛰지 않게)
        let volume = try writeGuard.volume(root.url).judgedForWrite(underScratch: UsbScratchRoots.isUnderAllowedRoot(mountPoint))
        guard let uuid = volume.volumeUUID?.uppercased(), !uuid.isEmpty,
              uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw UsbError.writeRefused([UsbBlock(code: "noVolumeUUID", scope: .volume,
                                                  message: String(ui: "이 USB의 볼륨 번호를 읽지 못했습니다. 다시 연결한 뒤 시도하세요"))])
        }
        if let expectedVolumeUUID, expectedVolumeUUID.uppercased() != uuid {
            throw UsbError.writeRefused([volumeChangedBlock])
        }
        guard hold.isSameVolume() else { throw UsbError.writeRefused([volumeChangedBlock]) }
        let lock = try UsbVolumeLock.acquire(directory: paths.sessions, key: uuid)
        keep = true
        return UsbWriteRun(root: root, paths: paths, writeGuard: writeGuard, fs: fileSystem, ppthReader: ppthReader, now: now,
                           progress: progress, mountPoint: mountPoint, volume: volume, volumeKey: uuid, lock: lock, hold: hold)
    }

    /// 사용자가 확인한 볼륨이 지금 그 자리에 없을 때(쓰기 전이라 USB는 그대로)
    static var volumeChangedBlock: UsbBlock {
        UsbBlock(code: "volumeChanged", scope: .volume,
                 message: String(ui: "확인한 USB가 아닌 다른 볼륨이 그 자리에 있습니다. USB 목록을 다시 읽고 고른 USB를 확인한 뒤 다시 시도하세요"))
    }

    func close() {
        hold.release()
        lock.release()
    }

    /// 실물 쓰기가 닫혀 있는 동안(코드 관문이 닫혔거나 사용자 동의가 없음) 루트 경로 자체가 임시 폴더 아래여야 한다(가드의 볼륨 정보를 쓰지 않는다).
    /// 디스크 이미지는 lab 도구·자가 테스트가 늘 임시 폴더 아래에 붙이고, 실물은 /Volumes 아래에 붙는다.
    /// 시험 프로세스는 관문이 열려 있어도 임시 폴더 밖에 쓰지 않는다(시험이 이 Mac에 꽂힌 USB에 닿지 않게).
    /// 그리고 루트가 정말 마운트 지점이어야 한다. 이 값을 기준으로 단계마다 다시 본다.
    static func scratchAndMountCheck(_ root: UsbRoot, _ fileSystem: any UsbFileSystem, gate: UsbPhysicalWriteGate,
                                     isTestProcess: Bool = TestProcess.isRunning) throws -> String {
        let real = UsbScratchRoots.realPath(root.url.path)
        if !(real.map(UsbScratchRoots.isUnderAllowedRoot) ?? false) {
            if let closed = gate.closedBlock { throw UsbError.writeRefused([closed]) }
            if isTestProcess { throw UsbError.writeRefused([testProcessBlock]) }
        }
        guard let real, try fileSystem.mountedOn(root.url) == real else {
            throw UsbError.writeRefused([UsbBlock(code: "notMountPoint", scope: .volume, message: String(ui: "USB 볼륨의 맨 위 폴더를 고르세요"))])
        }
        return real
    }

    /// 시험 프로세스가 임시 폴더 밖 루트에 쓰려 할 때(관문이 열려 있어도)
    static var testProcessBlock: UsbBlock {
        UsbBlock(code: "physicalDisabled", scope: .volume,
                 message: String(ui: "시험 실행은 임시 폴더 아래 디스크 이미지에만 씁니다"), rule: .physicalVolume)
    }

    // MARK: - 경로·저널

    func usb(_ relative: String) -> URL { relative.isEmpty ? root.url : root.url.appending(path: relative) }

    var journalURL: URL { UsbWriter.journalURL(paths: paths, volumeKey: volumeKey) }

    /// 이 볼륨의 백업 폴더(`usb-backups/<볼륨키>/` 바로 아래, realpath로 본다)인지. 없는 폴더는 false
    func isOurBackupFolder(_ folder: URL) -> Bool {
        guard let base = UsbScratchRoots.realPath(paths.backups.appending(path: volumeKey).path),
              let real = UsbScratchRoots.realPath(folder.path) else { return false }
        return (real as NSString).deletingLastPathComponent == base && real != base
    }

    func saveJournal() throws {
        journal.updatedAt = Date()
        try UsbDurableFile.write(journal, to: journalURL, fileSystem: fs)
    }

    func nextTempName() -> String {
        defer { journal.nextSequence += 1 }
        return UsbLayout.tempName(session: journal.session, sequence: journal.nextSequence)
    }

    /// 볼륨이 아직 기준 마운트 지점에 붙어 있고, 열 때 붙잡은 그 볼륨인지(같은 이름의 다른 USB가 같은 자리에 붙으면 마운트 지점만으로는 모른다).
    /// 아니면 `volumeLost`(되돌리지 않고 멈춘다). 정체가 어긋났으면 `identityLost`를 세워 밖으로 `volumeChanged`를 낸다
    func ensureMounted() throws {
        if identityLost { throw UsbWriteFailure.volumeLost }
        let mounted: Bool
        do {
            mounted = try fs.mountedOn(root.url) == mountPoint && fs.stat(root.url)?.kind == .directory
        } catch {
            mounted = false
        }
        if !mounted { throw UsbWriteFailure.volumeLost }
        if !hold.isSameVolume() {
            identityLost = true
            throw UsbWriteFailure.volumeLost
        }
    }

    /// 단계·파일 묶음의 시작, 되돌리기·회복·복원의 시작: `ensureMounted`에 더해 볼륨 정보(DiskArbitration UUID·용량)를 다시 읽어
    /// 처음 것과 같은지 본다. 읽지 못해도 다른 볼륨으로 본다(그 볼륨에 쓰지 않는다)
    func ensureSameVolume() throws {
        try ensureMounted()
        let current = try? writeGuard.volume(root.url)
        let sameUUID = current?.volumeUUID?.uppercased() == volumeKey
        let sameCapacity = (current?.capacity ?? 0) <= 0 || volume.capacity <= 0 || current?.capacity == volume.capacity
        if !(sameUUID && sameCapacity) {
            identityLost = true
            throw UsbWriteFailure.volumeLost
        }
    }

    /// 볼륨이 사라졌거나 바뀌어 멈출 때 밖으로 내는 오류
    var volumeGone: UsbError {
        identityLost ? .volumeChanged(volumeName: volume.name) : .volumeLost(volumeName: volume.name)
    }

    func checkRekordbox() throws {
        if writeGuard.isRekordboxRunning() { throw UsbWriteFailure.rekordboxRunning }
    }

    /// 7.2의 4: rekordbox, 볼륨 정책·보호 경로, 실물 관문(닫혀 있으면 실물은 `physicalDisabled`)
    func environmentBlocks(purpose: UsbVolumePurpose, required: Set<UsbProvisionalRule>, confirmName: String?,
                           checkRekordbox: Bool = true) -> [UsbBlock] {
        var blocks: [UsbBlock] = []
        if checkRekordbox, writeGuard.isRekordboxRunning() {
            blocks.append(UsbBlock(code: "rekordboxRunning", scope: .volume, message: String(ui: "rekordbox를 완전히 종료한 뒤 다시 시도하세요")))
        }
        blocks += UsbVolumePolicy.blocks(volume, purpose: purpose == .export ? .export : .edit)
        if isProtected {
            blocks.append(UsbBlock(code: "protectedPath", scope: .volume,
                                   message: String(ui: "rekordbox 라이브러리나 DJCrate 데이터 폴더에는 USB처럼 쓸 수 없습니다. USB 볼륨을 고르세요")))
        }
        blocks += UsbRuleCheck.blocks(required: required, volume: volume, gate: writeGuard.gate, confirmName: confirmName)
        return blocks
    }

    var isProtected: Bool {
        writeGuard.protectedRoots.contains { protected in
            let path = UsbScratchRoots.realPath(protected.path) ?? protected.path
            return mountPoint == path || mountPoint.hasPrefix(path + "/") || path.hasPrefix(mountPoint + "/")
        }
    }

    func stageReached(_ stage: UsbWriteStage) {
        if options.pauseAfter == stage { options.pauseHandler?(stage) }
    }

    /// 지금 USB DB 파일(사이드카 빼고)의 SHA-256(매체에서 다시 읽음)
    func currentDatabaseHashes() throws -> [String: String] {
        var result: [String: String] = [:]
        for path in UsbWriter.databaseOrder {
            let url = usb(path)
            guard let info = try fs.stat(url), info.kind == .file else { continue }
            result[path] = try fs.sha256(url, uncached: true)
        }
        return result
    }

    /// 정확한 이름의 `._<name>` 하나만 지운다(패턴으로 쓸지 않는다)
    func removeExactAppleDouble(parent: String, name: String) throws {
        let relative = UsbPath.join(parent, UsbLayout.appleDoubleName(for: name))
        guard try fs.stat(usb(relative)) != nil else { return }
        try ensureMounted()
        try fs.remove(usb(relative))
        report.appleDoubleRemoved += 1
    }

    /// 준비 폴더 파일을 읽고 크기·해시가 계획과 같은지 본다
    func readStaged(_ path: String, sha256: String, size: Int64) throws -> Data {
        let data = try fs.read(URL(filePath: path), maxBytes: Int(size) + 1)
        guard Int64(data.count) == size, UsbWriter.sha256(data) == sha256 else {
            throw UsbWriteFailure.failed("staged file changed: \(path)")
        }
        return data
    }

    /// 백업 폴더에 보고서와 닫는 저널 사본을 남긴다(끊긴 쓰기도 회복이 닫을 때 같은 두 파일을 쓴다)
    func writeBackupRecords(closing: UsbJournal) throws {
        guard let backupFolder else { return }
        var closing = closing
        closing.reportPath = backupFolder.appending(path: "report.json").path
        try UsbDurableFile.write(report, to: backupFolder.appending(path: "report.json"), fileSystem: fs)
        try UsbDurableFile.write(closing, to: backupFolder.appending(path: "journal.json"), fileSystem: fs)
    }

    /// 저널을 닫는다: 결과 DB 해시 → 백업 폴더 기록 → 정리 → 저널
    func closeJournal(_ state: UsbJournal.State, outcome: UsbWriteReport.Outcome) throws {
        report.outcome = outcome
        report.backup = backupFolder?.path
        report.resultDatabases = try currentDatabaseHashes()
        var closing = journal!
        try closing.move(to: state)
        closing.reportPath = backupFolder?.appending(path: "report.json").path
        try writeBackupRecords(closing: closing)
        journal = closing
        try saveJournal()
        UsbWriter.prune(paths: paths, volumeKey: volumeKey)
    }

    func emit(_ phase: UsbProgress.Phase, done: Int = 0, total: Int = 0, bytes: Int64 = 0, totalBytes: Int64 = 0, cancellable: Bool) {
        progress(UsbProgress(phase: phase, completedItems: done, totalItems: total, completedBytes: bytes, totalBytes: totalBytes,
                             cancellable: cancellable))
    }

    /// 파일이 없으면 위에서부터 한 단계씩 만든다(되돌리기에서 쓰기 전 폴더를 되살릴 때). 저널에 적지 않는다
    func makeParents(_ relative: String) throws {
        var path = ""
        for component in UsbPath.parent(relative).split(separator: "/") {
            path = UsbPath.join(path, String(component))
            if let info = try fs.stat(usb(path)) {
                guard info.kind == .directory else { throw UsbWriteFailure.failed("not a directory: \(path)") }
                continue
            }
            try ensureMounted()
            try fs.makeDirectory(usb(path))
            try removeExactAppleDouble(parent: UsbPath.parent(path), name: UsbPath.name(path))
        }
    }
}

// MARK: - 단계 조정

extension UsbWriteRun {
    func write(_ changes: UsbChangeSet, verifiers: [any UsbWriteVerifier], inspectors: [any UsbWriteInspector], options: UsbWriteOptions,
               isCancelled: @Sendable () -> Bool) throws -> UsbWriteReport {
        self.options = options
        report = UsbWriteReport(outcome: .written, session: changes.session)
        // 7.2의 4: 여기서 막히면 USB 파일을 열지 않는다
        let environment = environmentBlocks(purpose: changes.purpose, required: changes.requiredRules, confirmName: options.confirmName)
        if !environment.isEmpty { throw UsbError.writeRefused(environment) }
        // 7.2의 5–11
        let plan = try precheck(changes, inspectors: inspectors)
        stageReached(.precheck)
        // B
        var stagedChanges = changes
        if options.dryRun {
            // 미리 보기는 새 ID를 소비하지 않지만 이전 실제 쓰기의 상한은 다음 계획에도 남겨야 한다
            if case let .closed(previous) = UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
                stagedChanges.idHighWater = previous.idHighWater
            } else {
                stagedChanges.idHighWater = [:]
            }
        }
        try stage(stagedChanges, plan: plan)
        stageReached(.staged)
        if options.dryRun {
            try journal.move(to: .dryRun)
            try saveJournal()
            report.outcome = .dryRun
            report.filesCreated = changes.copies.filter { $0.disposition == .create }.count
                + changes.writes.filter { $0.disposition == .create }.count
            report.filesReused = changes.copies.filter { $0.disposition == .reuse }.count + changes.writes.filter { $0.disposition == .reuse }.count
            report.filesOverwritten = changes.writes.filter { $0.disposition == .overwrite }.count
            report.filesRemoved = changes.removals.count
            return report
        }
        // C
        try backup(changes)
        stageReached(.backedUp)
        do {
            // D → E → F → G
            try writeFiles(changes, isCancelled: isCancelled)
            stageReached(.files)
            try commitDatabases(changes)
            try cleanup(changes)
            stageReached(.cleaned)
            try verify(changes, verifiers: verifiers)
        } catch {
            try failAndRollBack(cause: error)
        }
        // I
        emit(.verify, done: verifiers.count, total: verifiers.count, cancellable: false)
        try closeJournal(.verified, outcome: .written)
        stageReached(.verified)
        return report
    }

    /// H로 되돌리고 알맞은 오류를 던진다. 볼륨이 사라졌으면 되돌리지 않고(저널은 마지막 상태 그대로) `volumeLost`
    func failAndRollBack(cause: Error) throws -> Never {
        let errors: [String]
        do {
            errors = try rollback(mode: .write)
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        }
        let reason = String(describing: cause)
        if errors.isEmpty {
            try closeJournal(.rolledBack, outcome: .rolledBack)
            if case UsbWriteFailure.cancelled = cause { throw UsbError.cancelled }
            throw UsbError.writeRolledBack(reason: reason)
        }
        try closeJournal(.restoreFailed, outcome: .restoreFailed)
        throw UsbError.restoreFailed(reason: reason, restoreError: errors.joined(separator: "\n"), backup: backupFolder?.path ?? "")
    }
}
