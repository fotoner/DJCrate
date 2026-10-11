import Foundation

/// USB 분석 파일(`PIONEER/USBANLZ/…`) 폴더 이름을 짓는 방법
public protocol UsbAnalysisNaming: Sendable {
    /// 이 구현이 쓰면 계획에 싣는 규칙(nil = 확인된 규칙)
    var rule: UsbProvisionalRule? { get }
    /// USBANLZ 아래 폴더 "P%03X/%08X". 이름을 못 지으면 nil
    func folder(contentsPath: String, contentID: Int) -> String?
    /// 이 곡 경로로 이름을 지을 때 계획에 싣는 규칙
    func rules(contentsPath: String) -> Set<UsbProvisionalRule>
}

public extension UsbAnalysisNaming {
    func rules(contentsPath: String) -> Set<UsbProvisionalRule> { rule.map { [$0] } ?? [] }
}

/// rekordbox 이름: 음원 경로(`/Contents/…`, NFC)의 해시로 짓는다.
/// CDJ-2000NXS는 pdb의 분석 경로(문자열 14)를 보지 않고 곡 경로에서 이 이름을 다시 계산해 분석 파일을 찾는다.
/// 근거: rekordbox 7.2.x가 빈 USB에 내보낸 곡 708개(2026-10-08 실험들)의 pdb 분석 경로가 모두 이 계산과 같았고,
/// DJCrate 고유 이름으로 내보낸 USB를 CDJ-2000NXS에 꽂자(2026-10-09) 기기가 불러온 곡 5개의 빈 분석 파일을 정확히 이 폴더에 만들었다.
/// 계산 모양은 MIT 라이선스 rekordbox_converter(ModeAxe)의 `hash_audio_path`와 같고, 위 관찰로 다시 확인했다(THIRD_PARTY_NOTICES.md).
public struct RekordboxAnalysisNaming: UsbAnalysisNaming {
    public init() {}

    /// 보충 평면 글자가 든 경로만 확인 안 된 규칙을 싣는다(아래 `hash` 참고)
    public var rule: UsbProvisionalRule? { nil }

    public func rules(contentsPath: String) -> Set<UsbProvisionalRule> {
        UsbLayout.nfc(contentsPath).unicodeScalars.contains { $0.value > 0xFFFF } ? [.supplementaryCharacters] : []
    }

    public func folder(contentsPath: String, contentID: Int) -> String? {
        guard contentsPath.hasPrefix("/") else { return nil }
        let value = Self.hash(contentsPath: contentsPath)
        return String(format: "P%03X/%08X", Self.bucket(value), value)
    }

    /// 경로의 UTF-16 단위마다 `h = (h × 0x5BC9 + c) × 0x93B5 + c`(u32에서 넘침 버림) → 200003으로 나눈 나머지.
    /// 보충 평면 글자(서로게이트 둘)를 단위 둘로 넣을지 한 글자로 넣을지는 관찰한 적이 없다
    public static func hash(contentsPath: String) -> Int {
        var h: UInt32 = 0
        for unit in UsbLayout.nfc(contentsPath).utf16 {
            let c = UInt32(unit)
            h = (h &* 0x5BC9 &+ c) &* 0x93B5 &+ c
        }
        return Int(h % 200_003)
    }

    /// 앞 폴더 번호: 해시의 0·2·6·7·9·13·16번 비트를 차례로 모은 7비트(관찰한 708곡에서 다른 비트는 섞이지 않았다)
    public static func bucket(_ value: Int) -> Int {
        [0, 2, 6, 7, 9, 13, 16].enumerated().reduce(0) { result, item in result | (((value >> item.element) & 1) << item.offset) }
    }
}

/// DJCrate 고유 이름: content ID로 짓는다(시험용). CDJ-2000NXS는 이 폴더를 찾지 못해 파형·큐를 보이지 않는다(2026-10-09, #233).
/// 쓰기는 `RekordboxAnalysisNaming`을 쓰고, 이것은 계획기 시험에서 폴더를 ID로 고정할 때만 쓴다.
public struct IdentifierAnalysisNaming: UsbAnalysisNaming {
    public init() {}

    public var rule: UsbProvisionalRule? { .analysisFolderNaming }

    public func folder(contentsPath: String, contentID: Int) -> String? {
        String(format: "P%03X/%08X", (contentID >> 12) & 0xFFF, contentID)
    }
}

/// 한 분석 폴더 안의 파일 번호(ANLZ0000, ANLZ0001 …)
public enum UsbAnalysisSlot {
    /// 폴더에 이미 있는 (번호, PPTH). 같은 PPTH가 있으면 그 번호(재사용), 아니면 가장 작은 빈 번호.
    /// 다른 곡의 파일은 절대 덮어쓰지 않는다. `reserved`는 이번 계획의 다른 곡이 이미 받은 번호다(같은 음원을 가리키는 두 곡도
    /// 폴더 이름이 같으므로, 한 파일을 두 번 쓰지 않게 다시 쓰지도 고르지도 않는다).
    public static func choose(existing: [(slot: Int, ppth: String)], contentsPath: String, reserved: Set<Int> = []) -> (slot: Int, reuse: Bool) {
        let path = UsbLayout.nfc(contentsPath)
        if let same = existing.filter({ UsbLayout.nfc($0.ppth) == path && !reserved.contains($0.slot) }).map(\.slot).min() {
            return (same, true)
        }
        let used = Set(existing.map(\.slot)).union(reserved)
        return ((0...).first { !used.contains($0) }!, false)
    }

    /// "ANLZ%04X"
    public static func fileStem(slot: Int) -> String {
        String(format: "ANLZ%04X", slot)
    }

    /// "/PIONEER/USBANLZ/<folder>/ANLZ%04X.DAT"
    public static func analysisPath(folder: String, slot: Int) -> String {
        "/" + UsbLayout.analysisRoot + "/" + folder + "/" + fileStem(slot: slot) + ".DAT"
    }
}
