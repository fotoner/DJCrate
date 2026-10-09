@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// `LibraryStore.usb`를 붙이고 뗄 때 USB 쓰기·초안 편집 흐름이 그 `UsbStore`와 그 쓰기 창구로 다시 만들어지는지
@MainActor
@Suite("USB 흐름 붙이기(LibraryStore.usb)")
struct UsbFlowAttachTests {
    func usbStore(_ service: FakeUsbWriteService) -> UsbStore {
        let image = FakeUsbVolume.diskImageFAT32(name: "합성 붙이기 USB")
        let host = FakeUsbHost([image])
        host.serveEmpty(image)
        return UsbTestData.store(host, service: service)
    }

    @Test("떼면 흐름도 없고, 다시 붙이면 새 UsbStore·새 쓰기 창구로 만들며 결과는 스토어에 알린다")
    func detachAndReattach() throws {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("usbattach"), persist: false),
                                 resultHistory: WriteResultHistory(), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in })
        #expect(store.usbCoordinator == nil && store.usbEdits == nil)

        let first = FakeUsbWriteService(), second = FakeUsbWriteService()
        let firstUsb = usbStore(first)
        store.usb = firstUsb
        #expect(store.usbCoordinator?.usb === firstUsb && store.usbEdits?.usb === firstUsb)
        #expect(store.usbCoordinator?.service as? FakeUsbWriteService === first)

        store.usb = nil
        #expect(store.usbCoordinator == nil && store.usbEdits == nil)

        let secondUsb = usbStore(second)
        store.usb = secondUsb
        #expect(store.usbCoordinator?.usb === secondUsb && store.usbEdits?.usb === secondUsb)
        // 미리 보기·확인(UsbStore.writeService)과 쓰기(코디네이터)가 같은 창구를 본다
        #expect(store.usbCoordinator?.service as? FakeUsbWriteService === second)
        #expect(secondUsb.writeService as? FakeUsbWriteService === second)
        // 흐름의 결과 알림은 스토어로 간다(약한 창구)
        let host = try #require(store.usbCoordinator?.host)
        host.toast = .notice("합성 알림", "합성", isUsb: true)
        #expect(store.toast?.title == "합성 알림")
    }
}
