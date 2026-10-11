import Foundation

/// 키 위치(ANSI 배열 키 코드)의 이름. 입력기와 무관하게 자판에 새겨진 글자로 보인다(한글 입력기에서 C를 "ㅊ"으로 보이지 않게).
public enum KeyLabel {
    public static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? String(ui: "키 \(Int(keyCode))")
    }

    private static let names: [UInt16: String] = {
        var names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
            34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
            46: "M", 47: ".", 50: "`",
            36: "Return", 48: "Tab", 49: "Space", 51: "⌫", 53: "Esc", 76: "Enter", 117: "⌦",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑", 114: "Help",
            65: keypad("."), 67: keypad("*"), 69: keypad("+"), 71: keypad("Clear"), 75: keypad("/"),
            78: keypad("−"), 81: keypad("="), 82: keypad("0"), 91: keypad("8"), 92: keypad("9"),
            93: "¥", 94: "_", 95: keypad(","), 102: "英数", 104: "かな",
        ]
        for (offset, code) in ([83, 84, 85, 86, 87, 88, 89] as [UInt16]).enumerated() {
            names[code] = keypad(String(offset + 1))
        }
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (offset, code) in functionKeys.enumerated() {
            names[code] = "F\(offset + 1)"
        }
        return names
    }()

    private static func keypad(_ key: String) -> String { String(ui: "숫자패드 \(key)") }
}
