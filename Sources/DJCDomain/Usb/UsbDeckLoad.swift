import Foundation

/// USB 곡 줄을 덱에 올릴 로컬 곡(#255). 덱은 로컬 분석 파일·초안을 읽으므로 USB 곡 대신 짝인 로컬 곡을 올린다.
/// 짝(볼륨키 → USB content_id → 로컬 ContentID)은 갱신 상태 배지와 함께 계산한 것을 받는다(`UsbSyncBadges`).
public enum UsbDeckLoad {
    /// USB 곡 줄 ID(`usb:<볼륨키>:<content_id>`) → 짝 로컬 ContentID. 읽은 볼륨의 키로만 풀어서
    /// 볼륨 곡이 아닌 `usb:` 줄(재생 기록 보존 곡 등)이나 짝 없는 곡은 nil이다.
    public static func localContentID(usbTrackID id: String, matches: [String: [Int: String]]) -> String? {
        for (key, byContent) in matches {
            let prefix = TrackRow.usbIDPrefix + key + ":"
            guard id.hasPrefix(prefix), let contentID = Int(id.dropFirst(prefix.count)) else { continue }
            return byContent[contentID]
        }
        return nil
    }
}
