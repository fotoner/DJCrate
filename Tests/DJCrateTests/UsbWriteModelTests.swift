@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Observation
import Testing

/// 바뀜 알림을 받았는지 적는 상자(관찰 범위 시험)
@MainActor
private final class ChangeFlag {
    var changed = false
}

@MainActor
@Suite("USB 쓰기 세션 화면 모델(UsbWriteModel)")
struct UsbWriteModelTests {
    let first = FakeUsbVolume.diskImageFAT32(name: "B1", uuid: "00000000-0000-0000-0000-0000000000B1")
    let second = FakeUsbVolume.diskImageFAT32(name: "B2", uuid: "00000000-0000-0000-0000-0000000000B2")

    @Test("핵심부 세션이 내보낸 잠금·진행·옮기기 상태를 관찰 상태로 옮긴다")
    func mirrorsSessionState() {
        let model = UsbWriteModel()
        let key = first.usbKey
        #expect(model.session.begin(first, title: "합성 미리 보기") != nil)
        #expect(model.busyVolumes == [key] && model.activeWrite?.title == "합성 미리 보기")
        let files = UsbProgress(phase: .files, completedItems: 1, totalItems: 2, cancellable: true)
        model.session.report(files, for: key)
        #expect(model.activeWrite?.progress == files)
        model.session.migrationBackups[key] = URL(filePath: "/private/tmp/djc-fixture/usb-backups/B1/m1")
        model.session.migrationBlockReasons[key] = "합성 막힘"
        #expect(model.migrationBackups[key] != nil && model.migrationBlockReasons[key] == "합성 막힘")
        model.session.end(key)
        #expect(model.busyVolumes.isEmpty && model.activeWrite == nil)
        #expect(model.session.state == UsbWriteSessionState(migrationBackups: model.migrationBackups,
                                                            migrationBlockReasons: model.migrationBlockReasons))
    }

    @Test("진행이 바뀌어도 잠금·옮기기만 보는 관찰은 다시 부르지 않고, 덮개(진행)를 보는 관찰만 부른다")
    func progressKeepsLockObserversQuiet() {
        let model = UsbWriteModel()
        let key = first.usbKey
        _ = model.session.begin(first, title: "합성 쓰기")
        let lock = ChangeFlag(), overlay = ChangeFlag()
        withObservationTracking {
            _ = model.busyVolumes
            _ = model.migrationBackups
            _ = model.migrationBlockReasons
        } onChange: { MainActor.assumeIsolated { lock.changed = true } }
        withObservationTracking { _ = model.activeWrite } onChange: { MainActor.assumeIsolated { overlay.changed = true } }
        model.session.report(UsbProgress(phase: .files, cancellable: true), for: key)
        model.session.setTitle("합성 다음 단계", for: key)
        #expect(overlay.changed && !lock.changed)
        model.session.end(key)
        #expect(lock.changed)
    }

    @Test("사이드바 저장소의 잠금은 이 화면 모델을 거친다: 같은 볼륨 두 번·다른 볼륨 동시 잠금을 막고 취소는 세션으로 간다")
    func storeLocksThroughModel() throws {
        let host = FakeUsbHost([first, second])
        let usb = UsbTestData.store(host)
        let flag = try #require(usb.beginWrite(first, title: "합성 쓰기"))
        #expect(usb.beginWrite(first, title: "두 번째") == nil)
        #expect(usb.beginWrite(second, title: "다른 볼륨") == nil)
        #expect(usb.busyVolumes == [first.usbKey] && usb.write.busyVolumes == [first.usbKey])
        #expect(usb.activeWrite == usb.write.activeWrite && usb.session === usb.write.session)
        usb.cancelWrite()
        #expect(flag.isSet)
        usb.endWrite(first.usbKey)
        #expect(usb.busyVolumes.isEmpty && usb.activeWrite == nil)
        #expect(usb.beginWrite(second, title: "다른 볼륨") != nil)
    }
}
