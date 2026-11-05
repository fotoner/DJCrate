import DJCDomain
import SwiftUI

/// 머리 줄의 평점·곡 색 필터 단추(#65, 화면 이름은 #299에서 '거르기' → '필터', 자리는 #339에서 툴바 → 머리 줄). 지금 목록(사이드바·검색)에서 평점이 몇 개 이상이거나 곡 색이 같은 곡만 보인다.
/// rekordbox 값(초안 전)으로 거른다: 정렬·사이드바 항목과 같다. 켜져 있으면 아이콘을 채우고 VoiceOver 값에 조건을 읽는다.
/// 켜진 조건은 단추 옆 칩(`ListFilterChips`)이 글로 보인다. 필터가 걸리지 않는 목록(`LibraryStore.listIsFilterable`)에서는 머리 줄이 이 단추를 두지 않는다.
struct AttributeFilterMenu: View {
    @Bindable var store: LibraryStore

    var body: some View {
        let active = store.isAttributeFiltered
        Menu {
            Section(.ui("평점")) {
                Picker(.ui("평점"), selection: $store.minimumRating) {
                    Text(.ui("모든 평점")).tag(0)
                    ForEach(1...5, id: \.self) { count in
                        Text(verbatim: Self.ratingTitle(count)).tag(count).accessibilityLabel(Self.ratingSpoken(count))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section(.ui("곡 색")) {
                Picker(.ui("곡 색"), selection: $store.colorFilter) {
                    Text(.ui("모든 곡 색")).tag(String?.none)
                    ForEach(store.trackColors.filter { TrackColor.ids.contains($0.id) }) { color in
                        Label {
                            Text(verbatim: color.name)
                        } icon: {
                            if let image = TagChoice.swatchImage(color.id) { Image(nsImage: image) }
                        }
                        .tag(String?.some(color.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if active {
                Divider()
                Button(.ui("평점·곡 색 필터 끄기")) { store.clearAttributeFilters() }
            }
        } label: {
            Label(.ui("평점·곡 색 필터"), systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // 아이콘만 있는 단추라 이름을 알리고, 거르는 기준(초안 전 값)을 함께 적는다. 켠 조건은 칩이 말한다
        .help(.ui("평점·곡 색 필터: rekordbox에 들어 있는 값으로 목록을 거릅니다"))
        .selfTestFrame("listHeader.filter", clearsOnDisappear: true)
        .accessibilityValue(active ? summary : String(ui: "꺼짐"))
    }

    /// 켠 조건을 한 줄로(툴팁·VoiceOver)
    private var summary: String {
        var parts: [String] = []
        if store.minimumRating > 0 { parts.append(Self.ratingSpoken(store.minimumRating)) }
        if let color = store.colorFilter { parts.append(String(ui: "곡 색 \(TrackColor.name(of: color, in: store.trackColors))")) }
        return String(ui: "필터 켜짐: \(parts.joined(separator: " · "))")
    }

    /// "★★★ 이상"(별 다섯은 그것만)
    static func ratingTitle(_ count: Int) -> String {
        let stars = String(repeating: "★", count: count)
        return count == 5 ? stars : String(ui: "\(stars) 이상")
    }

    static func ratingSpoken(_ count: Int) -> String {
        count == 5 ? String(ui: "별 5개") : String(ui: "별 \(count)개 이상")
    }
}
