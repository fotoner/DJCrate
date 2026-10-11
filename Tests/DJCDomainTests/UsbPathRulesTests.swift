import DJCDomain
import Foundation
import Testing

@Suite("USB 경로 성분·파일 이름 규칙")
struct UsbPathRulesTests {
    func folder(_ name: String?) -> UsbPathRules.Named {
        UsbPathRules.folderComponent(name, unknown: "UnknownArtist")
    }

    @Test("이름은 NFC로 맞춘다")
    func nfcApplied() {
        let named = folder("Cafe\u{0301} Bar")
        #expect(named.value == "Caf\u{00E9} Bar")
        #expect(named.value.unicodeScalars.count == 8)
        #expect(named.rules.isEmpty)
        #expect(UsbPathRules.fileName("Cafe\u{0301}.mp3").value == "Caf\u{00E9}.mp3")
    }

    @Test(": 와 / 는 _로 바꾸고 규칙이 없다")
    func colonAndSlashToUnderscore() {
        let named = folder("A:B/C")
        #expect(named.value == "A_B_C")
        #expect(named.rules.isEmpty)
        let file = UsbPathRules.fileName("x:y/z.mp3")
        #expect(file.value == "x_y_z.mp3")
        #expect(file.rules.isEmpty)
    }

    /// rekordbox 7.2.x 빈 USB 내보내기 골든(2026-10-08, 704곡): 로컬 아티스트·앨범·파일 이름과 USB 경로 성분을 견주어
    /// 폴더 성분에서 `" * / : > ? ~`, 파일 이름에서 `~`가 `_`로 바뀐 것을 봤다. 이름은 관찰한 모양을 본뜬 합성 값이다.
    @Test("골든: rekordbox가 바꾸는 글자(\" * / : > ? ~)는 _로 바꾸고 규칙이 없다")
    func goldenReplacedCharacters() {
        for character in ["\"", "*", "/", ":", ">", "?", "~"] {
            let named = folder("A\(character)B")
            #expect(named.value == "A_B", "\(character)")
            #expect(named.rules.isEmpty, "\(character)")
            let file = UsbPathRules.fileName("A\(character)B.mp3")
            #expect(file.value == "A_B.mp3", "\(character)")
            #expect(file.rules.isEmpty, "\(character)")
        }
        // 앨범 "abcd ~efgh ijk lmnopq~" 모양: 앞뒤 물결표 둘 다
        #expect(UsbPathRules.folderComponent("Some ~Thing Was Here~", unknown: "UnknownAlbum").value == "Some _Thing Was Here_")
        // 파일 "01 abcd ~EFG~.mp3" 모양
        #expect(UsbPathRules.fileName("01 Song Name ~Mix~.mp3").value == "01 Song Name _Mix_.mp3")
        // 48 스칼라를 넘는 앨범: 바꾼 뒤 자른다("….~01ab cdef…" 모양)
        let long = String(repeating: "a", count: 30) + ".~01ab " + String(repeating: "c", count: 20)
        #expect(UsbPathRules.folderComponent(long, unknown: "UnknownAlbum").value
            == String(repeating: "a", count: 30) + "._01ab " + String(repeating: "c", count: 11))
    }

    @Test("rekordbox에서 보지 못한 금지 글자와 제어 문자는 _로 바꾸고 forbiddenCharacters")
    func forbiddenOthersFlagged() {
        for character in ["<", "\\", "|", "\u{0001}", "\u{001F}", "\u{007F}"] {
            let named = folder("A\(character)B")
            #expect(named.value == "A_B", "\(character.unicodeScalars.first!.value)")
            #expect(named.rules == [.forbiddenCharacters])
            let file = UsbPathRules.fileName("A\(character)B.mp3")
            #expect(file.value == "A_B.mp3")
            #expect(file.rules == [.forbiddenCharacters])
        }
    }

    @Test("끝의 점 하나는 자르기 전에 _로 바꾼다")
    func trailingDotBeforeTruncate() {
        #expect(folder("Name.").value == "Name_")
        #expect(folder("Name.").rules.isEmpty)
        // 48자 안의 점은 자른 뒤 끝에 와도 _가 아니라 지운다
        let long = String(repeating: "a", count: 47) + ".bc"
        #expect(folder(long).value == String(repeating: "a", count: 47))
    }

    @Test("앞 48 스칼라로 자른다")
    func truncate48Scalars() {
        let named = folder(String(repeating: "a", count: 49))
        #expect(named.value == String(repeating: "a", count: 48))
        #expect(named.rules.isEmpty)
        #expect(folder(String(repeating: "가", count: 60)).value == String(repeating: "가", count: 48))
    }

    @Test("자른 뒤 끝의 공백·점을 지운다")
    func trailingSpaceDotStrippedAfterTruncate() {
        let named = folder(String(repeating: "a", count: 47) + " b")
        #expect(named.value == String(repeating: "a", count: 47))
        let dots = folder(String(repeating: "a", count: 46) + ". b")
        #expect(dots.value == String(repeating: "a", count: 46))
    }

    @Test("자르지 않아도 끝의 공백은 지운다")
    func untruncatedTrailingSpaceStripped() {
        #expect(folder("Name ").value == "Name")
        #expect(folder("Name   ").value == "Name")
        #expect(folder("Name ").rules.isEmpty)
    }

    @Test("비었거나 공백·점뿐이면 Unknown")
    func emptyToUnknown() {
        for name in [nil, "", "   ", "...", " . "] as [String?] {
            let named = folder(name)
            #expect(named.value == "UnknownArtist", "\(String(describing: name))")
            #expect(named.rules == [.emptyArtistAlbum])
        }
        #expect(UsbPathRules.folderComponent(nil, unknown: "UnknownAlbum").value == "UnknownAlbum")
    }

    @Test("보충 평면 글자는 스칼라 단위로 잘라 깨지지 않는다")
    func supplementaryNotSplit() {
        let name = String(repeating: "a", count: 46) + "😀🎵🎶🎧"
        #expect(name.unicodeScalars.count == 50)
        let named = folder(name)
        #expect(named.value == String(repeating: "a", count: 46) + "😀🎵")
        #expect(named.value.unicodeScalars.count == 48)
        #expect(named.value.utf16.count == 50)
        #expect(named.rules == [.supplementaryCharacters])
        // 자르지 않으면 규칙이 없다
        #expect(folder("A😀").rules.isEmpty)
    }

    @Test("앞 공백은 그대로 두고 leadingSpace")
    func leadingSpaceKept() {
        let named = folder(" Name")
        #expect(named.value == " Name")
        #expect(named.rules == [.leadingSpace])
        let file = UsbPathRules.fileName(" x.mp3")
        #expect(file.value == " x.mp3")
        #expect(file.rules == [.leadingSpace])
    }

    @Test("긴 파일 이름은 줄기만 잘라 확장자를 남긴다")
    func fileNameStemTruncationKeepsExtension() {
        let file = UsbPathRules.fileName(String(repeating: "s", count: 60) + ".mp3")
        #expect(file.value == String(repeating: "s", count: 44) + ".mp3")
        #expect(file.value.unicodeScalars.count == 48)
        #expect(file.rules == [.fileNameTruncation])
        // 자른 줄기 끝의 공백은 지운다
        let spaced = UsbPathRules.fileName(String(repeating: "s", count: 43) + " " + String(repeating: "t", count: 16) + ".mp3")
        #expect(spaced.value == String(repeating: "s", count: 43) + ".mp3")
        // 48자 이하면 줄기 끝 공백·점도 그대로
        #expect(UsbPathRules.fileName("abc .mp3").value == "abc .mp3")
        #expect(UsbPathRules.fileName("abc..mp3").value == "abc..mp3")
        #expect(UsbPathRules.fileName("abc .mp3").rules.isEmpty)
    }

    @Test("확장자 없는 파일 이름")
    func fileNameNoExtension() {
        #expect(UsbPathRules.fileName("README").value == "README")
        #expect(UsbPathRules.fileName("README").rules.isEmpty)
        let long = UsbPathRules.fileName(String(repeating: "n", count: 60))
        #expect(long.value == String(repeating: "n", count: 48))
        #expect(long.rules == [.fileNameTruncation])
    }

    @Test("번호를 붙여도 48 스칼라 안")
    func withSuffixFits48() {
        #expect(UsbPathRules.withSuffix("x.mp3", number: 2) == "x (2).mp3")
        #expect(UsbPathRules.withSuffix("README", number: 3) == "README (3)")
        let full = String(repeating: "s", count: 44) + ".mp3"
        let two = UsbPathRules.withSuffix(full, number: 2)
        #expect(two == String(repeating: "s", count: 40) + " (2).mp3")
        #expect(two.unicodeScalars.count == 48)
        let ninetyNine = UsbPathRules.withSuffix(full, number: 99)
        #expect(ninetyNine == String(repeating: "s", count: 39) + " (99).mp3")
        // 자른 줄기 끝 공백은 지운다
        let spaced = String(repeating: "s", count: 39) + " " + "tttt.mp3"
        #expect(UsbPathRules.withSuffix(spaced, number: 2) == String(repeating: "s", count: 39) + " (2).mp3")
    }

    @Test("확장자가 길어 줄기를 남길 수 없어도 번호를 붙인 이름은 48 스칼라 안")
    func withSuffixLongExtensionFits48() {
        for extensionLength in 38...45 {
            let name = "a." + String(repeating: "x", count: extensionLength)
            #expect(UsbPathRules.fileName(name).value == name)
            for number in [2, 10, 99] {
                let suffixed = UsbPathRules.withSuffix(name, number: number)
                #expect(suffixed.unicodeScalars.count <= UsbPathRules.maxScalars, "\(extensionLength) \(number)")
                #expect(suffixed.hasSuffix(" (\(number))") || suffixed.hasSuffix("." + String(repeating: "x", count: extensionLength)))
                #expect(UsbLayout.collisionKey(suffixed) != UsbLayout.collisionKey(name))
            }
        }
        // 줄기를 남길 수 없으면 이름 전체를 줄기로 보고 자른다
        let name = "a." + String(repeating: "x", count: 45)
        #expect(UsbPathRules.withSuffix(name, number: 2) == "a." + String(repeating: "x", count: 42) + " (2)")
        #expect(UsbPathRules.withSuffix(name, number: 99) == "a." + String(repeating: "x", count: 41) + " (99)")
    }

    @Test("Contents 경로는 성분 규칙을 모은다")
    func contentsPathJoinsComponents() {
        let path = UsbPathRules.contentsPath(artist: "Artist", album: nil, fileName: "a|b.mp3")
        #expect(path.value == "/Contents/Artist/UnknownAlbum/a_b.mp3")
        #expect(path.rules == [.emptyArtistAlbum, .forbiddenCharacters])
        let plain = UsbPathRules.contentsPath(artist: "A", album: "B", fileName: "f.flac")
        #expect(plain.value == "/Contents/A/B/f.flac")
        #expect(plain.rules.isEmpty)
    }

    @Test("골든: USB 파일 이름은 음원 경로의 끝 성분으로 짓는다(FileNameL이 옛 값이어도)")
    func audioFileNameFromFolderPath() {
        // rekordbox 7.2.x 빈 USB 내보내기(2026-10-08): FileNameL이 실제 파일 이름과 다른 곡 1개를 실제 파일 이름으로 내보냈다
        #expect(UsbPathRules.audioFileName(sourcePath: "/Music/곡、이름.mp3", fileNameL: "old name.mp3") == "곡、이름.mp3")
        #expect(UsbPathRules.audioFileName(sourcePath: "/Music/a.mp3", fileNameL: "a.mp3") == "a.mp3")
        // 경로가 없거나 로컬 경로가 아니면 FileNameL
        #expect(UsbPathRules.audioFileName(sourcePath: nil, fileNameL: "a.mp3") == "a.mp3")
        #expect(UsbPathRules.audioFileName(sourcePath: "stream:1", fileNameL: "a.mp3") == "a.mp3")
        #expect(UsbPathRules.audioFileName(sourcePath: "/", fileNameL: "a.mp3") == "a.mp3")
    }
}
