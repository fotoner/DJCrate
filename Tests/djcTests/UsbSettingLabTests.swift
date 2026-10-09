import RekordboxFixtures
@testable import djc
import DJCDomain
import Foundation
import RekordboxKit
import Testing

@Suite("USB 설정 파일 실험")
struct UsbSettingLabTests {
    /// 임시 폴더 하나를 만들고 끝나면 지운다.
    func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-setting-lab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    func withFolderAsync(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-setting-lab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    /// 지어낸 로컬 설정 파일 셋(MYSETTING2는 새 칸이 0인 옛 모양)
    func writeLocalFiles(in folder: URL) throws {
        var body = DeviceSettingFixture.syntheticBody(count: 40, seed: 5)
        body[0x6D - 0x68] = 0
        body[0x6E - 0x68] = 0
        try DeviceSettingFixture.write(DeviceSettingFixture.make(.mySetting), as: .mySetting, in: folder)
        try DeviceSettingFixture.write(DeviceSettingFixture.make(.mySetting2, body: body), as: .mySetting2, in: folder)
        try DeviceSettingFixture.write(DeviceSettingFixture.make(.djmMySetting), as: .djmMySetting, in: folder)
    }

    func refusal(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let UsbError.pathRefused(_, reason) {
            return reason
        } catch {
            return "other: \(error)"
        }
    }

    @Test("setting-export --out이 임시 폴더 밖이면 읽기 전에 거부한다")
    func labOutputOutsideScratchRejected() throws {
        try withFolder { local in
            try writeLocalFiles(in: local)
            #expect(refusal { _ = try UsbSettingLab.export(local: local.path, out: "/Volumes/x") } == "outsideScratch")
            #expect(refusal { _ = try UsbSettingLab.export(local: local.path, out: NSHomeDirectory()) } == "outsideScratch")
            let never = NSHomeDirectory() + "/djc-never-created-\(UUID().uuidString)"
            #expect(refusal { _ = try UsbSettingLab.export(local: local.path, out: never) } == "outsideScratch")
            #expect(!FileManager.default.fileExists(atPath: never))
        }
    }

    @Test("setting-export --out은 비어 있거나 없는 폴더만")
    func labOutputMustBeEmpty() throws {
        try withFolder { folder in
            let local = folder.appending(path: "local"), out = folder.appending(path: "out")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            try writeLocalFiles(in: local)
            try Data("x".utf8).write(to: out.appending(path: "keep"))
            #expect(refusal { _ = try UsbSettingLab.export(local: local.path, out: out.path) } == "notEmpty")
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["keep"])
        }
    }

    @Test("setting-check는 임시 폴더 밖 폴더를 읽지 않는다")
    func labCheckOutsideScratchRejected() {
        #expect(refusal { _ = try UsbSettingLab.check(folder: NSHomeDirectory()) } == "outsideScratch")
        #expect(refusal { _ = try UsbSettingLab.check(folder: "/Volumes") } == "outsideScratch")
    }

