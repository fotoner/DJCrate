import SwiftUI

/// 머리 줄 자리 배치(#340). 왼쪽 묶음은 검색칸 · 필터 단추 · 켜진 필터 칩, 오른쪽 묶음은 목록 상태 · 주 단추 · `…` 메뉴 · 보기 전환이고
/// 가운데 남는 폭은 비운다. HStack은 남은 폭을 자식 수로 나눠 제안하므로 폭이 모자랄 때 무엇을 먼저 줄일지 정할 수 없다.
/// 그래서 줄이는 차례를 여기서 못 박는다(앞 단계가 안 들어갈 때만 다음 단계로 간다):
/// ① 켜진 필터 칩 → 「필터 N」 하나 ② 상태 표시 글 → 아이콘만 ③ 검색칸 240 → 160 ④ 쓰기 대기·USB 주 단추 이름의 덧붙은 말 → 툴팁으로
/// ⑤ 검색칸 160 → 120 ⑥ 필터 칩 숨김(필터 단추의 채운 아이콘이 켜짐을 알린다). ⑤⑥은 본문 최소 폭에 글자를 키운 때나 닿는 마지막 수단이다.
/// 주 단추와 `…` 메뉴, 보기 전환, 필터 단추는 줄이지 않는다. 각 자리 뷰는 제안받은 폭에 맞는 모양을 스스로 고른다(`ViewThatFits`·검색칸 폭 범위).
struct ListHeaderLayout: Layout {
    enum Role: Hashable {
        case search, filter, chips, status, primary, menu, mode
    }

    static let spacing: CGFloat = 10

    private struct RoleKey: LayoutValueKey {
        static let defaultValue: Role? = nil
    }

    static func role(_ role: Role) -> some ViewModifier { RoleModifier(role: role) }

    private struct RoleModifier: ViewModifier {
        let role: Role
        func body(content: Content) -> some View { content.layoutValue(key: RoleKey.self, value: role) }
    }

    private func views(_ subviews: Subviews) -> [Role: LayoutSubview] {
        var found: [Role: LayoutSubview] = [:]
        for subview in subviews { if let role = subview[RoleKey.self] { found[role] = subview } }
        return found
    }

    private func width(_ view: LayoutSubview?, _ proposal: CGFloat?) -> CGFloat {
        view?.sizeThatFits(ProposedViewSize(width: proposal, height: nil)).width ?? 0
    }

    /// 폭 `limit` 안에 드는 가장 앞 단계의 자리 폭. 어느 단계도 안 들면 마지막 단계(넘친다)
    private func widths(limit: CGFloat, _ views: [Role: LayoutSubview]) -> [Role: CGFloat] {
        let filter = width(views[.filter], nil), menu = width(views[.menu], nil), mode = width(views[.mode], nil)
        let searchWide = width(views[.search], nil), searchNarrow = width(views[.search], ListSearchField.narrowWidth)
        let searchLeast = width(views[.search], 0)
        // 칩은 (전부, 하나로 줄임, 숨김) 세 모양이다. 하나로 줄인 폭은 전부보다 1 좁게 제안해 알아낸다. 그 폭에도 안 들면(줄여도 안 좁아짐) 줄임 단계는 건너뛴다
        let chipsAll = width(views[.chips], nil)
        let chipsShrunk = chipsAll > 0 ? width(views[.chips], chipsAll - 1) : 0
        let chipsOne = chipsShrunk > 0 ? chipsShrunk : chipsAll
        let statusText = width(views[.status], nil)
        let statusIcon = views[.status] == nil ? 0 : width(views[.status], max(statusText - 1, 0))
        let primaryFull = width(views[.primary], nil), primaryShort = width(views[.primary], 0)
        func rung(search: CGFloat, chips: CGFloat, status: CGFloat, primary: CGFloat) -> [Role: CGFloat] {
            [.search: search, .filter: filter, .chips: chips, .status: status, .primary: primary, .menu: menu, .mode: mode]
        }
        let ladder = [
            rung(search: searchWide, chips: chipsAll, status: statusText, primary: primaryFull),
            rung(search: searchWide, chips: chipsOne, status: statusText, primary: primaryFull),
            rung(search: searchWide, chips: chipsOne, status: statusIcon, primary: primaryFull),
            rung(search: searchNarrow, chips: chipsOne, status: statusIcon, primary: primaryFull),
            rung(search: searchNarrow, chips: chipsOne, status: statusIcon, primary: primaryShort),
            rung(search: searchLeast, chips: chipsOne, status: statusIcon, primary: primaryShort),
            rung(search: searchLeast, chips: 0, status: statusIcon, primary: primaryShort),
        ]
        return ladder.first { total($0) <= limit + 0.01 } ?? ladder[ladder.count - 1]
    }

    private func total(_ widths: [Role: CGFloat]) -> CGFloat {
        let present = widths.values.filter { $0 > 0 }
        return present.reduce(0, +) + CGFloat(max(present.count - 1, 0)) * Self.spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let found = views(subviews)
        let ideal = widths(limit: .infinity, found)
        return CGSize(width: proposal.width ?? total(ideal), height: proposal.height ?? ListHeaderBar.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let found = views(subviews)
        let chosen = widths(limit: bounds.width, found)
        func place(_ roles: [Role], from start: CGFloat) -> CGFloat {
            var x = start
            for role in roles {
                guard let view = found[role] else { continue }
                let width = chosen[role] ?? 0
                view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
                if width > 0 { x += width + Self.spacing }
            }
            return x
        }
        let right: [Role] = [.status, .primary, .menu, .mode]
        let rightWidth = total(chosen.filter { right.contains($0.key) })
        // 가운데를 비우고 오른쪽 묶음을 오른쪽 끝에 붙인다. 모자라면(마지막 단계도 넘칠 때) 왼쪽 묶음 바로 뒤에 잇는다
        let leftEnd = place([.search, .filter, .chips], from: bounds.minX)
        _ = place(right, from: max(bounds.maxX - rightWidth, leftEnd))
    }
}
