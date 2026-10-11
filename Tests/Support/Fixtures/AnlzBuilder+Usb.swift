import Foundation
import RekordboxKit

/// 로컬 rekordbox share 모양의 합성 분석 파일(USB 변환 시험용). 파형·박자·프레이즈 값은 모두 지어낸 것이다.
/// 태그 순서는 로컬 rekordbox 7이 쓰는 순서를 따르고, 큐 태그는 로컬처럼 비어 있다.
extension AnlzBuilder {
    /// `.DAT`: PPTH · PVBR · PQTZ · PWAV · PWV2 · PCOB(핫, 빈) · PCOB(메모리, 빈)
    public static func localDAT(path: String = "?/시험.mp3",
                                beats: [BeatGridTags.Beat] = AnlzBuilder.beats(bpm: 128, first: 50, count: 16)) -> Data {
        localFile([ppth(path), opaque("PVBR", bytes: 1_608), BeatGridTags.pqtz(beats), opaque("PWAV", bytes: 408),
                   opaque("PWV2", bytes: 108), emptyPCOB(kind: 1), emptyPCOB(kind: 0)])
    }

    /// `.EXT`: PPTH · PWV3 · PCOB×2 · PCO2×2 · PQT2 · PWV5 · PWV4 · [PVB2] · [PSSI]
    /// - pssiMood: nil이면 PSSI 없음. 1…3이면 평문, 그 밖의 값은 이미 마스크된 것처럼 보인다.
    /// - pqt2Empty: 박 소수가 빈 PQT2(로컬에서 rekordbox가 쓰는 빈 모양)
    public static func localEXT(path: String = "?/시험.mp3", pssiMood: Int? = 2, entries: Int = 3, pqt2Empty: Bool = false,
                                pvb2: Bool = false, beats: [BeatGridTags.Beat] = AnlzBuilder.beats(bpm: 128, first: 50, count: 16)) -> Data {
        var tags = [ppth(path), opaque("PWV3", bytes: 3_000), emptyPCOB(kind: 1), emptyPCOB(kind: 0), emptyPCO2(kind: 1),
                    emptyPCO2(kind: 0), BeatGridTags.pqt2(pqt2Empty ? [] : beats, unknown: pqt2Empty ? 0 : 0x1234),
                    opaque("PWV5", bytes: 600), opaque("PWV4", bytes: 1_200)]
        if pvb2 { tags.append(opaque("PVB2", bytes: 8_020)) }
        if let pssiMood { tags.append(pssi(mood: pssiMood, entries: entries)) }
        return localFile(tags)
    }

    /// `.2EX`: PPTH · PWV7 · PWV6 · PWVC · [PVDI]
    public static func local2EX(path: String = "?/시험.mp3", pvdi: Bool) -> Data {
        var tags = [ppth(path), opaque("PWV7", bytes: 900), opaque("PWV6", bytes: 360), opaque("PWVC", bytes: 8)]
        if pvdi { tags.append(Self.pvdi(bodyBytes: 90)) }
        return localFile(tags)
    }

    /// 뜻을 모르는 태그(바이트 그대로 남는지 본다)
    public static func unknownTag(fourcc: String) -> Data { opaque(fourcc, bytes: 44) }

    /// 평문 PSSI: 머리 32바이트(항목 수 u16 @0x10, mood u16 @0x12, 끝 박 u16 @0x1A, 뱅크 u8 @0x1E) · 항목 24바이트씩
    public static func pssi(mood: Int, entries: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32 + 24 * entries)
        func put(_ value: Int, _ offset: Int, _ width: Int = 2) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (width - i - 1))) }
        }
        bytes.replaceSubrange(0..<4, with: "PSSI".utf8)
        put(32, 4, 4); put(bytes.count, 8, 4); put(24, 12, 4)
        put(entries, 0x10); put(mood, 0x12); put(1 + 16 * entries, 0x1A); bytes[0x1E] = 3
        for i in 0..<entries {
            let p = 32 + 24 * i
            put(i + 1, p); put(1 + 16 * i, p + 2); put(i % 3 + 1, p + 4)
            for k in 6..<24 { bytes[p + k] = UInt8(truncatingIfNeeded: (i + 1) * 17 + k) }
        }
        return Data(bytes)
    }

    /// 로컬 PVDI: 머리 24바이트(`00 00 04 00` · `56 22 00 01` · 본문 길이) · 본문
    public static func pvdi(bodyBytes: Int) -> Data {
        var out = Data("PVDI".utf8)
        out.append(be(0x18)); out.append(be(UInt32(0x18 + bodyBytes)))
        out.append(contentsOf: [0x00, 0x00, 0x04, 0x00, 0x56, 0x22, 0x00, 0x01])
        out.append(be(UInt32(bodyBytes)))
        out.append(Data((0..<bodyBytes).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }))
        return out
    }

    static func emptyPCOB(kind: UInt32) -> Data {
        var out = Data("PCOB".utf8)
        out.append(be(0x18)); out.append(be(0x18)); out.append(be(kind)); out.append(be(0)); out.append(be(0xFFFF_FFFF))
        return out
    }

    static func emptyPCO2(kind: UInt32) -> Data {
        var out = Data("PCO2".utf8)
        out.append(be(0x14)); out.append(be(0x14)); out.append(be(kind)); out.append(be(0))
        return out
    }

    /// PMAI 머리 뒤 16바이트를 0이 아닌 값으로 채워 머리가 그대로 남는지 본다.
    static func localFile(_ tags: [Data]) -> Data {
        var out = file(tags)
        out.replaceSubrange(12..<28, with: [0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        return out
    }
}
