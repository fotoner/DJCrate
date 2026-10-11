import DJCDomain
import SwiftUI

struct RelatedTracksButton: View {
    let store: LibraryStore
    let deck: DeckModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label(.ui("관련 곡"), systemImage: "music.note.list")
        }
        .disabled(deck.row == nil || store.isWritingRekordbox)
        .help(.ui("덱에 올린 곡과 BPM·키·장르·코멘트의 #태그가 어울리는 곡을 찾습니다"))
        .popover(isPresented: $isPresented) {
            RelatedTracksView(source: deck.row, rows: store.rows) { id in
                // 더블클릭·Return·오른쪽 클릭 메뉴로만 덱에 올린다(한 번 클릭은 고르기만, #93).
                store.loadToDeck(store.rowsByID[id])
                isPresented = false
            }
            .disabled(store.isWritingRekordbox)
        }
    }
}

private struct RelatedTracksView: View {
    let source: TrackRow?
    let rows: [TrackRow]
    let onLoad: (String) -> Void
    @State private var model = RelatedTracksModel()
    @State private var selection: String?
    @State private var libraryRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.ui("관련 곡")).font(.headline)
            if let source {
                Text(.ui("기준: \(source.title)")).font(.callout).lineLimit(1)
            }
            Text(.ui("BPM ±6% · 반·두 배 포함 · 키 이웃 · 장르 · #태그\n점수순 상위 100곡 · 더블클릭·Return으로 덱에 올립니다"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if model.isLoading {
                ProgressView { Text(.ui("관련 곡을 찾는 중…")) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if source == nil {
                ContentUnavailableView(.ui("기준곡이 없습니다"), systemImage: "music.note",
                                       description: Text(.ui("목록에서 곡을 더블클릭해 덱에 올리세요")))
            } else if model.matches.isEmpty {
                ContentUnavailableView(.ui("관련 곡이 없습니다"), systemImage: "music.note.list",
                                       description: Text(.ui("다른 기준곡을 고르거나 BPM·키·장르·#태그를 확인하세요")))
            } else {
                List(model.matches, selection: $selection) { match in
                    candidate(match)
                        .padding(.vertical, 3)
                        .help(.ui("더블클릭하면 \(match.row.title)을 덱에 올립니다"))
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        Button(.ui("덱에 불러오기")) { onLoad(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { onLoad(id) }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 460)
        .task(id: Request(source: source?.track, libraryRevision: libraryRevision)) {
            await model.load(source: source?.track, rows: rows)
        }
        .onChange(of: rows) { libraryRevision += 1 }
    }

    private struct Request: Equatable {
        let source: Track?
        let libraryRevision: Int
    }

    private func candidate(_ match: RelatedTrackRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(match.row.title).font(.body).lineLimit(1)
                HStack(spacing: 8) {
                    if !match.row.artist.isEmpty { Text(match.row.artist).lineLimit(1) }
                    if let bpm = match.row.track.bpm, bpm.isFinite, bpm > 0 {
                        Text(verbatim: "\(bpm.formatted(.number.precision(.fractionLength(1)))) BPM").fixedSize()
                    }
                    if let key = match.row.track.key { Text(key).fixedSize() }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(reasons(match.score)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(.ui("\(match.score.total, specifier: "%.0f")점"))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func reasons(_ score: RelatedTracks.Score) -> String {
        var reasons: [String] = []
        if score.bpm > 0 {
            reasons.append(score.tempoMultiplier == 2 ? String(ui: "BPM 두 배로 비교") : score.tempoMultiplier == 0.5 ? String(ui: "BPM 절반으로 비교") : String(ui: "가까운 BPM"))
        }
        if score.key > 0 { reasons.append(score.key == 30 ? String(ui: "같은 키") : String(ui: "호환 키")) }
        if score.genre > 0 { reasons.append(String(ui: "같은 장르")) }
        if score.tags > 0 { reasons.append(String(ui: "#태그 겹침")) }
        return reasons.joined(separator: " · ")
    }
}
