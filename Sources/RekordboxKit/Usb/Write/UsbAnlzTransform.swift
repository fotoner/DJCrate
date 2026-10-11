import DJCDomain
import Foundation

/// 로컬 분석 파일 세 개를 USB에 쓸 바이트로 바꾼 결과. `.3EX`는 만들지 않는다.
public struct UsbAnlzResult: Sendable {
    public var dat: Data
    public var ext: Data
    /// 로컬 .2EX가 없으면 nil(막는 것은 계획 몫)
    public var twoEx: Data?
    /// 큐 모양에 필요한 확인 안 된 규칙
    public var rules: Set<UsbProvisionalRule>
    /// `UsbAnlzWarning`의 rawValue(계획 보고에서 문구로 바꾼다)
    public var warnings: [String]
}

/// 변환하며 남기는 경고. rawValue는 계획 보고가 문구를 고르는 열쇠라 바꾸지 않는다.
public enum UsbAnlzWarning: String, CaseIterable, Sendable {
    /// 핫큐 번호가 없는 큐(Kind 4 등)를 뺐다
    case cueKindDropped
    /// created_at을 시각으로 풀지 못해 글자로 순서를 정했다
    case cueCreatedAtUnparsed
    /// 큐를 넣을 로컬 큐 태그가 없어 그 목록을 쓰지 못했다
    case cueTagMissing
    /// 로컬 PSSI가 이미 마스크된 모양이라 USB에서 뺐다
    case maskedLocalPSSIDropped
    /// 로컬 PVDI가 이미 마스크된 모양(플래그 0x80)이라 그대로 옮겼다
    case maskedLocalPVDIKept
    /// 로컬 PVDI가 평문도 마스크된 것도 아닌 모양(모르는 플래그·짧은 태그)이라 옮기지 않고 그 자리에 빈 PVDI를 두었다
    case unknownLocalPVDIDropped
}

/// 로컬 분석 파일 → USB 분석 파일. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기).
/// 태그 순서는 로컬 그대로 두고, 태그마다:
/// - 모든 파일의 PPTH는 USB 경로로 새로
/// - .DAT PCOB 둘, .EXT PCOB 둘·PCO2 둘은 djmdCue로 새로(목록 종류는 태그 0x0C로 가린다)
/// - .EXT PSSI는 평문이면 마스크, 이미 마스크된 것이면 빼고 경고. 빈 PQT2는 뺀다
/// - .2EX PVDI는 평문이면 마스크, 이미 마스크된 것이면 그대로, 모르는 모양이면 그 자리에 빈 PVDI. 없으면 빈 PVDI를 끝에 붙인다
/// - 그 밖(파형·박자·탐색표·모르는 태그)은 바이트 그대로
public enum UsbAnlzTransform {
    public static func transform(localDAT: Data, localEXT: Data, local2EX: Data?, contentsPath: String,
                                 cues: [UsbCueInput], fileType: Int) throws -> UsbAnlzResult {
        let layout = UsbCuePlacement.layout(cues)
        var warnings: [UsbAnlzWarning] = []
        if !layout.dropped.isEmpty { warnings.append(.cueKindDropped) }
        if cues.contains(where: { $0.createdAt == nil }) { warnings.append(.cueCreatedAtUnparsed) }
        let ppth = AnlzPathTag.encode(contentsPath)

        let dat = try rewrite(localDAT, name: "DAT", ppth: ppth, warnings: &warnings, expectedCueTags: [
            CueSlot(fourcc: "PCOB", kind: AnlzCueTags.hotList, cues: layout.datHot),
            CueSlot(fourcc: "PCOB", kind: AnlzCueTags.memoryList, cues: layout.datMemory),
        ], fileType: fileType) { _, _ in nil }

        let ext = try rewrite(localEXT, name: "EXT", ppth: ppth, warnings: &warnings, expectedCueTags: [
            CueSlot(fourcc: "PCOB", kind: AnlzCueTags.hotList, cues: layout.extHot),
            CueSlot(fourcc: "PCOB", kind: AnlzCueTags.memoryList, cues: layout.extMemory),
            CueSlot(fourcc: "PCO2", kind: AnlzCueTags.hotList, cues: layout.extAllHot),
            CueSlot(fourcc: "PCO2", kind: AnlzCueTags.memoryList, cues: layout.extAllMemory),
        ], fileType: fileType) { tag, warnings in
            switch tag.fourcc {
            case "PSSI":
                if let mood = AnlzMasks.pssiMood(tag.bytes), (1...3).contains(mood) { return .replace(AnlzMasks.maskPSSI(tag.bytes)) }
                warnings.append(.maskedLocalPSSIDropped)
                return .drop
            case "PQT2" where isEmptyPQT2(tag.bytes):
                return .drop
            default:
                return nil
            }
        }

        let twoEx = try local2EX.map { local in
            var sawPVDI = false
            var file = try rewrite(local, name: "2EX", ppth: ppth, warnings: &warnings, expectedCueTags: [], fileType: fileType) { tag, warnings in
                guard tag.fourcc == "PVDI" else { return nil }
                sawPVDI = true
                if AnlzMasks.isPlainPVDI(tag.bytes) { return .replace(AnlzMasks.maskPVDI(tag.bytes)) }
                if AnlzMasks.isMaskedPVDI(tag.bytes) {
                    // 로컬에서 본 적 없는 모양이다. 새로 만들 수 없어 그대로 옮긴다.
                    warnings.append(.maskedLocalPVDIKept)
                    return .keep
                }
                // 평문도 마스크된 것도 아니면 마스크를 씌울 수도, 그대로 옮길 수도 없다. 로컬에 PVDI가 없는 곡처럼 빈 PVDI를 두되
                // 태그 순서는 지키려고 그 자리에 둔다.
                warnings.append(.unknownLocalPVDIDropped)
                return .replace(AnlzMasks.emptyPVDI)
            }
            if !sawPVDI {
                var anlz = try AnlzFile(data: file)
                anlz.tags.append(AnlzFile.Tag(fourcc: "PVDI", bytes: AnlzMasks.emptyPVDI))
                file = anlz.serialized()
            }
            return file
        }

        return UsbAnlzResult(dat: dat, ext: ext, twoEx: twoEx,
                             rules: UsbCueRules.rules(fileType: fileType, cues: cues.map(\.traits)),
                             warnings: warnings.map(\.rawValue))
    }