    @Test("로컬 세 파일을 옮기면 MYSETTING2의 새 칸만 채우고, setting-check가 셋 다 맞다고 본다")
    func exportThenCheck() throws {
        try withFolder { folder in
            let local = folder.appending(path: "local"), out = folder.appending(path: "out")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            try writeLocalFiles(in: local)
            // 폴더를 훑지 않는다: 다른 파일은 옮기지 않는다.
            try DeviceSettingFixture.write(DeviceSettingFixture.make(.devSetting), as: .devSetting, in: local)
            try Data("profile".utf8).write(to: local.appending(path: "djprofile.nxs"))

            let exported = try UsbSettingLab.export(local: local.path, out: out.path)
            let lines = exported.lines
            #expect(lines.count == 3 && exported.made == 3)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
                == ["MYSETTING.DAT", "MYSETTING2.DAT", "DJMMYSETTING.DAT"])
            for kind in [DeviceSettingFile.Kind.mySetting, .djmMySetting] {
                #expect(try Data(contentsOf: out.appending(path: kind.fileName)) == Data(contentsOf: local.appending(path: kind.fileName)))
            }
            let my2 = try Data(contentsOf: out.appending(path: "MYSETTING2.DAT"))
            #expect(my2[0x6D] == 0x80 && my2[0x6E] == 0x80)
            #expect(lines.contains { $0.hasPrefix("MYSETTING2.DAT") && $0.contains("0x6D") && $0.contains("0x6E") })

            let result = try UsbSettingLab.check(folder: out.path)
            #expect(result.crcMatched == 3 && result.valid == 3)
            #expect(result.lines.last == "CRC 3/3 맞음")
        }
    }

    @Test("setting-check는 없는 파일·어긋난 파일을 따로 적는다")
    func checkReportsProblems() throws {
        try withFolder { folder in
            try DeviceSettingFixture.write(DeviceSettingFixture.make(.mySetting), as: .mySetting, in: folder)
            try DeviceSettingFixture.write(DeviceSettingFixture.make(.djmMySetting, crc: 0x0001), as: .djmMySetting, in: folder)
            let result = try UsbSettingLab.check(folder: folder.path)
            #expect(result.crcMatched == 1 && result.valid == 1)
            #expect(result.lines.last == "CRC 1/3 맞음")
            #expect(result.lines.contains { $0.hasPrefix("MYSETTING2.DAT") && $0.contains("없음") })
            #expect(result.lines.contains { $0.hasPrefix("DJMMYSETTING.DAT") && $0.contains("CRC") })
        }
    }

    @Test("로컬 파일이 검증에 실패하면 그 파일은 만들지 않고, 명령은 실패로 끝난다")
    func exportSkipsInvalidLocalFile() async throws {
        try await withFolderAsync { folder in
            let local = folder.appending(path: "local"), out = folder.appending(path: "out")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            try writeLocalFiles(in: local)
            try DeviceSettingFixture.write(DeviceSettingFixture.make(.mySetting, size: 150), as: .mySetting, in: local)
            let result = try UsbSettingLab.export(local: local.path, out: out.path)
            #expect(result.made == 2)
            #expect(!FileManager.default.fileExists(atPath: out.appending(path: "MYSETTING.DAT").path))
            #expect(result.lines.contains { $0.hasPrefix("MYSETTING.DAT") && $0.contains("만들지 않음") })
            #expect(FileManager.default.fileExists(atPath: out.appending(path: "MYSETTING2.DAT").path))

            // 명령으로 부르면 하나라도 못 만들었을 때 실패로 끝난다(스크립트가 성공으로 보지 않게).
            let again = folder.appending(path: "again")
            await #expect(throws: UsbSettingLab.ExportIncomplete(made: 2, total: 3)) {
                try await UsbSettingLab.exportCommand(["setting-export", "--local", local.path, "--out", again.path])
            }
        }
    }

    @Test("로컬 폴더가 틀리면 아무것도 만들지 않고, 만든 빈 출력 폴더도 남기지 않는다")
    func exportWithMissingLocalFolder() async throws {
        try await withFolderAsync { folder in
            let local = folder.appending(path: "nonexistent"), out = folder.appending(path: "out")
            let result = try UsbSettingLab.export(local: local.path, out: out.path)
            #expect(result.made == 0 && result.lines.count == 3)
            #expect(result.lines.allSatisfy { $0.contains("만들지 않음") && $0.contains("없음") })
            // 로컬 경로 전체를 출력에 적지 않는다.
            #expect(!result.lines.contains { $0.contains(local.path) })
            #expect(!FileManager.default.fileExists(atPath: out.path))

            await #expect(throws: UsbSettingLab.ExportIncomplete(made: 0, total: 3)) {
                try await UsbSettingLab.exportCommand(["setting-export", "--local", local.path, "--out", out.path])
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))

            // 이미 있던 빈 폴더는 지우지 않는다.
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            #expect(try UsbSettingLab.export(local: local.path, out: out.path).made == 0)
            #expect(FileManager.default.fileExists(atPath: out.path))
        }
    }
}
