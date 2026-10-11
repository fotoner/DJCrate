import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// USB 수정·옮기기 세션의 순서·판정(가짜 포트, DB·디스크 없이). 실제 엔진을 묶은 쓰기·되돌리기는 DJCAdaptersTests `UsbEditSessionTests`·
/// `UsbMigrateSessionTests`
@Suite("USB 수정·옮기기 세션 흐름")
struct UsbEditSessionFlowTests {
    static let removeOne: [UsbLibraryEdit] = [.removeTracks(usbContentIDs: [3])]
    static let addOne: [UsbLibraryEdit] = [.addTracks(localContentIDs: ["101"], playlist: nil)]
    static let options = UsbWriteOptions(confirmName: "DJCTEST")
    static let time = "2100-01-01T00:00:00Z"
    static let key = "00000000-0000-0000-0000-000000000001"

    static func fingerprint(_ sha: String) -> UsbFingerprint {
        UsbFingerprint(files: [UsbLayout.exportPdb: .init(size: 10, mtime: FakeUsbPorts.snapshotDate, sha256: sha)])
    }

    /// 계획이 바꿀 것을 낸 결과
    static func planned(blocked: Bool = false) -> UsbEditResult {
        var result = UsbEditResult(changes: FakeUsbPorts.changes(staging: FakeUsbPorts.paths.staging.appending(path: "s")),
                                   outcomes: [(edit: 1, outcome: .written)], formatsWritten: UsbFormat.defaultSet)
        if blocked {
            result.outcomes.append((edit: 2, outcome: .blocked(UsbBlock(code: "historyTrack", scope: .track("2"), message: "기록"))))
        }
        return result
    }

