import DJCDomain
import Foundation
import Testing

@Suite("USB 경로 규칙")
struct UsbLayoutTests {
    @Test("임시 파일 이름은 원래 이름과 무관하고 AppleDouble 모양과 겹치지 않는다")
    func tempNameShape() {
        let name = UsbLayout.tempName(session: "k3f9x2qa", sequence: 42)
        #expect(name == ".djc-part-k3f9x2qa-000042")
        #expect(UsbLayout.isTemp(name))
        #expect(!UsbLayout.isAppleDouble(name))
        #expect(!UsbLayout.isTemp("._Track.mp3"))
        #expect(!UsbLayout.isTemp("_djc-part-x"))
        #expect(UsbLayout.isAppleDouble("._Track.mp3"))
        #expect(UsbLayout.appleDoubleName(for: "Track.mp3") == "._Track.mp3")
        #expect(UsbLayout.tempName(session: "aaaaaaaa", sequence: 1_234_567) == ".djc-part-aaaaaaaa-1234567")
    }

    @Test("충돌 키는 대소문자와 정규화를 접는다")
    func collisionKeyFoldsCaseAndNormalization() {
        #expect(UsbLayout.collisionKey("Foo.mp3") == UsbLayout.collisionKey("FOO.MP3"))
        #expect(UsbLayout.collisionKey("\u{E9}") == UsbLayout.collisionKey("e\u{301}"))
        #expect(UsbLayout.collisionKey("Caf\u{E9}.MP3") == UsbLayout.collisionKey("cafe\u{301}.mp3"))
        #expect(UsbLayout.collisionKey("\u{FF21}") != UsbLayout.collisionKey("A"))
        #expect(UsbLayout.nfc("e\u{301}") == "\u{E9}")
    }

    @Test("열지 않는 경로는 성분 단위로 대소문자를 무시하고 맞춘다")
    func neverReadMatchesByComponentIgnoringCase() {
        #expect(UsbLayout.isNeverRead("pioneer/EXTRACTED/x"))
        #expect(UsbLayout.isNeverRead("PIONEER/extracted"))
        #expect(!UsbLayout.isNeverRead("PIONEER/extractedX"))
        #expect(UsbLayout.isNeverRead("PIONEER/djprofile.nxs"))
        #expect(UsbLayout.isNeverRead("PIONEER/CDP/a/b"))
        #expect(!UsbLayout.isNeverRead("PIONEER"))
        #expect(!UsbLayout.isNeverRead("PIONEER/rekordbox/export.pdb"))
        #expect(!UsbLayout.isNeverRead("Contents/PIONEER/extracted"))
        // "."·빈 성분으로 돌아가도 같은 경로로 본다.
        #expect(UsbLayout.isNeverRead("./PIONEER//extracted/x"))
        #expect(UsbLayout.isNeverRead("PIONEER/./CDP"))
    }

    /// 곡 목록은 USB DB에 적힌 그림·분석 파일 경로를 그대로 읽는다(#256). 손상됐거나 꾸민 경로가 그 폴더 밖을 가리키면 읽지 않는다
    @Test("목록이 읽는 그림·분석 파일 경로는 그 폴더 아래 파일만 받는다")
    func readablePathStaysUnderRoot() {
        #expect(UsbLayout.readablePath("/PIONEER/Artwork/00001/b7.jpg", under: UsbLayout.artworkRoot) == "PIONEER/Artwork/00001/b7.jpg")
        #expect(UsbLayout.readablePath("PIONEER/Artwork/00001/a7.jpg", under: UsbLayout.artworkRoot) == "PIONEER/Artwork/00001/a7.jpg")
        // FAT는 대소문자를 가리지 않는다
        #expect(UsbLayout.readablePath("/pioneer/usbanlz/P016/0000875E/ANLZ0000.DAT", under: UsbLayout.analysisRoot)
            == "pioneer/usbanlz/P016/0000875E/ANLZ0000.DAT")
        let refused = ["", "/", "/PIONEER/Artwork", "/PIONEER/Artwork/", "/PIONEER/Artwork//a1.jpg", "/PIONEER/Artwork/./00001/a1.jpg",
                       "/PIONEER/Artwork/../../etc/hosts", "/PIONEER/Artwork/00001/../../CDP/a1.jpg", "/PIONEER/Artwork/00001/._a1.jpg",
                       "/PIONEER/Artwork/00001/a\u{0}.jpg", "/PIONEER/ArtworkX/a1.jpg", "/Contents/a1.jpg",
                       "/PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT"]
        for path in refused { #expect(UsbLayout.readablePath(path, under: UsbLayout.artworkRoot) == nil, "\(path)") }
        // 열지 않는 자리(SAFE-24)는 어느 뿌리로도 받지 않는다
        #expect(UsbLayout.readablePath("/PIONEER/CDP/x.DAT", under: "PIONEER/CDP") == nil)
        #expect(UsbLayout.readablePath("/PIONEER/extracted/x.jpg", under: "PIONEER") == nil)
    }

