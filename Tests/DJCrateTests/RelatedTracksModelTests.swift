@testable import DJCrate
import DJCDomain
import Foundation
import Testing

@Suite("관련 곡 목록", .serialized)
@MainActor
struct RelatedTracksModelTests {
    private func row(_ id: String, key: String = "8A", bpm: Double = 120) -> TrackRow {
        let track = Track(id: id, uuid: id, title: "합성 \(id)", artist: "시험", album: nil, albumArtist: nil,
                          genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: bpm,
                          lengthSeconds: 180, folderPath: "/synthetic/\(id).wav", comment: "", importedOn: nil,
                          analysisDataPath: nil, imagePath: nil, isDeleted: false)
        return TrackRow(track: track, cues: [], playCount: 0)
    }

    @Test func 합성_목록을_백그라운드에서_정렬해_행과_연결한다() async {
        let model = RelatedTracksModel()
        let source = row("source")
        let best = row("best"), neighbor = row("neighbor", key: "9A"), unrelated = row("outside", bpm: 140)
        await model.load(source: source.track, rows: [neighbor, unrelated, source, best])
        #expect(model.matches.map(\.id) == ["best", "neighbor"])
        #expect(model.matches.first?.row == best)
        #expect(model.matches.first?.score.total == 80)
        #expect(!model.isLoading)
        await model.load(source: nil, rows: [best])
        #expect(model.matches.isEmpty && !model.isLoading)
    }

    @Test func 취소된_요청은_목록을_게시하지_않는다() async {
        let model = RelatedTracksModel()
        let source = row("source"), candidate = row("candidate")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(source: source.track, rows: [candidate])
        }
        await task.value
        #expect(model.matches.isEmpty && !model.isLoading)
    }

    @Test func 이전_요청은_기준곡을_비운_뒤_결과를_덮지_않는다() async throws {
        let model = RelatedTracksModel()
        let source = row("source")
        let rows = (0..<10_000).map { row(String($0)) }
        let first = Task { await model.load(source: source.track, rows: rows) }
        for _ in 0..<1_000 {
            if model.isLoading { break }
            await Task.yield()
        }
        try #require(model.isLoading)
        await model.load(source: nil, rows: [])
        await first.value
        #expect(model.matches.isEmpty && !model.isLoading)
    }
}
