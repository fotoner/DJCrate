@testable import DJCrate
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 앱 전후 캡처에 쓰는 합성 사본·Device Library 폴더. 기존 USB 캡처의 임시 폴더 인자를 같이 쓴다.
struct UsbMigrateAppFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_USB_SELFTEST_SCRATCH"] != nil))
    func fixture() throws {
        let root = URL(filePath: try UsbScratchPath.check(ProcessInfo.processInfo.environment["DJC_USB_SELFTEST_SCRATCH"] ?? "", as: .existingDirectory))
        let fixture = try RekordboxFixture()
        _ = try UsbSelfTestLibrary.make(in: root.appending(path: "local"), schemaFrom: fixture.database)
        var usb = UsbLibraryFixture()
        usb.formats = [.deviceLibrary]
        usb.myTagLinks = []
        let tree = UsbTreeFixture(base: root.appending(path: "seed"))
        try usb.write(to: tree)
        print("USB 옮기기 캡처 합성 재료: Device Library · 곡 3 · 재생 목록 1 · 앨범아트 6")
    }
}