    @Test("macOS가 만드는 폴더는 비교에서 뺀다")
    func systemIgnoredPaths() {
        #expect(UsbLayout.isSystemIgnored(".fseventsd"))
        #expect(UsbLayout.isSystemIgnored(".Spotlight-V100/Store-V2/x"))
        #expect(UsbLayout.isSystemIgnored(".trashes"))
        #expect(!UsbLayout.isSystemIgnored("PIONEER/rekordbox"))
        #expect(!UsbLayout.isSystemIgnored(".fseventsdX"))
    }

    @Test("세션 ID는 소문자 base32 8자")
    func sessionIDIsEightBase32() {
        let alphabet = Set("abcdefghijklmnopqrstuvwxyz234567")
        let ids = (0..<50).map { _ in UsbLayout.newSessionID() }
        for id in ids {
            #expect(id.count == 8)
            #expect(id.allSatisfy { alphabet.contains($0) })
        }
        #expect(Set(ids).count > 1)
    }

    @Test("형식 파일 위치")
    func formatPaths() {
        #expect(UsbLayout.oneLibrary.hasPrefix(UsbLayout.rekordboxDir + "/"))
        #expect(UsbLayout.exportPdb == "PIONEER/rekordbox/export.pdb")
        #expect(UsbLayout.exportExtPdb == "PIONEER/rekordbox/exportExt.pdb")
        #expect(UsbLayout.neverRead.allSatisfy { !$0.hasPrefix("/") })
    }

    @Suite("USB DB 파일 지문")
    struct UsbFingerprintTests {
        func stamp(_ size: Int64, _ hash: String, _ seconds: TimeInterval) -> UsbFingerprint.Stamp {
            .init(size: size, mtime: Date(timeIntervalSince1970: seconds), sha256: hash)
        }

        @Test("mtime은 비교하지 않는다")
        func sameContentIgnoresMtime() {
            let a = UsbFingerprint(files: [UsbLayout.oneLibrary: stamp(10, "aa", 0)])
            let b = UsbFingerprint(files: [UsbLayout.oneLibrary: stamp(10, "aa", 2)])
            #expect(a.sameContent(as: b))
            #expect(a != b)
        }

        @Test("크기·해시·파일 목록이 다르면 다르다")
        func differentSizeOrHashDiffers() {
            let a = UsbFingerprint(files: [UsbLayout.oneLibrary: stamp(10, "aa", 0)])
            #expect(!a.sameContent(as: UsbFingerprint(files: [UsbLayout.oneLibrary: stamp(11, "aa", 0)])))
            #expect(!a.sameContent(as: UsbFingerprint(files: [UsbLayout.oneLibrary: stamp(10, "ab", 0)])))
            #expect(!a.sameContent(as: UsbFingerprint(files: [:])))
            #expect(!a.sameContent(as: UsbFingerprint(files: [UsbLayout.oneLibrary: stamp(10, "aa", 0),
                                                               UsbLayout.oneLibrary + "-wal": stamp(0, "e3", 0)])))
        }

        @Test func codableRoundTrip() throws {
            let a = UsbFingerprint(files: [UsbLayout.exportPdb: stamp(4096, "cafe", 1_790_000_000)])
            let decoded = try JSONDecoder().decode(UsbFingerprint.self, from: JSONEncoder().encode(a))
            #expect(decoded == a)
        }
    }
}
