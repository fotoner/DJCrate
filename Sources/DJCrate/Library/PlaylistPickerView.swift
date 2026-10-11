import DJCDomain
import SwiftUI

/// '재생 목록에 넣기…': 이름(폴더 경로 포함)으로 목록을 찾아 고른 곡을 넣는다. 찾지 않을 때는 최근 목록이 위에 온다.
struct PlaylistPickerView: View {
    @Bindable var model: PlaylistPickerModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    var body: some View {
        let choices = model.choices
        VStack(alignment: .leading, spacing: 12) {
            Text(.ui("재생 목록에 넣기 (\(model.trackCount)곡)")).font(.headline)
            TextField(text: $model.query, prompt: Text(.ui("목록·폴더 이름"))) { Text(.ui("찾기")) }
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if model.addSelection() { dismiss() } }
            List(choices, selection: $model.selection) { choice in
                HStack(spacing: 6) {
                    Image(systemName: choice.recent ? "clock" : "music.note.list").foregroundStyle(.secondary)
                    Text(verbatim: choice.name).lineLimit(1)
                    if !choice.path.isEmpty {
                        Text(verbatim: choice.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .tag(choice.id)
                .accessibilityElement(children: .combine)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in if model.add(ids.first) { dismiss() } }
            .overlay {
                if choices.isEmpty { Text(.ui("맞는 재생 목록이 없습니다")).foregroundStyle(.secondary) }
            }
            HStack {
                Text(.ui("넣은 곡은 ‘rekordbox에 쓰기’(⇧⌘E)로 저장합니다.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(.ui("넣기")) { if model.addSelection() { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choices.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
        .onAppear { searchFocused = true }
    }
}
