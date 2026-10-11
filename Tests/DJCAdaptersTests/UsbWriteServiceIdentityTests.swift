import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 앱 쓰기 창구(`UsbWriteService` + 실제 엔진)는 사용자가 확인한 볼륨(사이드바의 볼륨 정보)의 UUID를 쓰기 절차에 넘긴다.
/// 그 사이 같은 자리에 다른 USB가 붙었으면 USB 파일 연산 없이 막힌다(임시 폴더 루트, 가짜 볼륨 정보)
@Suite("USB 쓰기 창구의 볼륨 확인")
struct UsbWriteServiceIdentityTests {
    func service(_ fixture: UsbChangeSetFixture, fs: FaultyUsbFileSystem) -> UsbWriteService {
        UsbWriteService(paths: fixture.paths, localCopies: fixture.home.appending(path: "usb-snapshots"), writeGuard: { fixture.writeGuard() },
                        engine: .live(fileSystem: fs), device: .testing(), drafts: .live(directory: fixture.home.appending(path: "usb-drafts")),
                        now: { Date() })
    }

    @Test("native 사전 확인은 기존 recheck의 현재 정보를 반환하고 쓰기 폴더를 만들지 않는다")
    func nativePreflightUsesRecheckWithoutCreatingFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-readonly-preflight-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var listed = FakeUsbVolume.diskImageFAT32(name: "합성 preflight USB")
        listed.mountPoint = root.appending(path: "fake-mount").path
        var changed = listed
        changed.volumeUUID = "00000000-0000-0000-0000-00000000BEEF"
        let actual = changed
        var service = UsbWriteService(paths: .init(backups: root.appending(path: "backups"), sessions: root.appending(path: "sessions"),
                                                   staging: root.appending(path: "staging")),
                                      localCopies: root.appending(path: "copies"), writeGuard: { .system },
                                      engine: .live(fileSystem: PosixUsbFileSystem()), device: .testing(),
                                      drafts: .live(directory: root.appending(path: "drafts")), now: { Date() })
        service.recheck = { _ in actual }
        #expect(try service.currentVolume(listed) == actual)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// 확인 창에 보인 볼륨: 같은 자리(마운트 지점)·같은 이름, UUID만 다르다
    func confirmed(_ fixture: UsbChangeSetFixture) -> UsbVolumeInfo {
        var volume = fixture.volume
        volume.mountPoint = fixture.usbURL.path
        volume.volumeUUID = "00000000-0000-0000-0000-0000000000C3"
        return volume
    }

    func code(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let UsbError.writeRefused(blocks) {
            return blocks.first?.code
        } catch {
            return "\(error)"
        }
    }

    @Test("회복·되돌리기는 확인한 볼륨이 아니면 USB를 건드리지 않고 막는다")
    func recoverAndRestoreCompareConfirmedUUID() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.exportChanges())
        let before = fixture.tree()
        let volume = confirmed(fixture)
        let fs = fixture.fileSystem()
        let service = service(fixture, fs: fs)
        #expect(code { _ = try service.recover(volume) } == "volumeChanged")
        #expect(code { _ = try service.restore(volume, backup: nil, discardDeviceChanges: false) } == "volumeChanged")
        // 볼륨 확인(마운트 지점 보기) 말고는 USB 파일 연산이 없다
        #expect(fs.calls.allSatisfy { $0.hasPrefix("mountedOn ") })
        #expect(fixture.tree() == before)
        // 같은 볼륨이면 되돌린다
        var same = volume
        same.volumeUUID = fixture.volumeKey
        #expect(try service.restore(same, backup: nil, discardDeviceChanges: false).outcome == .restored)
    }
}
