import Foundation

/// 엑셀·구글 시트와 주고받는 탭 구분 텍스트. 칸 안에 탭·줄바꿈·따옴표가 있으면 따옴표로 감싼다.
public enum TSV {
    public static func quote(_ cell: String) -> String {
        guard cell.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 따옴표 칸(`"a\nb"`, 이중 따옴표 `""`)과 `\r\n`·`\r` 줄 끝을 처리한다.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = ""
        var inQuotes = false, atCellStart = true
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        if chars.last == "\n" { chars.removeLast() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    cell.append(c)
                }
            } else if c == "\"", atCellStart {
                inQuotes = true
            } else if c == "\t" {
                row.append(cell); cell = ""; atCellStart = true; i += 1; continue
            } else if c == "\n" {
                row.append(cell); rows.append(row); row = []; cell = ""; atCellStart = true; i += 1; continue
            } else {
                cell.append(c)
            }
            atCellStart = false
            i += 1
        }
        row.append(cell)
        rows.append(row)
        return rows
    }
}
