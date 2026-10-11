@testable import DJCrate
import DJCDomain
import Testing

@Suite("덱 — 이전·다음 곡")
struct DeckTrackNavigationTests {
    private func row(_ id: String, uuid: String? = nil, streaming: Bool = false) -> TrackRow {
        let track = Track(id: id, uuid: uuid ?? id, title: id, artist: nil, album: nil, albumArtist: nil,
                          genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: nil,
                          lengthSeconds: 180, folderPath: streaming ? "stream:\(id)" : "/synthetic/\(id).wav",
                          comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        return TrackRow(track: track, cues: [], playCount: 0)
    }

    @Test(arguments: ["a", "b", "c"])
    func 스트리밍을_건너뛰고_목록_순서와_경계를_지킨다(current: String) {
        let a = row("a"), b = row("b"), c = row("c")
        let rows = [row("stream-a", streaming: true), a, row("stream-b", streaming: true), b, c,
                    row("stream-c", streaming: true)]
        let result = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: current)
        #expect(result.previous == (current == "a" ? nil : current == "b" ? a : b))
        #expect(result.next == (current == "c" ? nil : current == "b" ? c : b))
    }

    @Test func 빈_목록과_스트리밍만_있는_목록에는_이웃이_없다() {
        for rows in [[], [row("stream", streaming: true)]] {
            let result = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: "stream")
            #expect(result.previous == nil && result.next == nil)
        }
        let single = DeckTrackNavigation.adjacentRows(in: [row("a")], currentUUID: "a")
        #expect(single.previous == nil && single.next == nil)
    }

    @Test(arguments: [nil, "missing", "stream"] as [String?])
    func 현재곡이_없으면_이전은_끝_다음은_첫곡이다(current: String?) {
        let a = row("a"), b = row("b")
        let result = DeckTrackNavigation.adjacentRows(in: [a, row("stream", streaming: true), b], currentUUID: current)
        #expect(result.previous == b && result.next == a)
        let single = DeckTrackNavigation.adjacentRows(in: [a], currentUUID: current)
        #expect(single.previous == a && single.next == a)
    }

    @Test func UUID가_겹쳐도_첫_재생가능_행을_기준으로_원래_행을_돌려준다() {
        let a = row("a", uuid: "shared"), b = row("b"), repeated = row("repeat", uuid: "shared")
        var occurrence = repeated
        occurrence.playlistOccurrence = .init(id: "occurrence", number: 3)
        let rows = [row("stream", uuid: "shared", streaming: true), b, a, occurrence, row("djc-staged")]
        let result = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: repeated.track.uuid)
        #expect(result.previous == b && result.next == occurrence)
        let last = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: "djc-staged")
        #expect(last.previous == occurrence && last.next == nil)
    }

    @Test func 목록과_덱을_바꾸면_새_입력으로_양쪽을_구한다() {
        let a = row("a"), b = row("b"), c = row("c")
        var rows = [a, b, c]
        var current = b.track.uuid
        var result = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: current)
        #expect(result.previous == a && result.next == c)
        rows = [c, b, a]
        result = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: current)
        #expect(result.previous == c && result.next == a)
        current = c.track.uuid
        result = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: current)
        #expect(result.previous == nil && result.next == b)
        rows = [a]
        result = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: current)
        #expect(result.previous == a && result.next == a)
    }

    @Test func 작은_목록의_중복과_스트리밍_조합은_기존_계산과_같다() {
        let choices = [row("a", uuid: "shared"), row("repeat", uuid: "shared"), row("b"),
                       row("stream", uuid: "shared", streaming: true)]
        var lists: [[TrackRow]] = [[]]
        for length in 1...4 {
            lists += lists.filter { $0.count == length - 1 }.flatMap { prefix in
                choices.map { prefix + [$0] }
            }
        }
        for rows in lists {
            for current in [nil, "shared", "b", "missing"] as [String?] {
                let expected = legacyAdjacentRows(in: rows, currentUUID: current)
                let result = DeckTrackNavigation.adjacentRows(in: rows, currentUUID: current)
                #expect(result.previous == expected.previous && result.next == expected.next)
            }
        }
    }

    @Test(arguments: ["missing", "2", "49999"])
    func 합성_대목록을_최대_한번_읽어_양쪽을_구한다(current: String) {
        let rows = (0..<50_000).map { row(String($0), streaming: $0.isMultiple(of: 10)) }
        let oldCounter = Counter(), counter = Counter()
        let expected = legacyAdjacentRows(in: CountedRows(rows: rows, counter: oldCounter), currentUUID: current)
        let result = DeckTrackNavigation.adjacentRows(in: CountedRows(rows: rows, counter: counter), currentUUID: current)
        #expect(result.previous == expected.previous && result.next == expected.next)
        #expect(oldCounter.reads == 100_000)
        #expect(counter.reads == (current == "2" ? 4 : rows.count))
        print("덱 이웃 순회 · 현재 \(current) · 기존 \(oldCounter.reads)행 · 변경 \(counter.reads)행")
    }

    // 변경 전 두 버튼의 계산을 독립 기준으로 남겨 UUID 첫 일치와 fallback을 함께 확인한다.
    private func legacyAdjacentRows<Rows: Sequence>(in rows: Rows, currentUUID: String?) -> (previous: TrackRow?, next: TrackRow?) where Rows.Element == TrackRow {
        func adjacent(forward: Bool) -> TrackRow? {
            let playable = rows.filter { !$0.track.isStreaming }
            guard !playable.isEmpty else { return nil }
            guard let currentUUID, let index = playable.firstIndex(where: { $0.track.uuid == currentUUID }) else {
                return forward ? playable.first : playable.last
            }
            let next = index + (forward ? 1 : -1)
            return playable.indices.contains(next) ? playable[next] : nil
        }
        return (adjacent(forward: false), adjacent(forward: true))
    }

    private final class Counter { var reads = 0 }

    private struct CountedRows: Sequence {
        let rows: [TrackRow]
        let counter: Counter

        func makeIterator() -> AnyIterator<TrackRow> {
            var iterator = rows.makeIterator()
            return AnyIterator {
                guard let row = iterator.next() else { return nil }
                counter.reads += 1
                return row
            }
        }
    }
}
