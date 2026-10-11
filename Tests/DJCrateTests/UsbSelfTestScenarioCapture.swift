@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// `--usb-selftest`와 같은 흐름을 앱을 띄우지 않고 돈다(실제 디스크 이미지·실제 쓰기 절차). 볼륨은 시험 이미지의 마운트 지점만 본다
/// (DiskArbitration으로 다른 볼륨을 지켜보지 않는다). 기본은 꺼져 있다:
/// `DJC_USB_SELFTEST_SCRATCH=<임시 폴더 아래 빈 폴더> swift test --filter UsbSelfTestScenarioCapture`
@MainActor
struct UsbSelfTestScenarioCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_USB_SELFTEST_SCRATCH"] != nil))
    func scenario() async throws {
        let scratch = try UsbScratchPath.check(ProcessInfo.processInfo.environment["DJC_USB_SELFTEST_SCRATCH"] ?? "", as: .existingDirectory)
        let home = URL(filePath: scratch).appending(path: "home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        // 합성 라이브러리의 표 구조는 구조만 있는 rekordbox 7.2.18 DB에서 가져온다
        let fixture = try RekordboxFixture()
        var lines: [String] = []
        let scenario = UsbSelfTestScenario(home: home, schemaSource: fixture.database, log: { line in
            print(line)
            lines.append(line)
        })
        let mount = scenario.mountPoint.path
        let (events, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
        defer { continuation.finish() }
        let usbHost = SystemUsbHost(io: UsbAppComposition.hostIO(snapshots: home.appending(path: "usb-snapshots")), events: events, current: {
            guard let real = UsbScratchRoots.realPath(mount), UsbScratchRoots.mountedOn(real) == real,
                  let volume = try? UsbVolumes.info(root: URL(filePath: real)) else { return [] }
            return [volume]
        })
        let service = scenario.makeService()
        let usb = UsbStore(host: usbHost, readPolicy: .diskImagesOnly, writeService: service, localLibrary: { nil }, journal: { service.journal(volumeKey: $0) })
        let passed = try await scenario.run(usb: usb, host: FakeUsbWriteHost())
        print(passed)
        #expect(passed.hasPrefix("USB 시험 통과"))
        #expect(lines.contains { $0.hasPrefix("USB 시험 provenance: ") })
        #expect(lines.contains { $0.hasPrefix("USB 시험 옮기기 통과") })
        #expect(try !UsbDiskImage.detach(image: scenario.image.path))
    }
}
