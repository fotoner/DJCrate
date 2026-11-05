import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 시점 스냅샷 유스케이스를 실제 엔진에 묶은 연결 시험(#226): 임시 폴더 USB(마운트 흉내, 디스크 이미지로 보이는 가짜 가드)에
/// 합성 두 형식 라이브러리를 두고 뜬 뒤 되돌린다. 맥 쪽 폴더도 모두 임시 폴더다. 계획 규칙은 RekordboxKitTests `UsbPointRestoreTests`
@Suite("USB 시점 스냅샷(실제 엔진)")
struct UsbPointSnapshotsTests {
    @Test("기기가 바꾼 USB는 버린다는 동의 없이 막고, 동의하면 스냅샷 때로 되돌린다. 되돌린 결과는 아는 상태라 다시 막지 않는다")
    func restoreAfterDeviceChange() throws {
        let usb = UsbChangeSetFixture()
        defer { usb.remove() }
        try UsbLibraryFixture().write(to: UsbTreeFixture(base: usb.usbURL))
        let snapshots = UsbPointSnapshots(directory: usb.home.appending(path: "usb-point-snapshots"), paths: usb.paths,
                                          writeGuard: { usb.writeGuard() }, engine: .live(fileSystem: usb.fileSystem()), device: .testing(),
                                          now: { Date() })
        let entry = try snapshots.create(root: usb.usbURL, name: "공연 전")
        #expect(snapshots.entries(volumeKey: usb.volumeKey) == [entry])
        let atSnapshot = usb.tree()

        // 기기가 재생 기록을 남긴 것처럼: export.pdb가 바뀌고 OneLibrary 옆에 -journal이 남는다
        usb.write(UsbLayout.exportPdb, UsbChangeSetFixture.random(4096))
        usb.write(UsbLayout.oneLibrary + "-journal", UsbChangeSetFixture.random(512))
        let preview = try snapshots.previewRestore(root: usb.usbURL, entry: entry, options: UsbWriteOptions())
        #expect(preview.deviceChanged && preview.blocks.isEmpty && preview.result.databases == 2)
        let refused = #expect(throws: UsbError.self) {
            try snapshots.restore(root: usb.usbURL, entry: entry, discardDeviceChanges: false, options: UsbWriteOptions(),
                                  progress: { _ in }, isCancelled: { false })
        }
        if case let .writeRefused(blocks)? = refused { #expect(blocks.map(\.code) == ["deviceChanged"]) } else { Issue.record("막힘이 아님") }
        #expect(usb.backupFolders().isEmpty)

        let written = try snapshots.restore(root: usb.usbURL, entry: entry, discardDeviceChanges: true, options: UsbWriteOptions(),
                                            progress: { _ in }, isCancelled: { false })
        #expect(written.report?.outcome == .written && usb.journal()?.state == .verified)
        #expect(usb.tree() == atSnapshot)
        #expect(usb.backupFolders().count == 1)

        let again = try snapshots.previewRestore(root: usb.usbURL, entry: entry, options: UsbWriteOptions())
        #expect(!again.deviceChanged && again.result.isUnchanged)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: usb.paths.staging.path)) ?? []).isEmpty)
    }
}
