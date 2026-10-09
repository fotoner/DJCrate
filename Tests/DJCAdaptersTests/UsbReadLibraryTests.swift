import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// `UsbRead.library`(실제 엔진): 앱 사이드바가 합성 USB 폴더를 사본으로 읽어 두 형식을 합친다(USB에는 아무것도 쓰지 않는다).
/// 다시 본 볼륨 판정은 DJCApplicationTests `UsbReadFlowTests`(가짜 포트)
@Suite("USB 라이브러리 읽기(앱)")
struct UsbReadLibraryTests {
    func withUsb(_ configure: (inout UsbLibraryFixture) -> Void = { _ in }, _ body: (UsbTreeFixture, URL) throws -> Void) throws {
        var usb = UsbLibraryFixture()
        configure(&usb)
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try usb.write(to: tree)
        let snapshots = FileManager.default.temporaryDirectory.appending(path: "djc-usblibrary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: snapshots) }
        try body(tree, snapshots)
    }

    func folders(_ snapshots: URL, _ key: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: snapshots.appending(path: key).path)) ?? []).sorted()
    }

    @Test("두 형식을 사본으로 읽어 합치고, USB 파일은 그대로 둔다")
    func readsBothFormats() throws {
        try withUsb { tree, snapshots in
            let before = tree.tree()
            let (library, mismatches) = try UsbRead.live.library(root: tree.base, snapshots: snapshots, volumeKey: "K1", volume: nil, now: Date())
            #expect(library.formats == UsbFormat.defaultSet)
            #expect(library.tracks.map(\.id) == [1, 2, 3])
            #expect(library.playlists.map(\.name) == ["시험 목록"])
            #expect(mismatches.isEmpty)
            #expect(tree.tree() == before)
            #expect(folders(snapshots, "K1").count == 1)
        }
        for formats: Set<UsbFormat> in [[.oneLibrary], [.deviceLibrary]] {
            try withUsb({ $0.formats = formats }) { tree, snapshots in
                let library = try UsbRead.live.library(root: tree.base, snapshots: snapshots, volumeKey: "K1", volume: nil, now: Date()).library
                #expect(library.formats == formats)
                #expect(library.tracks.count == 3)
            }
        }
    }

    @Test("사본 폴더는 볼륨마다 최근 것만 남긴다")
    func keepsRecentSnapshots() throws {
        try withUsb { tree, snapshots in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            for index in 0..<4 {
                _ = try UsbRead.live.library(root: tree.base, snapshots: snapshots, volumeKey: "K2", volume: nil,
                                        now: start.addingTimeInterval(Double(index)), keep: 2)
            }
            // 같은 시각에 다시 읽어도 새 폴더를 쓴다
            _ = try UsbRead.live.library(root: tree.base, snapshots: snapshots, volumeKey: "K2", volume: nil,
                                    now: start.addingTimeInterval(3), keep: 2)
            let kept = folders(snapshots, "K2")
            #expect(kept.count == 2)
            #expect(kept.allSatisfy { $0.hasPrefix("20270115T080003") })
        }
    }

    @Test("잘못된 볼륨키는 사본 폴더를 만들지 않고, 실물 USB는 등록 없이 읽는다")
    func refusalCreatesNothing() throws {
        try withUsb { tree, snapshots in
            for key in ["", "..", "a/b"] {
                #expect(throws: UsbError.self) {
                    _ = try UsbRead.live.library(root: tree.base, snapshots: snapshots, volumeKey: key, volume: nil, now: Date())
                }
            }
            #expect(!FileManager.default.fileExists(atPath: snapshots.path))
            let physical = FakeUsbVolume.physicalFAT32()
            let library = try UsbRead.live.library(root: tree.base, snapshots: snapshots, volumeKey: "K3", volume: physical, now: Date()).library
            #expect(library.tracks.count == 3)
        }
        // 라이브러리가 없는 USB는 읽을 것이 없다
        let empty = UsbTreeFixture()
        defer { empty.remove() }
        empty.mkdir("PIONEER/rekordbox")
        let snapshots = FileManager.default.temporaryDirectory.appending(path: "djc-usblibrary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: snapshots) }
        #expect(throws: UsbError.self) {
            _ = try UsbRead.live.library(root: empty.base, snapshots: snapshots, volumeKey: "K4", volume: nil, now: Date())
        }
        #expect(folders(snapshots, "K4").isEmpty)
    }
}
