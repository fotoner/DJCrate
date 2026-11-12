import DJCDomain
import SwiftUI

/// 머리 줄 필터 단추 오른쪽의 칩 자리(#339·#351). 켜진 조건마다 글자와 ✕만 있는 작은 단추를 두고, 누르면 그 조건만 꺼진다.
/// 폭이 모자라면(배치가 제안하는 폭에 따라 `ViewThatFits`가 고른다) 첫 조건을 글로 남긴 「BPM 120–130 외 2 ✕」 하나로 줄인다.
/// 이 줄인 칩을 누르면 켠 조건 목록이 열리고, 조건마다 하나씩 끈다. 모두 끄기는 필터 창에 있다.
/// 그래도 모자라면 숨긴다. 켜진 조건이 없으면 폭 0이다.
/// 필터 값은 이 잎만 읽는다: 필터를 바꿔도 `ContentView`·`LibraryDetail`·`ListHeaderBar` 본문은 다시 계산하지 않는다.
struct ListFilterChips: View {
    let store: LibraryStore

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        let chips = store.attributeFilterChips
        if chips.isEmpty {
            // 칩 자리는 배치(`ListHeaderLayout`)가 모양을 고른다. 켜진 조건이 없으면 폭 0이다
            Color.clear.frame(width: 0, height: 0)
        } else {
            // 칩이 다 들어가는 첫 모양을, 안 들어가면 하나로 줄인 모양을 고른다. 칩 자리는 남는 폭을 모두 받아야 두 모양을 가를 폭을 받는다
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) {
                    ForEach(chips.chips) { chip in
                        FilterChipButton(title: chip.title, accessibilityName: chip.accessibilityName) {
                            store.clearAttributeFilter(chip.condition)
                        }
                    }
                }
                CollapsedFilterChip(chips: chips) { store.clearAttributeFilter($0) }
                // 배치가 폭 0을 제안하면(마지막 수단) 칩을 숨긴다. 켜진 조건은 필터 단추의 채운 아이콘이 알린다
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }
}

/// 줄인 칩. 조건이 여럿이면 누르면 켠 조건 목록이 열리고, 하나뿐이면 그 조건이 바로 꺼진다
private struct CollapsedFilterChip: View {
    /// 줄인 칩이 차지할 가장 긴 폭(글자 배율을 곱한다). 첫 조건 글은 `AttributeFilterChips.collapsedLeadUnits`로 먼저 줄이므로 이 한도는 안전망이다
    static let maxWidth: CGFloat = 220

    let chips: AttributeFilterChips
    let clear: (AttributeFilterChip.Condition) -> Void
    @State private var isPresented = false

    var body: some View {
        FilterChipButton(title: chips.collapsedTitle, accessibilityName: chips.collapsedAccessibilityName, maxWidth: Self.maxWidth) {
            if chips.chips.count > 1 { isPresented.toggle() } else if let only = chips.chips.first { clear(only.condition) }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ActiveFilterList(chips: chips.chips) { clear($0) }
        }
    }
}

/// 켠 조건 목록: 줄마다 조건 글과 ✕. 누르면 그 조건 하나만 꺼진다. 마지막 하나를 끄면 칩과 함께 사라진다
private struct ActiveFilterList: View {
    @Environment(\.textScale) private var textScale
    let chips: [AttributeFilterChip]
    let clear: (AttributeFilterChip.Condition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(chips) { chip in
                Button { clear(chip.condition) } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: chip.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "xmark").font(.scaled(.caption2, textScale).weight(.bold)).foregroundStyle(.secondary)
                    }
                    .font(.scaled(.callout, textScale))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chip.accessibilityName)
            }
        }
        .padding(6)
        .frame(width: 240)
    }
}

/// 글자와 ✕만 있는 작은 단추. 배경·테두리·색 띠를 두지 않는다
private struct FilterChipButton: View {
    @Environment(\.textScale) private var textScale
    let title: String
    let accessibilityName: String
    /// 정하면 글자가 이 폭(글자 배율 1일 때)을 넘을 때 뒤를 줄인다(줄인 칩)
    var maxWidth: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                Image(systemName: "xmark").font(.scaled(.caption2, textScale).weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.scaled(.callout, textScale))
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .frame(maxWidth: maxWidth.map { $0 * textScale })
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(accessibilityName)
        .selfTestFrame("listHeader.chip.\(title)", clearsOnDisappear: true)
    }
}

/// 머리 줄 오른쪽 끝: 목록 | 태그 시트 전환과, 태그 시트일 때만 보이는 ⓘ(초안 범례)(#339).
/// 보기 모드와 막힘 이유는 이 잎만 읽는다. 전환이 막히는 조건·이유와 보기 메뉴(⌘1·⌘2)는 툴바에 있던 때와 같다.
struct ListViewModeControls: View {
    @AppStorage(SettingKeys.sheetMode.name) private var sheetMode = SettingKeys.sheetMode.defaultValue
    let store: LibraryStore

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        let blocked = store.viewModeBlockReason
        HStack(spacing: 8) {
            if store.showsTagSheet(sheetMode: sheetMode) {
                InfoPopoverButton(label: String(ui: "저장 대기 표시"),
                                  lines: [String(ui: "왼쪽 위 모서리 삼각형이 붙은 칸은 저장 안 한 값입니다.")])
                    .selfTestFrame("listHeader.info", clearsOnDisappear: true)
            }
            Picker(.ui("보기"), selection: $sheetMode) {
                Text(.ui("목록")).tag(false)
                Text(.ui("태그 시트")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(blocked != nil)
            // 글자로 보이는 전환이라 막힐 때의 이유만 알린다
            .help(blocked ?? "")
            .selfTestFrame("listHeader.viewMode")
        }
    }
}
