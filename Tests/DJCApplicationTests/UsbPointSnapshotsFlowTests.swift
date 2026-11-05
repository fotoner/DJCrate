import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// USB 시점 스냅샷 유스케이스의 순서·판정(가짜 포트, DB·디스크 없이). 실제 엔진을 묶은 뜨기·되돌리기는 DJCAdaptersTests
/// `UsbPointSnapshotsTests`, 계획 규칙은 RekordboxKitTests `UsbPointRestoreTests`
@Suite("USB 시점 스냅샷 흐름")
struct UsbPointSnapshotsFlowTests {
    static let key = "00000000-0000-0000-0000-000000000001"
    static let directory = URL(filePath: "/private/tmp/djc-fixture/usb-point-snapshots")
    static let options = UsbWriteOptions(confirmName: "DJCTEST")

    static func entry(volume: String = key) -> UsbPointSnapshotEntry {
        let metadata = UsbPointSnapshotMetadata(name: "공연 전", kind: .manual, createdAt: FakeUsbPorts.snapshotDate, volumeUUID: volume,
                                                volumeName: "DJCTEST", files: [:])
        return UsbPointSnapshotEntry(url: directory.appending(path: volume).appending(path: "2027-01-15T080000Z-manual"), metadata: metadata)
    }

    static func fingerprint(_ sha: String) -> UsbFingerprint {
        UsbFingerprint(files: [UsbLayout.exportPdb: .init(size: 10, mtime: FakeUsbPorts.snapshotDate, sha256: sha)])
    }

    /// 바꿀 것이 있는 계획
    static func planned() -> UsbPointRestoreResult {
        var result = UsbPointRestoreResult()
        result.changes = FakeUsbPorts.changes(staging: FakeUsbPorts.paths.staging.appending(path: "s1"))
        result.databases = 1
        return result
    }

    @Test("만들기는 확인한 볼륨 그대로 엔진에 넘기고, 목록·찾기는 그 볼륨의 스냅샷만 본다")
    func createAndFind() throws {
        let ports = FakeUsbPorts { $0.pointSnapshots = [Self.entry()] }
        let snapshots = ports.pointSnapshots(directory: Self.directory)
        let created = try snapshots.create(root: FakeUsbPorts.root, name: "공연 전")
        #expect(created == Self.entry())
        let request = try #require(ports.current.pointCreates.first)
        #expect(request.root == FakeUsbPorts.root && request.directory == Self.directory && request.name == "공연 전")
        #expect(try snapshots.volumeKey(root: FakeUsbPorts.root) == Self.key)
        #expect(try snapshots.find("공연 전", volumeKey: Self.key) == Self.entry())
        #expect(throws: UsbError.self) { try snapshots.find("없는 스냅샷", volumeKey: Self.key) }
    }

