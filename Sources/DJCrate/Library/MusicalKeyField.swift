import DJCDomain
import SwiftUI

/// 태그 인스펙터의 키 고르기(#5): rekordbox 키 목록의 Camelot 이름(1A~12B)과 "없음"에서 고른다. 글자를 쓰지 않는다.
/// DJCrate가 추정한 키(추가한 곡은 음원 태그의 키)는 여기가 아니라 덱 제안 줄(`DeckSuggestionBar`)에서 제안한다. 고른 키는 추가한 곡을 넣을 때 함께 쓴다.
/// 값은 고르는 순간에만 초안에 넣는다(보이는 값이 바뀔 때마다 쓰지 않는다: 읽은 키가 옛 표기여도 건드리지 않는다).
struct MusicalKeyField: View {
    @Environment(\.textScale) private var textScale
    let model: TagInspectorModel
    let rows: [TrackRow]

    private var key: TagFields.Key { .musicalKey }

    var body: some View {
        let current = model.field(key, rows: rows)
        let edited = current.edited
        let editable = KeyPicker.isEditable(rows)
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { current.mixed ? KeyPicker.mixedTag : current.value }, set: { choose($0) })) {
                if current.mixed { Text(String(ui: "(여러 값)")).tag(KeyPicker.mixedTag) }
                Text(String(ui: "없음")).tag("")
                ForEach(KeyPicker.choices(current: current.mixed ? "" : current.value), id: \.self) { Text($0).tag($0) }
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
            .help(rows.compactMap(KeyPicker.unavailableReason).first ?? key.label)
            if editable, let reason = rows.compactMap(KeyPicker.unavailableReason).first {
                // 고른 곡 가운데 일부만 못 고칠 때: 그 곡은 빼고 쓴다는 것을 알린다
                Label(reason, systemImage: "lock").font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
            }
            TagConflictView(conflict: model.conflict(key, rows: rows)) { model.resolveConflict(key, keepingDraft: $0, rows: rows) }
        }
    }

    /// 사용자가 고른 값만 초안에 넣는다(여러 값 표식은 값이 아니다).
    private func choose(_ value: String) {
        guard value != KeyPicker.mixedTag else { return }
        model.pickKey(value, rows: rows)
    }
}

/// 현재 rekordbox 값과 내 초안이 부딪친 칸 하나를 고르게 한다(곡 하나를 골랐을 때, 충돌 값은 `TagInspectorModel.conflict`).
struct TagConflictView: View {
    let conflict: TagInspectorModel.Conflict?
    /// 고른 쪽(true면 내 초안 유지)
    let resolve: (_ keepingDraft: Bool) -> Void

    var body: some View {
        if let conflict {
            Text(String(ui: "현재 rekordbox: \(conflict.current)"))
                .textSelection(.enabled)
            Text(String(ui: "내 초안: \(conflict.draft)")).textSelection(.enabled)
            HStack {
                Button(.ui("내 초안 유지")) { resolve(true) }
                Button(.ui("rekordbox 값 사용")) { resolve(false) }
            }
        }
    }
}
