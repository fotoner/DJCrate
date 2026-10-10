import AppKit
import DJCApplication
import DJCDomain
import SwiftUI
import UniformTypeIdentifiers

/// 태그 인스펙터의 그림 칸(#66): 지금 그림(또는 초안 그림)을 보이고, 그림 파일을 끌어다 놓거나 골라 넣기·바꾸기 초안을, 지우기 초안을 만든다.
/// 반영하면 rekordbox 라이브러리의 그림만 바뀌고 음원 파일에 든 그림은 그대로다.
struct ArtworkInspectorSection: View {
    @Environment(\.textScale) private var textScale
    @Bindable var store: LibraryStore
    let rows: [TrackRow]
    @State private var targeted = false

    private var editable: [TrackRow] { rows.filter(store.canEditArtwork) }
    private var drafts: [ArtworkDraft] { editable.compactMap { store.artworkDrafts[$0.track.uuid] } }

    var body: some View {
        Section(.ui("앨범아트")) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkWell(store: store, row: rows.count == 1 ? rows.first : nil, targeted: targeted)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first, !editable.isEmpty else { return false }
                        store.setArtwork(fileAt: url, rows: editable)
                        return true
                    } isTargeted: { targeted = $0 }
                VStack(alignment: .leading, spacing: 6) {
                    status
                    Button(.ui("앨범아트 고르기")) { choose() }
                        .help(String(ui: "JPEG·PNG 앨범아트 파일을 골라 앨범아트 초안을 만듭니다"))
                    Button(.ui("앨범아트 지우기")) { store.deleteArtwork(rows: editable) }
                        .disabled(!editable.contains { store.artworkBase(for: $0).hasArtwork })
                        .help(String(ui: "앨범아트를 지우는 초안을 만듭니다"))
                    Button(.ui("앨범아트 초안 버리기")) { store.discardArtworkDrafts(rows: editable) }
                        .disabled(drafts.isEmpty)
                }
                .disabled(editable.isEmpty || store.isWritingRekordbox)
            }
            if let message = store.artworkMessage {
                Label(message.text, systemImage: WarningMark.symbol)
                    .font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
            }
            // 결정(#66): rekordbox는 음원의 그림도 바꾸지만 DJCrate는 음원을 읽기만 한다.
            Text(.ui("앨범아트는 rekordbox 라이브러리에만 씁니다. 음원 파일에 든 앨범아트는 바뀌지 않습니다."))
                .font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        if rows.count == 1, let row = rows.first {
            if let draft = store.artworkDrafts[row.track.uuid] {
                Label(draft.kind.label, systemImage: DraftMark.symbol)
                    .foregroundStyle(UIColors.draft.color)
                    .help(DraftMark.help)
                    .accessibilityLabel(Text(verbatim: "\(draft.kind.label), \(DraftMark.spoken)"))
            } else if !store.artworkBase(for: row).hasArtwork {
                // 앨범아트가 있으면 그림이 보이므로 이름을 되풀이하지 않는다("rekordbox 앨범아트"는 아래 안내가 말한다).
                Text(.ui("앨범아트 없음")).foregroundStyle(.secondary)
            }
        } else if !drafts.isEmpty {
            Label(String(ui: "앨범아트 초안 \(drafts.count)곡"), systemImage: DraftMark.symbol).foregroundStyle(UIColors.draft.color)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(ui: "넣을 앨범아트(JPEG·PNG)를 고르세요")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setArtwork(fileAt: url, rows: editable)
    }
}

/// 그림 칸: 초안 그림이 있으면 그것을, 없으면 rekordbox 그림을 보인다(지우기 초안이면 빈 칸).
private struct ArtworkWell: View {
    @Bindable var store: LibraryStore
    let row: TrackRow?
    let targeted: Bool
    @State private var loader = ArtworkWellLoader()

    private var draft: ArtworkDraft? { row.flatMap { store.artworkDrafts[$0.track.uuid] } }
    /// 초안(그림 사본의 해시)과 rekordbox 그림이 바뀔 때만 다시 읽는다.
    private var key: String {
        guard let row else { return "" }
        let pending = draft.map { "\($0.change.rawValue)-\($0.imageSHA256 ?? "")" } ?? "-"
        return "\(row.track.id)|\(ArtworkRevisions.key(row.track.id))|\(row.track.imagePath ?? "")|\(pending)"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternarySystemFill))
            if let image = loader.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(targeted ? Color.accentColor : (draft != nil ? UIColors.draft.color : .clear), lineWidth: 2))
        .help(String(ui: "앨범아트 파일(JPEG·PNG)을 끌어다 놓으면 앨범아트 초안을 만듭니다"))
        .accessibilityElement()
        .accessibilityLabel(loader.image == nil ? Text(.ui("앨범아트 없음")) : Text(.ui("앨범아트")))
        .task(id: key) { await loader.load(row, store: store) }
    }
}
