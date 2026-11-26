import DJCDomain
import Foundation

/// 켜진 필터 조건 하나(머리 줄 칩, #339·#351). 칩을 누르면 그 조건만 꺼진다.
struct AttributeFilterChip: Equatable, Identifiable {
    /// 조건마다 값을 든다: 칩을 누른 사이 다른 곳에서 값이 바뀌었으면 끄지 않는다(`LibraryStore.clearAttributeFilter`)
    enum Condition: Hashable {
        case bpm(BPMRange)
        case key(KeyCondition)
        case genre(String)
        case rating(Int)
        /// 곡 색 하나. 색을 여럿 고르면 색마다 칩이 하나다
        case color(String)
    }

    let condition: Condition
    /// 칩에 보이는 글. 예: "BPM 120–130", "어울리는 키 8A", "장르 House", "★★★ 이상", "곡 색 Red"
    let title: String
    /// 화면 낭독 이름. 조건 전체를 읽고 누르면 무엇이 되는지 말한다
    let accessibilityName: String
    var id: Condition { condition }
}

/// 켠 필터 조건을 칩 목록으로 바꾼 값. 칩이 하나도 없으면 필터가 꺼져 있다.
/// 순서는 필터 창의 구역 순서와 같다: BPM, 키, 장르, 평점, 곡 색(곡 색은 rekordbox 색 순서).
struct AttributeFilterChips: Equatable {
    private(set) var chips: [AttributeFilterChip] = []

    init(filter: TrackFilter, colors: [TrackColor]) {
        if let bpm = filter.bpm, !bpm.isEmpty {
            let title = Self.bpmTitle(bpm)
            chips.append(AttributeFilterChip(condition: .bpm(bpm), title: title, accessibilityName: String(ui: "\(title) 필터 끄기")))
        }
        if let key = filter.key {
            let name = key.camelot ?? key.text
            let title = key.mode == .compatible ? String(ui: "어울리는 키 \(name)") : String(ui: "키 \(name)")
            chips.append(AttributeFilterChip(condition: .key(key), title: title, accessibilityName: String(ui: "\(title) 필터 끄기")))
        }
        if let genre = filter.genre {
            let title = String(ui: "장르 \(genre)")
            chips.append(AttributeFilterChip(condition: .genre(genre), title: title, accessibilityName: String(ui: "\(title) 필터 끄기")))
        }
        if filter.minimumRating > 0 {
            let count = min(filter.minimumRating, 5)
            chips.append(AttributeFilterChip(
                condition: .rating(count), title: AttributeFilterMenu.ratingTitle(count),
                accessibilityName: String(ui: "평점 \(AttributeFilterMenu.ratingSpoken(count)) 필터 끄기")))
        }
        // 목록에 없는 색 번호(라이브러리에서 지운 색)도 끌 수 있게 뒤에 번호순으로 둔다
        let known = colors.map(\.id).filter(filter.colorIDs.contains)
        for id in known + filter.colorIDs.subtracting(known).sorted() {
            let title = String(ui: "곡 색 \(TrackColor.name(of: id, in: colors))")
            chips.append(AttributeFilterChip(condition: .color(id), title: title, accessibilityName: String(ui: "\(title) 필터 끄기")))
        }
    }

    /// "BPM 120–130" · "BPM 128 이상" · "BPM 100 이하"
    static func bpmTitle(_ range: BPMRange) -> String {
        switch (range.lower, range.upper) {
        case let (lower?, upper?): String(ui: "BPM \(BPMRange.format(lower))–\(BPMRange.format(upper))")
        case let (lower?, nil): String(ui: "BPM \(BPMRange.format(lower)) 이상")
        case let (nil, upper?): String(ui: "BPM \(BPMRange.format(upper)) 이하")
        case (nil, nil): ""
        }
    }

    var isEmpty: Bool { chips.isEmpty }
    /// 줄인 칩에 남기는 첫 조건 글의 가로 길이 한도. 영문·숫자 1, 한글·기호 2로 센다. 길면 뒤를 …로 줄여 「외 N」이 잘리지 않게 한다
    static let collapsedLeadUnits = 20

    /// 폭이 모자라 칩 하나로 줄였을 때의 글. 첫 조건을 글로 남기고 나머지는 개수로 말한다. 예: "BPM 120–130 외 2"
    /// 조건이 하나뿐이면 그 조건 그대로다
    var collapsedTitle: String {
        guard let first = chips.first, chips.count > 1 else { return chips.first?.title ?? "" }
        return String(ui: "\(Self.clipped(first.title, units: Self.collapsedLeadUnits)) 외 \(chips.count - 1)")
    }

    /// 가로 길이(`units`)를 넘으면 뒤를 …로 줄인다
    static func clipped(_ text: String, units: Int) -> String {
        func width(_ character: Character) -> Int { (character.unicodeScalars.first?.value ?? 0) < 0x2E80 ? 1 : 2 }
        guard text.reduce(0, { $0 + width($1) }) > units else { return text }
        var result = ""
        var used = 0
        for character in text {
            if used + width(character) > units - 1 { break }
            result.append(character)
            used += width(character)
        }
        return result + "…"
    }
    /// 줄인 칩의 화면 낭독 이름. 누르면 켠 조건 목록이 열린다
    var collapsedAccessibilityName: String {
        chips.count > 1 ? String(ui: "필터 \(chips.count)개, 목록 열기") : (chips.first?.accessibilityName ?? "")
    }
}
