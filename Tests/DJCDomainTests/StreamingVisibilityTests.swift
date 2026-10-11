import DJCDomain
import Testing

/// 설정 '스트리밍 곡 숨기기': 목록에 보이는 것만 거른다. 곡·초안·쓰기 내용은 이 규칙이 만지지 않는다.
@Suite("스트리밍 곡 숨기기 규칙")
struct StreamingVisibilityTests {
    static func track(_ id: String, _ path: String, bpm: Double? = 120) -> Track {
        Track(id: id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: nil, bpm: bpm, lengthSeconds: 180, folderPath: path, comment: "",
              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    /// 로컬 두 곡과 스트리밍 두 곡(경로가 `/`로 시작하지 않는 곡)
    static let tracks = [track("1", "/m/a.mp3"), track("2", "spotify:track:abc"), track("3", "/m/b.mp3"), track("4", "apple-music:42")]

    @Test func 숨기기를_켜면_스트리밍_곡만_숨기고_순서는_그대로_둔다() {
        #expect(StreamingVisibility.visible(Self.tracks, hidingStreaming: true, track: { $0 }).map(\.id) == ["1", "3"])
        #expect(StreamingVisibility.hides(Self.tracks[1], hidingStreaming: true))
        #expect(!StreamingVisibility.hides(Self.tracks[0], hidingStreaming: true))
    }

    @Test func 숨기기를_끄면_아무것도_거르지_않는다() {
        #expect(StreamingVisibility.visible(Self.tracks, hidingStreaming: false, track: { $0 }) == Self.tracks)
        #expect(Self.tracks.allSatisfy { !StreamingVisibility.hides($0, hidingStreaming: false) })
    }

    @Test func 재생_목록_곡_수는_찾을_수_있고_보이는_자리만_센다() {
        let byID = Dictionary(uniqueKeysWithValues: Self.tracks.map { ($0.id, $0) })
        // 같은 곡이 두 번 든 목록(1)과 컬렉션에 없는 곡(9)
        let ids = ["1", "2", "1", "3", "4", "9"]
        #expect(StreamingVisibility.visibleCount(of: ids, hidingStreaming: false, track: { byID[$0] }) == 5)
        #expect(StreamingVisibility.visibleCount(of: ids, hidingStreaming: true, track: { byID[$0] }) == 3)
    }

    @Test func 필터별_곡_수에서_스트리밍_곡이_빠진다() {
        let filters = LibraryFilter.visible(commentPreset: .none, hidingStreaming: false)
        func includes(_ filter: LibraryFilter, _ track: Track) -> Bool {
            filter.includes(track: track, comment: nil, hasCues: false, playCount: 0, tempoChanges: [], fileMissing: false)
        }
        let all = StreamingVisibility.filterCounts(Self.tracks, filters: filters, hidingStreaming: false, track: { $0 }, includes: includes)
        #expect(all[.all] == 4 && all[.streaming] == 2 && all[.noCues] == 4)
        let hidden = StreamingVisibility.filterCounts(Self.tracks, filters: LibraryFilter.visible(commentPreset: .none, hidingStreaming: true),
                                                      hidingStreaming: true, track: { $0 }, includes: includes)
        #expect(hidden[.all] == 2 && hidden[.noCues] == 2)
        #expect(hidden[.streaming] == nil, "숨기는 동안 스트리밍 필터는 세지 않는다")
    }

    @Test func 사이드바_필터에서_스트리밍은_숨기기를_켠_동안만_빠진다() {
        #expect(LibraryFilter.visible(commentPreset: .anisong, hidingStreaming: false) == LibraryFilter.allCases)
        #expect(LibraryFilter.visible(commentPreset: .anisong, hidingStreaming: true) == LibraryFilter.allCases.filter { $0 != .streaming })
        // 옛 호출(숨기기 인자 없음)은 그대로 모두 보인다
        #expect(LibraryFilter.visible(commentPreset: .none) == LibraryFilter.visible(commentPreset: .none, hidingStreaming: false))
        #expect(LibraryFilter.visible(commentPreset: .none, hidingStreaming: true).contains(.all))
    }
}
