import Foundation

/// FAT 폴더 하나에 들어가는 항목 수 추정
public enum UsbFatDirectory {
    /// FAT 폴더 항목은 65,536개가 한계다. 여유를 둔다.
    public static let entryLimit = 60_000

    /// 짧은 이름(8.3)에 쓸 수 있는 ASCII 글자(대문자·숫자·기호)
    static let shortNameCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~".unicodeScalars)

    /// 항목 수 = 짧은 이름 1 + (8.3에 맞으면 0, 아니면 ⌈UTF-16 길이 / 13⌉). AppleDouble("._")은 세지 않는다(끝에 지운다).
    public static func entries(forName name: String) -> Int {
        fitsShortName(name) ? 1 : 1 + (name.utf16.count + 12) / 13
    }

    /// 대문자 8.3 이름(줄기 1–8, 확장자 0–3, 점 하나 이하)
    static func fitsShortName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let stem = parts.first, (1...8).contains(stem.unicodeScalars.count) else { return false }
        if parts.count == 2 && !(1...3).contains(parts[1].unicodeScalars.count) { return false }
        return parts.allSatisfy { $0.unicodeScalars.allSatisfy(shortNameCharacters.contains) }
    }
}
