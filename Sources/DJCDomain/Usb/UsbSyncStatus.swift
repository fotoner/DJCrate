import Foundation

/// USB 곡이 로컬 곡보다 뒤처졌는지
public enum UsbSyncStatus: Sendable, Hashable {
    case upToDate
    /// 로컬에서 더 고친 필드
    case localNewer(Set<Field>)
    /// 짝이 되는 로컬 곡이 없음
    case missingLocal
    /// 기기(CDJ 등)에서 고친 곡. 로컬로 덮어쓰면 기기 편집을 잃는다
    case deviceModified

    public enum Field: String, Sendable, Hashable, CaseIterable {
        case information, analysis, cue
    }

    /// 카운터 비교: 로컬 nil과 USB ""를 같게 본다. 둘 다 숫자면 정수로 비교해 로컬이 크면 localNewer,
    /// 숫자가 아니면 글자가 다를 때 localNewer. 기기에서 고친 표시(hasModified 1)나 기기 큐 행이 있으면 deviceModified.
    public static func compare(localInfo: String?, localAnalysis: String?, localCue: String?,
                               usbInfo: String, usbAnalysis: String, usbCue: String, hasModified: Int, hasCueRows: Bool) -> UsbSyncStatus {
        if hasModified == 1 || hasCueRows { return .deviceModified }
        var newer: Set<Field> = []
        for (field, local, usb) in [(Field.information, localInfo, usbInfo), (.analysis, localAnalysis, usbAnalysis), (.cue, localCue, usbCue)] {
            let local = local ?? ""
            if local == usb { continue }
            if let l = Int64(local), let u = Int64(usb) {
                if l > u { newer.insert(field) }
            } else {
                newer.insert(field)
            }
        }
        return newer.isEmpty ? .upToDate : .localNewer(newer)
    }
}
