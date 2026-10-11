import DJCApplication
import DJCDomain
import SwiftUI

/// 쓰기 대기 목록 위: 라이브러리·추가 목록에 없는 곡의 초안이 있으면 알리고 목록을 연다(#175).
struct UnlinkedDraftsBar: View {
    let store: LibraryStore
    /// 시트를 띄우는 주 창 모델
    let window: LibraryWindowModel

    var body: some View {
        HStack(spacing: 12) {
            Label(String(ui: "rekordbox 라이브러리와 추가 목록에 없는 곡의 초안이 \(store.unlinkedDraftUUIDs.count)곡 있습니다."),
                  systemImage: "questionmark.folder")
            Spacer(minLength: 0)
            Button(.ui("연결되지 않은 초안 보기…")) { window.openUnlinkedDrafts() }
                .disabled(store.isWritingRekordbox)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.edge).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 연결되지 않은 초안 목록. 어디서 왔는지 모르므로 자동으로 지우지 않고, 고른 것만 확인한 뒤 버린다.
struct UnlinkedDraftsView: View {
    @Bindable var model: UnlinkedDraftsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.ui("연결되지 않은 초안")).font(.title2.bold())
            Text(.ui("지금 rekordbox 라이브러리와 추가 목록에 없는 곡의 초안입니다. rekordbox에서 뺀 곡이나 다른 라이브러리에서 만든 초안일 수 있으니 필요 없는 것만 골라 버리세요."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.drafts.isEmpty {
                Text(.ui("연결되지 않은 초안이 없습니다.")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.drafts) { draft in
                    Toggle(isOn: Binding(get: { model.isSelected(draft.uuid) }, set: { model.setSelected(draft.uuid, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: draft.title ?? String(draft.uuid.prefix(8)))
                            Text(verbatim: Self.detail(draft)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text(verbatim: draft.title ?? draft.uuid))
                }
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(UIColors.warning.color)
            }
            HStack {
                Button(.ui("모두 고르기")) { model.chooseAll() }
                    .disabled(!model.canChooseAll)
                Spacer()
                Button(.ui("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(.ui("선택한 초안 버리기…")) { model.askDiscard() }
                    .disabled(!model.canDiscard)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .onAppear { model.reload() }
        .alert(Text(verbatim: String(ui: "선택한 \(model.selected.count)곡의 초안을 버릴까요?")), isPresented: $model.confirming) {
            Button(.ui("초안 버리기"), role: .destructive) { model.discard() }
            Button(.ui("취소"), role: .cancel) {}
        } message: {
            Text(.ui("큐·그리드·게인·태그 초안을 모두 버리며 되돌릴 수 없습니다."))
        }
    }

    /// "큐·태그 · 2026. 10. 2. 오후 3:00 · UUID"
    static func detail(_ draft: UnlinkedDraft) -> String {
        var parts = [draft.kinds.map(\.label).joined(separator: "·")]
        if let modified = draft.modified { parts.append(modified.formatted(date: .abbreviated, time: .shortened)) }
        parts.append(draft.uuid)
        return parts.joined(separator: " · ")
    }
}
