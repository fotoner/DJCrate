import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// USB 쓰기 유스케이스(`UsbWriteService`): 앱 쓰기 흐름·CLI가 함께 쓰는 세션 조립·회복·되돌리기·저널(가짜 포트)
@Suite("USB 쓰기 유스케이스")
struct UsbWriteServiceTests {
    static let volume = FakeUsbVolume.diskImageFAT32()

    static func service(_ ports: FakeUsbPorts, drafts: UsbDraftFiles = .memory(now: { FakeUsbPorts.snapshotDate })) -> UsbWriteService {
        let writeGuard = ports.writeGuard
        var service = UsbWriteService(paths: FakeUsbPorts.paths, localCopies: FakeUsbPorts.copies, writeGuard: { writeGuard }, engine: ports.engine,
                                      device: ports.device, drafts: drafts, now: { FakeUsbPorts.snapshotDate })
        service.recheck = { $0 }
        return service
    }

    @Test("저널 상태를 앱 표시로 바꾼다: 없음·열림(끝나지 않은 쓰기)·닫힘·읽지 못함")
    func journalInfo() {
        let ports = FakeUsbPorts()
        let cases: [(UsbJournalStatus, UsbJournalInfo, Bool)] = [
            (.missing, .none, false), (.open(.filesWritten), .state(.filesWritten), true),
            (.closed(.dryRun, idHighWater: [:]), .state(.dryRun), false), (.corrupt, .unreadable, false),
        ]
        for (status, info, pending) in cases {
            ports.update { $0.journal = status }
            let shown = Self.service(ports).journal(volumeKey: "K")
            #expect(shown == info && shown.isPending == pending)
        }
        // 저널을 보기만 할 때는 Mac 쪽 폴더를 만들지 않는다
        #expect(ports.current.madeFolders == 0)
    }

    @Test("회복·되돌리기는 폴더를 만든 뒤 조립 지점의 가드·폴더와 확인한 볼륨 이름·UUID를 쓰기 절차에 넘긴다")
    func recoverAndRestorePassConfirmedVolume() throws {
        let ports = FakeUsbPorts { $0.gate = FakeUsbVolume.gate(consented: true) }
        let service = Self.service(ports)
        _ = try service.recover(Self.volume)
        let backup = URL(filePath: "/private/tmp/djc-fixture/usb-backups/K/b1")
        _ = try service.restore(Self.volume, backup: backup, discardDeviceChanges: true)
        let recover = try #require(ports.current.recovers.first), restore = try #require(ports.current.restores.first)
        #expect(recover.confirmName == Self.volume.name && recover.expectedVolumeUUID == Self.volume.volumeUUID && !recover.discardTemp)
        #expect(recover.paths.sessions == FakeUsbPorts.paths.sessions && recover.writeGuard.gate.consented)
        #expect(restore.backup == backup && restore.discardDeviceChanges && !restore.dryRun && restore.confirmName == Self.volume.name)
        #expect(ports.current.madeFolders == 2)
        #expect(ports.calls.firstIndex(of: "makeFolders")! < ports.calls.firstIndex(of: "recover")!)
    }

    @Test("CLI 회복·되돌리기는 받은 인자 그대로 넘긴다(확인한 UUID 없음, 드라이 런·임시 파일 지우기)")
    func cliRecoverRestoreArguments() throws {
        let ports = FakeUsbPorts()
        let service = Self.service(ports)
        _ = try service.recover(root: FakeUsbPorts.root, discardTemp: true, confirmName: "X", expectedVolumeUUID: nil)
        _ = try service.restore(root: FakeUsbPorts.root, backup: nil, discardDeviceChanges: false, confirmName: nil, dryRun: true,
                                expectedVolumeUUID: nil)
        #expect(ports.current.recovers.first?.discardTemp == true && ports.current.recovers.first?.confirmName == "X")
        #expect(ports.current.restores.first?.dryRun == true && ports.current.restores.first?.backup == nil)
        #expect(ports.current.madeFolders == 0)
    }

    @Test("초안 base는 그 자리 볼륨을 다시 본 뒤 뜨고, 다시 보기에 실패하면 지문을 뜨지 않는다")
    func draftBaseRechecks() throws {
        let ports = FakeUsbPorts()
        var service = Self.service(ports)
        _ = try service.draftBase(Self.volume)
        #expect(ports.calls == ["fingerprint"])
        service.recheck = { _ in throw UsbError.readFailed(detail: "volumeChanged") }
        #expect(throws: UsbError.self) { _ = try service.draftBase(Self.volume) }
        #expect(ports.calls == ["fingerprint"])
    }

    @Test("동기화 선택 원문: 다시 본 볼륨이 확인한 볼륨과 다르면 읽지 않고 취소한다")
    func syncFilesRequireSameVolume() throws {
        let ports = FakeUsbPorts { $0.syncFiles = [.deviceLibrary: Data("x".utf8)] }
        var service = Self.service(ports)
        #expect(try service.syncSelectionBaseFiles(Self.volume, formats: [.deviceLibrary]) == [.deviceLibrary: Data("x".utf8)])
        var other = Self.volume
        other.volumeUUID = "00000000-0000-0000-0000-0000000000FF"
        service.recheck = { [other] _ in other }
        #expect(thrownUsbError { _ = try service.syncSelectionBaseFiles(Self.volume, formats: [.deviceLibrary]) }?.shape == "cancelled")
        #expect(ports.calls == ["syncFiles"])
    }

