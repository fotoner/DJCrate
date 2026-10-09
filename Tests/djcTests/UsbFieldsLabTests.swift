import RekordboxFixtures
@testable import djc
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit
import Testing

@Suite("USB 리더 칸 해시(외부 파서 대조용)")
struct UsbFieldsLabTests {
    func run(_ arguments: [String]) throws -> (Int32, String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-labhome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["lab"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["DJC_HOME": home.path, "DJC_LANG": "ko"]) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// 정규형 해시는 외부 비교기(Python)와 같아야 한다. 상수는 `sha256(정규형 UTF-8)` 앞 16자를 따로 계산한 값이다(`scripts/usb-parser-compare.py`의 `SELF_CHECK`·`digest`)
    @Test func canonicalHashMatchesDocumentedForm() {
        #expect(UsbFieldsLab.hash("s:시험 곡 1") == "e7918c99dd3a6fb6")
        #expect(UsbFieldsLab.canonical(12800 as Int) == "i:12800")
        #expect(UsbFieldsLab.canonical(Int64(12800)) == "i:12800")
        #expect(UsbFieldsLab.canonical(UInt16(12800)) == "i:12800")
        #expect(UsbFieldsLab.canonical(true) == "b:1")
        #expect(UsbFieldsLab.canonical([1, 2]) == "l:1,2")
        #expect(UsbFieldsLab.canonical("") == "s:")
        // NFC로 바꾸지 않는다(외부 파서가 읽은 바이트 그대로 견준다)
        #expect(UsbFieldsLab.canonical("e\u{301}") == "s:e\u{301}")
    }

    @Test func writesHashesAndStructureWithoutValues() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        var fixture = UsbLibraryFixture()
        fixture.pdbHistoryEntries = [1]
        try fixture.write(to: tree)
        let before = tree.tree()
        let out = FileManager.default.temporaryDirectory.appending(path: "djc-usbfields-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }

        let (status, output) = try run(["usb-fields", tree.base.path, "--out", out.path])
        #expect(status == 0, "\(output)")
        let text = try String(contentsOf: out, encoding: .utf8)
        for value in ["시험", "Contents/", "test1.mp3", "USBANLZ"] {
            #expect(!output.contains(value))
            #expect(!text.contains(value))
        }
        #expect(tree.tree() == before)

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        #expect(json["hash"] as? String == "sha256:16")
        let device = try #require(json["deviceLibrary"] as? [String: Any])
        let deviceTables = try #require(device["tables"] as? [String: [String: [String: String]]])
        #expect(deviceTables["tracks"]?.count == 3)
        #expect(deviceTables["tracks"]?["1"]?["title"] == "e7918c99dd3a6fb6")
        #expect(deviceTables["trackRowExtras"]?["1"]?["u7"] == UsbFieldsLab.hash("i:3"))
        #expect(deviceTables["histories"]?.count == 1)
        #expect(deviceTables["property"]?["0"]?["numberOfContents"] == UsbFieldsLab.hash("i:3"))
        let files = try #require(device["files"] as? [String: [String: Any]])
        let export = try #require(files["export.pdb"])
        let header = try #require(export["header"] as? [String: Any])
        #expect(header["numTables"] as? Int == 20)
        let exportTables = try #require(export["tables"] as? [[String: Any]])
        #expect(exportTables.count == 20)
        let tracksTable = try #require(exportTables.first { $0["type"] as? Int == 0 })
        let pages = try #require(tracksTable["pages"] as? [[String: Any]])
        // 인덱스 쪽과 데이터 쪽, 데이터 쪽의 산 행 오프셋
        #expect(pages.first?["isIndex"] as? Bool == true)
        #expect(pages.dropFirst().flatMap { $0["liveOffsets"] as? [Int] ?? [] }.count == 3)
        #expect((files["exportExt.pdb"]?["tables"] as? [[String: Any]])?.count == 9)

        let one = try #require(json["oneLibrary"] as? [String: Any])
        let oneTables = try #require(one["tables"] as? [String: [String: [String: String]]])
        #expect(oneTables["tracks"]?["1"]?["title"] == "e7918c99dd3a6fb6")
        #expect(oneTables["myTagLinks"]?["8:1"] != nil)
        #expect(output.contains("Device Library") && output.contains("OneLibrary"))
    }

    @Test func refusesOutputOutsideScratchOrExisting() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try UsbLibraryFixture().write(to: tree)
        let (outside, outsideOutput) = try run(["usb-fields", tree.base.path, "--out", "/etc/djc-usb-fields.json"])
        #expect(outside != 0)
        #expect(outsideOutput.contains("outsideScratch"))
        let existing = tree.url("already.json")
        tree.write("already.json", "{}")
        let (status, output) = try run(["usb-fields", tree.base.path, "--out", existing.path])
        #expect(status != 0)
        #expect(output.contains("exists"))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "{}")
        let (usage, usageOutput) = try run(["usb-fields", tree.base.path])
        #expect(usage == 0)
        #expect(usageOutput.contains("사용법"))
    }
}
