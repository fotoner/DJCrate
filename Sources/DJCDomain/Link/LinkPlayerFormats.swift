import Foundation

/// 플레이어 기종별로 직접 재생하는 형식(#277). 기종 이름은 장치 알림(keep-alive)에 실린 이름이다(예: "CDJ-2000nexus", "CDJ-3000").
/// PRO DJ LINK를 쓰는 플레이어와 올인원 기종을 적는다. FLAC·ALAC은 CDJ-2000NXS2·XDJ-1000MK2·XDJ-RX2 세대부터 재생한다(제조사 사양).
/// 표에 없는 기종은 바꾸는 쪽으로 둔다(실리지 않는 것보다 낫다). 실기로 확인한 것은 CDJ-2000nexus(못 읽음)뿐이다.
public enum LinkPlayerFormats {
    /// 기종 이름(대문자) → FLAC·ALAC을 직접 재생하는지
    static let lossless: [String: Bool] = [
        // 플레이어
        "CDJ-3000X": true,
        "CDJ-3000": true,
        "CDJ-2000NXS2": true,
        "CDJ-TOUR1": true,
        "XDJ-1000MK2": true,
        "CDJ-2000NEXUS": false,
        "CDJ-2000": false,
        "CDJ-900NXS": false,
        "CDJ-900": false,
        "XDJ-1000": false,
        "XDJ-700": false,
        // 올인원
        "OPUS-QUAD": true,
        "XDJ-AZ": true,
        "XDJ-XZ": true,
        "XDJ-RX3": true,
        "XDJ-RX2": true,
        "XDJ-RX": false,
    ]

    /// 그 기종이 FLAC·ALAC을 직접 재생하는지(그러면 WAV로 바꾸지 않고 원본을 싣는다). 표에 없는 기종은 false
    public static func playsLossless(model: String) -> Bool {
        lossless[model.trimmingCharacters(in: .whitespaces).uppercased()] ?? false
    }
}
