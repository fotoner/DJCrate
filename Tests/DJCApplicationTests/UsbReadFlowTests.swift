import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// USB 읽기 점검(`UsbRead`)의 순서·판정(가짜 포트). 실제 엔진으로 합성 USB를 읽는 시험은 DJCAdaptersTests `UsbReadLibraryTests`·
/// djcTests `UsbInfoTests`
@Suite("USB 읽기 흐름")
struct UsbReadFlowTests {
    static let root = URL(filePath: "/Volumes/DJCTEST")
    static let scratch = URL(filePath: "/private/tmp/djc-fixture/usb-snapshots/info-1")

    func reader(_ ports: FakeUsbPorts) -> UsbRead { UsbRead(engine: ports.engine, device: ports.device) }

    func detail(_ body: () throws -> UsbVolumeInfo) -> String? {
        do { _ = try body() } catch let UsbError.readFailed(detail) { return detail } catch { return "\(error)" }
        return nil
    }

    @Test("읽기 직전 다시 본 볼륨이 목록의 볼륨과 다르면(UUID·디스크 이미지·자리) 읽지 않는다")
    func currentVolumeMustMatch() throws {
        var listed = FakeUsbVolume.diskImageFAT32()
        listed.mountPoint = "/private/tmp/djc-fixture/mnt"
        // 같은 볼륨이면 지금 읽은 정보를 돌려준다(대소문자만 다른 UUID도 같은 볼륨)
        var now = listed
        now.volumeUUID = listed.volumeUUID?.lowercased()
        now.available = 1
        let ports = FakeUsbPorts {
            $0.mountedOn = [listed.mountPoint: listed.mountPoint]
            $0.volumeInfo = .success(now)
        }
        #expect(try reader(ports).currentVolume(matching: listed) == now)

        var other = listed
        other.volumeUUID = "00000000-0000-0000-0000-0000000000FF"
        var physical = listed
        physical.isDiskImage = false
        physical.diskImagePath = nil
        var otherImage = listed
        otherImage.diskImagePath = "/private/tmp/djc-fixture/OTHER.img"
        var elsewhere = listed
        elsewhere.mountPoint = listed.mountPoint + "-2"
        for changed in [other, physical, otherImage, elsewhere] {
            ports.update { $0.volumeInfo = .success(changed) }
            #expect(detail { try reader(ports).currentVolume(matching: listed) } == "volumeChanged")
        }
        // 그 자리가 Mac 시동 볼륨이 됐거나(볼륨이 빠짐) 마운트 지점을 모르면 읽지 않는다
        ports.update {
            $0.volumeInfo = .success(listed)
            $0.mountedOn = [listed.mountPoint: "/"]
        }
        #expect(detail { try reader(ports).currentVolume(matching: listed) } == "volumeChanged")
        ports.update { $0.mountedOn = [:] }
        #expect(detail { try reader(ports).currentVolume(matching: listed) } != nil)
    }

