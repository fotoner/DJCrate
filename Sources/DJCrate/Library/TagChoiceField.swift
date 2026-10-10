import DJCDomain
import SwiftUI

/// 태그 인스펙터의 평점·곡 색 고르기(#65): 없음·별 1~5개, 없음·rekordbox 색에서 고른다. 글자를 쓰지 않는다.
/// 값은 고르는 순간에만 초안에 넣는다. 고칠 수 없는 곡(추가한 곡, 상태 258처럼 쓰기를 확인하지 않은 곡)은 빼고 쓰며 이유를 보인다.
struct TagChoiceField: View {
    @Environment(\.textScale) private var textScale
    let model: TagInspectorModel
    let rows: [TrackRow]
    let key: TagFields.Key

    /// 곡 여럿의 값이 서로 다를 때 고르기 목록의 현재 표식(고를 수 있는 값이 아니다)
    static let mixedTag = "\u{1}mixed"

    var body: some View {
        let current = model.field(key, rows: rows)
        let edited = current.edited
        let reasons = rows.compactMap { TrackListTagEditing.unavailableReason($0, key: key) }
        let editable = reasons.count < rows.count
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { current.mixed ? Self.mixedTag : current.value }, set: { choose($0) })) {
                if current.mixed { Text(String(ui: "(여러 값)")).tag(Self.mixedTag) }
                ForEach(TagChoice.options(key, current: current.mixed ? "" : current.value, colors: model.trackColors), id: \.value) { option in
                    label(option).tag(option.value).disabled(!option.enabled)
                }
            } label: {
                // 초안이면 칸 이름 옆에 연필 표식을 붙이고 VoiceOver 이름에도 "초안"을 더한다(색만으로 알리지 않는다).
                HStack(spacing: 4) {
                    Text(key.label)
                    if edited {
                        Image(systemName: DraftMark.symbol).foregroundStyle(UIColors.draft.color).help(DraftMark.help)
                    }
                }
            }
            .accessibilityLabel(edited ? "\(key.label), \(DraftMark.spoken)" : key.label)
            .foregroundStyle(edited ? UIColors.draft.color : .primary)
            .disabled(!editable)
            .help(reasons.first ?? key.label)
            if let reason = reasons.first {
                // 고를 수 없거나(모든 곡) 고른 곡 가운데 일부만 못 고칠 때: 그 곡은 빼고 쓴다는 것을 알린다
                Label(reason, systemImage: "lock").font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
            }
            TagConflictView(conflict: model.conflict(key, rows: rows)) { model.resolveConflict(key, keepingDraft: $0, rows: rows) }
        }
    }

    @ViewBuilder private func label(_ option: TagChoice.Option) -> some View {
        if key == .color, let image = TagChoice.swatchImage(option.value) {
            Label { Text(verbatim: option.title) } icon: { Image(nsImage: image) }
        } else if key == .rating, !option.value.isEmpty {
            Text(verbatim: option.title).accessibilityLabel(TagChoice.spoken(key, option.value, colors: model.trackColors))
        } else {
            Text(verbatim: option.title)
        }
    }

    /// 사용자가 고른 값만 초안에 넣는다(여러 값 표식은 값이 아니다).
    private func choose(_ value: String) {
        guard value != Self.mixedTag else { return }
        model.pick(key, value, rows: rows)
    }
}
