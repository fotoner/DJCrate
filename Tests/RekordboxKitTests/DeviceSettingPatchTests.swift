import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("기기 설정 파일 칸 패치")
struct DeviceSettingPatchTests {
    typealias Kind = DeviceSettingFile.Kind

    /// 두 파일에서 다른 바이트 위치
    func changedOffsets(_ a: Data, _ b: Data) -> Set<Int> {
        Set(zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset))
    }

    /// 새 칸이 0인 옛 모양의 MYSETTING2(지어낸 본문)
    func oldMySetting2(_ first: UInt8 = 0, _ second: UInt8 = 0) -> Data {
        var body = DeviceSettingFixture.syntheticBody(count: 40, seed: 3)
        body[0x6D - 0x68] = first
        body[0x6E - 0x68] = second
        return DeviceSettingFixture.make(.mySetting2, body: body)
    }

    @Test("MYSETTING2 내보내기는 새 칸 두 바이트와 CRC만 바꾼다")
    func patchChangesOnlyKnownBytes() throws {
        let source = oldMySetting2()
        let output = try #require(DeviceSettingPatch.forExport(try DeviceSettingFile(kind: .mySetting2, bytes: source)))
        #expect(output.bytes.count == source.count)
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
        #expect(output.bytes[0x6D] == 0x80 && output.bytes[0x6E] == 0x80)
        let changed = changedOffsets(source, output.bytes)
        #expect(changed.isSuperset(of: [0x6D, 0x6E]))
        #expect(changed.isSubset(of: [0x6D, 0x6E, 144, 145]))
        #expect(changed.count > 2, "CRC도 다시 계산")
        // 고친 파일은 다시 읽어도 검증을 통과한다.
        #expect(try DeviceSettingFile(kind: .mySetting2, bytes: output.bytes) == output)
        #expect(output.bytes == DeviceSettingFixture.resealed({
            var data = source
            data[0x6D] = 0x80
            data[0x6E] = 0x80
            return data
        }(), as: .mySetting2))
    }

    @Test("새 칸은 둘 다 0일 때만 채우고, 둘 다 0x80이면 그대로, 그 밖의 모양은 만들지 않는다")
    func patchFillsOnlyWhenBothZero() throws {
        let already = oldMySetting2(0x80, 0x80)
        #expect(DeviceSettingPatch.forExport(try DeviceSettingFile(kind: .mySetting2, bytes: already))?.bytes == already)

        // 확인하지 않은 모양은 한 바이트만 채워 새 모양을 만들지 않는다.
        for (first, second) in [(UInt8(0x81), UInt8(0)), (0, 0x80), (0x80, 0), (0x80, 0x81), (0x01, 0x01)] {
            let file = try DeviceSettingFile(kind: .mySetting2, bytes: oldMySetting2(first, second))
            #expect(DeviceSettingPatch.forExport(file) == nil, "\(first) \(second)")
            #expect(throws: DeviceSettingError.unconfirmedNewField(first, second)) {
                try DeviceSettingPatch.exportedFile(from: file)
            }
        }
    }

    @Test("MYSETTING·DJMMYSETTING은 바이트를 바꾸지 않는다(모르는 칸 그대로)")
    func unknownBytesPreserved() throws {
        for kind in [Kind.mySetting, .djmMySetting] {
            // 머리 문자열 칸의 0 뒤에도 모르는 바이트를 둔다.
            var data = DeviceSettingFixture.make(kind, body: DeviceSettingFixture.syntheticBody(count: kind.size - 0x6C, seed: 91))
            data[0x04 + 30] = 0x5A
            data[0x24 + 20] = 0xA5
            data = DeviceSettingFixture.resealed(data, as: kind)
            let output = try #require(DeviceSettingPatch.forExport(try DeviceSettingFile(kind: kind, bytes: data)))
            #expect(output.bytes == data, "\(kind)")
        }
        // MYSETTING2도 새 칸 밖의 바이트는 그대로다.
        let source = oldMySetting2()
        let output = try #require(DeviceSettingPatch.forExport(try DeviceSettingFile(kind: .mySetting2, bytes: source)))
        for offset in 0..<144 where offset != 0x6D && offset != 0x6E {
            #expect(output.bytes[offset] == source[offset], "0x\(String(offset, radix: 16))")
        }
    }

    @Test("DEVSETTING은 내보내기용으로 만들지 않는다")
    func devSettingNotExported() throws {
        let dev = try DeviceSettingFile(kind: .devSetting, bytes: DeviceSettingFixture.make(.devSetting))
        #expect(DeviceSettingPatch.forExport(dev) == nil)
        #expect(throws: DeviceSettingError.notExported(fileName: "DEVSETTING.DAT")) {
            try DeviceSettingPatch.exportedFile(from: dev)
        }
    }

    @Test("알려진 칸 한 바이트만 고치고 CRC를 다시 계산한다")
    func settingOneKnownField() throws {
        let source = DeviceSettingFixture.make(.mySetting)
        let file = try DeviceSettingFile(kind: .mySetting, bytes: source)
        let patched = try #require(DeviceSettingPatch.setting(.quantizeBeatValue, to: 0x82, in: file))
        #expect(patched.value(.quantizeBeatValue) == 0x82)
        #expect(changedOffsets(source, patched.bytes).isSubset(of: [0x80, 144, 145]))
        #expect(changedOffsets(source, patched.bytes).contains(0x80))
        #expect(try DeviceSettingFile(kind: .mySetting, bytes: patched.bytes) == patched)

        let djm = try DeviceSettingFile(kind: .djmMySetting, bytes: DeviceSettingFixture.make(.djmMySetting))
        let fx = try #require(DeviceSettingPatch.setting(.beatFxQuantize, to: 0x80, in: djm))
        #expect(fx.value(.beatFxQuantize) == 0x80)
        #expect(changedOffsets(djm.bytes, fx.bytes).isSubset(of: [0x78, 156, 157]))
        // 다른 종류의 칸은 고치지 않는다.
        #expect(DeviceSettingPatch.setting(.beatJumpBeatValue, to: 0x80, in: file) == nil)
    }

    @Test("로컬 파일은 세 이름만 열고, 검증에 실패하면 만들지 않는다")
    func forExportLocalFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try DeviceSettingFixture.write(oldMySetting2(), as: .mySetting2, in: folder)
        let output = try #require(DeviceSettingPatch.forExport(localFile: folder.appending(path: "MYSETTING2.DAT")))
        #expect(output[0x6D] == 0x80 && output[0x6E] == 0x80)
        let read = try DeviceSettingPatch.readForExport(localFile: folder.appending(path: "MYSETTING2.DAT"))
        #expect(read.source.bytes == oldMySetting2())
        #expect(read.output.bytes == output)

        // 이름이 세 파일 밖이면 올바른 파일이어도 만들지 않는다.
        try DeviceSettingFixture.write(DeviceSettingFixture.make(.devSetting), as: .devSetting, in: folder)
        #expect(DeviceSettingPatch.forExport(localFile: folder.appending(path: "DEVSETTING.DAT")) == nil)
        #expect(throws: DeviceSettingError.notExported(fileName: "DEVSETTING.DAT")) {
            try DeviceSettingPatch.readForExport(localFile: folder.appending(path: "DEVSETTING.DAT"))
        }
        try DeviceSettingFixture.make(.mySetting).write(to: folder.appending(path: "mysetting.dat.bak"))
        #expect(DeviceSettingPatch.forExport(localFile: folder.appending(path: "mysetting.dat.bak")) == nil)

        // 새 칸이 확인하지 않은 모양이면 만들지 않고 이유를 던진다.
        try DeviceSettingFixture.write(oldMySetting2(0x81, 0), as: .mySetting2, in: folder)
        #expect(DeviceSettingPatch.forExport(localFile: folder.appending(path: "MYSETTING2.DAT")) == nil)
        #expect(throws: DeviceSettingError.unconfirmedNewField(0x81, 0)) {
            try DeviceSettingPatch.readForExport(localFile: folder.appending(path: "MYSETTING2.DAT"))
        }

        // 없는 파일, 검증에 실패한 파일
        #expect(DeviceSettingPatch.forExport(localFile: folder.appending(path: "MYSETTING.DAT")) == nil)
        try DeviceSettingFixture.write(DeviceSettingFixture.make(.djmMySetting, trailer: 2), as: .djmMySetting, in: folder)
        #expect(DeviceSettingPatch.forExport(localFile: folder.appending(path: "DJMMYSETTING.DAT")) == nil)
        #expect(throws: DeviceSettingError.trailerNotZero(2)) {
            try DeviceSettingPatch.readForExport(localFile: folder.appending(path: "DJMMYSETTING.DAT"))
        }
    }
}