    @Test("볼륨이 막히면 저널·USB 사본·로컬 사본 없이 막힘만 돌려준다")
    func gatedVolumeStopsBeforeJournal() throws {
        let ports = FakeUsbPorts {
            $0.volume = FakeUsbVolume.physicalFAT32()
            $0.underScratch = false
        }
        let result = try ports.editSession().preview(Self.addOne, options: Self.options, snapshotTime: Self.time)
        #expect(result.blocks.contains { $0.code == "physicalDisabled" } && result.changes == nil)
        for call in ["journal", "editLoad", "copyLocal", "editPlan"] { #expect(!ports.calls.contains(call)) }
    }

    @Test("끝나지 않은 쓰기·읽지 못한 저널은 USB 사본을 뜨기 전에 막는다")
    func journalBlocksBeforeCopy() throws {
        for (journal, code) in [(UsbJournalStatus.open(.filesWritten), "recoveryNeeded"), (.corrupt, "journalUnreadable")] {
            let ports = FakeUsbPorts { $0.journal = journal }
            let result = try ports.editSession().preview(Self.removeOne, options: Self.options)
            #expect(result.blocks.map(\.code) == [code])
            #expect(!ports.calls.contains("editLoad"))
        }
    }

    @Test("닫힌 저널의 ID 상한을 이어 쓰고, 기기가 바꿔 다시 계획하라고 닫았으면 알림을 앞에 단다")
    func closedJournalCarriesHighWater() throws {
        let ports = FakeUsbPorts {
            $0.journal = .closed(.needsReplan, idHighWater: ["content": 9])
            $0.editResult = Self.planned()
        }
        let result = try ports.editSession().preview(Self.removeOne, options: Self.options)
        #expect(ports.current.editPlans.first?.highWater == ["content": 9])
        #expect(result.notes.first == String(ui: "USB가 그 사이 바뀌어 다시 계획했습니다"))
    }

    @Test("로컬 사본은 곡 더하기·갱신·동기화가 있고 USB 원본에 막힘이 없을 때만 뜬다")
    func localCopyOnlyWhenNeeded() throws {
        let remove = FakeUsbPorts()
        _ = try remove.editSession().preview(Self.removeOne, options: Self.options, snapshotTime: Self.time)
        #expect(remove.current.copied.isEmpty && remove.current.editPlans.first?.hasLocal == false)

        let add = FakeUsbPorts()
        _ = try add.editSession().preview(Self.addOne, options: Self.options, snapshotTime: Self.time)
        #expect(add.current.copied.count == 1 && add.current.editPlans.first?.hasLocal == true)
        #expect(add.calls.contains("close"))
        // 세션 사본·USB DB 사본은 끝나면 지운다
        #expect(add.removedCopies(prefix: "local-").count == 1 && add.removedCopies(prefix: "usb-").count == 1)

        let blocked = FakeUsbPorts { $0.editSourceBlocks = [UsbBlock(code: "formatMismatch", scope: .volume, message: "두 형식이 다름")] }
        _ = try blocked.editSession().preview(Self.addOne, options: Self.options, snapshotTime: Self.time)
        #expect(blocked.current.copied.isEmpty)
    }

    @Test("계획에 늘 막는 확인 안 된 규칙이 붙으면 변경 묶음을 버리고 준비 폴더를 지운다")
    func lateRuleBlockDropsChanges() throws {
        var result = Self.planned()
        result.changes?.requiredRules = [.carriedDeviceRows]
        let ports = FakeUsbPorts { $0.editResult = result }
        let preview = try ports.editSession().preview(Self.removeOne, options: Self.options)
        #expect(preview.blocks.contains { $0.code == "provisional" } && preview.changes == nil)
        #expect(ports.removedStaging().count == 1)
    }

    @Test("초안 쓰기: 초안이 없으면 noDraft로 막고, 쓴 뒤 막힌 편집만 지금 지문을 base로 남긴다")
    func draftKeepsOnlyBlockedEdits() throws {
        let drafts = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        let ports = FakeUsbPorts {
            $0.editResult = Self.planned(blocked: true)
            $0.fingerprints = [Self.fingerprint("base"), Self.fingerprint("after")]
        }
        let missing = try ports.editSession(drafts: drafts).preview(Self.removeOne, options: Self.options)
        #expect(missing.changes != nil)
        #expect(throws: UsbError.self) {
            _ = try ports.editSession(drafts: drafts).writeDraft(options: Self.options, progress: { _ in }, isCancelled: { false })
        }
        let blockedEdit = UsbLibraryEdit.removeTracks(usbContentIDs: [2])
        try drafts.save(UsbDraft(volumeKey: Self.key, base: Self.fingerprint("base"), edits: [.removeTracks(usbContentIDs: [3]), blockedEdit],
                                 createdAt: FakeUsbPorts.snapshotDate))
        let (_, report) = try ports.editSession(drafts: drafts).writeDraft(options: Self.options, progress: { _ in }, isCancelled: { false })
        #expect(report?.outcome == .written && ports.current.writes.first?.verification == "edit")
        let kept = try #require(try drafts.load(Self.key))
        #expect(kept.edits == [blockedEdit] && kept.base == Self.fingerprint("after") && kept.createdAt == FakeUsbPorts.snapshotDate)

        // 막힌 것이 없으면 초안을 지운다
        ports.update { $0.editResult = Self.planned() }
        _ = try ports.editSession(drafts: drafts).writeDraft(options: Self.options, progress: { _ in }, isCancelled: { false })
        #expect(try drafts.load(Self.key) == nil)
    }

