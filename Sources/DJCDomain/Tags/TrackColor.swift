import Foundation

/// rekordbox 곡 색(`djmdColor` 한 줄, #65). 곡 행 `ColorID`가 `ID`를 글자로 가리킨다.
/// rekordbox 7.2.18 라이브러리는 여덟 색이다: `ID` '1'~'8', `SortKey` 1~8, `Commnt` Pink·Red·Orange·Yellow·Green·Aqua·Blue·Purple,
/// `ColorCode` NULL(2026-10-04 묶음 2 사본). 색을 고르거나 지울 때 `djmdColor`는 바뀌지 않았다.
public struct TrackColor: Hashable, Sendable, Identifiable {
    /// `djmdColor.ID`
    public let id: String
    /// rekordbox가 보이는 이름(`djmdColor.Commnt`)
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// rekordbox 7.2.18의 여덟 색(정렬 순서). 라이브러리에서 색 목록을 읽지 못했을 때 쓴다.
    public static let rekordboxDefaults: [TrackColor] = ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"]
        .enumerated().map { TrackColor(id: String($0.offset + 1), name: $0.element) }

    /// 초안에 둘 수 있는 색 번호(rekordbox 여덟 색)
    public static let ids: Set<String> = Set(rekordboxDefaults.map(\.id))

    /// 시트 붙여넣기·CLI 입력("2"·"red"·"Blue")을 초안 값으로. 비웠거나 '0'이면 빈칸(색 없음), 모르는 값이면 nil.
    /// 이름은 라이브러리의 색 이름(`colors`)과 대소문자 없이 맞춘다.
    public static func accepted(_ text: String, in colors: [TrackColor]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0" { return "" }
        if ids.contains(trimmed) { return trimmed }
        return colors.first { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame && ids.contains($0.id) }?.id
    }

    /// 색 번호의 이름. 모르는 번호는 번호 그대로, 빈칸은 빈칸이다.
    public static func name(of id: String, in colors: [TrackColor]) -> String {
        guard !id.isEmpty else { return "" }
        return colors.first { $0.id == id }?.name ?? id
    }
}

/// 평점(`djmdContent.Rating`, #65). rekordbox는 별 수(0~5)를 정수 그대로 쓴다(XML의 0·51·…·255 척도가 아니다, 2026-10-04 묶음 2).
public enum TrackRating {
    /// 고를 수 있는 값(별 1~5개). 없음은 빈칸이다.
    public static let choices: [String] = (1...5).map(String.init)

    /// 입력("3"·"★★★"·"0"·"")을 초안 값으로. 0·빈칸은 빈칸(없음), 1~5가 아니면 nil.
    public static func accepted(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0" { return "" }
        if choices.contains(trimmed) { return trimmed }
        let filled = trimmed.filter { $0 == "★" }.count
        guard trimmed.allSatisfy({ $0 == "★" || $0 == "☆" }), trimmed.count == 5 || !trimmed.contains("☆"),
              (1...5).contains(filled) else { return nil }
        return String(filled)
    }

    /// 목록·시트에 보일 별("★★★☆☆"). 없음은 빈칸.
    public static func stars(_ value: String) -> String {
        guard let count = Int(value), count > 0 else { return "" }
        let filled = min(count, 5)
        return String(repeating: "★", count: filled) + String(repeating: "☆", count: 5 - filled)
    }

    /// 칸이 좁아 `stars`가 안 들어갈 때 대신 보일 짧은 표기("3★"). 없음은 빈칸.
    /// 별을 줄여 자르면("★★★…") 3·4·5가 같아 보이므로, 별 수를 숫자로 먼저 적는다.
    public static func compact(_ value: String) -> String {
        guard let count = Int(value), count > 0 else { return "" }
        return "\(min(count, 5))★"
    }
}
