import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 로컬 모양 합성 분석 파일 → USB 분석 파일. 형식 규칙은 rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
@Suite("USB 분석 파일 변환")
struct UsbAnlzTransformTests {
    let path = "/Contents/시험 아티스트/시험 앨범/시험 곡.mp3"

    /// 메모리 2개 · 핫 A · 핫 E(8박 루프)
    var cues: [UsbCueInput] {
        [UsbCueInput(id: "m1", kind: 0, inMsec: 1_000, comment: "도입", createdAtRaw: "2026-01-01 00:00:01.000 +00:00"),
         UsbCueInput(id: "m2", kind: 0, inMsec: 9_000, createdAtRaw: "2026-01-01 00:00:02.000 +00:00"),
         UsbCueInput(id: "a", kind: 1, inMsec: 500, colorTableIndex: 0, createdAtRaw: "2026-01-01 00:00:03.000 +00:00"),
         UsbCueInput(id: "e", kind: 6, inMsec: 4_000, outMsec: 7_750, beatLoopSize: 8 << 16 | 1,
                     createdAtRaw: "2026-01-01 00:00:04.000 +00:00")]
    }

    func transform(dat: Data = AnlzBuilder.localDAT(), ext: Data = AnlzBuilder.localEXT(),
                   twoEx: Data? = AnlzBuilder.local2EX(pvdi: true), cues: [UsbCueInput]? = nil, fileType: Int = 1) throws -> UsbAnlzResult {
        try UsbAnlzTransform.transform(localDAT: dat, localEXT: ext, local2EX: twoEx, contentsPath: path,
                                       cues: cues ?? self.cues, fileType: fileType)
    }

    func names(_ data: Data) throws -> [String] { try AnlzFile(data: data).tags.map(\.fourcc) }

    func inserting(_ tag: Data, into file: Data, at index: Int) throws -> Data {
        var anlz = try AnlzFile(data: file)
        anlz.tags.insert(AnlzFile.Tag(fourcc: String(decoding: tag.prefix(4), as: UTF8.self), bytes: tag), at: index)
        return anlz.serialized()
    }

    func kind(_ tag: AnlzFile.Tag) -> UInt32 { AnlzFile.u32([UInt8](tag.bytes), 12) }

    @Test("경로·큐·PSSI·PVDI 말고는 태그 바이트와 순서가 같고 파일 길이는 다시 적는다")
    func onlyExpectedTagsChange() throws {
        let localDAT = AnlzBuilder.localDAT(), localEXT = AnlzBuilder.localEXT(pssiMood: 2)
        let local2EX = AnlzBuilder.local2EX(pvdi: true)
        let result = try transform(dat: localDAT, ext: localEXT, twoEx: local2EX)
        let layout = UsbCuePlacement.layout(cues)
        let ppth = AnlzPathTag.encode(path)

        for (local, usb) in [(localDAT, result.dat), (localEXT, result.ext), (local2EX, try #require(result.twoEx))] {
            let before = try AnlzFile(data: local), after = try AnlzFile(data: usb)
            #expect(after.tags.map(\.fourcc) == before.tags.map(\.fourcc))
            #expect(after.header.subdata(in: 12..<28) == before.header.subdata(in: 12..<28))
            #expect(AnlzFile.u32([UInt8](usb), 8) == UInt32(usb.count))
            for (old, new) in zip(before.tags, after.tags) {
                switch old.fourcc {
                case "PPTH": #expect(new.bytes == ppth)
                case "PCOB", "PCO2", "PSSI", "PVDI": continue
                default: #expect(new.bytes == old.bytes, "\(old.fourcc)")
                }
            }
        }
        let dat = try AnlzFile(data: result.dat).tags.filter { $0.fourcc == "PCOB" }
        #expect(dat.map(\.bytes) == [AnlzCueTags.pcob(kind: 1, cues: layout.datHot), AnlzCueTags.pcob(kind: 0, cues: layout.datMemory)])
        let ext = try AnlzFile(data: result.ext)
        #expect(ext.tags.filter { $0.fourcc == "PCOB" }.map(\.bytes)
            == [AnlzCueTags.pcob(kind: 1, cues: layout.extHot), AnlzCueTags.pcob(kind: 0, cues: [])])
        #expect(ext.tags.filter { $0.fourcc == "PCO2" }.map(\.bytes)
            == [AnlzCueTags.pco2(kind: 1, cues: layout.extAllHot, fileType: 1), AnlzCueTags.pco2(kind: 0, cues: layout.extAllMemory, fileType: 1)])
        #expect(ext.tag("PSSI")?.bytes == AnlzMasks.maskPSSI(try #require(AnlzFile(data: localEXT).tag("PSSI")).bytes))
        let twoEx = try AnlzFile(data: try #require(result.twoEx))
        #expect(twoEx.tag("PVDI")?.bytes == AnlzMasks.maskPVDI(try #require(AnlzFile(data: local2EX).tag("PVDI")).bytes))
        #expect(result.warnings.isEmpty)
    }

