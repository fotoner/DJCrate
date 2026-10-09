import DJCDomain
@testable import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// DiskArbitration 알림 해석(순수): 어떤 볼륨을 사이드바에 올릴지. 설명 사전은 지어낸 값만 쓴다.
@Suite("USB 볼륨 지켜보기")
struct UsbVolumeMonitorTests {
    static let scratch = "/private/tmp/djc-monitor-fixture/vm"

    func description(_ base: [String: Any], path: String?) -> [String: Any] {
        var description = base
        if let path { description["DAVolumePath"] = URL(filePath: path, directoryHint: .isDirectory) }
        return description
    }

    func mountPoints(_ disks: [String: UsbVolumeMonitor.Disk]) -> [String] {
        UsbVolumeMonitor.mountPoints(disks) { $0.hasPrefix("/private/tmp/") }
    }

    @Test("실물 USB·임시 폴더의 디스크 이미지만 올리고 내장·네트워크·시스템 이미지는 뺀다")
    func candidates() {
        var internalUsbPath = FakeDiskArbitration.physicalUsbPartition(bsd: "disk10s1")
        internalUsbPath["DADeviceInternal"] = nil
        var network = FakeDiskArbitration.physicalUsbPartition(bsd: "disk11s1")
        network["DAVolumeNetwork"] = true
        let disks: [String: UsbVolumeMonitor.Disk] = [
            "disk9s1": .init(description: description(FakeDiskArbitration.physicalUsbPartition(), path: "/Volumes/DJCPHYS")),
            "disk7s1": .init(description: description(FakeDiskArbitration.diskImagePartition(), path: Self.scratch)),
            "disk3s5": .init(description: description(FakeDiskArbitration.internalDisk(), path: "/System/Volumes/Data")),
            "disk3s6": .init(description: description(FakeDiskArbitration.internalDisk(), path: "/Volumes/Other")),
            "disk8s1": .init(description: description(FakeDiskArbitration.diskImagePartition(bsd: "disk8s1"),
                                                      path: "/Library/Developer/CoreSimulator/Volumes/Runtime")),
            "disk10s1": .init(description: description(internalUsbPath, path: "/Volumes/UNKNOWN")),
            "disk11s1": .init(description: description(network, path: "/Volumes/SHARE")),
            "disk12s1": .init(description: description(FakeDiskArbitration.physicalUsbPartition(bsd: "disk12s1"), path: nil)),
            "disk13s1": .init(description: description(FakeDiskArbitration.physicalUsbPartition(bsd: "disk13s1"), path: "/")),
        ]
        #expect(mountPoints(disks) == ["/Volumes/DJCPHYS", Self.scratch])
        // 시험 실행은 실물 볼륨의 정보도 읽지 않는다
        #expect(UsbVolumeMonitor.mountPoints(disks, diskImagesOnly: true) { $0.hasPrefix("/private/tmp/") } == [Self.scratch])
    }

    @Test("나타남·경로 바뀜·사라짐 알림으로 표를 고친다")
    func applyEvents() {
        var disks: [String: UsbVolumeMonitor.Disk] = [:]
        UsbVolumeMonitor.apply(.appeared(bsd: "disk9s1", description: FakeDiskArbitration.physicalUsbPartition()), to: &disks)
        // 마운트 전에는 경로가 없어 올리지 않는다
        #expect(mountPoints(disks).isEmpty)
        UsbVolumeMonitor.apply(.changed(bsd: "disk9s1", description: description(FakeDiskArbitration.physicalUsbPartition(),
                                                                                  path: "/Volumes/DJCPHYS")), to: &disks)
        #expect(mountPoints(disks) == ["/Volumes/DJCPHYS"])
        // 떼기(마운트 해제)는 경로가 빠진 설명으로 온다
        UsbVolumeMonitor.apply(.changed(bsd: "disk9s1", description: FakeDiskArbitration.physicalUsbPartition()), to: &disks)
        #expect(mountPoints(disks).isEmpty)
        UsbVolumeMonitor.apply(.appeared(bsd: "disk7s1", description: description(FakeDiskArbitration.diskImagePartition(),
                                                                                   path: Self.scratch)), to: &disks)
        UsbVolumeMonitor.apply(.disappeared(bsd: "disk9s1"), to: &disks)
        #expect(disks.keys.sorted() == ["disk7s1"])
        #expect(mountPoints(disks) == [Self.scratch])
    }

    @Test("설명 사전의 칸 해석: 경로는 파일 URL·문자열 모두, 내장 키가 없으면 모름")
    func parseDescription() {
        let image = UsbVolumeMonitor.Disk(description: description(FakeDiskArbitration.diskImagePartition(), path: Self.scratch + "/"))
        #expect(image.volumePath == Self.scratch && image.isDiskImage && image.isInternal == nil && !image.isNetwork)
        var text = FakeDiskArbitration.physicalUsbPartition()
        text["DAVolumePath"] = "/Volumes/DJCPHYS"
        let physical = UsbVolumeMonitor.Disk(description: text)
        #expect(physical.volumePath == "/Volumes/DJCPHYS" && !physical.isDiskImage && physical.isInternal == false)
    }
}
