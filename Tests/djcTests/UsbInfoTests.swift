import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// `UsbRead.info`·`djc usb-info`: 합성 USB 폴더를 읽기만 한다(가짜 볼륨·시험이 만든 목록 상태만 쓴다)
@Suite("USB 정보")
struct UsbInfoTests {
    static let otherUUID = "00000000-0000-0000-0000-00000000BEEF"

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-usbinfo-\(UUID().uuidString)")
    }

    /// 합성 USB를 만들어 body에 넘기고 끝나면 지운다
    func withUsb(_ configure: (inout UsbLibraryFixture) -> Void = { _ in }, _ body: (UsbTreeFixture) throws -> Void) throws {
        var usb = UsbLibraryFixture()
        // Device Library의 My Tag 연결은 DJCrate가 다시 쓸 수 없어 왕복 경고가 난다(UsbInfoRoundTripTests가 따로 본다)
        usb.myTagLinks = []
        configure(&usb)
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try usb.write(to: tree)
        try body(tree)
    }

    func info(_ tree: UsbTreeFixture, volume: UsbVolumeInfo? = nil, appVersion: String? = "7.2.18") throws -> UsbInfo {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = try UsbRead.testing(appVersion: appVersion).info(root: tree.base, scratch: scratch, volume: volume)
        // 읽은 뒤 사본을 남기지 않는다
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        return result
    }

    // MARK: - 볼륨·목록

    @Test("실물 USB는 등록 없이 읽는다(볼륨 UUID가 없어도, exFAT·GPT도)")
    func physicalReadWithoutRegistration() throws {
        try withUsb { tree in
            let read = try info(tree, volume: FakeUsbVolume.physicalFAT32())
            #expect(read.volume?.isDiskImage == false && read.oneLibrary?.tracks == 3)
            #expect(read.volume?.writableForExport == true && read.volume?.writableForEdit == true)
            var noUUID = FakeUsbVolume.physicalFAT32()
            noUUID.volumeUUID = nil
            #expect(try info(tree, volume: noUUID).oneLibrary?.tracks == 3)
            for volume in [FakeUsbVolume.exfat(), FakeUsbVolume.gpt()] {
                let wider = try info(tree, volume: volume)
                #expect(wider.volume?.writableForExport == true && wider.volume?.writableForEdit == true)
            }
            let apfs = try info(tree, volume: FakeUsbVolume.apfs())
            #expect(apfs.oneLibrary?.tracks == 3)
            #expect(apfs.volume?.writableForExport == false && apfs.volume?.problems == ["unsupportedFileSystem"])
        }
    }

    /// info가 던진 readFailed detail(다른 오류면 기록)
    func readFailure(_ body: () throws -> UsbInfo) -> String? {
        do {
            _ = try body()
            return nil
        } catch let UsbError.readFailed(detail) {
            return detail
        } catch {
            Issue.record("다른 오류: \(error)")
            return "other"
        }
    }

    @Test func folderTargetMustBeOnStartupVolume() throws {
        try withUsb { tree in
            // 볼륨을 nil로 넘겨도 대상이 Mac 시동·데이터 볼륨 위가 아니면 읽지 않는다(볼륨 정보를 빠뜨리지 않게)
            let scratch = Self.scratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let before = tree.tree()
            let detail = readFailure {
                try UsbRead.testing(appVersion: nil, mountedOn: { _ in "/Volumes/DJCPHYS" }).info(root: tree.base, scratch: scratch, volume: nil)
            }
            #expect(detail == "volumeNotChecked")
            #expect(readFailure {
                try UsbRead.testing(appVersion: nil, mountedOn: { _ in nil }).info(root: tree.base, scratch: scratch, volume: nil)
            } == "volumeNotChecked")
            #expect(!FileManager.default.fileExists(atPath: scratch.path))
            #expect(tree.tree() == before)
            // Mac 데이터 볼륨의 폴더는 읽는다
            let read = try UsbRead.testing(appVersion: nil, mountedOn: { _ in "/System/Volumes/Data" })
                .info(root: tree.base, scratch: scratch, volume: nil)
            #expect(read.oneLibrary?.tracks == 3)
        }
    }

    @Test func nonEmptyScratchRefusedAndKept() throws {
        try withUsb { tree in
            // 사본 폴더에 이미 있던 것은 지우지 않는다(이 호출이 만든 것만 지운다)
            let scratch = Self.scratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let keep = scratch.appending(path: "db/keep")
            try FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: keep)
            #expect(readFailure {
                try UsbRead.testing(appVersion: nil).info(root: tree.base, scratch: scratch, volume: nil)
            } == "scratch not empty")
            #expect(FileManager.default.fileExists(atPath: keep.path))
            // USB 루트를 사본 폴더로 주어도 USB 안을 지우지 않는다
            tree.write("db/keep", "synthetic")
            let before = tree.tree()
            #expect(readFailure {
                try UsbRead.testing(appVersion: nil).info(root: tree.base, scratch: tree.base, volume: nil)
            } == "scratch not empty")
            #expect(tree.tree() == before)
            // 빈 사본 폴더는 받고, 폴더는 남긴 채 이 호출이 뜬 사본만 지운다
            let emptyScratch = Self.scratch()
            try FileManager.default.createDirectory(at: emptyScratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyScratch) }
            _ = try UsbRead.testing(appVersion: nil).info(root: tree.base, scratch: emptyScratch, volume: nil)
            #expect((try FileManager.default.contentsOfDirectory(atPath: emptyScratch.path)).isEmpty)
        }
    }

    @Test func subfolderOfPhysicalVolumeChecked() throws {
        try withUsb { tree in
            // 실물 볼륨 안 하위 폴더: statfs가 그 볼륨 마운트 지점을 돌려준다
            let volume = try #require(try UsbRead.testing(mountedOn: { _ in "/Volumes/DJCPHYS" }, volumeInfo: { _ in FakeUsbVolume.notMountPoint() })
                .volume(for: tree.base))
            let read = try info(tree, volume: volume)
            #expect(read.volume?.problems.contains("notMountPoint") == true)
            #expect(read.volume?.writableForExport == false)
            // 폴더 대상(Mac 데이터 볼륨)은 볼륨 정보를 보지 않는다
            for mount in ["/System/Volumes/Data", "/"] {
                let folder = try UsbRead.testing(mountedOn: { _ in mount }, volumeInfo: { _ in
                    Issue.record("폴더 대상에서 볼륨 정보를 읽었다")
                    return FakeUsbVolume.physicalFAT32()
                }).volume(for: tree.base)
                #expect(folder == nil)
            }
            // 마운트 지점을 모르면 읽지 않는다
            #expect(throws: UsbError.self) {
                try UsbRead.testing(mountedOn: { _ in nil }, volumeInfo: { _ in FakeUsbVolume.physicalFAT32() }).volume(for: tree.base)
            }
        }
    }

    @Test func folderTargetHasNoVolume() throws {
        try withUsb { (tree: UsbTreeFixture) in
            let volume = try UsbRead.testing().volume(for: tree.base)
            #expect(volume == nil)
            let read = try info(tree)
            #expect(read.volume == nil && read.oneLibrary?.tracks == 3)
        }
    }

    @Test func neverReadNotOpened() throws {
        try withUsb { tree in
            let locked = ["PIONEER/extracted", "PIONEER/CDP", "PIONEER/djprofile.nxs"]
            tree.write("PIONEER/extracted/a.bin", "synthetic")
            tree.write("PIONEER/CDP/b.bin", "synthetic")
            tree.write("PIONEER/djprofile.nxs", "synthetic")
            for path in locked { #expect(chmod(tree.url(path).path, 0) == 0) }
            defer { for path in locked { chmod(tree.url(path).path, 0o755) } }
            let result = try info(tree)
            #expect(result.oneLibrary?.tracks == 3 && result.deviceLibrary?.tracks == 3)
            #expect(result.warnings.isEmpty)
        }
    }

    @Test func sourceUnchanged() throws {
        try withUsb({ $0.oneLibraryWAL = true }) { tree in
            let before = tree.tree()
            _ = try info(tree)
            #expect(tree.tree() == before)
        }
    }

    // MARK: - 명령

    @Test func humanLinesHaveCountsWithoutTitlesOrPaths() throws {
        try withUsb({ $0.pdbFlag10 = 1 }) { tree in
            let lines = UsbCommands.infoLines(try info(tree, volume: FakeUsbVolume.diskImageFAT32()))
            let text = lines.joined(separator: "\n")
            #expect(text.contains("OneLibrary") && text.contains("Device Library"))
            #expect(lines.contains { $0.hasPrefix("OneLibrary: 곡 3") })
            #expect(lines.contains { $0.contains("rekordbox에 이 USB를 연결했다가") })
            for secret in ["시험 곡", "test1", "Contents", tree.base.path, "DJCTEST"] { #expect(!text.contains(secret)) }
        }
    }

    func run(_ arguments: [String], in directory: URL? = nil, language: String = "ko") throws -> (status: Int32, stdout: String, stderr: String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let home = Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.environment = ProcessInfo.processInfo.environment.merging(["DJC_HOME": home.path, "DJC_LANG": language]) { _, new in new }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile(), err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 사본은 DJC_HOME 안에 떴다가 지워진다
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: "usb-snapshots").path))?.isEmpty ?? true)
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    @Test func commandPrintsJSONAndText() throws {
        try withUsb { tree in
            let before = tree.tree()
            let json = try run(["usb-info", tree.base.path, "--json"])
            #expect(json.status == 0)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
            #expect(object["command"] as? String == "usb-info")
            #expect((object["data"] as? [String: Any])?["formats"] as? [String] == ["oneLibrary", "deviceLibrary"])
            #expect((object["data"] as? [String: Any])?["media"] as? [String: Int] == ["tracksChecked": 3, "filesChecked": 3, "missingFiles": 0])
            // root는 받은 경로를 절대 경로로 바꿔 그대로 적는다(볼륨이면 볼륨 이름이 들어갈 수 있다)
            #expect((object["data"] as? [String: Any])?["root"] as? String == tree.base.path)
            let relative = try run(["usb-info", tree.base.lastPathComponent, "--json"], in: tree.base.deletingLastPathComponent())
            let relativeRoot = ((try JSONSerialization.jsonObject(with: Data(relative.stdout.utf8)) as? [String: Any])?["data"]
                as? [String: Any])?["root"] as? String
            #expect(relativeRoot?.hasPrefix("/") == true && relativeRoot?.hasSuffix("/" + tree.base.lastPathComponent) == true)
            let text = try run(["usb-info", tree.base.path])
            #expect(text.status == 0)
            #expect(text.stdout.contains("OneLibrary: 곡 3"))
            #expect(text.stdout.contains("음원: 곡 3 · 파일 3 · 없는 파일 0"))
            #expect(!text.stdout.contains("시험 곡") && !text.stdout.contains("test1"))
            #expect(tree.tree() == before)

            let usage = try run(["usb-info"])
            #expect(usage.stdout.contains("usb-info"))
            let bad = try run(["usb-info", "--json"])
            #expect(bad.status == 1 && bad.stdout.isEmpty && bad.stderr.contains("invalid_arguments"))
            let missing = try run(["usb-info", tree.base.path + "/none", "--json"])
            #expect(missing.status == 1 && missing.stderr.contains("\"code\""))
        }
    }

    @Test func commandRefusesLiveLibrary() throws {
        let live = NSHomeDirectory() + "/Library/Pioneer/rekordbox"
        let result = try run(["usb-info", live])
        #expect(result.status == 1)
        #expect(result.stderr.contains("rekordbox 라이브러리나 DJCrate 데이터 폴더는 USB가 아닙니다"))
    }
}
