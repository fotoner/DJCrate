import DJCDomain
import Foundation
import Testing

/// #233: NFC·NFD 철자 비교와 목록 이름 바꾸기 판정. 이름은 지어낸 값이다
@Suite("USB 이름 철자")
struct UsbNameSpellingTests {
    let nfc = "한글 목록".precomposedStringWithCanonicalMapping
    let nfd = "한글 목록".decomposedStringWithCanonicalMapping

    @Test("Swift ==는 NFC·NFD를 같다고 보지만 철자 비교는 다르게 본다")
    func scalarsDiffer() {
        #expect(nfc == nfd)
        #expect(!UsbNameSpelling.sameScalars(nfc, nfd) && UsbNameSpelling.sameScalars(nfc, nfc))
        #expect(UsbNameSpelling.changesUnderNFC(nfd) && !UsbNameSpelling.changesUnderNFC(nfc) && !UsbNameSpelling.changesUnderNFC("ASCII"))
        #expect(UsbNameSpelling.deviceLibraryText(nfd).unicodeScalars.elementsEqual(nfc.unicodeScalars))
        // NFD 자모(U+1100–U+11FF)가 NFC 음절(U+AC00–U+D7A3)이 된다
        #expect(nfd.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) })
        #expect(!UsbNameSpelling.deviceLibraryText(nfd).unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) })
    }

    @Test("목록 이름 바꾸기: OneLibrary에 있으면 철자로, Device Library에만 있으면 정규형으로 본다")
    func playlistRename() {
        #expect(UsbNameSpelling.playlistNeedsRename(from: nfd, to: nfc, formats: [.oneLibrary, .deviceLibrary]))
        #expect(UsbNameSpelling.playlistNeedsRename(from: nfd, to: nfc, formats: [.oneLibrary]))
        #expect(!UsbNameSpelling.playlistNeedsRename(from: nfd, to: nfc, formats: [.deviceLibrary]))
        #expect(!UsbNameSpelling.playlistNeedsRename(from: nfc, to: nfc, formats: [.oneLibrary, .deviceLibrary]))
        #expect(UsbNameSpelling.playlistNeedsRename(from: nfc, to: "다른 이름", formats: [.deviceLibrary]))
        #expect(!UsbNameSpelling.playlistNeedsRename(from: nfd, to: nfc, formats: []))
    }
}
