import DJCAdapters
import DJCApplication
import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// `djc usb-snapshot` 인자·출력 줄(#226). 흐름은 임시 폴더 USB(마운트 흉내, 디스크 이미지로 보이는 가짜 가드)에 둔 합성
/// Device Library로 돌린다(이 묶음은 SQLCipher 키 유도가 무거워 OneLibrary를 열지 않는 USB를 쓴다)
@Suite("USB 시점 스냅샷 명령")
struct UsbSnapshotCommandTests {
    typealias Request = UsbSnapshotCommand.Request

    @Test("인자: 하위 명령·볼륨·ID·되돌리기 선택")
    func parsesArguments() throws {
        #expect(try UsbSnapshotCommand.request(["usb-snapshot", "create", "--volume", "/tmp/v", "--name", "공연 전"])
            == Request(action: .create, volume: "/tmp/v", name: "공연 전"))
        #expect(try UsbSnapshotCommand.request(["usb-snapshot", "list", "--volume", "/tmp/v"]) == Request(action: .list, volume: "/tmp/v"))
        #expect(try UsbSnapshotCommand.request(["usb-snapshot", "restore", "2026-x", "--volume", "/tmp/v", "--discard-device-changes", "--dry-run",
                                                "--allow-physical", "--confirm", "DJCTEST"])
            == Request(action: .restore, volume: "/tmp/v", key: "2026-x", discardDeviceChanges: true, dryRun: true, confirmName: "DJCTEST",
                       allowPhysical: true))
        #expect(try UsbSnapshotCommand.request(["usb-snapshot", "delete", "--volume", "/tmp/v", "2026-x"]) == Request(action: .delete, volume: "/tmp/v",
                                                                                                                     key: "2026-x"))
    }

    @Test("잘못된 인자는 사용법, 라이브 라이브러리는 거부")
    func rejectsBadArguments() {
        for args in [
            ["usb-snapshot"],
            ["usb-snapshot", "make", "--volume", "/v"],
            ["usb-snapshot", "create"],
            ["usb-snapshot", "create", "--volume"],
            ["usb-snapshot", "create", "--volume", "/v", "ID"],
            ["usb-snapshot", "create", "--volume", "/v", "--allow-physical"],
            ["usb-snapshot", "list", "--volume", "/v", "--discard-device-changes"],
            ["usb-snapshot", "restore", "--volume", "/v"],
            ["usb-snapshot", "restore", "a", "--volume", "/v", "--name", "x"],
            ["usb-snapshot", "restore", "a", "--volume", "/v", "--confirm"],
            ["usb-snapshot", "pin", "a", "b", "--volume", "/v"],
        ] {
            #expect(throws: UsageError.self) { try UsbSnapshotCommand.request(args) }
        }
        #expect(throws: UsbError.self) {
            try UsbSnapshotCommand.request(["usb-snapshot", "list", "--volume", NSHomeDirectory() + "/Library/Pioneer/rekordbox"])
        }
    }

    @Test("만들기·목록·되돌리기·고정·지우기: 수와 ID만 찍고 스냅샷 폴더 경로·곡 경로는 찍지 않는다")
    func runLines() throws {
        let usb = UsbChangeSetFixture()
        defer { usb.remove() }
        var fixture = UsbLibraryFixture()
        fixture.formats = [.deviceLibrary]
        fixture.myTagLinks = []
        try fixture.write(to: UsbTreeFixture(base: usb.usbURL))
        let directory = usb.home.appending(path: "usb-point-snapshots")
        let snapshots = UsbPointSnapshots(directory: directory, paths: usb.paths, writeGuard: { usb.writeGuard() },
                                          engine: .live(fileSystem: usb.fileSystem()), device: .testing(), now: { Date() })
        var lines: [String] = []
        var all: [String] = []
        func run(_ args: [String]) throws {
            lines = []
            try UsbSnapshotCommand.run(["usb-snapshot"] + args + ["--volume", usb.usbURL.path], snapshots: snapshots) {
                lines.append($0)
                all.append($0)
            }
        }

        try run(["create", "--name", "공연 전"])
        let entry = try #require(snapshots.entries(volumeKey: usb.volumeKey).first)
        #expect(lines.first == "USB 스냅샷을 남겼습니다: \(entry.id)" && lines.contains(UsbSnapshotCommand.contentsLine(entry.metadata)))
        try run(["list"])
        #expect(lines.count == 2 && lines[0] == "USB 스냅샷 1개" && lines[1].hasPrefix("  \(entry.id) · ‘공연 전’ · "))

        // 그 뒤 바뀐 USB는 버린다는 동의 없이 되돌리지 않는다
        usb.write(UsbLayout.exportPdb, UsbChangeSetFixture.random(4096))
        #expect(throws: UsbError.self) { try run(["restore", "공연 전"]) }
        #expect(lines.first?.hasPrefix("막힘 deviceChanged: ") == true)
        // 드라이 런은 버렸다고 하지 않는다(USB는 그대로, 백업도 없다)
        try run(["restore", "공연 전", "--discard-device-changes", "--dry-run"])
        #expect(lines.contains("실제로 되돌리면 그 뒤 USB가 바뀐 내용(기기가 쓴 기록 등)을 버립니다.")
            && lines.contains("결과: 미리 보기만 했습니다(USB는 그대로)") && !lines.contains { $0.contains("버렸습니다") })
        try run(["restore", "공연 전", "--discard-device-changes"])
        #expect(lines.first == "‘공연 전’ 시점으로: DB 1 · 만들 파일 0 · 덮을 파일 0 · 지울 파일 0")
        #expect(lines.contains("결과: 썼습니다") && lines.contains("되돌리기 전으로 돌리려면: djc usb-restore --volume \(usb.usbURL.path)"))
        try run(["restore", entry.id])
        #expect(lines.first == "지금 USB가 ‘공연 전’ 시점과 같아 바꾸지 않았습니다.")

        try run(["pin", entry.id])
        #expect(lines == ["고정했습니다: \(entry.id)"])
        #expect(throws: UsbError.self) { try run(["delete", entry.id]) }
        try run(["unpin", entry.id])
        try run(["delete", "공연 전"])
        #expect(lines == ["지웠습니다: \(entry.id)"] && snapshots.entries(volumeKey: usb.volumeKey).isEmpty)
        #expect(!all.contains { $0.contains(directory.path) || $0.contains("Contents/") })
    }
}
