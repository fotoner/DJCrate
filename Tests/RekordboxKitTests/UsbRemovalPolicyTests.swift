import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("USB 지우기 허용 목록")
struct UsbRemovalPolicyTests {
    @Test("허용 패턴", arguments: [
        "Contents/Artist/Album/Song.mp3",
        "Contents/x.flac",
        "Contents/Artist/Album/._Song.mp3",
        "PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT",
        "PIONEER/USBANLZ/P0FF/89ABCDEF/ANLZ0001.EXT",
        "PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.2EX",
        "PIONEER/USBANLZ/P001/0000ABCD/._ANLZ0000.DAT",
        "PIONEER/Artwork/00001/a1.jpg",
        "PIONEER/Artwork/00001/b12_m.jpg",
        "PIONEER/Artwork/00002/._a3_m.jpg",
    ])
    func allowedPatterns(path: String) {
        #expect(UsbRemovalPolicy.allows(path))
    }

    @Test("목록 밖은 거부", arguments: [
        "PIONEER/rekordbox/RBFLTR.DAT",
        "PIONEER/USBANLZ/P001/0000ABCD/USBMNG.DAT",
        "PIONEER/USBANLZ/USBMNG.DAT",
        "PIONEER/log/x.json",
        "PIONEER/rekordbox/exportLibrary.db",
        "PIONEER/Artwork/00001/c1.jpg",
        "PIONEER/Artwork/1/a1.jpg",
        "PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.TXT",
        "PIONEER/USBANLZ/PXYZ/0000ABCD/ANLZ0000.DAT",
        "Contents",
        "Contents/",
        "Other/x.mp3",
        "/Contents/x.mp3",
        "Contents/../PIONEER/rekordbox/export.pdb",
        "Contents/./x.mp3",
        "",
    ])
    func outsideListRejected(path: String) {
        #expect(!UsbRemovalPolicy.allows(path))
    }

    @Test("열지 않는 경로는 거부")
    func neverReadRejected() {
        #expect(!UsbRemovalPolicy.allows("PIONEER/extracted/GCRED.DAT"))
        #expect(!UsbRemovalPolicy.allows("PIONEER/CDP/x"))
        #expect(!UsbRemovalPolicy.allows("PIONEER/djprofile.nxs"))
        #expect(!UsbRemovalPolicy.allows("pioneer/EXTRACTED/x"))
    }

    @Test("대소문자·NFC/NFD를 가리지 않는다")
    func caseInsensitiveNFC() {
        #expect(UsbRemovalPolicy.allows("contents/Cafe\u{301}/song.MP3"))
        #expect(UsbRemovalPolicy.allows("pioneer/usbanlz/p001/0000abcd/anlz0000.dat"))
        #expect(UsbRemovalPolicy.allows("pioneer/artwork/00001/A1_M.JPG"))
    }

    @Test("심볼릭 링크는 거부")
    func symlinkRejected() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        fixture.write("Contents/real/x.mp3", "audio")
        fixture.symlink("Contents/link", to: fixture.url("Contents/real").path)
        fixture.symlink("Contents/real/y.mp3", to: fixture.url("Contents/real/x.mp3").path)
        let fs = PosixUsbFileSystem()
        #expect(try UsbRemovalPolicy.allows("Contents/real/x.mp3", root: fixture.root, fileSystem: fs))
        #expect(try !UsbRemovalPolicy.allows("Contents/link/x.mp3", root: fixture.root, fileSystem: fs))
        #expect(try !UsbRemovalPolicy.allows("Contents/real/y.mp3", root: fixture.root, fileSystem: fs))
    }

    @Test("짝 AppleDouble은 정확한 이름 하나뿐(패턴으로 쓸지 않음)")
    func userAppleDoubleNotSwept() {
        #expect(UsbRemovalPolicy.appleDoubleCompanion(of: "Contents/A/x.mp3") == "Contents/A/._x.mp3")
        #expect(UsbRemovalPolicy.appleDoubleCompanion(of: "x.mp3") == "._x.mp3")
        // 이미 AppleDouble이면 짝이 없다.
        #expect(UsbRemovalPolicy.appleDoubleCompanion(of: "Contents/A/._x.mp3") == nil)
    }
}
