import DJCDomain
import Observation

struct RelatedTrackRow: Identifiable, Sendable {
    let row: TrackRow
    let score: RelatedTracks.Score
    var id: String { row.id }
}

@MainActor
@Observable
final class RelatedTracksModel {
    private(set) var matches: [RelatedTrackRow] = []
    private(set) var isLoading = false
    @ObservationIgnored private var generation = 0

    func load(source: Track?, rows: [TrackRow]) async {
        generation += 1
        let request = generation
        matches = []
        isLoading = false
        guard let source, !Task.isCancelled else { return }
        isLoading = true
        defer { if request == generation { isLoading = false } }

        // 메타데이터 정규화·전체 정렬·행 연결까지 메인 액터 밖에서 한다.
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return [RelatedTrackRow]() }
            let ranked = RelatedTracks.rank(source: source, candidates: rows.map(\.track))
            guard !Task.isCancelled else { return [RelatedTrackRow]() }
            let index = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ranked.compactMap { match in
                index[match.id].map { RelatedTrackRow(row: $0, score: match.score) }
            }
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard request == generation, !Task.isCancelled else { return }
        matches = result
    }
}