    @Test("볼륨이 막히면 USB를 읽지 않고, 다른 볼륨의 스냅샷·끝나지 않은 쓰기는 계획 전에 막는다")
    func blocksBeforePlan() throws {
        let gated = FakeUsbPorts {
            $0.volume = FakeUsbVolume.physicalFAT32()
            $0.underScratch = false
        }
        let summary = try gated.pointSnapshots(directory: Self.directory).previewRestore(root: FakeUsbPorts.root, entry: Self.entry(),
                                                                                          options: Self.options)
        #expect(summary.blocks.contains { $0.code == "physicalDisabled" })
        for call in ["journal", "fingerprint", "pointPlan"] { #expect(!gated.calls.contains(call)) }

        let other = FakeUsbPorts()
        let otherSummary = try other.pointSnapshots(directory: Self.directory).previewRestore(root: FakeUsbPorts.root,
                                                                                              entry: Self.entry(volume: "OTHER"), options: Self.options)
        #expect(otherSummary.blocks.map(\.code) == ["pointSnapshotOtherVolume"] && !other.calls.contains("pointPlan"))

        let open = FakeUsbPorts { $0.journal = .open(.filesWritten) }
        let openSummary = try open.pointSnapshots(directory: Self.directory).previewRestore(root: FakeUsbPorts.root, entry: Self.entry(),
                                                                                            options: Self.options)
        #expect(openSummary.blocks.map(\.code) == ["recoveryNeeded"] && !open.calls.contains("pointPlan"))
    }

    @Test("기기가 바꾼 USB(아는 상태 밖)는 버린다는 동의 없이 쓰지 않고, 동의하면 쓰기 절차로 쓴다")
    func deviceChangedNeedsConsent() throws {
        let ports = FakeUsbPorts {
            $0.journal = .closed(.verified, idHighWater: ["content": 9])
            $0.fingerprints = [Self.fingerprint("기기가 쓴 뒤")]
            $0.pointPlan = Self.planned()
        }
        let snapshots = ports.pointSnapshots(directory: Self.directory)
        let summary = try snapshots.previewRestore(root: FakeUsbPorts.root, entry: Self.entry(), options: Self.options)
        #expect(summary.deviceChanged && summary.blocks.isEmpty)
        #expect(ports.current.pointPlans.first?.highWater == ["content": 9])
        // 판정한 지문을 계획의 base로 넘긴다
        #expect(ports.current.pointPlans.first?.base == Self.fingerprint("기기가 쓴 뒤"))

        let refused = #expect(throws: UsbError.self) {
            try snapshots.restore(root: FakeUsbPorts.root, entry: Self.entry(), discardDeviceChanges: false, options: Self.options,
                                  progress: { _ in }, isCancelled: { false })
        }
        if case let .writeRefused(blocks)? = refused { #expect(blocks.map(\.code) == ["deviceChanged"]) } else { Issue.record("막힘이 아님") }
        #expect(ports.current.writes.isEmpty)

        let written = try snapshots.restore(root: FakeUsbPorts.root, entry: Self.entry(), discardDeviceChanges: true, options: Self.options,
                                            progress: { _ in }, isCancelled: { false })
        #expect(written.report?.outcome == .written)
        #expect(ports.current.writes.map(\.verification) == ["pointRestore"] && ports.current.writes.first?.root == FakeUsbPorts.root)
    }

    /// 스냅샷 상태(DB 없음)에서 시작한 DJCrate 쓰기
    static let ourWrite = UsbVolumeEvent.write(id: "w1", date: FakeUsbPorts.snapshotDate.addingTimeInterval(60), before: [:], beforeSidecars: false,
                                               after: [UsbLayout.exportPdb: "쓴 결과"], kind: .carry, outcome: .written)

    @Test("스냅샷 뒤 DJCrate 쓰기만 있었으면 동의 없이 쓰고, 바꿀 것이 없으면 쓰지 않는다")
    func knownStateWritesWithoutConsent() throws {
        let ports = FakeUsbPorts {
            $0.fingerprints = [Self.fingerprint("쓴 결과")]
            $0.volumeEvents = [Self.ourWrite]
            $0.pointPlan = Self.planned()
        }
        let written = try ports.pointSnapshots(directory: Self.directory).restore(
            root: FakeUsbPorts.root, entry: Self.entry(), discardDeviceChanges: false, options: Self.options, progress: { _ in }, isCancelled: { false })
        #expect(!written.summary.deviceChanged && written.report != nil && ports.current.writes.count == 1)

        let same = FakeUsbPorts {
            $0.fingerprints = [Self.fingerprint("쓴 결과")]
            $0.volumeEvents = [Self.ourWrite]
        }
        let nothing = try same.pointSnapshots(directory: Self.directory).restore(
            root: FakeUsbPorts.root, entry: Self.entry(), discardDeviceChanges: false, options: Self.options, progress: { _ in }, isCancelled: { false })
        #expect(nothing.report == nil && nothing.summary.result.isUnchanged && same.current.writes.isEmpty)
    }
}

extension FakeUsbPorts {
    func pointSnapshots(directory: URL) -> UsbPointSnapshots {
        UsbPointSnapshots(directory: directory, paths: Self.paths, writeGuard: { [self] in writeGuard }, engine: engine, device: device,
                          now: { FakeUsbPorts.snapshotDate })
    }
}