    @Test("볼륨 정보 없이 Mac 밖 볼륨을 넘기면 읽지 않고, 무엇이 든 사본 폴더는 받지 않는다")
    func refusesUncheckedVolumeAndBusyScratch() {
        let outside = FakeUsbPorts { $0.mountedOn = [Self.root.path: Self.root.path] }
        #expect(thrownUsbError {
            _ = try reader(outside).info(root: Self.root, scratch: Self.scratch, volume: nil)
        }?.shape == "readFailed volumeNotChecked")
        #expect(!outside.calls.contains("rekordboxFileNames"))
        let busy = FakeUsbPorts {
            $0.existing = [Self.scratch]
            $0.folderNames = [Self.scratch: ["남의 파일"]]
        }
        #expect(thrownUsbError {
            _ = try reader(busy).info(root: Self.root, scratch: Self.scratch, volume: FakeUsbVolume.diskImageFAT32())
        }?.shape == "readFailed scratch not empty")
        #expect(busy.current.removed.isEmpty)
    }

    @Test("OneLibrary 사본이 온전하지 않으면 pdb만 따로 떠서 읽고 경고하며, 이 호출이 만든 사본 폴더만 지운다")
    func brokenOneLibraryFallsBackToPdb() throws {
        let pdb = (export: URL(filePath: "/private/tmp/djc-fixture/pdb/export.pdb"), ext: URL?.none)
        let ports = FakeUsbPorts {
            $0.rekordboxFileNames = ["exportLibrary.db", "export.pdb"]
            $0.databaseCopy = .failure(.readFailed(detail: "integrity_check failed"))
            $0.pdbCopy = pdb
            $0.deviceLibrary = .success(FakeUsbPorts.deviceLibrary())
        }
        let info = try reader(ports).info(root: Self.root, scratch: Self.scratch, volume: FakeUsbVolume.diskImageFAT32())
        #expect(info.oneLibrary?.integrityOK == false)
        #expect(info.warnings.contains { $0.code == "oneLibraryUnreadable" })
        #expect(info.deviceLibrary?.roundTripOK == true)
        #expect(ports.calls.contains("copyPdb"))
        // 사본 폴더(db·pdb)와 이 호출이 만든 scratch를 지운다
        #expect(Set(ports.current.removed) == [Self.scratch.appending(path: "db"), Self.scratch.appending(path: "pdb"), Self.scratch])
    }

    @Test("사이드바 읽기: 읽지 못한 사본 폴더는 남기지 않고, 읽으면 볼륨마다 최근 사본 폴더만 남긴다")
    func libraryCleansFailedAndOldSnapshots() throws {
        let snapshots = URL(filePath: "/private/tmp/djc-fixture/usb-snapshots")
        let base = snapshots.appending(path: "K1")
        let failed = FakeUsbPorts {
            $0.rekordboxFileNames = ["exportLibrary.db"]
            $0.databaseCopy = .failure(.readFailed(detail: "copy failed"))
        }
        #expect(throws: UsbError.self) {
            _ = try reader(failed).library(root: Self.root, snapshots: snapshots, volumeKey: "K1", volume: FakeUsbVolume.diskImageFAT32(),
                                           now: FakeUsbPorts.snapshotDate)
        }
        #expect(failed.current.removed.count == 1 && failed.current.removed.first.map { FakeUsbPorts.isChild($0, of: base) } == true)

        let ports = FakeUsbPorts {
            $0.rekordboxFileNames = ["exportLibrary.db"]
            $0.databaseCopy = .success(FakeUsbPorts.copy(pdb: false))
            $0.folderNames = [base: ["20260101T000000", "20260102T000000", "20260103T000000", "남의 것"]]
        }
        _ = try reader(ports).library(root: Self.root, snapshots: snapshots, volumeKey: "K1", volume: FakeUsbVolume.diskImageFAT32(),
                                      now: FakeUsbPorts.snapshotDate, keep: 2)
        #expect(ports.current.removed == [base.appending(path: "20260101T000000")])
    }

    @Test("잘못된 볼륨키·라이브러리 없는 USB는 사본을 뜨지 않는다")
    func refusesBadKeyAndEmptyUsb() {
        let ports = FakeUsbPorts()
        for key in ["", "..", "a/b"] {
            #expect(throws: UsbError.self) {
                _ = try reader(ports).library(root: Self.root, snapshots: Self.scratch, volumeKey: key, volume: FakeUsbVolume.diskImageFAT32(),
                                              now: FakeUsbPorts.snapshotDate)
            }
        }
        #expect(thrownUsbError {
            _ = try reader(ports).library(root: Self.root, snapshots: Self.scratch, volumeKey: "K", volume: FakeUsbVolume.diskImageFAT32(),
                                          now: FakeUsbPorts.snapshotDate)
        }?.shape == "readFailed noLibrary")
        #expect(!ports.calls.contains("copyDatabases"))
    }
}