    @Test("쓰기 대기 미리 보기: 초안이 없으면 noDraft 요약, 있으면 확인한 볼륨 이름으로 계획한다")
    func previewEditNoDraft() throws {
        let drafts = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        let ports = FakeUsbPorts()
        let input = UsbEditInput(database: nil, share: nil, volume: Self.volume, snapshotTime: nil)
        let none = try Self.service(ports, drafts: drafts).previewEdit(input)
        #expect(none.edits.isEmpty && !none.hasChanges)
        try drafts.save(UsbDraft(volumeKey: Self.volume.usbKeyForTest, base: UsbFingerprint(files: [:]), edits: [.removeTracks(usbContentIDs: [1])],
                                 createdAt: FakeUsbPorts.snapshotDate))
        let summary = try Self.service(ports, drafts: drafts).previewEdit(input)
        #expect(summary.edits == [.removeTracks(usbContentIDs: [1])])
        #expect(ports.current.madeFolders == 2)
    }

    @Test("최근 백업·rekordbox 실행·임시 폴더 판정은 엔진·가드·이 Mac의 일을 그대로 쓴다")
    func passThroughJudgements() {
        let backup = URL(filePath: "/private/tmp/djc-fixture/usb-backups/K/b2")
        let ports = FakeUsbPorts {
            $0.backups = [backup, URL(filePath: "/private/tmp/djc-fixture/usb-backups/K/b1")]
            $0.rekordboxRunning = true
            $0.underScratch = false
        }
        let service = Self.service(ports)
        #expect(service.latestBackup(volumeKey: "K") == backup)
        #expect(service.isRekordboxRunning())
        #expect(!service.isScratchMount("/Volumes/DJCTEST"))
    }
}

extension UsbVolumeInfo {
    /// 초안 파일 이름의 볼륨 번호(`UsbEditSession.volumeKey`)
    var usbKeyForTest: String { (try? UsbEditSession.volumeKey(self)) ?? "" }
}

/// USB 초안 고치기(`UsbDraftEditing`): 읽고-고치고-쓰기의 규칙
@Suite("USB 초안 고치기")
struct UsbDraftEditingTests {
    static let key = "K"
    static let base = UsbFingerprint(files: [UsbLayout.exportPdb: .init(size: 1, mtime: FakeUsbPorts.snapshotDate, sha256: "b")])

    func editing(_ drafts: UsbDraftFiles, base: @escaping @Sendable (UsbVolumeInfo) throws -> UsbFingerprint = { _ in base }) -> UsbDraftEditing {
        UsbDraftEditing(files: drafts, base: base, now: { FakeUsbPorts.snapshotDate })
    }

    @Test("처음 초안은 지금 USB DB 지문을 base로, 빠진 볼륨·지문 실패는 빈 지문으로 만들고, 있던 초안의 base·만든 때는 지킨다")
    func mutateKeepsFirstBase() throws {
        let drafts = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        let first = try editing(drafts).mutate(Self.key, volume: FakeUsbVolume.diskImageFAT32()) { $0 + [.removeTracks(usbContentIDs: [1])] }
        #expect(first.changed == UsbDraftEditing.Change(before: [], after: [.removeTracks(usbContentIDs: [1])]))
        #expect(try drafts.load(Self.key)?.base == Self.base)
        // 있던 초안의 base는 그대로(다시 뜨지 않는다)
        _ = try editing(drafts, base: { _ in throw UsbError.cancelled }).mutate(Self.key, volume: FakeUsbVolume.diskImageFAT32()) {
            $0 + [.removeTracks(usbContentIDs: [2])]
        }
        #expect(try drafts.load(Self.key)?.base == Self.base && drafts.load(Self.key)?.edits.count == 2)

        let absent = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        _ = try editing(absent).mutate(Self.key, volume: nil) { $0 + [.removeTracks(usbContentIDs: [1])] }
        #expect(try absent.load(Self.key)?.base == UsbFingerprint(files: [:]))
        let failed = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        _ = try editing(failed, base: { _ in throw UsbError.readFailed(detail: "volumeChanged") })
            .mutate(Self.key, volume: FakeUsbVolume.diskImageFAT32()) { $0 + [.removeTracks(usbContentIDs: [1])] }
        #expect(try failed.load(Self.key)?.base == UsbFingerprint(files: [:]))
    }

    @Test("바꿀 것이 없으면 그대로 두고, 비면 초안을 지운다")
    func mutateNilKeepsEmptyDiscards() throws {
        let drafts = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        _ = try editing(drafts).mutate(Self.key, volume: nil) { $0 + [.removeTracks(usbContentIDs: [1])] }
        let unchanged = try editing(drafts).mutate(Self.key, volume: nil) { _ in nil }
        #expect(unchanged.changed == nil && unchanged.edits == [.removeTracks(usbContentIDs: [1])])
        _ = try editing(drafts).mutate(Self.key, volume: nil) { _ in [] }
        #expect(try drafts.load(Self.key) == nil)
    }

    @Test("통째로 바꾸기: 바꾸기 전 초안을 돌려주고 빈 초안은 지운다")
    func replace() throws {
        let drafts = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        let draft = UsbDraft(volumeKey: Self.key, base: Self.base, edits: [.removeTracks(usbContentIDs: [1])], createdAt: FakeUsbPorts.snapshotDate)
        let first = try editing(drafts).replace(Self.key) { _ in draft }
        #expect(first.old == nil && first.new == draft)
        let emptied = try editing(drafts).replace(Self.key) { old in old.map { UsbDraft(volumeKey: $0.volumeKey, base: $0.base, edits: [], createdAt: $0.createdAt) } }
        #expect(emptied.old == draft && emptied.new == nil)
        #expect(try drafts.load(Self.key) == nil)
    }
}
