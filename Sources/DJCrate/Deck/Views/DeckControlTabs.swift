import DJCDomain
import SwiftUI

/// 덱 아래 조작 탭(CUE/LOOP · GRID). 왼쪽 세로 탭 중 고른 탭이 오른쪽 판과 같은 색으로 이어진다.
/// 두 판을 겹쳐 두고 고른 것만 보여, 탭을 바꿔도 덱 높이(파형·목록 배치)가 흔들리지 않는다.
/// GRID 탭이 곧 그리드 편집 모드다: 탭을 고르면 편집을 켜고, 다른 탭으로 가면 끈다.
struct DeckControlTabs: View {
    @Environment(\.textScale) private var textScale
    let tags: TagEditStore
    @Bindable var deck: DeckModel
    let tabWidth: CGFloat
    @AppStorage(SettingKeys.deckControlTab.name) private var tabName = SettingKeys.deckControlTab.defaultValue

    private var tab: DeckControlTab { DeckControlTab(rawValue: tabName) ?? .cueLoop }
    private var tabHeight: CGFloat { TextScale.length(30, scale: textScale) }

    private var radius: CGFloat { 6 }

    var body: some View {
        // 판 높이를 내용이 정하고, 탭들은 그 높이를 나눠 가져 탭 줄과 판의 위아래 끝이 맞는다.
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(DeckControlTab.allCases, id: \.self) { tabButton($0) }
            }
            .frame(width: tabWidth)
            .frame(maxHeight: .infinity)
            ZStack(alignment: .topLeading) {
                page(.cueLoop) {
                    VStack(alignment: .leading, spacing: 6) {
                        TransportBar(deck: deck)
                        AudioControlsRow(deck: deck)
                    }
                }
                page(.grid) {
                    VStack(alignment: .leading, spacing: 6) {
                        GridEditorBar(deck: deck, framed: false)
                        // 게인·그리드·키 제안도 이 판 안에 둔다. 보류 중인 제안이 있으면 GRID 탭에 점을 찍는다.
                        DeckSuggestionBar(tags: tags, deck: deck, singleLine: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: TextScale.length(24, scale: textScale))
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: tabHeight * CGFloat(DeckControlTab.allCases.count), alignment: .topLeading)
            .background(fill(tab), in: panelShape)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if tab == .grid { deck.gridEditing = true } else if deck.gridEditing { tabName = DeckControlTab.grid.rawValue }
        }
        .onChange(of: tabName) { deck.gridEditing = tab == .grid }
        // 자가 테스트 등이 편집을 직접 켜고 끄면 탭도 따라간다.
        .onChange(of: deck.gridEditing) { _, editing in
            let target = (editing ? DeckControlTab.grid : .cueLoop).rawValue
            if tabName != target { tabName = target }
        }
    }

    private func page<Content: View>(_ item: DeckControlTab, @ViewBuilder _ content: () -> Content) -> some View {
        let shown = tab == item
        return content()
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }

    private func tabButton(_ item: DeckControlTab) -> some View {
        let selected = tab == item
        return Button { tabName = item.rawValue } label: {
            Text(verbatim: item.label)
                .font(.scaled(size: 11, weight: .heavy, textScale))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: tabHeight, maxHeight: .infinity)
                .background(selected ? fill(item) : Color.clear,
                            in: UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius))
                .overlay(alignment: .topTrailing) {
                    if item == .grid { DeckSuggestionBadge(tags: tags, deck: deck) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(item.accessibilityName)
    }

    /// 고른 탭과 이어지는 판 모서리만 각지게 둔다(위 탭이면 왼쪽 위, 아래 탭이면 왼쪽 아래).
    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: tab == DeckControlTab.allCases.first ? 0 : radius,
                               bottomLeadingRadius: tab == DeckControlTab.allCases.last ? 0 : radius,
                               bottomTrailingRadius: radius, topTrailingRadius: radius)
    }

    /// 그리드 판은 초안 색(그리드 편집 막대와 같은 색)으로 칠해 지금 그리드를 고치는 자리임을 보인다.
    private func fill(_ item: DeckControlTab) -> Color {
        switch item {
        case .cueLoop: Color.primary.opacity(0.07)
        case .grid: UIColors.draftFill
        }
    }
}

/// 보류 중인 제안이 있으면 GRID 탭 모서리에 빨간 점. 목록 상태는 이 작은 뷰 안에서만 읽는다(#129).
private struct DeckSuggestionBadge: View {
    @Environment(\.textScale) private var textScale
    let tags: TagEditStore
    let deck: DeckModel

    var body: some View {
        let count = DeckSuggestions(deck: deck, tags: tags).list.shown.count
        if count > 0 {
            Circle()
                .fill(Color.red)
                .frame(width: TextScale.length(7, scale: textScale), height: TextScale.length(7, scale: textScale))
                .padding(5)
                .accessibilityLabel(String(ui: "제안 \(count)개"))
                .help(String(ui: "제안 \(count)개"))
        }
    }
}

private extension DeckControlTab {
    /// 탭 글자는 CDJ·rekordbox 표기를 따라 번역하지 않는다.
    var label: String {
        switch self {
        case .cueLoop: "CUE/LOOP"
        case .grid: "GRID"
        }
    }

    var accessibilityName: String {
        switch self {
        case .cueLoop: String(ui: "큐·루프")
        case .grid: String(ui: "그리드 편집")
        }
    }
}
