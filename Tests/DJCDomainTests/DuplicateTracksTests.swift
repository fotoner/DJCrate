import DJCDomain
import Foundation
import Testing

@Suite("중복 후보 규칙")
struct DuplicateTracksTests {
    private func track(_ id: String, title: String = "시험 곡", artist: String? = "시험 가수",
                       length: Int = 180, path: String = "/synthetic/track.mp3", deleted: Bool = false) -> Track {
        Track(id: id, uuid: id, title: title, artist: artist, album: nil, albumArtist: nil,
              genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: nil,
              lengthSeconds: length, folderPath: path, comment: "", importedOn: nil,
              analysisDataPath: nil, imagePath: nil, isDeleted: deleted)
    }

    @Test func NFC와_대소문자와_연속_공백을_정규화한다() {
        let tracks = [track("a", title: "  CAFÉ\tSong \n", artist: "  THE\u{00a0} Band"),
                      track("b", title: "cafe\u{0301} song", artist: "the band")]
        #expect(DuplicateTracks.groups(in: tracks).map(\.trackIDs) == [["a", "b"]])
    }

    @Test func 괄호_버전과_악센트와_다른_아티스트를_보존한다() {
        let tracks = [track("a", title: "Café"), track("b", title: "Cafe"),
                      track("c", title: "Café (Live)"), track("d", title: "Café (Remix)"),
                      track("e", title: "Café", artist: "다른 가수")]
        #expect(DuplicateTracks.groups(in: tracks).isEmpty)
        #expect(DuplicateTracks.groups(in: [track("a", title: "곡 (LIVE)"), track("b", title: "곡 (live)")]).count == 1)
    }

    @Test func 길이_차이는_양쪽_2초까지_허용하고_형식과_경로는_무시한다() {
        let tracks = [track("a", length: 178), track("b", length: 180, path: "/other/copy.flac"),
                      track("c", length: 182), track("d", length: 185)]
        #expect(DuplicateTracks.groups(in: tracks).map(\.trackIDs) == [["a", "b"], ["b", "c"]])
    }

    @Test func 연쇄_길이_차이를_합치지_않고_겹치는_후보도_빠뜨리지_않는다() {
        let tracks = [track("a", length: 180), track("b", length: 180), track("c", length: 182), track("d", length: 184)]
        #expect(DuplicateTracks.groups(in: tracks).map(\.trackIDs) == [["a", "b", "c"], ["c", "d"]])
        #expect(DuplicateTracks.groups(in: tracks.reversed()) == DuplicateTracks.groups(in: tracks))
    }

    @Test func 빈_메타데이터와_길이와_삭제와_스트리밍과_자기자신은_제외한다() {
        for invalid in [track("x", title: " \t"), track("x", artist: nil), track("x", artist: " \n"),
                        track("x", length: 0), track("x", length: -1), track("x", deleted: true),
                        track("x", path: "spotify:synthetic"), track("x", title: "$A7:v1:synthetic")] {
            #expect(DuplicateTracks.groups(in: [invalid, invalid, track("valid")]).isEmpty)
        }
        #expect(DuplicateTracks.groups(in: [track("a"), track("a")]).isEmpty)
        #expect(DuplicateTracks.groups(in: []).isEmpty)
    }

    @Test func 같은_제목의_큰_합성_컬렉션도_한_묶음으로_만든다() {
        let tracks = (0..<10_000).map { track(String(format: "%05d", $0)) }
        let groups = DuplicateTracks.groups(in: tracks.reversed())
        #expect(groups.count == 1)
        #expect(groups.first?.trackIDs == tracks.map(\.id))
    }
}
