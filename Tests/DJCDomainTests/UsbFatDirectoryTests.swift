import DJCDomain
import Foundation
import Testing

@Suite("FAT 폴더 항목 수 추정")
struct UsbFatDirectoryTests {
    @Test("대문자 8.3 이름은 짧은 이름 항목 하나")
    func sfnOnlyForUppercase83() {
        for name in ["ANLZ0000.DAT", "P000", "00000001", "A1.JPG", "00001", "X_1-2.MP3"] {
            #expect(UsbFatDirectory.entries(forName: name) == 1, "\(name)")
        }
        // 소문자·긴 이름·긴 확장자·공백·점 둘·ASCII 밖은 긴 이름 항목이 붙는다
        #expect(UsbFatDirectory.entries(forName: "a1.jpg") == 2)
        #expect(UsbFatDirectory.entries(forName: "ANLZ0000.2EXX") == 2)
        #expect(UsbFatDirectory.entries(forName: "TOOLONGNAME.MP3") == 3)
        #expect(UsbFatDirectory.entries(forName: "A B.MP3") == 2)
        #expect(UsbFatDirectory.entries(forName: "A.B.MP3") == 2)
        #expect(UsbFatDirectory.entries(forName: "É.MP3") == 2)
        #expect(UsbFatDirectory.entryLimit == 60_000)
    }

    @Test("긴 이름 항목은 UTF-16 13단위마다 하나")
    func lfnEntriesPer13Units() {
        #expect(UsbFatDirectory.entries(forName: "abcdefghijklm") == 2)
        #expect(UsbFatDirectory.entries(forName: "abcdefghijklmn") == 3)
        #expect(UsbFatDirectory.entries(forName: String(repeating: "a", count: 26)) == 3)
        #expect(UsbFatDirectory.entries(forName: String(repeating: "a", count: 27)) == 4)
        // 보충 평면 글자는 UTF-16 두 단위
        #expect(UsbFatDirectory.entries(forName: String(repeating: "😀", count: 7)) == 3)
    }
}