    /// 로컬 분석 파일 자리: `share + AnalysisDataPath`에서 확장자만 바꾼다(파일 이름이 ANLZ0000이 아닐 수 있다).
    public static func localFiles(share: URL, analysisDataPath: String) -> (dat: URL, ext: URL, twoEx: URL)? {
        guard let dat = RekordboxShare.analysisURL(analysisDataPath, root: share) else { return nil }
        let base = dat.deletingPathExtension()
        return (dat, base.appendingPathExtension("EXT"), base.appendingPathExtension("2EX"))
    }

    /// 로컬 분석 파일을 읽기만 한다. .DAT·.EXT가 없으면 던지고, .2EX가 없으면 nil.
    public static func readLocal(share: URL, analysisDataPath: String) throws -> (dat: Data, ext: Data, twoEx: Data?) {
        guard let files = localFiles(share: share, analysisDataPath: analysisDataPath) else {
            throw DJCError.invalidAnalysisFile(String(ui: "분석 파일 경로(AnalysisDataPath)가 없음"))
        }
        func read(_ url: URL) throws -> Data {
            do { return try Data(contentsOf: url) } catch {
                throw DJCError.invalidAnalysisFile(String(ui: "로컬 분석 파일(.\(url.pathExtension))을 읽지 못함"))
            }
        }
        let twoEx = FileManager.default.fileExists(atPath: files.twoEx.path) ? try read(files.twoEx) : nil
        return (try read(files.dat), try read(files.ext), twoEx)
    }

    // MARK: - 태그 고쳐 쓰기

    struct CueSlot {
        var fourcc: String
        var kind: UInt32
        var cues: [UsbCueInput]
    }

    enum Action {
        case keep, drop
        case replace(Data)
    }

    /// 태그를 순서대로 돌며 새 목록을 만든다(`AnlzFile.replace`는 같은 이름 첫 태그만 바꿔 쓰지 않는다).
    /// `other`가 nil을 돌려주면 PPTH·큐 태그만 바꾸고 나머지는 그대로 둔다.
    static func rewrite(_ data: Data, name: String, ppth: Data, warnings: inout [UsbAnlzWarning], expectedCueTags: [CueSlot],
                        fileType: Int, other: (AnlzFile.Tag, inout [UsbAnlzWarning]) -> Action?) throws -> Data {
        var file = try AnlzFile(data: data)
        guard file.tag("PPTH") != nil else { throw DJCError.invalidAnalysisFile(String(ui: "로컬 .\(name)에 경로(PPTH)가 없음")) }
        var filled = Set<Int>()
        var tags: [AnlzFile.Tag] = []
        for tag in file.tags {
            let action: Action
            if tag.fourcc == "PPTH" {
                action = .replace(ppth)
            } else if let slot = expectedCueTags.indices.first(where: { index in
                expectedCueTags[index].fourcc == tag.fourcc && tag.bytes.count >= 16
                    && AnlzFile.u32([UInt8](tag.bytes), 12) == expectedCueTags[index].kind && !filled.contains(index)
            }) {
                filled.insert(slot)
                let cueSlot = expectedCueTags[slot]
                action = .replace(cueSlot.fourcc == "PCOB"
                    ? AnlzCueTags.pcob(kind: cueSlot.kind, cues: cueSlot.cues)
                    : AnlzCueTags.pco2(kind: cueSlot.kind, cues: cueSlot.cues, fileType: fileType))
            } else {
                action = other(tag, &warnings) ?? .keep
            }
            switch action {
            case .keep: tags.append(tag)
            case .drop: continue
            case let .replace(bytes): tags.append(AnlzFile.Tag(fourcc: tag.fourcc, bytes: bytes))
            }
        }
        let missing = expectedCueTags.indices.filter { !filled.contains($0) && !expectedCueTags[$0].cues.isEmpty }
        if !missing.isEmpty && !warnings.contains(.cueTagMissing) { warnings.append(.cueTagMissing) }
        file.tags = tags
        return file.serialized()
    }

    /// 빈 PQT2: 길이 56, 0x0C부터 `00 00 00 00 01 00 00 02`, 나머지 0. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static let emptyPQT2Head: [UInt8] = [0, 0, 0, 0, 0x01, 0, 0, 0x02]

    static func isEmptyPQT2(_ tag: Data) -> Bool {
        let b = [UInt8](tag)
        guard b.count == 56, AnlzFile.u32(b, 8) == 56 else { return false }
        return Array(b[12..<20]) == emptyPQT2Head && b[20...].allSatisfy { $0 == 0 }
    }
}