    @Test("초안 미리 보기: 초안이 없으면 nil, 만든 뒤 USB가 바뀌었으면 다시 계획 알림을 붙인다")
    func previewDraftNotesReplan() throws {
        let drafts = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        let ports = FakeUsbPorts { $0.editResult = Self.planned() }
        let volume = FakeUsbVolume.diskImageFAT32()
        #expect(try ports.editSession(drafts: drafts).previewDraft(volume: volume, options: Self.options, currentBase: { Self.fingerprint("x") }) == nil)
        try drafts.save(UsbDraft(volumeKey: Self.key, base: Self.fingerprint("base"), edits: Self.removeOne, createdAt: FakeUsbPorts.snapshotDate))
        let same = try #require(try ports.editSession(drafts: drafts).previewDraft(volume: volume, options: Self.options,
                                                                                   currentBase: { Self.fingerprint("base") }))
        #expect(!same.result.notes.contains(String(ui: "USB가 그 사이 바뀌어 다시 계획했습니다")) && same.edits == Self.removeOne)
        let changed = try #require(try ports.editSession(drafts: drafts).previewDraft(volume: volume, options: Self.options,
                                                                                      currentBase: { Self.fingerprint("other") }))
        #expect(changed.result.notes.first == String(ui: "USB가 그 사이 바뀌어 다시 계획했습니다"))
    }

    @Test("초안에 더하기: 막힌 볼륨이면 더하지 않고, 처음 더할 때 지금 USB DB 지문을 base로 둔다")
    func addToDraftUsesCurrentFingerprint() throws {
        let drafts = UsbDraftFiles.memory(now: { FakeUsbPorts.snapshotDate })
        let gated = FakeUsbPorts {
            $0.volume = FakeUsbVolume.physicalFAT32()
            $0.underScratch = false
        }
        #expect(throws: UsbError.self) { try gated.editSession(drafts: drafts).addToDraft(.removeTracks(usbContentIDs: [1])) }
        #expect(try drafts.load(FakeUsbVolume.physicalUUID) == nil)
        let ports = FakeUsbPorts { $0.fingerprints = [Self.fingerprint("now")] }
        try ports.editSession(drafts: drafts).addToDraft(.removeTracks(usbContentIDs: [1]))
        #expect(try drafts.load(Self.key)?.base == Self.fingerprint("now"))
    }

    @Test("쓰는 도중 볼륨이 사라지면 준비 폴더를 남긴다")
    func editVolumeLostKeepsStaging() {
        let ports = FakeUsbPorts {
            $0.editResult = Self.planned()
            $0.writeResult = .failure(.volumeLost(volumeName: "DJCTEST"))
        }
        #expect(thrownUsbError {
            _ = try ports.editSession().write(Self.removeOne, options: Self.options, progress: { _ in }, isCancelled: { false })
        }?.shape == "volumeLost")
        #expect(ports.removedStaging().isEmpty)
    }

    // MARK: - 옮기기

    @Test("옮기기: 볼륨이 막히거나 끝나지 않은 쓰기가 있으면 사본 없이 막는다")
    func migrateStopsBeforeCopy() throws {
        let gated = FakeUsbPorts {
            $0.volume = FakeUsbVolume.physicalFAT32()
            $0.underScratch = false
        }
        #expect(try gated.migrateSession().preview(options: Self.options).blocks.contains { $0.code == "physicalDisabled" })
        let open = FakeUsbPorts { $0.journal = .open(.backedUp) }
        #expect(try open.migrateSession().preview(options: Self.options).blocks.map(\.code) == ["recoveryNeeded"])
        for ports in [gated, open] { #expect(!ports.calls.contains("migrationPlan")) }
    }

    @Test("옮기기: OneLibrary가 이미 있으면(DB 지문) 사본을 뜨지 않고 막는다")
    func migrateRefusesExistingOneLibrary() throws {
        let ports = FakeUsbPorts {
            $0.fingerprints = [UsbFingerprint(files: [UsbLayout.oneLibrary + "-wal": .init(size: 1, mtime: FakeUsbPorts.snapshotDate, sha256: "w")])]
        }
        let result = try ports.migrateSession().preview(options: Self.options)
        #expect(result.blocks.map(\.code) == ["oneLibraryExists"])
        #expect(!ports.calls.contains("migrationPlan"))
    }

    @Test("옮기기 쓰기: 옮기기 검증으로 엔진 쓰기에 넘기고, 볼륨이 사라지면 준비 폴더를 남긴다")
    func migrateWritesWithMigrationChecks() throws {
        var planned = UsbMigrationResult()
        planned.changes = FakeUsbPorts.changes(staging: FakeUsbPorts.paths.staging.appending(path: "m"))
        let ports = FakeUsbPorts { $0.migration = planned }
        let (_, report) = try ports.migrateSession().write(options: Self.options, progress: { _ in }, isCancelled: { false })
        #expect(report?.outcome == .written && ports.current.writes.first?.verification == "migration")
        #expect(ports.removedStaging().count == 1 && ports.removedCopies(prefix: "usb-").count == 1)

        ports.update { $0.writeResult = .failure(.volumeChanged(volumeName: "DJCTEST")) }
        let before = ports.removedStaging().count
        #expect(thrownUsbError {
            _ = try ports.migrateSession().write(options: Self.options, progress: { _ in }, isCancelled: { false })
        }?.shape == "volumeChanged")
        #expect(ports.removedStaging().count == before)
    }
}
