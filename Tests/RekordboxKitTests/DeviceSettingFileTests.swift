import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("기기 설정 파일 읽기·검증")
struct DeviceSettingFileTests {
    typealias Kind = DeviceSettingFile.Kind

    func reason(_ data: Data, _ kind: Kind) -> DeviceSettingError? {
        do {
            _ = try DeviceSettingFile(kind: kind, bytes: data)
            return nil
        } catch let error as DeviceSettingError {
            return error
        } catch {
            Issue.record("다른 오류: \(error)")
            return nil
        }
    }

    @Test("종류별 크기와 CRC 범위: DJMMYSETTING만 파일 처음부터")
    func sizesAndRanges() throws {
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
        #expect(Kind.mySetting.size == 148)
        #expect(Kind.mySetting2.size == 148)
        #expect(Kind.djmMySetting.size == 160)
        #expect(Kind.devSetting.size == 140)
        #expect(Kind.allCases.filter(\.crcIncludesHeader) == [.djmMySetting])

        for kind in Kind.allCases {
            let data = DeviceSettingFixture.make(kind)
            let file = try DeviceSettingFile(kind: kind, bytes: data)
            #expect(file.bytes == data)
            #expect(file.body.count == DeviceSettingFixture.layout(kind).size - 0x68 - 4)
            #expect(file.brand == "SYNTHBRAND" && file.software == "synthsoft" && file.version == "9.876")
        }

        // 머리 바이트를 바꾸면 DJMMYSETTING만 CRC가 어긋난다.
        for kind in Kind.allCases {
            var data = DeviceSettingFixture.make(kind)
            data[0x44] ^= 0x01
            if kind.crcIncludesHeader {
                guard case .crcMismatch = reason(data, kind) else { Issue.record("\(kind): 머리를 고쳤는데 CRC가 맞음"); continue }
            } else {
                #expect(reason(data, kind) == nil, "\(kind): 본문만 CRC에 든다")
            }
        }

        // 범위를 바꿔 계산한 CRC는 받지 않는다.
        let body = DeviceSettingFixture.syntheticBody(count: 40)
        let myWithFullCRC = DeviceSettingFixture.make(.mySetting, body: body)
        let fullCRC = CRC16XModem.checksum(myWithFullCRC.prefix(148 - 4))
        guard case .crcMismatch = reason(DeviceSettingFixture.make(.mySetting, body: body, crc: fullCRC), .mySetting) else {
            Issue.record("MYSETTING이 파일 처음부터 계산한 CRC를 받음"); return
        }
        let djmBody = DeviceSettingFixture.syntheticBody(count: 52)
        let bodyCRC = CRC16XModem.checksum(djmBody)
        guard case .crcMismatch = reason(DeviceSettingFixture.make(.djmMySetting, body: djmBody, crc: bodyCRC), .djmMySetting) else {
            Issue.record("DJMMYSETTING이 본문만 계산한 CRC를 받음"); return
        }
    }

    @Test("크기·길이 칸·CRC·끝 2바이트가 하나라도 어긋나면 읽지 않는다")
    func rejectsWrongSizeLengthCRC() {
        #expect(reason(DeviceSettingFixture.make(.mySetting, size: 147), .mySetting) == .wrongSize(expected: 148, actual: 147))
        #expect(reason(DeviceSettingFixture.make(.mySetting2, size: 152), .mySetting2) == .wrongSize(expected: 148, actual: 152))
        #expect(reason(Data(), .djmMySetting) == .wrongSize(expected: 160, actual: 0))
        // 다른 종류의 파일을 이 종류로 읽지 않는다.
        #expect(reason(DeviceSettingFixture.make(.djmMySetting), .mySetting) == .wrongSize(expected: 148, actual: 160))

        #expect(reason(DeviceSettingFixture.make(.mySetting, stringsLength: 0x61), .mySetting) == .wrongStringsLength(0x61))
        #expect(reason(DeviceSettingFixture.make(.djmMySetting, dataLength: 40), .djmMySetting) == .wrongDataLength(expected: 52, actual: 40))

        let good = DeviceSettingFixture.make(.mySetting2)
        let stored = UInt16(good[144]) | UInt16(good[145]) << 8
        #expect(reason(DeviceSettingFixture.make(.mySetting2, crc: stored ^ 0x0100), .mySetting2)
            == .crcMismatch(stored: stored ^ 0x0100, computed: stored))
        var flipped = good
        flipped[0x70] ^= 0x10
        guard case .crcMismatch = reason(flipped, .mySetting2) else { Issue.record("본문을 고쳤는데 CRC가 맞음"); return }

