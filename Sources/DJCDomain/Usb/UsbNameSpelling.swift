import Foundation

/// USB 이름의 철자(유니코드 정규화) 규칙(#233).
/// Swift 문자열 `==`는 정규형이 같은 NFC(완성형)·NFD(풀어 쓴 자모)를 같다고 본다. 그래서 정규화만 다른 이름을 비교할 때는
/// 유니코드 스칼라로 본다.
public enum UsbNameSpelling {
    /// 철자(유니코드 스칼라)까지 같은지
    public static func sameScalars(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// NFC로 바꾸면 철자가 달라지는지
    public static func changesUnderNFC(_ value: String) -> Bool {
        !sameScalars(value, UsbLayout.nfc(value))
    }

    /// Device Library(export.pdb·exportExt.pdb)에 쓰는 사람이 읽는 문자열(이름·제목 등). 늘 NFC로 쓴다.
    /// CDJ-2000NXS는 풀어 쓴 한글(NFD, U+1100–U+11FF 자모)을 "~"로 보이고 완성형은 바르게 보였다(2026-10-09 관찰, #233).
    /// rekordbox는 받은 철자 그대로 쓰므로 rekordbox와 다르다(`pdbStringNFC`). 파일 경로는 USB의 실제 철자를 가리켜야 해 바꾸지 않는다
    public static func deviceLibraryText(_ value: String) -> String {
        UsbLayout.nfc(value)
    }

    /// 재생 목록 이름을 바꿔야 하는지. `formats`는 그 목록이 있고 이번에 고칠 수 있는 형식이다.
    /// - OneLibrary는 받은 철자 그대로 쓰므로(rekordbox와 같다) 철자가 다르면 바꾼다.
    /// - Device Library는 늘 NFC로 쓰므로(`deviceLibraryText`) Device Library에만 있는 목록은 NFC가 같으면 바꾸지 않는다.
    ///   그러지 않으면 NFC로 읽힌 USB 이름과 NFD인 로컬 이름이 동기화마다 바뀐 것으로 보인다.
    ///   USB의 Device Library에 NFD로 적힌 이름은 다음 쓰기에서 Device Library를 다시 만들어 고친다(`UsbEditSource.deviceLibraryNeedsNFC`).
    public static func playlistNeedsRename(from current: String, to name: String, formats: Set<UsbFormat>) -> Bool {
        formats.contains(.oneLibrary) ? !sameScalars(current, name) : current != name
    }
}
