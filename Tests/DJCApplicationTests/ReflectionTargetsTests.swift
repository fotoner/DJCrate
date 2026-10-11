import DJCApplication
import DJCDomain
import Testing

/// 고른 곡 → 쓰기·넣기·빼기 대상(메뉴·세션·시험 가짜가 함께 부르는 규칙, adv2 N9·adv4 T7)
@Suite("반영 대상 고르기")
struct ReflectionTargetsTests {
    static func row(_ id: String, path: String? = nil) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "u-\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                              folderPath: path ?? "/x/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil,
                              isDeleted: false),
                 cues: [], playCount: 0)
    }

    let local = row("1"), other = row("2"), staged = row("djc-3"), stream = row("4", path: "spotify:track:4")

    @Test func 쓰기는_반영_대기_초안이_있는_rekordbox_곡만_고른다() {
        let rows = [local, other, staged, stream]
        // 추가한 곡은 초안이 있어도 넣기로 쓴다(쓰기 대상이 아니다).
        let pending: Set = ["u-1", "u-djc-3", "u-4"]
        #expect(ReflectionTargets.write(rows, pending: pending).map(\.id) == ["1", "4"])
        #expect(ReflectionTargets.write(rows, pending: []).isEmpty)
    }

    @Test func 넣기는_추가한_곡만_고른다() {
        #expect(ReflectionTargets.add([local, staged, stream]).map(\.id) == ["djc-3"])
    }

    @Test func 빼기는_컬렉션의_로컬_곡만_고르고_iTunes_목록에서는_고르지_않는다() {
        #expect(ReflectionTargets.delete([local, staged, stream, other], iTunesSelection: false).map(\.id) == ["1", "2"])
        #expect(ReflectionTargets.delete([local, other], iTunesSelection: true).isEmpty)
    }

    @Test func 저장_대기_입력만_있는_곡도_쓰기_대상이다() {
        // 메뉴는 저장이 끝나기 전의 곡도 같은 대상으로 본다(옛 메뉴는 표시된 초안만 보고 세션은 저장 대기까지 봤다).
        let pending = ReflectionTargets.pending(marked: ["u-1"], unsaved: ["u-2"])
        #expect(ReflectionTargets.write([local, other], pending: pending).map(\.id) == ["1", "2"])
    }
}