    @Test("로컬 큐 태그 순서가 달라도 목록 종류(0x0C)로 핫·메모리를 가린다")
    func cueTagsMatchedByListKind() throws {
        var dat = try AnlzFile(data: AnlzBuilder.localDAT())
        let hotIndex = try #require(dat.tags.firstIndex { $0.fourcc == "PCOB" })
        dat.tags.swapAt(hotIndex, hotIndex + 1)
        let result = try transform(dat: dat.serialized())
        let pcob = try AnlzFile(data: result.dat).tags.filter { $0.fourcc == "PCOB" }
        #expect(pcob.map(kind) == [0, 1])
        #expect(pcob[0].bytes == AnlzCueTags.pcob(kind: 0, cues: UsbCuePlacement.layout(cues).datMemory))
    }

    @Test("빈 PQT2는 빼고 비지 않은 PQT2는 그대로")
    func emptyPQT2Removed_nonEmptyKept() throws {
        let empty = try transform(ext: AnlzBuilder.localEXT(pqt2Empty: true))
        #expect(try !names(empty.ext).contains("PQT2"))
        #expect(try names(empty.ext) == ["PPTH", "PWV3", "PCOB", "PCOB", "PCO2", "PCO2", "PWV5", "PWV4", "PSSI"])
        let localEXT = AnlzBuilder.localEXT(pqt2Empty: false)
        let kept = try transform(ext: localEXT)
        #expect(try AnlzFile(data: kept.ext).tag("PQT2")?.bytes == AnlzFile(data: localEXT).tag("PQT2")?.bytes)
        // 길이는 56이지만 머리가 빈 모양이 아닌 PQT2는 그대로 둔다
        var odd = try AnlzFile(data: AnlzBuilder.localEXT(pqt2Empty: true))
        let index = try #require(odd.tags.firstIndex { $0.fourcc == "PQT2" })
        var bytes = [UInt8](odd.tags[index].bytes)
        bytes[40] = 1
        odd.tags[index].bytes = Data(bytes)
        #expect(try names(transform(ext: odd.serialized()).ext).contains("PQT2"))
    }

    @Test("이미 마스크된 로컬 PSSI는 빼고 경고")
    func maskedLocalPSSIDroppedWithWarning() throws {
        let result = try transform(ext: AnlzBuilder.localEXT(pssiMood: 0x77))
        #expect(try !names(result.ext).contains("PSSI"))
        #expect(result.warnings == [UsbAnlzWarning.maskedLocalPSSIDropped.rawValue])
        let none = try transform(ext: AnlzBuilder.localEXT(pssiMood: nil))
        #expect(try !names(none.ext).contains("PSSI"))
        #expect(none.warnings.isEmpty)
    }

