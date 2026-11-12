import DJCDomain
import SwiftUI

/// 머리 줄 필터 단추 오른쪽의 칩 자리(#339). 켜진 조건마다 글자와 ✕만 있는 작은 단추를 두고, 누르면 그 조건만 꺼진다.
/// 폭이 모자라면(배치가 제안하는 폭에 따라 `ViewThatFits`가 고른다) 「필터 N ✕」 하나로 줄이고, 누르면 모두 꺼진다.
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
                FilterChipButton(title: chips.collapsedTitle, accessibilityName: chips.collapsedAccessibilityName) {
                    store.clearAttributeFilters()
                }
                // 배치가 폭 0을 제안하면(마지막 수단) 칩을 숨긴다. 켜진 조건은 필터 단추의 채운 아이콘이 알린다
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }
}

/// 글자와 ✕만 있는 작은 단추. 배경·테두리·색 띠를 두지 않는다
private struct FilterChipButton: View {
    @Environment(\.textScale) private var textScale
    let title: String
    let accessibilityName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(verbatim: title).lineLimit(1)
                Image(systemName: "xmark").font(.scaled(.caption2, textScale).weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.scaled(.callout, textScale))
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
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
