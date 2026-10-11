import DJCDomain
import Testing

/// USB 곡 줄을 덱에 올릴 로컬 곡 찾기(#255)
@Suite("USB 곡의 덱 불러오기 짝")
struct UsbDeckLoadTests {
    let matches: [String: [Int: String]] = ["VOL-A": [1: "101", 2: "102"], "VOL-B": [1: "201"]]

    @Test("읽은 볼륨의 USB 곡 ID는 그 볼륨의 짝 로컬 ContentID로 푼다")
    func resolvesMatchedTrack() {
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL-A:1", matches: matches) == "101")
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL-A:2", matches: matches) == "102")
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL-B:1", matches: matches) == "201")
    }

    @Test("짝이 없는 곡, 읽지 않은 볼륨, USB 볼륨 곡이 아닌 usb: 줄, 로컬 곡 ID는 nil이다")
    func unmatchedIsNil() {
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL-A:3", matches: matches) == nil)
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL-C:1", matches: matches) == nil)
        // 재생 기록 보존 줄(`usb:history:…`)은 볼륨 곡이 아니다
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:history:abc:1", matches: matches) == nil)
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL-A:x", matches: matches) == nil)
        #expect(UsbDeckLoad.localContentID(usbTrackID: "101", matches: matches) == nil)
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL-A:1", matches: [:]) == nil)
    }

    @Test("키가 다른 키의 앞부분이어도 볼륨을 헷갈리지 않는다")
    func prefixKeys() {
        let overlapping: [String: [Int: String]] = ["VOL": [1: "1"], "VOL-2": [1: "2"]]
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL-2:1", matches: overlapping) == "2")
        #expect(UsbDeckLoad.localContentID(usbTrackID: "usb:VOL:1", matches: overlapping) == "1")
    }
}
