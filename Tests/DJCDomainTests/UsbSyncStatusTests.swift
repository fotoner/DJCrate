import DJCDomain
import Foundation
import Testing

@Suite("USB 곡 갱신 상태")
struct UsbSyncStatusTests {
    func compare(_ local: (String?, String?, String?), _ usb: (String, String, String),
                 hasModified: Int = 0, hasCueRows: Bool = false) -> UsbSyncStatus {
        UsbSyncStatus.compare(localInfo: local.0, localAnalysis: local.1, localCue: local.2,
                              usbInfo: usb.0, usbAnalysis: usb.1, usbCue: usb.2, hasModified: hasModified, hasCueRows: hasCueRows)
    }

    @Test("로컬 nil과 USB 빈 글자는 같다")
    func nullEqualsEmpty() {
        #expect(compare((nil, nil, nil), ("", "", "")) == .upToDate)
        #expect(compare(("3", "4", nil), ("3", "4", "")) == .upToDate)
    }

    @Test("로컬 카운터가 크면 그 필드가 새것")
    func localNewerFields() {
        #expect(compare(("5", "2", "10"), ("3", "2", "9")) == .localNewer([.information, .cue]))
        // 로컬이 작으면 새것이 아니다(숫자로 비교: "10" > "9")
        #expect(compare(("3", "2", "9"), ("5", "2", "10")) == .upToDate)
        // 숫자가 아니면 글자가 다를 때 새것
        #expect(compare(("abc", nil, nil), ("abd", "", "")) == .localNewer([.information]))
        #expect(compare((nil, "7", nil), ("", "", "")) == .localNewer([.analysis]))
    }

    @Test("기기에서 고친 곡은 카운터보다 앞선다")
    func deviceModifiedWins() {
        #expect(compare(("5", "5", "5"), ("1", "1", "1"), hasModified: 1) == .deviceModified)
        #expect(compare((nil, nil, nil), ("", "", ""), hasCueRows: true) == .deviceModified)
        #expect(compare(("1", "1", "1"), ("1", "1", "1"), hasModified: 0) == .upToDate)
    }
}