        #expect(reason(DeviceSettingFixture.make(.devSetting, trailer: 1), .devSetting) == .trailerNotZero(1))
    }

    @Test("CRC 짝: 끝에 적힌 값과 종류별 범위로 계산한 값")
    func crcPair() throws {
        let data = DeviceSettingFixture.make(.djmMySetting)
        let pair = try #require(DeviceSettingFile.crcPair(kind: .djmMySetting, bytes: data))
        #expect(pair.stored == pair.computed)
        #expect(pair.computed == CRC16XModem.checksum(data.prefix(156)))
        #expect(DeviceSettingFile.crcPair(kind: .mySetting, bytes: Data(count: 0x6B)) == nil)
        // 조각(Data slice)도 처음부터 센다.
        let slice = (Data([0xAA, 0xBB]) + data).dropFirst(2)
        #expect(DeviceSettingFile.crcPair(kind: .djmMySetting, bytes: slice)?.computed == pair.computed)
        #expect(try DeviceSettingFile(kind: .djmMySetting, bytes: slice).bytes == data)
    }

    @Test("알려진 칸은 제 종류의 파일에서만 읽는다")
    func knownFields() throws {
        var body = DeviceSettingFixture.syntheticBody(count: 40)
        body[0x72 - 0x68] = 0x81
        body[0x80 - 0x68] = 0x83
        body[0x81 - 0x68] = 0x80
        let my = try DeviceSettingFile(kind: .mySetting, bytes: DeviceSettingFixture.make(.mySetting, body: body))
        #expect(my.value(.quantize) == 0x81)
        #expect(my.value(.quantizeBeatValue) == 0x83)
        #expect(my.value(.hotcueAutoload) == 0x80)
        #expect(my.value(.beatJumpBeatValue) == nil)
        #expect(my.value(.beatFxQuantize) == nil)

        var djmBody = DeviceSettingFixture.syntheticBody(count: 52)
        djmBody[0x78 - 0x68] = 0x82
        let djm = try DeviceSettingFile(kind: .djmMySetting, bytes: DeviceSettingFixture.make(.djmMySetting, body: djmBody))
        #expect(djm.value(.beatFxQuantize) == 0x82)
        #expect(DeviceSettingField.all.allSatisfy { $0.offset >= 0x68 && $0.offset < $0.kind.size - 4 })
    }

    @Test("머리 문자열은 첫 0 바이트까지")
    func headerStringsStopAtNul() throws {
        var data = DeviceSettingFixture.make(.mySetting, brand: "AB")
        data[0x04 + 5] = 0x7A // 0 뒤의 모르는 바이트
        let file = try DeviceSettingFile(kind: .mySetting, bytes: data)
        #expect(file.brand == "AB")
    }

    @Test("파일 이름으로 종류를 찾는다(대소문자 그대로)")
    func kindFromFileName() {
        #expect(Kind(fileName: "MYSETTING.DAT") == .mySetting)
        #expect(Kind(fileName: "MYSETTING2.DAT") == .mySetting2)
        #expect(Kind(fileName: "DJMMYSETTING.DAT") == .djmMySetting)
        #expect(Kind(fileName: "DEVSETTING.DAT") == .devSetting)
        #expect(Kind(fileName: "mysetting.dat") == nil)
        #expect(Kind(fileName: "djprofile.nxs") == nil)
        #expect(Kind.exported == [.mySetting, .mySetting2, .djmMySetting])
    }

    @Test("오류 설명은 칸과 값을 적는다")
    func errorDescriptions() {
        let errors: [DeviceSettingError] = [
            .wrongSize(expected: 148, actual: 147), .wrongStringsLength(0x61), .wrongDataLength(expected: 40, actual: 41),
            .crcMismatch(stored: 0x1234, computed: 0xABCD), .trailerNotZero(1), .notExported(fileName: "DEVSETTING.DAT"),
        ]
        let texts = errors.map(\.description)
        #expect(Set(texts).count == errors.count)
        #expect(texts[3].contains("0x1234") && texts[3].contains("0xABCD"))
        #expect(texts[5].contains("DEVSETTING.DAT"))
    }
}
