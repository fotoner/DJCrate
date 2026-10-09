import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// Device Library만 있는 USB를 OneLibrary로 옮기는 세션(#46): 임시 폴더 USB(마운트 흉내, 디스크 이미지로 보이는 가짜 가드)에
/// 합성 Device Library(곡 1·2·3, 목록 10, My Tag, 그림 1·2·3)를 두고 쓴다. 맥 쪽 폴더(백업·저널·준비·사본)도 모두 임시 폴더다.
@Suite("USB OneLibrary로 옮기기 세션")
struct UsbMigrateSessionTests {
    final class Env {
        let usb = UsbChangeSetFixture()

        init(_ configure: (inout UsbLibraryFixture) -> Void = { _ in }) throws {
            var fixture = UsbLibraryFixture()
            fixture.formats = [.deviceLibrary]
            fixture.myTagLinks = []
            configure(&fixture)
            try fixture.write(to: UsbTreeFixture(base: usb.usbURL))
        }

        deinit { usb.remove() }

        var copies: URL { usb.home.appending(path: "usb-snapshots") }

        func session(fileSystem: FaultyUsbFileSystem? = nil, gate: UsbPhysicalWriteGate = FakeUsbVolume.gate()) -> UsbMigrateSession {
            UsbMigrateSession(root: usb.usbURL, guard: usb.writeGuard(gate: gate), paths: usb.paths,
                              engine: .live(fileSystem: fileSystem ?? usb.fileSystem()), device: .testing(), copies: copies)
        }

        func write(_ session: UsbMigrateSession? = nil, dryRun: Bool = false) throws -> (UsbMigrationResult, UsbWriteReport?) {
            try (session ?? self.session()).write(options: UsbWriteOptions(dryRun: dryRun), progress: { _ in }, isCancelled: { false })
        }

        /// 세션이 끝난 뒤 남은 USB DB 사본·준비 폴더
        var leftovers: [String] {
            let fm = FileManager.default
            return ((try? fm.contentsOfDirectory(atPath: copies.path)) ?? []) + ((try? fm.contentsOfDirectory(atPath: usb.paths.staging.path)) ?? [])
        }

        /// 지금 USB를 사본으로 떠서 읽은 두 형식
        func read() throws -> (oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?) {
            let folder = usb.folder.appending(path: "read-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let snapshot = try UsbSnapshot.take(root: usb.root, into: folder)
            return (try snapshot.oneLibrary.map { try OneLibraryReader.read(copyAt: $0) }, try PdbReader.read(snapshot: snapshot)?.0)
        }
    }

    static let added = Set([UsbLayout.oneLibrary] + (1...3).flatMap { ["PIONEER/Artwork/00001/b\($0).jpg", "PIONEER/Artwork/00001/b\($0)_m.jpg"] })

    @Test("옮기면 exportLibrary.db와 b 그림만 더하고 원래 파일은 바이트까지 그대로이며 두 형식이 맞게 읽힌다")
    func writeAddsOneLibraryOnly() throws {
        let env = try Env()
        let before = env.usb.tree()
        let (result, report) = try env.write()
        #expect(report?.outcome == .written && result.blocks.isEmpty)
        #expect(result.trackCount == 3 && result.playlistCount == 1 && result.artworkFiles == 6)
        let after = env.usb.tree()
        #expect(before.allSatisfy { after[$0.key] == $0.value })
        #expect(Set(after.keys).subtracting(before.keys) == Self.added)
        #expect(env.usb.journal()?.state == .verified)
        let (oneLibrary, deviceLibrary) = try env.read()
        let ol = try #require(oneLibrary)
        #expect(ol.tracks.map(\.id) == [1, 2, 3] && ol.playlists.map { $0.entries[.oneLibrary] } == [[1, 2]])
        #expect(UsbLibrary.merge(oneLibrary: ol, deviceLibrary: deviceLibrary).1.isEmpty)
        #expect(env.leftovers.isEmpty)
        // 이제 OneLibrary가 있어 다시 옮기지 않는다
        let again = try env.session().preview(options: UsbWriteOptions())
        #expect(again.blocks.map(\.code) == ["oneLibraryExists"] && again.changes == nil)
    }

    @Test("옮긴 뒤 되돌리면 트리가 옮기기 전과 같다")
    func writeThenRestore() throws {
        let env = try Env()
        let before = env.usb.tree()
        _ = try env.write()
        let restored = try UsbWriter.restore(root: env.usb.root, paths: env.usb.paths, backup: nil, guard: env.usb.writeGuard(),
                                             fileSystem: env.usb.fileSystem())
        #expect(restored.outcome == .restored)
        #expect(env.usb.tree() == before)
    }

    @Test("미리 보기와 드라이 런은 USB에 쓰지 않는다")
    func previewAndDryRunDoNotWrite() throws {
        let env = try Env()
        let before = env.usb.tree()
        let preview = try env.session().preview(options: UsbWriteOptions())
        #expect(preview.blocks.isEmpty && preview.changes?.requiredRules.contains(.deviceLibraryMigration) == true)
        let (_, report) = try env.write(dryRun: true)
        #expect(report?.outcome == .dryRun && env.usb.journal()?.state == .dryRun)
        #expect(env.usb.tree() == before && env.leftovers.isEmpty)
        // 드라이 런 뒤에도 옮길 수 있다
        #expect(try env.write().1?.outcome == .written)
    }

    @Test("DB를 바꾸다 실패하면 되돌려 exportLibrary.db·b 그림이 남지 않는다")
    func failureRollsBack() throws {
        let env = try Env()
        let before = env.usb.tree()
        let failing = env.usb.fileSystem()
        failing.failAt = (operation: .rename, occurrence: 1, mode: .error)
        failing.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        let report = try? env.write(env.session(fileSystem: failing)).1
        #expect(report == nil || report?.outcome == .rolledBack)
        #expect(env.usb.journal()?.state == .rolledBack)
        #expect(env.usb.tree() == before)
    }

    @Test("이미 OneLibrary가 있는 USB는 막고 쓰지 않는다")
    func oneLibraryPresentRefused() throws {
        let env = try Env { $0.formats = UsbFormat.defaultSet }
        let before = env.usb.tree()
        #expect(throws: UsbError.self) { try env.write() }
        let preview = try env.session().preview(options: UsbWriteOptions())
        #expect(preview.blocks.map(\.code) == ["oneLibraryExists"])
        #expect(env.usb.tree() == before && env.leftovers.isEmpty)
    }
}
