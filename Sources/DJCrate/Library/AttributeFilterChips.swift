import DJCDomain
import Foundation

/// 켜진 평점·곡 색 조건 하나(머리 줄 칩, #339). 칩을 누르면 그 조건만 꺼진다.
struct AttributeFilterChip: Equatable, Identifiable {
    enum Condition: Hashable {
        case rating(Int)
        case color(String)
    }

    let condition: Condition
    /// 칩에 보이는 글. 예: "★★★ 이상", "곡 색 Red"
    let title: String
    /// 화면 낭독 이름. 조건 전체를 읽고 누르면 무엇이 되는지 말한다
    let accessibilityName: String
    var id: Condition { condition }
}

/// 켠 평점·곡 색 조건을 칩 목록으로 바꾼 값. 칩이 하나도 없으면 필터가 꺼져 있다.
/// 평점 칩이 먼저, 곡 색 칩이 다음이다(필터 메뉴의 구역 순서와 같다).
struct AttributeFilterChips: Equatable {
    private(set) var chips: [AttributeFilterChip] = []

    init(minimumRating: Int, colorFilter: String?, colors: [TrackColor]) {
        if minimumRating > 0 {
            let count = min(minimumRating, 5)
            chips.append(AttributeFilterChip(
                condition: .rating(count), title: AttributeFilterMenu.ratingTitle(count),
                accessibilityName: String(ui: "평점 \(AttributeFilterMenu.ratingSpoken(count)) 필터 끄기")))
        }
        if let color = colorFilter {
            let name = String(ui: "곡 색 \(TrackColor.name(of: color, in: colors))")
            chips.append(AttributeFilterChip(condition: .color(color), title: name, accessibilityName: String(ui: "\(name) 필터 끄기")))
        }
    }

    var isEmpty: Bool { chips.isEmpty }
    /// 폭이 모자라 칩 하나로 줄였을 때의 글. 예: "필터 2"
    var collapsedTitle: String { String(ui: "필터 \(chips.count)") }
    /// 줄인 칩의 화면 낭독 이름. 누르면 모두 꺼진다
    var collapsedAccessibilityName: String { String(ui: "필터 \(chips.count)개 모두 끄기") }
}
