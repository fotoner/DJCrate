import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// `usb-info`의 Device Library 왕복 검사(읽기 → 모델 → 다시 쓰기 → 다시 읽기). 합성 pdb만 쓴다.
@Suite("USB 정보 왕복 검사")
struct UsbInfoRoundTripTests {
    static func info(_ tree: UsbTreeFixture) throws -> UsbInfo {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "djc-usbinfo-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try UsbRead.testing().info(root: tree.base, scratch: scratch, volume: nil)
    }

    /// 작성기(`PdbWriter`)로 만든 합성 Device Library
    static func writerTree() throws -> UsbTreeFixture {
        let fixture = try UsbExportFixture()
        try fixture.addTrack(id: "101", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
        try fixture.addTrack(id: "102", artist: ("2", "다른 아티스트"))
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: ["101", "102"]))
        let files = try PdbWriter.files(build.model.library, mode: .fresh)
        let tree = UsbTreeFixture()
        tree.write(UsbLayout.exportPdb, files.export)
        tree.write(UsbLayout.exportExtPdb, files.exportExt)
        return tree
    }

    @Test("작성기로 만든 pdb는 왕복 검사를 통과한다")
    func usbInfoRoundTripFilled() throws {
        let tree = try Self.writerTree()
        defer { tree.remove() }
        let result = try Self.info(tree)
        let part = try #require(result.deviceLibrary)
        #expect(part.roundTripChecked)
        #expect(part.roundTripOK == true)
        #expect(!result.warnings.contains { $0.code == "pdbRoundTripFailed" })
    }

    @Test("트랙 상수 칸이 관찰값과 다른 pdb는 왕복 실패로 경고한다(문제 수만, 값·경로 없이)")
    func roundTripFailureWarned() throws {
        var export = PdbBuilder(kind: .export)
        for id in [1, 2] {
            var spec = PdbTrackSpec(id: id)
            spec[.filePath] = "/Contents/합성/곡\(id).mp3"
            spec[.fileName] = "곡\(id).mp3"
            spec[.title] = "합성 제목 \(id)"
            if id == 2 { spec.bitmask = 0x000C_0701 }
            export.add(.tracks, PdbBuilder.trackRow(spec))
        }
        export.add(.history19, PdbBuilder.propertyRow(count: 2, date: "2026-01-03"))
        var ext = PdbBuilder(kind: .exportExt)
        ext.add(.myTagProperty, PdbBuilder.myTagPropertyRow(masterDBID: 4_242))
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write(UsbLayout.exportPdb, export.build().data)
        tree.write(UsbLayout.exportExtPdb, ext.build().data)

        let result = try Self.info(tree)
        let part = try #require(result.deviceLibrary)
        #expect(part.roundTripChecked)
        #expect(part.roundTripOK == false)
        let warning = try #require(result.warnings.first { $0.code == "pdbRoundTripFailed" })
        for secret in ["합성", "곡1", "Contents"] { #expect(!warning.message.contains(secret)) }
        let problems = try PdbRoundTrip.check(export: export.build().data, exportExt: ext.build().data)
        #expect(!problems.isEmpty)
        #expect(warning.message.contains("(문제 \(problems.count)개)"))
    }

    @Test("Device Library에 My Tag 연결이 있으면 다시 쓸 수 없어 왕복 실패로 경고한다")
    func myTagLinksRoundTripWarned() throws {
        let usb = UsbLibraryFixture()
        #expect(!usb.myTagLinks.isEmpty)
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try usb.write(to: tree)
        let result = try Self.info(tree)
        let part = try #require(result.deviceLibrary)
        #expect(part.roundTripChecked && part.roundTripOK == false)
        #expect(result.warnings.map(\.code) == ["pdbRoundTripFailed"])
    }

    @Test("JSON 키는 v1 그대로(왕복 칸은 pdb가 있으면 늘 채움)")
    func jsonKeysUnchanged() throws {
        let tree = try Self.writerTree()
        defer { tree.remove() }
        let data = try ReadJSON.encode(command: "usb-info", data: try Self.info(tree))
        let body = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any])
        #expect(body["schemaVersion"] as? Int == 1)
        let part = try #require(body["deviceLibrary"] as? [String: Any])
        #expect(Set(part.keys) == ["exportFlag10", "extFlag10", "roundTripChecked", "roundTripOK", "tracks", "playlists", "historyRows",
                                   "unknownTableRows", "structureIssues"])
        #expect(part["roundTripChecked"] as? Bool == true && part["roundTripOK"] as? Bool == true)
        #expect(Set(body.keys) == ["schemaVersion", "root", "formats", "volume", "oneLibrary", "deviceLibrary", "consistency", "analysis",
                                   "media", "settings", "localCompatibility", "warnings"])
    }
}
