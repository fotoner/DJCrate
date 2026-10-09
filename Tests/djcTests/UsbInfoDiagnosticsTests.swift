import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

@Suite("USB 정보 음원·설정 진단")
struct UsbInfoDiagnosticsTests {
    func body(_ info: UsbInfo) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
    }

    func settings(_ info: UsbInfo) throws -> [[String: Any]] {
        try #require(try body(info)["settings"] as? [[String: Any]])
    }

    @Test("기존 v1 JSON도 새 진단의 기본값으로 읽는다")
    func legacyV1DecodesDefaults() throws {
        var legacy = try body(UsbInfo(root: "/synthetic"))
        legacy.removeValue(forKey: "media")
        legacy.removeValue(forKey: "settings")
        let decoded = try JSONDecoder().decode(UsbInfo.self, from: JSONSerialization.data(withJSONObject: legacy))
        let encoded = try body(decoded)
        #expect(encoded["schemaVersion"] as? Int == 1)
        #expect(encoded["media"] as? [String: Int] == ["tracksChecked": 0, "filesChecked": 0, "missingFiles": 0])
        #expect((encoded["settings"] as? [Any])?.isEmpty == true)
    }

    @Test("두 형식의 같은 음원은 한 번 세며 합성 바이트도 존재로 판정한다")
    func mediaPresenceAndMissing() throws {
        let helper = UsbInfoTests()
        try helper.withUsb { tree in
            let present = try #require(try body(helper.info(tree))["media"] as? [String: Int])
            #expect(present == ["tracksChecked": 3, "filesChecked": 3, "missingFiles": 0])
            try FileManager.default.removeItem(at: tree.url(String(UsbLibraryFixture.trackPath(2).dropFirst())))
            let before = tree.tree()
            let result = try helper.info(tree)
            let missing = try #require(try body(result)["media"] as? [String: Int])
            #expect(missing == ["tracksChecked": 3, "filesChecked": 3, "missingFiles": 1])
            #expect(result.warnings.map(\.code) == ["mediaMissing"])
            #expect(result.warnings.first?.message == "음원 파일이 없는 곡이 있으므로 rekordbox로 USB를 다시 내보내세요")
            #expect(tree.tree() == before)
            let text = UsbCommands.infoLines(result).joined(separator: "\n")
            #expect(text.contains("음원: 곡 3 · 파일 3 · 없는 파일 1"))
            for secret in ["test2", "시험 아티스트", "Contents", tree.base.path] { #expect(!text.contains(secret)) }
        }
    }

    @Test("음원 경로의 링크·폴더·상위 탈출·금지 경로는 열지 않고 누락으로 센다")
    func unsafeMediaReferencesMissing() throws {
        let tree = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { tree.remove(); outside.remove() }
        outside.write("audio.mp3", "synthetic outside")
        tree.mkdir("Contents/folder.mp3")
        tree.mkdir("Contents")
        try FileManager.default.createSymbolicLink(at: tree.url("Contents/link.mp3"), withDestinationURL: outside.url("audio.mp3"))
        try FileManager.default.createSymbolicLink(at: tree.url("Contents/linked"), withDestinationURL: outside.base)
        var export = PdbBuilder(kind: .export)
        let paths = ["/Contents/link.mp3", "/Contents/folder.mp3", "/Contents/linked/audio.mp3", "/../audio.mp3",
                     "/PIONEER/extracted/audio.mp3", "/PIONEER/CDP/audio.mp3", "/PIONEER/djprofile.nxs", ""]
        for (index, path) in paths.enumerated() {
            var track = PdbTrackSpec(id: index + 1)
            track[.filePath] = path
            export.add(.tracks, PdbBuilder.trackRow(track))
        }
        tree.write(UsbLayout.exportPdb, export.build().data)
        let before = outside.tree()
        let result = try UsbInfoTests().info(tree)
        let media = try #require(try body(result)["media"] as? [String: Int])
        #expect(media == ["tracksChecked": paths.count, "filesChecked": paths.count, "missingFiles": paths.count])
        #expect(outside.tree() == before)
    }

    @Test("설정 파일이 없는 것은 오류가 아니며 null 키를 유지한다")
    func missingSettingsAreOptional() throws {
        try UsbInfoTests().withUsb { tree in
            let result = try UsbInfoTests().info(tree)
            let files = try settings(result)
            #expect(files.compactMap { $0["fileName"] as? String } == DeviceSettingFile.Kind.allCases.map(\.fileName))
            #expect(files.allSatisfy { $0["status"] as? String == "missing" && $0["issue"] is NSNull && $0["crcOK"] is NSNull })
            #expect(result.warnings.isEmpty)
        }
    }

    @Test("라이브러리 DB가 없어도 알려진 설정 파일의 형식과 CRC를 진단한다")
    func settingsWithoutDatabase() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        for kind in DeviceSettingFile.Kind.allCases {
            tree.write("PIONEER/" + kind.fileName, DeviceSettingFixture.make(kind))
        }
        let before = tree.tree()
        let result = try UsbInfoTests().info(tree)
        let files = try settings(result)
        #expect(result.formats.isEmpty)
        #expect(files.allSatisfy { $0["status"] as? String == "valid" && $0["crcOK"] as? Bool == true && $0["issue"] is NSNull })
        #expect(result.warnings.isEmpty && tree.tree() == before)
        let text = UsbCommands.infoLines(result).joined(separator: "\n")
        #expect(text.contains("MYSETTING.DAT: 형식·CRC 확인"))
        #expect(!text.contains("SYNTHBRAND") && !text.contains("9.876"))
    }

    @Test("설정 파일 구조 오류와 CRC 오류는 고정 code로 구분한다")
    func invalidSettingsReported() throws {
        let cases: [(DeviceSettingFile.Kind, Data, String, Bool?)] = [
            (.mySetting, Data([1, 2, 3]), "wrongSize", nil),
            (.mySetting, DeviceSettingFixture.make(.mySetting, stringsLength: 0), "wrongStringsLength", true),
            (.mySetting2, DeviceSettingFixture.make(.mySetting2, dataLength: 999), "wrongDataLength", true),
            (.djmMySetting, DeviceSettingFixture.make(.djmMySetting, trailer: 1), "trailerNotZero", true),
            (.devSetting, DeviceSettingFixture.make(.devSetting, crc: 0), "crcMismatch", false),
        ]
        for (kind, data, issue, crcOK) in cases {
            let tree = UsbTreeFixture()
            defer { tree.remove() }
            tree.write("PIONEER/" + kind.fileName, data)
            let result = try UsbInfoTests().info(tree)
            let file = try #require(try settings(result).first { $0["fileName"] as? String == kind.fileName })
            #expect(file["status"] as? String == "invalid" && file["issue"] as? String == issue)
            #expect(file["crcOK"] as? Bool == crcOK)
            if crcOK == nil { #expect(file["crcOK"] is NSNull) }
            #expect(result.warnings.map(\.code) == ["settingsInvalid"])
            #expect(result.warnings.first?.message == "설정 파일을 확인하지 못했으므로 rekordbox에서 기기 설정을 다시 저장한 뒤 USB로 내보내세요")
            #expect(UsbCommands.infoLines(result).contains { $0.contains(kind.fileName) && $0.contains(issue) })
        }
    }

    @Test("설정 파일이나 상위 폴더의 링크·일반 파일이 아닌 경로는 읽지 않는다")
    func unsafeSettingsUnreadable() throws {
        let outside = UsbTreeFixture()
        defer { outside.remove() }
        for kind in DeviceSettingFile.Kind.allCases { outside.write(kind.fileName, DeviceSettingFixture.make(kind)) }
        let before = outside.tree()
        for linkParent in [false, true] {
            let tree = UsbTreeFixture()
            defer { tree.remove() }
            if linkParent {
                try FileManager.default.createSymbolicLink(at: tree.url("PIONEER"), withDestinationURL: outside.base)
            } else {
                tree.mkdir("PIONEER")
                try FileManager.default.createSymbolicLink(at: tree.url("PIONEER/MYSETTING.DAT"), withDestinationURL: outside.url("MYSETTING.DAT"))
                tree.mkdir("PIONEER/MYSETTING2.DAT")
            }
            let result = try UsbInfoTests().info(tree)
            let files = try settings(result)
            let checked = linkParent ? files : Array(files.prefix(2))
            #expect(checked.allSatisfy { $0["status"] as? String == "unreadable" && $0["crcOK"] is NSNull })
            #expect(result.warnings.map(\.code) == ["settingsInvalid"])
        }
        #expect(outside.tree() == before)
    }

    @Test("CLI 진단 JSON의 키·상태·오류 code는 언어에 따라 바뀌지 않는다")
    func commandDiagnosticsAcrossLocales() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write("PIONEER/MYSETTING.DAT", DeviceSettingFixture.make(.mySetting, crc: 0))
        let helper = UsbInfoTests()
        var reference: NSDictionary?
        for language in ["ko", "en", "ja"] {
            let output = try helper.run(["usb-info", tree.base.path, "--json"], language: language)
            #expect(output.status == 0)
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
            let data = try #require(envelope["data"] as? [String: Any])
            let part = NSDictionary(dictionary: ["media": try #require(data["media"]), "settings": try #require(data["settings"])])
            if let reference { #expect(part == reference) } else { reference = part }
            let warnings = try #require(data["warnings"] as? [[String: Any]])
            #expect(warnings.compactMap { $0["code"] as? String } == ["settingsInvalid"])
            let text = try helper.run(["usb-info", tree.base.path], language: language)
            #expect(text.status == 0)
            let summary = switch language {
            case "en": "Settings file MYSETTING.DAT: Format or CRC error"
            case "ja": "設定ファイル MYSETTING.DAT: 形式またはCRCのエラー"
            default: "설정 파일 MYSETTING.DAT: 형식 또는 CRC 오류"
            }
            #expect(text.stdout.contains(summary))
        }
    }
}
