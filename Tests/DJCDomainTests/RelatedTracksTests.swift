import DJCDomain
import Foundation
import Testing

@Suite("관련 곡 점수")
struct RelatedTracksTests {
    private func track(_ id: String = "candidate", bpm: Double? = nil, key: String? = nil,
                       genre: String? = nil, comment: String = "", deleted: Bool = false,
                       path: String = "/synthetic/track.wav") -> Track {
        Track(id: id, uuid: id, title: id, artist: nil, album: nil, albumArtist: nil,
              genre: genre, composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: bpm,
              lengthSeconds: 180, folderPath: path, comment: comment, importedOn: nil,
              analysisDataPath: nil, imagePath: nil, isDeleted: deleted)
    }

    @Test func 같은_BPM이_가장_높고_반과_두_배도_비교한다() throws {
        let source = track("source", bpm: 120)
        let exact = try #require(RelatedTracks.score(source: source, candidate: track(bpm: 120)))
        let nearby = try #require(RelatedTracks.score(source: source, candidate: track(bpm: 123)))
        let half = try #require(RelatedTracks.score(source: source, candidate: track(bpm: 60)))
        let double = try #require(RelatedTracks.score(source: source, candidate: track(bpm: 240)))
        #expect(exact.bpm > nearby.bpm)
        #expect(exact.bpm > half.bpm && half.bpm == double.bpm)
        #expect(half.tempoMultiplier == 2 && double.tempoMultiplier == 0.5)
        #expect(exact.tempoMultiplier == 1)
    }

    @Test func BPM_범위_경계와_범위_밖() {
        let source = track("source", bpm: 100, key: "8A", genre: "House")
        #expect(RelatedTracks.score(source: source, candidate: track(bpm: 106)) != nil)
        #expect(RelatedTracks.score(source: source, candidate: track(bpm: 94)) != nil)
        #expect(RelatedTracks.score(source: source, candidate: track(bpm: 106.01, key: "8A", genre: "House")) == nil)
        #expect(RelatedTracks.score(source: source, candidate: track(bpm: 93.99)) == nil)
    }

    @Test(arguments: ["8A", "8B", "7A", "9A", " 08a "])
    func 호환되는_키(key: String) throws {
        let score = try #require(RelatedTracks.score(source: track("source", key: "8A"), candidate: track(key: key)))
        #expect(score.key > 0)
    }

    @Test func 키_원형_경계와_대각선_제외() {
        let source = track("source", key: "12B")
        #expect(RelatedTracks.score(source: source, candidate: track(key: "1B"))?.key == 24)
        #expect(RelatedTracks.score(source: track("source", key: "1A"), candidate: track(key: "12A"))?.key == 24)
        #expect(RelatedTracks.score(source: source, candidate: track(key: "1A")) == nil)
        #expect(RelatedTracks.score(source: source, candidate: track(key: "10B")) == nil)
        #expect(RelatedTracks.score(source: source, candidate: track(key: "13B")) == nil)
        #expect(RelatedTracks.score(source: track("source", key: "unknown"), candidate: track(key: "unknown")) == nil)
    }

    @Test func 장르와_명시적_코멘트_태그를_정규화해서_비교한다() throws {
        let source = track("source", genre: " House ", comment: "자유 코멘트 #Warm #보컬 #Warm")
        let score = try #require(RelatedTracks.score(source: source,
            candidate: track(genre: "ＨＯＵＳＥ", comment: "다른 코멘트 #warm, #보컬!")))
        #expect(score.genre == 10 && score.tags == 10)
        let partial = try #require(RelatedTracks.score(source: source, candidate: track(comment: "#warm #dance")))
        #expect(abs(partial.tags - 10.0 / 3) < 0.001)
        #expect(RelatedTracks.score(source: source, candidate: track(comment: "자유 코멘트 warm 보컬")) == nil)
    }

    @Test func 빈값과_유효하지_않은_BPM은_가점이_없다() {
        #expect(RelatedTracks.score(source: track("source"), candidate: track()) == nil)
        for bpm in [0.0, -120, .infinity, .nan] {
            let score = RelatedTracks.score(source: track("source", bpm: bpm, key: "8A"), candidate: track(bpm: bpm, key: "8A"))
            #expect(score?.bpm == 0 && score?.key == 30)
        }
        #expect(RelatedTracks.score(source: track("source", genre: "  "), candidate: track(genre: "")) == nil)
    }

    @Test func 자기자신과_삭제곡과_스트리밍은_제외한다() {
        let source = track("source", bpm: 120)
        for candidate in [source, track(bpm: 120, deleted: true), track(bpm: 120, path: "spotify:synthetic")] {
            #expect(RelatedTracks.score(source: source, candidate: candidate) == nil)
        }
    }

    @Test func 합성_라이브러리의_순서와_동점과_최대_개수() {
        let source = track("source", bpm: 120, key: "8A", genre: "House", comment: "#warm")
        let candidates = [track("z", bpm: 120), source, track("best", bpm: 120, key: "8A", genre: "House", comment: "#warm"),
                          track("outside", bpm: 140, key: "8A"), track("a", bpm: 120), track("key", bpm: 120, key: "9A")]
        let ranked = RelatedTracks.rank(source: source, candidates: candidates)
        #expect(ranked.map(\.id) == ["best", "key", "a", "z"])
        #expect(ranked.first?.score.total == 100)
        #expect(RelatedTracks.rank(source: source, candidates: candidates.reversed()).map(\.id) == ranked.map(\.id))
        #expect(RelatedTracks.rank(source: source, candidates: candidates, limit: 2).map(\.id) == ["best", "key"])
        #expect(RelatedTracks.rank(source: source, candidates: candidates, limit: 0).isEmpty)
        #expect(RelatedTracks.rank(source: source, candidates: [], limit: -1).isEmpty)
    }

    @Test func 큰_합성_라이브러리도_점수순으로_제한한다() {
        let source = track("source", bpm: 120, key: "8A")
        let candidates = (0..<10_000).map { track(String(format: "%05d", $0), bpm: 120, key: $0 % 2 == 0 ? "8A" : "9A") }
        let result = RelatedTracks.rank(source: source, candidates: candidates, limit: 100)
        #expect(result.count == 100)
        #expect(result.map(\.id) == stride(from: 0, to: 200, by: 2).map { String(format: "%05d", $0) })
    }
}
