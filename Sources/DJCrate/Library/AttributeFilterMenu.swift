import DJCDomain
import SwiftUI

/// 툴바의 평점·곡 색 거르기(#65). 지금 목록(사이드바·검색)에서 평점이 몇 개 이상이거나 곡 색이 같은 곡만 보인다.
/// rekordbox 값(초안 전)으로 거른다: 정렬·사이드바 필터와 같다. 켜져 있으면 아이콘을 채우고 VoiceOver 값에 조건을 읽는다.
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
                Button(.ui("평점·곡 색 거르기 끄기")) { clear() }
            }
        } label: {
            Label(.ui("평점·곡 색 거르기"), systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(active ? summary : String(ui: "평점·곡 색으로 목록을 거릅니다(초안 전 rekordbox 값)"))
        .accessibilityValue(active ? summary : String(ui: "꺼짐"))
    }

    /// 켠 조건을 한 줄로(툴팁·VoiceOver)
    private var summary: String {
        var parts: [String] = []
        if store.minimumRating > 0 { parts.append(Self.ratingSpoken(store.minimumRating)) }
        if let color = store.colorFilter { parts.append(String(ui: "곡 색 \(TrackColor.name(of: color, in: store.trackColors))")) }
        return String(ui: "거르는 중: \(parts.joined(separator: " · "))")
    }

    private func clear() {
        store.minimumRating = 0
        store.colorFilter = nil
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