    @Test("로컬에 PVDI가 없으면 빈 PVDI를 .2EX 끝에 붙인다")
    func missingPVDIAppendsEmpty() throws {
        let result = try transform(twoEx: AnlzBuilder.local2EX(pvdi: false))
        let twoEx = try AnlzFile(data: try #require(result.twoEx))
        #expect(twoEx.tags.map(\.fourcc) == ["PPTH", "PWV7", "PWV6", "PWVC", "PVDI"])
        #expect(twoEx.tags.last?.bytes == AnlzMasks.emptyPVDI)
    }

    @Test("이미 마스크된 로컬 PVDI는 그대로 두고 경고")
    func maskedLocalPVDIKept() throws {
        var local = try AnlzFile(data: AnlzBuilder.local2EX(pvdi: true))
        let index = try #require(local.tags.firstIndex { $0.fourcc == "PVDI" })
        local.tags[index].bytes = AnlzMasks.maskPVDI(local.tags[index].bytes)
        let result = try transform(twoEx: local.serialized())
        #expect(try AnlzFile(data: try #require(result.twoEx)).tag("PVDI")?.bytes == local.tags[index].bytes)
        #expect(result.warnings == [UsbAnlzWarning.maskedLocalPVDIKept.rawValue])
    }

    /// PVDI 태그를 바꿔 넣은 로컬 .2EX(PVDI 뒤에 태그를 하나 더 두어 자리가 지켜지는지 본다)
    func local2EX(pvdi: Data) throws -> Data {
        var local = try AnlzFile(data: AnlzBuilder.local2EX(pvdi: true))
        let index = try #require(local.tags.firstIndex { $0.fourcc == "PVDI" })
        local.tags[index].bytes = pvdi
        local.tags.append(AnlzFile.Tag(fourcc: "PXYZ", bytes: AnlzBuilder.unknownTag(fourcc: "PXYZ")))
        return local.serialized()
    }

    @Test("평문도 마스크된 것도 아닌 로컬 PVDI(모르는 플래그·짧은 태그)는 옮기지 않고 그 자리에 빈 PVDI, 경고")
    func unknownLocalPVDIReplacedWithEmpty() throws {
        var flagged = [UInt8](AnlzBuilder.pvdi(bodyBytes: 40))
        flagged[12] = 0x01
        var short = [UInt8](AnlzBuilder.pvdi(bodyBytes: 0).prefix(20))
        short.replaceSubrange(8..<12, with: [0, 0, 0, 20])
        for bytes in [flagged, short] {
            let result = try transform(twoEx: try local2EX(pvdi: Data(bytes)))
            let twoEx = try AnlzFile(data: try #require(result.twoEx))
            #expect(twoEx.tags.map(\.fourcc) == ["PPTH", "PWV7", "PWV6", "PWVC", "PVDI", "PXYZ"])
            #expect(twoEx.tag("PVDI")?.bytes == AnlzMasks.emptyPVDI)
            #expect(result.warnings == [UsbAnlzWarning.unknownLocalPVDIDropped.rawValue])
        }
    }

    @Test("거부 이유는 무엇이 없는지 한국어 문장으로 적는다")
    func refusalReasons() throws {
        func reason(_ body: () throws -> Void) -> String? {
            do { try body() } catch let DJCError.invalidAnalysisFile(reason) { return reason } catch { return "\(error)" }
            return nil
        }
        let share = FileManager.default.temporaryDirectory.appending(path: "djc-usb-anlz-\(UUID().uuidString)")
        #expect(reason { _ = try UsbAnlzTransform.readLocal(share: share, analysisDataPath: "") } == "분석 파일 경로(AnalysisDataPath)가 없음")
        #expect(reason { _ = try UsbAnlzTransform.readLocal(share: share, analysisDataPath: "/PIONEER/USBANLZ/none/ANLZ0000.DAT") }
            == "로컬 분석 파일(.DAT)을 읽지 못함")
        var noPath = try AnlzFile(data: AnlzBuilder.localEXT())
        noPath.tags.removeAll { $0.fourcc == "PPTH" }
        #expect(reason { _ = try transform(ext: noPath.serialized()) } == "로컬 .EXT에 경로(PPTH)가 없음")
    }

    @Test("모르는 태그는 자리와 바이트 그대로")
    func unknownTagPreserved() throws {
        let unknown = AnlzBuilder.unknownTag(fourcc: "PXYZ")
        let dat = try inserting(unknown, into: AnlzBuilder.localDAT(), at: 3)
        let ext = try inserting(unknown, into: AnlzBuilder.localEXT(), at: 2)
        let twoEx = try inserting(unknown, into: AnlzBuilder.local2EX(pvdi: true), at: 4)
        let result = try transform(dat: dat, ext: ext, twoEx: twoEx)
        #expect(try AnlzFile(data: result.dat).tags[3].bytes == unknown)
        #expect(try AnlzFile(data: result.ext).tags[2].bytes == unknown)
        #expect(try AnlzFile(data: try #require(result.twoEx)).tags[4].bytes == unknown)
        #expect(try names(result.dat) == names(dat))
    }

    @Test("PVB2는 바이트 그대로")
    func pvb2Preserved() throws {
        let local = AnlzBuilder.localEXT(pssiMood: nil, pvb2: true)
        let result = try transform(ext: local, fileType: 5)
        #expect(try names(result.ext) == names(local))
        #expect(try AnlzFile(data: result.ext).tag("PVB2")?.bytes == AnlzFile(data: local).tag("PVB2")?.bytes)
    }

    @Test(".3EX는 만들지 않고, 로컬 .2EX가 없으면 .2EX도 없다")
    func no3EX() throws {
        let result = try transform()
        #expect(Mirror(reflecting: result).children.compactMap(\.label) == ["dat", "ext", "twoEx", "rules", "warnings"])
        #expect(try transform(twoEx: nil).twoEx == nil)
    }

    @Test("로컬 분석 파일 이름이 ANLZ0000이 아니어도 AnalysisDataPath대로 읽는다")
    func localANLZ0001NameAccepted() throws {
        let share = FileManager.default.temporaryDirectory.appending(path: "djc-usb-anlz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: share) }
        let folder = share.appending(path: "PIONEER/USBANLZ/abc/0000-1111/")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dat = AnlzBuilder.localDAT(), ext = AnlzBuilder.localEXT()
        try dat.write(to: folder.appending(path: "ANLZ0001.DAT"))
        try ext.write(to: folder.appending(path: "ANLZ0001.EXT"))
        let analysisPath = "/PIONEER/USBANLZ/abc/0000-1111/ANLZ0001.DAT"

        let files = UsbAnlzTransform.localFiles(share: share, analysisDataPath: analysisPath)
        #expect(files?.ext.lastPathComponent == "ANLZ0001.EXT" && files?.twoEx.lastPathComponent == "ANLZ0001.2EX")
        let local = try UsbAnlzTransform.readLocal(share: share, analysisDataPath: analysisPath)
        #expect(local.dat == dat && local.ext == ext && local.twoEx == nil)
        #expect(try transform(dat: local.dat, ext: local.ext, twoEx: local.twoEx).twoEx == nil)

        let twoEx = AnlzBuilder.local2EX(pvdi: false)
        try twoEx.write(to: folder.appending(path: "ANLZ0001.2EX"))
        #expect(try UsbAnlzTransform.readLocal(share: share, analysisDataPath: analysisPath).twoEx == twoEx)

        #expect(UsbAnlzTransform.localFiles(share: share, analysisDataPath: "") == nil)
        #expect(throws: DJCError.self) { try UsbAnlzTransform.readLocal(share: share, analysisDataPath: "") }
        #expect(throws: DJCError.self) { try UsbAnlzTransform.readLocal(share: share, analysisDataPath: "/PIONEER/USBANLZ/none/ANLZ0000.DAT") }
        try FileManager.default.removeItem(at: folder.appending(path: "ANLZ0001.EXT"))
        #expect(throws: DJCError.self) { try UsbAnlzTransform.readLocal(share: share, analysisDataPath: analysisPath) }
    }

    @Test("규칙 표시는 큐 모양 분류 그대로")
    func rulesFromCueTraits() throws {
        #expect(try transform().rules.isEmpty)
        let colored = [UsbCueInput(id: "c", kind: 1, inMsec: 100, colorTableIndex: 4, createdAtRaw: "2026-01-01 00:00:00 +00:00")]
        #expect(try transform(cues: colored).rules == [.cueVariant])
        #expect(try transform(cues: cues, fileType: 11).rules == [.cueSeekFields])
        #expect(try transform(cues: [], fileType: 11).rules.isEmpty)
    }

    @Test("Kind 4·풀 수 없는 created_at은 경고")
    func cueWarnings() throws {
        let odd = cues + [UsbCueInput(id: "x", kind: 4, inMsec: 100, createdAtRaw: "2026-01-01 00:00:00 +00:00"),
                          UsbCueInput(id: "y", kind: 0, inMsec: 200, createdAtRaw: "어제")]
        let result = try transform(cues: odd)
        #expect(result.warnings == [UsbAnlzWarning.cueKindDropped.rawValue, UsbAnlzWarning.cueCreatedAtUnparsed.rawValue])
        let hot = try AnlzCueTags.decodePCO2(try #require(AnlzFile(data: result.ext).tags.first { $0.fourcc == "PCO2" }).bytes)
        #expect(hot.entries.count == 2)
    }

    @Test("큐가 있는 목록의 로컬 큐 태그가 없으면 경고, 경로 태그가 없으면 거부")
    func missingLocalTags() throws {
        var dat = try AnlzFile(data: AnlzBuilder.localDAT())
        dat.tags.removeAll { $0.fourcc == "PCOB" && kind($0) == 0 }
        let result = try transform(dat: dat.serialized())
        #expect(result.warnings == [UsbAnlzWarning.cueTagMissing.rawValue])
        #expect(try transform(dat: dat.serialized(), cues: []).warnings.isEmpty)

        var noPath = try AnlzFile(data: AnlzBuilder.localEXT())
        noPath.tags.removeAll { $0.fourcc == "PPTH" }
        #expect(throws: DJCError.self) { try transform(ext: noPath.serialized()) }
        #expect(throws: DJCError.self) { try transform(dat: Data("PMAI".utf8)) }
    }
}
