import DJCDomain
import Foundation
import Testing

@Suite("USB 분석 파일 폴더·번호")
struct UsbAnalysisNamingTests {
    @Test("DJCrate 고유 폴더 이름: P + 상위 12비트 3자리, content ID 8자리(16진)")
    func identifierFormat() {
        let naming = IdentifierAnalysisNaming()
        #expect(naming.folder(contentsPath: "/Contents/A/B/x.mp3", contentID: 1) == "P000/00000001")
        #expect(naming.folder(contentsPath: "/Contents/A/B/x.mp3", contentID: 0x12345) == "P012/00012345")
        #expect(naming.folder(contentsPath: "/Contents/A/B/x.mp3", contentID: 0xABCDEF) == "PABC/00ABCDEF")
    }

    @Test("고유 이름은 analysisFolderNaming 규칙을 싣는다")
    func ruleIsAnalysisFolderNaming() {
        #expect(IdentifierAnalysisNaming().rule == .analysisFolderNaming)
        let naming: any UsbAnalysisNaming = IdentifierAnalysisNaming()
        #expect(naming.rule == .analysisFolderNaming)
    }

    @Test("rekordbox 폴더 이름: 경로 해시 % 200003을 8자리, 해시의 7비트를 모은 P 3자리(16진)")
    func rekordboxFormat() {
        let naming = RekordboxAnalysisNaming()
        // 합성 경로. 값은 아래 규칙을 따로 구현한 계산과 같다
        #expect(naming.folder(contentsPath: "/Contents/A/B/x.mp3", contentID: 1) == "P054/00011242")
        #expect(naming.folder(contentsPath: "/Contents/Synthetic Artist/Synthetic Album/track 1.mp3", contentID: 1) == "P028/0002748A")
        #expect(naming.folder(contentsPath: "/Contents/합성 아티스트/합성 앨범/합성 곡.mp3", contentID: 7) == "P056/0001CB64")
        // content ID와 상관없다
        #expect(naming.folder(contentsPath: "/Contents/A/B/x.mp3", contentID: 999) == "P054/00011242")
        // NFD로 받은 경로도 NFC로 계산한다(USB 경로는 NFC)
        #expect(naming.folder(contentsPath: "/Contents/UnknownArtist/UnknownAlbum/Cafe\u{0301}.flac", contentID: 1) == "P00C/000094F2")
        #expect(naming.folder(contentsPath: "Contents/A/B/x.mp3", contentID: 1) == nil)
    }

    @Test("P 번호는 해시의 0·2·6·7·9·13·16번 비트(CDJ-2000NXS가 만든 폴더 5개의 번호, 2026-10-09)")
    func rekordboxBucket() {
        // 기기가 만든 폴더 이름의 (해시, P)만 옮긴다(곡 경로는 적지 않는다)
        let observed: [(Int, Int)] = [(0x1A29, 0x11), (0x2DAA0, 0x18), (0x2E1FA, 0x2C), (0x3ED7, 0x3F), (0x1ECCE, 0x6E)]
        for (hash, bucket) in observed { #expect(RekordboxAnalysisNaming.bucket(hash) == bucket) }
        #expect(RekordboxAnalysisNaming.bucket(0) == 0)
        #expect(RekordboxAnalysisNaming.bucket(200_002) <= 0x7F)
        #expect(RekordboxAnalysisNaming.hash(contentsPath: "/Contents/A/B/x.mp3") < 200_003)
    }

    @Test("rekordbox 이름은 확인된 규칙이고, 보충 평면 글자가 든 경로만 규칙을 싣는다")
    func rekordboxRules() {
        let naming = RekordboxAnalysisNaming()
        #expect(naming.rule == nil)
        #expect(naming.rules(contentsPath: "/Contents/A/B/x.mp3").isEmpty)
        #expect(naming.rules(contentsPath: "/Contents/A/B/\u{1F600}.mp3") == [.supplementaryCharacters])
        // 보충 평면 글자는 UTF-16 단위 둘로 넣는다(관찰 못 함)
        #expect(naming.folder(contentsPath: "/Contents/A/B/\u{1F600}.mp3", contentID: 1) == "P06A/000129B6")
        #expect(IdentifierAnalysisNaming().rules(contentsPath: "/Contents/A/B/x.mp3") == [.analysisFolderNaming])
    }

    @Test("같은 곡 경로(PPTH)가 있으면 그 번호를 다시 쓴다")
    func slotReuseSamePPTH() {
        let existing = [(slot: 0, ppth: "/Contents/A/B/other.mp3"), (slot: 1, ppth: "/Contents/A/B/x.mp3")]
        let chosen = UsbAnalysisSlot.choose(existing: existing, contentsPath: "/Contents/A/B/x.mp3")
        #expect(chosen.slot == 1)
        #expect(chosen.reuse)
        // NFD로 적힌 경로도 같은 곡
        let nfd = UsbAnalysisSlot.choose(existing: [(slot: 2, ppth: "/Contents/A/B/Cafe\u{0301}.mp3")],
                                         contentsPath: "/Contents/A/B/Caf\u{00E9}.mp3")
        #expect(nfd.slot == 2 && nfd.reuse)
    }

    @Test("다른 곡 파일이 있으면 덮어쓰지 않고 가장 작은 빈 번호")
    func slotNextFreeWhenOtherPPTH() {
        #expect(UsbAnalysisSlot.choose(existing: [], contentsPath: "/Contents/x.mp3") == (slot: 0, reuse: false))
        let one = UsbAnalysisSlot.choose(existing: [(slot: 0, ppth: "/Contents/o.mp3")], contentsPath: "/Contents/x.mp3")
        #expect(one == (slot: 1, reuse: false))
        let two = UsbAnalysisSlot.choose(existing: [(slot: 0, ppth: "/Contents/o.mp3"), (slot: 1, ppth: "/Contents/p.mp3")],
                                         contentsPath: "/Contents/x.mp3")
        #expect(two == (slot: 2, reuse: false))
        let gap = UsbAnalysisSlot.choose(existing: [(slot: 1, ppth: "/Contents/p.mp3")], contentsPath: "/Contents/x.mp3")
        #expect(gap == (slot: 0, reuse: false))
    }

    @Test("이번 계획의 다른 곡이 받은 번호는 같은 PPTH여도 다시 쓰지 않는다(같은 음원을 가리키는 두 곡)")
    func slotReservedWithinPlan() {
        #expect(UsbAnalysisSlot.choose(existing: [], contentsPath: "/Contents/x.mp3", reserved: [0]) == (slot: 1, reuse: false))
        let existing = [(slot: 0, ppth: "/Contents/x.mp3")]
        #expect(UsbAnalysisSlot.choose(existing: existing, contentsPath: "/Contents/x.mp3") == (slot: 0, reuse: true))
        #expect(UsbAnalysisSlot.choose(existing: existing, contentsPath: "/Contents/x.mp3", reserved: [0]) == (slot: 1, reuse: false))
    }

    @Test("파일 줄기와 경로는 번호를 16진 4자리로")
    func fileStemHex() {
        #expect(UsbAnalysisSlot.fileStem(slot: 0) == "ANLZ0000")
        #expect(UsbAnalysisSlot.fileStem(slot: 10) == "ANLZ000A")
        #expect(UsbAnalysisSlot.analysisPath(folder: "P000/00000001", slot: 10) == "/PIONEER/USBANLZ/P000/00000001/ANLZ000A.DAT")
    }
}
