import DJCDomain
import DJCEnvironment
import DJCTestKit
import Darwin
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 쓰기 전 막힘(A 단계). 막히면 USB·백업·저널에 아무것도 남지 않는다.
@Suite("USB 쓰기 전 막힘")
struct UsbWriteGuardTests {
    /// 막힘 code 목록(막히지 않거나 다른 오류면 기록하고 빈 배열)
    func codes(_ body: () throws -> Void) -> [String] {
        do {
            try body()
            Issue.record("막히지 않았다")
            return []
        } catch let UsbError.writeRefused(blocks) {
            return blocks.map(\.code)
        } catch {
            Issue.record("다른 오류: \(error)")
            return []
        }
    }

    func blocks(_ body: () throws -> Void) -> [UsbBlock] {
        do {
            try body()
            return []
        } catch let UsbError.writeRefused(blocks) {
            return blocks
        } catch {
            Issue.record("다른 오류: \(error)")
            return []
        }
    }

    func lockFiles(_ fixture: UsbChangeSetFixture) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fixture.paths.sessions.path)) ?? []).filter { $0.hasSuffix(".lock") }
    }

    /// 막힘 뒤 USB 트리·백업·저널이 그대로인지
    func expectUntouched(_ fixture: UsbChangeSetFixture, before: [String: String]) {
        #expect(fixture.tree() == before)
        #expect(fixture.backupFolders().isEmpty)
        #expect(fixture.journal() == nil)
    }

    @Test("볼륨 정보를 잠금보다 먼저 읽는다(가드와 무관한 마운트 확인 → 볼륨 → 잠금)")
    func volumeReadBeforeLock() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let fs = fixture.fileSystem()
        let lockPath = fixture.paths.sessions.appending(path: fixture.volumeKey + ".lock").path
        let volume = fixture.volume
        let guard_ = UsbWriteGuard(volume: { _ in
            fs.record("guard.volume lock=\(FileManager.default.fileExists(atPath: lockPath))")
            return volume
        }, isRekordboxRunning: {
            fs.record("guard.rekordbox lock=\(FileManager.default.fileExists(atPath: lockPath))")
            return false
        }, protectedRoots: [], gate: FakeUsbVolume.gate())
        _ = try UsbWriter.write(fixture.exportChanges(), root: fixture.root, paths: fixture.paths, guard: guard_, fileSystem: fs)
        let calls = fs.calls
        #expect(calls[0] == "mountedOn .")
        #expect(calls[1] == "guard.volume lock=false")
        #expect(calls[2] == "guard.rekordbox lock=true")
    }

    @Test("볼륨 UUID가 없으면 잠금 파일도 만들지 않고 막는다")
    func missingUUIDBlocksWithoutLockFile() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.volume.volumeUUID = nil
        #expect(codes { _ = try UsbWriter.write(fixture.exportChanges(), root: fixture.root, paths: fixture.paths,
                                            guard: fixture.writeGuard(), fileSystem: fixture.fileSystem()) } == ["noVolumeUUID"])
        #expect(lockFiles(fixture).isEmpty)
    }

    @Test("다른 쓰기가 잠금을 쥐고 있으면 막는다")
    func lockHeld() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let held = try UsbVolumeLock.acquire(directory: fixture.paths.sessions, key: fixture.volumeKey)
        defer { held.release() }
        let before = fixture.tree()
        #expect(codes { try fixture.write(fixture.exportChanges()) } == ["volumeBusy"])
        expectUntouched(fixture, before: before)
    }

    @Test func rekordboxRunning() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.rekordboxRunning = true
        let before = fixture.tree()
        #expect(codes { try fixture.write(fixture.exportChanges()) } == ["rekordboxRunning"])
        expectUntouched(fixture, before: before)
    }

    /// 쓰기 입구가 볼륨 정책을 지나는지 대표 하나씩(막힘 하나·허용 하나). 모양마다의 판정(막힘 여덟·허용 넷)은 `UsbVolumePolicyTests`가
    /// 모두 본다(#167: 같은 판정을 쓰기 전 과정으로 되풀이하지 않는다).
    @Test("볼륨 모양 막힘", arguments: ["apfs"])
    func volumeShapeBlocks(shape: String) {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let code: String
        switch shape {
        case "notMountPoint": fixture.volume.rootIsMountPoint = false; code = "notMountPoint"
        case "apfs": fixture.volume.fileSystem = .apfs; code = "unsupportedFileSystem"
        case "hfsPlus": fixture.volume.fileSystem = .hfsPlus; code = "unsupportedFileSystem"
        case "fat16": fixture.volume.fileSystem = .fat16; fixture.volume.partitionContent = "DOS_FAT_16"; code = "unsupportedFileSystem"
        case "apm": fixture.volume.partitionScheme = .apm; code = "partitionScheme"
        case "internal": fixture.volume.isInternal = true; code = "internal"
        case "network": fixture.volume.isNetwork = true; code = "network"
        default: fixture.volume.isReadOnly = true; code = "readOnly"
        }
        let fs = fixture.fileSystem()
        #expect(codes { try fixture.write(fixture.exportChanges(), fileSystem: fs) }.contains(code))
        // 볼륨이 막히면 USB 파일은 읽지도 않는다(가드와 무관한 마운트 확인만)
        #expect(fs.calls == ["mountedOn ."])
        expectUntouched(fixture, before: [:])
    }

    @Test("exFAT 볼륨에도 쓴다", arguments: ["exfat"])
    func widerVolumeShapesWrite(shape: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        switch shape {
        case "exfat": fixture.volume.fileSystem = .exfat; fixture.volume.partitionContent = "Windows_NTFS"
        case "gpt": fixture.volume.partitionScheme = .gpt; fixture.volume.partitionIndex = 2
        case "secondPartition": fixture.volume.partitionIndex = 2
        default: fixture.volume.sectorSize = 4096
        }
        #expect(try fixture.write(fixture.exportChanges()).outcome == .written)
    }

    @Test("보호 경로 안이면 막는다")
    func protectedRoot() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let guard_ = fixture.writeGuard(protectedRoots: [fixture.folder])
        #expect(codes { _ = try UsbWriter.write(fixture.exportChanges(), root: fixture.root, paths: fixture.paths, guard: guard_,
                                            fileSystem: fixture.fileSystem()) } == ["protectedPath"])
    }

    @Test("실물은 동의(앱 확인 창·--allow-physical) 없이는 막힌다")
    func physicalBlockedWithoutConsent() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.volume = FakeUsbVolume.physicalFAT32()
        let gate = FakeUsbVolume.gate()
        let fs = fixture.fileSystem()
        let found = codes {
            _ = try UsbWriter.write(fixture.exportChanges(), root: fixture.root, paths: fixture.paths, guard: fixture.writeGuard(gate: gate),
                                fileSystem: fs, options: UsbWriteOptions(confirmName: "DJCPHYS"))
        }
        #expect(found.contains("physicalDisabled"))
        #expect(fs.calls == ["mountedOn ."])
    }

    // MARK: - 실물 쓰기를 연 관문

    /// 실물 쓰기에 동의한 관문
    static var openGate: UsbPhysicalWriteGate { FakeUsbVolume.gate(consented: true) }

    @Test("동의한 실물 USB는 등록 없이 디스크 이미지와 같은 절차로 쓴다(백업·저널·검증), 되돌리면 쓰기 전과 같다",
          arguments: ["stick", "externalSSD", "sdCardReader"])
    func openGateWritesPhysicalLikeDiskImage(device: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.volume = switch device {
        case "externalSSD": FakeUsbVolume.externalSSD()
        case "sdCardReader": FakeUsbVolume.physicalFAT32(name: "DJCPHYS")
        default: FakeUsbVolume.physicalFAT32()
        }
        if device == "sdCardReader" { fixture.volume.deviceProtocol = "Secure Digital" }
        fixture.gate = Self.openGate
        let before = fixture.tree()
        let report = try fixture.write(fixture.exportChanges(), options: UsbWriteOptions(confirmName: "DJCPHYS"))
        #expect(report.outcome == .written)
        #expect(fixture.journal()?.state == .verified)
        #expect(fixture.backupFolders().count == 1)
        #expect(fixture.tree() != before)
        // 되돌리기도 같은 관문(이름 확인 포함)을 지난다
        #expect(codes { _ = try fixture.restore() } == ["confirmMismatch"])
        let restored = try fixture.restore(confirmName: "DJCPHYS")
        #expect(restored.outcome == .restored)
        #expect(fixture.tree() == before)
    }

    @Test("동의해도 이름 확인이 틀린 쓰기·시동 디스크·Time Machine(APFS)은 USB 파일 연산 없이 막는다",
          arguments: ["confirmMismatch", "rootVolume", "unsupportedFileSystem"])
    func openGateStillRefuses(code: String) {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.volume = FakeUsbVolume.physicalFAT32()
        fixture.gate = Self.openGate
        var confirm: String? = "DJCPHYS"
        switch code {
        case "confirmMismatch": confirm = "djcphys"
        case "rootVolume": fixture.volume.isRootVolume = true
        default: fixture.volume.fileSystem = .apfs; fixture.volume.name = "Time Machine"; confirm = "Time Machine"
        }
        let fs = fixture.fileSystem()
        #expect(codes { _ = try fixture.write(fixture.exportChanges(), fileSystem: fs, options: UsbWriteOptions(confirmName: confirm)) } == [code])
        #expect(fs.calls == ["mountedOn ."])
        expectUntouched(fixture, before: [:])
    }

    @Test("동의한 실물에는 곡 내용 규칙(색 핫큐 등)이 있어도 쓰고, 기기 기록 행 옮기기만 막는다")
    func openGateWritesContentRules() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.volume = FakeUsbVolume.physicalFAT32()
        fixture.gate = Self.openGate
        var changes = fixture.exportChanges()
        changes.requiredRules = [.analysisFolderNaming, .cueVariant, .carriedDeviceRows]
        let found = blocks { _ = try fixture.write(changes, options: UsbWriteOptions(confirmName: "DJCPHYS")) }
        #expect(found.map(\.rule) == [.carriedDeviceRows])
        expectUntouched(fixture, before: [:])
        changes.requiredRules = [.analysisFolderNaming, .cueVariant, .artworkMissing, .editRefreshTracks]
        #expect(try fixture.write(changes, options: UsbWriteOptions(confirmName: "DJCPHYS")).outcome == .written)
    }

    @Test("임시 폴더 밖에 붙은 디스크 이미지는 관문이 열려도 실물로 판정한다(동의·이름 확인이 필요)")
    func outsideScratchImageJudgedPhysical() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let home = try #require(UsbScratchRoots.realPath(NSHomeDirectory()))
        let fs = FaultyUsbFileSystem(root: URL(filePath: home))
        fs.simulatedMountPoint = home
        // 시험 프로세스가 아닌 실행에서는 경로 확인을 지나고(쓰기 없음, statfs 흉내만), 볼륨 판정은 실물이 된다
        #expect(try UsbWriteRun.scratchAndMountCheck(UsbRoot(URL(filePath: home)), fs, gate: Self.openGate, isTestProcess: false) == home)
        #expect(FakeUsbVolume.diskImageFAT32().judgedForWrite(underScratch: UsbScratchRoots.isUnderAllowedRoot(home)).isDiskImage == false)
    }

    @Test("시험 프로세스는 관문이 열려 있어도 임시 폴더 밖 루트를 가드를 부르기 전에 거부한다", arguments: ["/Volumes/DJCNOTEXIST", NSHomeDirectory()])
    func testProcessNeverWritesOutsideScratch(rootPath: String) {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let root = UsbRoot(URL(filePath: rootPath))
        let fs = FaultyUsbFileSystem(root: root.url)
        fs.simulatedMountPoint = rootPath
        var physical = FakeUsbVolume.physicalFAT32()
        physical.mountPoint = rootPath
        let volume = physical
        let guard_ = UsbWriteGuard(volume: { _ in
            fs.record("guard.volume")
            return volume
        }, isRekordboxRunning: { false }, protectedRoots: [], gate: Self.openGate)
        let changes = fixture.exportChanges()
        let actions: [() throws -> Void] = [
            { _ = try UsbWriter.write(changes, root: root, paths: fixture.paths, guard: guard_, fileSystem: fs,
                                      options: UsbWriteOptions(confirmName: "DJCPHYS")) },
            { _ = try UsbWriter.restore(root: root, paths: fixture.paths, backup: nil, guard: guard_, fileSystem: fs, confirmName: "DJCPHYS") },
            { _ = try UsbWriter.recover(root: root, paths: fixture.paths, guard: guard_, fileSystem: fs, discardTemp: true, confirmName: "DJCPHYS") },
        ]
        for action in actions {
            let found = blocks(action)
            #expect(found.map(\.code) == ["physicalDisabled"])
            #expect(found.first?.message == "시험 실행은 임시 폴더 아래 디스크 이미지에만 씁니다")
        }
        #expect(fs.calls.isEmpty)
        #expect(lockFiles(fixture).isEmpty)
    }

    @Test("닫히지 않은 저널이 있으면 회복부터")
    func unclosedJournal() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var journal = UsbJournal(changes: fixture.exportChanges(), volumeUUID: fixture.volumeKey, volumeName: "DJCTEST", now: .now)
        journal.state = .filesWritten
        try FileManager.default.createDirectory(at: fixture.paths.sessions, withIntermediateDirectories: true)
        try UsbJournal.encoder().encode(journal).write(to: fixture.paths.sessions.appending(path: fixture.volumeKey + ".json"))
        #expect(codes { try fixture.write(fixture.exportChanges()) } == ["recoveryNeeded"])
        #expect(UsbWriter.journalStatus(paths: fixture.paths, volumeKey: fixture.volumeKey) == .open(journal))
        // 깨진 저널은 쓰기·되돌리기·회복이 같은 이유로 막는다(회복하라고 안내하면 회복도 거부되므로)
        try Data("{".utf8).write(to: fixture.paths.sessions.appending(path: fixture.volumeKey + ".json"))
        #expect(UsbWriter.journalStatus(paths: fixture.paths, volumeKey: fixture.volumeKey) == .corrupt)
        let write = blocks { try fixture.write(fixture.exportChanges()) }
        #expect(write.map(\.code) == ["journalUnreadable"])
        #expect(codes { _ = try fixture.restore() } == ["journalUnreadable"])
        let recover = blocks { _ = try fixture.recover() }
        #expect(recover.map(\.code) == ["journalUnreadable"])
        #expect(write.map(\.message) == recover.map(\.message))
    }

    @Test("우리 폴더에 임시 파일이 있으면 막는다")
    func tempFilesPresent() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("Contents/Other/.djc-part-zzzzzzzz-000001", Data("x".utf8))
        let before = fixture.tree()
        #expect(codes { try fixture.write(fixture.exportChanges()) } == ["tempFilesPresent"])
        expectUntouched(fixture, before: before)
    }

    @Test("수정: 계획 뒤 USB DB가 바뀌었으면 막는다")
    func baseMismatch() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        fixture.write(UsbLayout.exportPdb, UsbChangeSetFixture.random(10))
        let before = fixture.tree()
        #expect(codes { try fixture.write(changes) } == ["usbChanged"])
        expectUntouched(fixture, before: before)
        // 기기가 사이드카를 남긴 것도 바뀐 것이다.
        let fresh = try fixture.editChanges()
        fixture.write(UsbLayout.oneLibrary + "-wal", Data("wal".utf8))
        #expect(codes { try fixture.write(fresh) } == ["usbChanged"])
    }

    @Test("내보내기: PIONEER 아래 파일 하나만 있어도 막는다")
    func exportNotEmpty() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("PIONEER/Artwork/00001/a1.jpg", Data("art".utf8))
        let before = fixture.tree()
        let found = blocks { try fixture.write(fixture.exportChanges()) }
        let notEmpty = try #require(found.first { $0.code == "notEmpty" })
        #expect(notEmpty.message.contains("1개"))
        expectUntouched(fixture, before: before)
    }

    @Test("내보내기 막힘의 개수는 PIONEER 바로 아래 이름만 센다(열지 않는 폴더로 내려가지 않음)")
    func exportNotEmptyCountsTopLevelOnly() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("PIONEER/extracted/GCRED.DAT", Data("secret".utf8))
        fixture.write("PIONEER/x.txt", Data("x".utf8))
        fixture.write("PIONEER/.hidden", Data("x".utf8))
        let locked = fixture.usb("PIONEER/extracted").path
        #expect(chmod(locked, 0) == 0)
        defer { chmod(locked, 0o755) }
        let found = blocks { try fixture.write(fixture.exportChanges()) }
        #expect(found.map(\.code) == ["notEmpty"])
        #expect(found.first?.message.contains("2개") == true)
    }

    @Test("만들 대상 충돌 검사는 열지 않는 폴더를 stat·열거하지 않는다")
    func createCollisionSkipsNeverRead() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("PIONEER/extracted/GCRED.DAT", Data("secret".utf8))
        let locked = fixture.usb("PIONEER/extracted").path
        #expect(chmod(locked, 0) == 0)
        defer { chmod(locked, 0o755) }
        var changes = fixture.exportChanges()
        changes.writes[0].destination = "PIONEER/extracted/x.bin"
        changes.databases[0].destination = "PIONEER/extracted/y.db"
        let fs = fixture.fileSystem()
        #expect(try UsbWriter.createCollisionBlocks(changes, root: fixture.root, fileSystem: fs).isEmpty)
        #expect(!fs.calls.contains { $0.hasPrefix("list PIONEER/extracted") || $0.hasPrefix("stat PIONEER/extracted") })
        // 쓰기 전 확인도 경로 막힘이 있으면 형식 검사기를 부르지 않는다
        let inspector = Recording()
        let found = blocks { try fixture.write(changes, fileSystem: fs, inspectors: [inspector]) }
        #expect(found.contains { $0.code == "pathRefused" })
        #expect(!inspector.called)
        #expect(!fs.calls.contains { $0.hasPrefix("list PIONEER/extracted") || $0.hasPrefix("stat PIONEER/extracted") })
    }

    final class Recording: UsbWriteInspector, @unchecked Sendable {
        private let lock = NSLock()
        private var wasCalled = false
        var called: Bool { lock.withLock { wasCalled } }
        func blocks(root: UsbRoot, changes: UsbChangeSet) throws -> [UsbBlock] {
            lock.withLock { wasCalled = true }
            return []
        }
    }

    struct Refusing: UsbWriteInspector {
        func blocks(root: UsbRoot, changes: UsbChangeSet) throws -> [UsbBlock] {
            [UsbBlock(code: "inspectorSaysNo", scope: .format(.oneLibrary), message: "no")]
        }
    }

    @Test("형식 검사기의 막힘을 더한다")
    func inspectorBlock() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        #expect(codes { try fixture.write(fixture.exportChanges(), inspectors: [Refusing()]) } == ["inspectorSaysNo"])
    }

    @Test("여유 공간이 모자라면 막는다")
    func insufficientSpace() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.volume.available = 200 * 1024 * 1024
        fixture.volume.clusterSize = 32_768
        // 64MiB 여유를 더해도 이 정도는 들어간다
        let small = fixture.exportChanges()
        _ = try? fixture.write(small)
        let other = UsbChangeSetFixture()
        defer { other.remove() }
        other.volume.available = 1024 * 1024
        let before = other.tree()
        #expect(codes { try other.write(other.exportChanges()) } == ["insufficientSpace"])
        expectUntouched(other, before: before)
        #expect(fixture.journal()?.state == .verified)
    }

    @Test("대상 경로가 루트 밖·열지 않는 곳·이상한 이름이면 막는다", arguments: [
        "../outside.mp3", "Contents/../../outside.mp3", "/Contents/x.mp3", "PIONEER/extracted/x.bin", "PIONEER/CDP/x",
        "Contents/A/./x.mp3", "Contents//x.mp3", "Other/x.mp3", "Contents/A/._x.mp3", "Contents/A/.djc-part-x", ".Trashes/x",
    ])
    func pathEscapes(destination: String) {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = fixture.exportChanges()
        changes.writes[0].destination = destination
        let found = blocks { try fixture.write(changes) }
        #expect(found.contains { $0.code == "pathRefused" && $0.scope == .file(destination) })
        #expect(!fixture.exists("outside.mp3"))
        #expect(fixture.backupFolders().isEmpty)
    }

    @Test("부모 경로에 심볼릭 링크가 있으면 막는다")
    func symlinkParentRefused() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.usb("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.usb("Contents/Artist A").path, withDestinationPath: fixture.home.path)
        let found = blocks { try fixture.write(fixture.exportChanges()) }
        #expect(found.contains { $0.code == "pathRefused" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).filter { !$0.hasPrefix("usb-") }.isEmpty)
    }

    @Test("막힘 뒤 USB·백업·저널이 그대로")
    func precheckHasNoSideEffects() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        var changes = try fixture.editChanges()
        changes.writes[0].destination = "../escape"
        let before = fixture.tree()
        let dirs = fixture.directories()
        _ = blocks { try fixture.write(changes) }
        expectUntouched(fixture, before: before)
        #expect(fixture.directories() == dirs)
    }

    @Test("거짓 가드(이미지라고 속임)도 임시 폴더 밖 루트는 가드를 부르기 전에 거부한다", arguments: ["/Volumes/DJCNOTEXIST", NSHomeDirectory()])
    func lyingGuardRefusedOutsideScratch(rootPath: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let root = UsbRoot(URL(filePath: rootPath))
        let fs = FaultyUsbFileSystem(root: root.url)
        fs.simulatedMountPoint = rootPath
        var lie = fixture.volume
        lie.mountPoint = rootPath
        let lying = lie
        let guard_ = UsbWriteGuard(volume: { _ in
            fs.record("guard.volume")
            return lying
        }, isRekordboxRunning: {
            fs.record("guard.rekordbox")
            return false
        }, protectedRoots: [], gate: FakeUsbVolume.gate())
        let changes = fixture.exportChanges()
        let actions: [() throws -> Void] = [
            { _ = try UsbWriter.write(changes, root: root, paths: fixture.paths, guard: guard_, fileSystem: fs) },
            { _ = try UsbWriter.restore(root: root, paths: fixture.paths, backup: nil, guard: guard_, fileSystem: fs) },
            { _ = try UsbWriter.recover(root: root, paths: fixture.paths, guard: guard_, fileSystem: fs, discardTemp: true) },
        ]
        for action in actions {
            #expect(codes(action) == ["physicalDisabled"])
        }
        #expect(fs.calls.isEmpty)
        #expect(lockFiles(fixture).isEmpty)
    }

    @Test("루트가 마운트 지점이 아니면 파일 연산 없이 막는다")
    func rootMustBeMountPoint() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let fs = fixture.fileSystem()
        fs.simulatedMountPoint = "/private/tmp/djc-elsewhere"
        #expect(codes { try fixture.write(fixture.exportChanges(), fileSystem: fs) } == ["notMountPoint"])
        #expect(fs.calls == ["mountedOn ."])
        #expect(lockFiles(fixture).isEmpty)
    }

    @Test("만들 파일은 기존 파일을 조용히 덮지 않는다(대소문자·NFC/NFD 무시)", arguments: [
        "Contents/Artist A/Album B/_intro.mp3",
        "Contents/Artist A/Album B/_INTRO.MP3",
        "contents/artist a/album b/_intro.mp3",
        "Contents/Cafe\u{301}/Album/Cafe\u{301} Song.mp3",
        "Contents/Caf\u{E9}/Album/CAF\u{C9} SONG.mp3",
    ])
    func createNeverReplacesExistingFile(userFile: String) {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let userData = UsbChangeSetFixture.random(777)
        fixture.write(userFile, userData)
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        let found = blocks { try fixture.write(fixture.exportChanges(), fileSystem: fs) }
        #expect(!found.isEmpty && found.allSatisfy { $0.code == "destinationExists" })
        #expect(found.allSatisfy { if case .file = $0.scope { true } else { false } })
        #expect(fixture.tree() == before)
        #expect(!fs.calls.contains { $0.hasPrefix("rename") })
        #expect(fixture.backupFolders().isEmpty)
        #expect(fixture.journal() == nil)
    }

    @Test("새로 만들 폴더의 철자만 다른 폴더가 있어도 막는다")
    func newFolderSpellingDiffers() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.usb("Contents/artist a"), withIntermediateDirectories: true)
        let found = blocks { try fixture.write(fixture.exportChanges()) }
        #expect(found.contains { $0.code == "destinationExists" && $0.scope == .file("Contents/Artist A") })
        // 같은 철자의 폴더는 그대로 쓴다.
        let other = UsbChangeSetFixture()
        defer { other.remove() }
        try FileManager.default.createDirectory(at: other.usb("Contents/Artist A"), withIntermediateDirectories: true)
        try other.write(other.exportChanges())
        #expect(other.journal()?.state == .verified)
    }

    @Test("A 단계 뒤에 생긴 같은 이름 파일로는 rename하지 않는다")
    func createRecheckBeforeRename() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        let target = UsbChangeSetFixture.exportAnalysis[0]
        let intruder = (target as NSString).deletingLastPathComponent + "/anlz0000.dat"
        let userData = UsbChangeSetFixture.random(500)
        var planted = false
        fs.onOperation = { op, url in
            // 분석 파일 첫 임시 파일을 쓰는 순간 사용자가 같은 이름(대소문자만 다름)을 만든다
            if op == .writeNew, !planted, fs.relative(url)?.hasPrefix("PIONEER/USBANLZ/") == true {
                planted = true
                FileManager.default.createFile(atPath: fixture.usb(intruder).path, contents: userData)
            }
        }
        #expect(throws: UsbError.self) { try fixture.write(changes, fileSystem: fs) }
        #expect(planted)
        #expect(!fs.calls.contains { $0.hasPrefix("rename") && $0.hasSuffix("-> " + target) })
        #expect(fixture.data(intruder) == userData)
        #expect(fixture.tempCount() == 0)
        #expect(fixture.journal()?.state == .rolledBack)
    }
}
