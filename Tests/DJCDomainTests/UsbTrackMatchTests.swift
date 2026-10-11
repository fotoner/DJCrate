import DJCDomain
import Foundation
import Testing

@Suite("USB 곡 ↔ 로컬 곡 짝짓기")
struct UsbTrackMatchTests {
    /// 지어낸 로컬 DB ID
    let localDBID: Int64 = 424_242

    let local = [
        UsbLocalTrackKey(contentID: "11", masterSongID: "501", fileNameL: "a.mp3"),
        UsbLocalTrackKey(contentID: "12", masterSongID: "502", fileNameL: "b.mp3"),
    ]

    @Test("마스터 DB ID·곡 ID·파일 이름이 모두 같으면 그 로컬 곡")
    func matchesByMasterIDsAndFileName() {
        let usb = UsbTrackKey(masterDbId: localDBID, masterContentId: 502, fileName: "b.mp3")
        #expect(UsbTrackMatch.match(usb, localDBID: localDBID, local: local) == "12")
        // 다른 라이브러리에서 내보낸 곡
        #expect(UsbTrackMatch.match(usb, localDBID: localDBID + 1, local: local) == nil)
        // 파일 이름이 다르면 다른 곡(로컬에서 다른 파일로 다시 연결한 곡)
        let renamed = UsbTrackKey(masterDbId: localDBID, masterContentId: 502, fileName: "c.mp3")
        #expect(UsbTrackMatch.match(renamed, localDBID: localDBID, local: local) == nil)
        let other = UsbTrackKey(masterDbId: localDBID, masterContentId: 999, fileName: "b.mp3")
        #expect(UsbTrackMatch.match(other, localDBID: localDBID, local: local) == nil)
    }

    @Test("NFD로 적힌 파일 이름도 짝이 된다")
    func nfdFileNameMatches() {
        let locals = [UsbLocalTrackKey(contentID: "21", masterSongID: "601", fileNameL: "Caf\u{00E9}.mp3")]
        let usb = UsbTrackKey(masterDbId: localDBID, masterContentId: 601, fileName: "Cafe\u{0301}.mp3")
        #expect(UsbTrackMatch.match(usb, localDBID: localDBID, local: locals) == "21")
    }

    @Test("짝이 둘 이상이면 고르지 않는다")
    func ambiguousIsNil() {
        let locals = local + [UsbLocalTrackKey(contentID: "13", masterSongID: "502", fileNameL: "b.mp3")]
        let usb = UsbTrackKey(masterDbId: localDBID, masterContentId: 502, fileName: "b.mp3")
        #expect(UsbTrackMatch.match(usb, localDBID: localDBID, local: locals) == nil)
    }

    /// 지어낸 곡 ID 하나에 로컬 파일 이름 하나
    func match(_ fileName: String, local fileNameL: String) -> String? {
        let locals = [UsbLocalTrackKey(contentID: "31", masterSongID: "701", fileNameL: fileNameL)]
        return UsbTrackMatch.match(UsbTrackKey(masterDbId: localDBID, masterContentId: 701, fileName: fileName), localDBID: localDBID, local: locals)
    }

    @Test("내보내기 이름 규칙으로 바뀐 USB 경로 끝 성분도 짝이 된다(번호·금지 글자·자르기·FAT 대소문자)")
    func exportNamingMatches() {
        #expect(match("b (2).mp3", local: "b.mp3") == "31")
        #expect(match("b (99).mp3", local: "b.mp3") == "31")
        // 같은 내용 파일을 다시 쓸 때는 USB에 있던 철자를 가리킨다
        #expect(match("B.MP3", local: "b.mp3") == "31")
        #expect(match("a_b.mp3", local: "a:b.mp3") == "31")
        let long = String(repeating: "가", count: 60) + ".mp3"
        let truncated = UsbPathRules.fileName(long).value
        #expect(truncated != long)
        #expect(match(truncated, local: long) == "31")
        // 자른 이름에 번호를 붙이면 줄기가 더 잘린다
        #expect(match(UsbPathRules.withSuffix(truncated, number: 3), local: long) == "31")
    }

    @Test("내보내기 번호 규칙 밖의 이름은 짝이 아니다")
    func nonExportNamesDoNotMatch() {
        for name in ["b (1).mp3", "b (100).mp3", "b(2).mp3", "b (2).wav", "b (2) (2).mp3", "xb.mp3"] {
            #expect(match(name, local: "b.mp3") == nil, "\(name)")
        }
    }

    @Test("이름이 그대로 맞는 곡이 번호를 붙여 맞는 곡보다 앞선다")
    func exactNameWinsOverNumbered() {
        let locals = [UsbLocalTrackKey(contentID: "41", masterSongID: "801", fileNameL: "b.mp3"),
                      UsbLocalTrackKey(contentID: "42", masterSongID: "801", fileNameL: "b (2).mp3")]
        func match(_ name: String) -> String? {
            UsbTrackMatch.match(UsbTrackKey(masterDbId: localDBID, masterContentId: 801, fileName: name), localDBID: localDBID, local: locals)
        }
        #expect(match("b (2).mp3") == "42")
        #expect(match("b.mp3") == "41")
        // 번호로만 맞는 곡이 둘이면 고르지 않는다
        let twins = [UsbLocalTrackKey(contentID: "51", masterSongID: "802", fileNameL: "c.mp3"),
                     UsbLocalTrackKey(contentID: "52", masterSongID: "802", fileNameL: "C.mp3")]
        #expect(UsbTrackMatch.match(UsbTrackKey(masterDbId: localDBID, masterContentId: 802, fileName: "c (2).mp3"), localDBID: localDBID,
                                    local: twins) == nil)
    }

    @Test("2026-10-09 전 이름 규칙(~를 그대로 둠)으로 쓴 USB 파일도 짝이 된다")
    func legacyTildeNamesMatch() {
        // 지금 규칙
        #expect(match("a_b_.mp3", local: "a~b?.mp3") == "31")
        // 옛 규칙: ~는 그대로, ?만 바꿈
        #expect(match("a~b_.mp3", local: "a~b?.mp3") == "31")
        #expect(match("a~b_ (2).mp3", local: "a~b?.mp3") == "31")
        #expect(match("a_b_ (2).mp3", local: "a~b?.mp3") == "31")
        #expect(match("a~b~.mp3", local: "a~b~.mp3") == "31")
        #expect(match("a_b_.mp3", local: "a~b~.mp3") == "31")
    }

    @Test("음원 경로의 끝 성분으로 지은 USB 파일 이름도, 옛 FileNameL 이름도 짝이 된다")
    func folderPathNameMatches() {
        let locals = [UsbLocalTrackKey(contentID: "61", masterSongID: "901", fileNameL: "old name.mp3", folderPath: "/Music/new~name.mp3")]
        func match(_ name: String) -> String? {
            UsbTrackMatch.match(UsbTrackKey(masterDbId: localDBID, masterContentId: 901, fileName: name), localDBID: localDBID, local: locals)
        }
        #expect(match("new_name.mp3") == "61")
        #expect(match("new~name.mp3") == "61")
        #expect(match("new_name (2).mp3") == "61")
        #expect(match("old name.mp3") == "61")
        #expect(match("other.mp3") == nil)
    }
}
