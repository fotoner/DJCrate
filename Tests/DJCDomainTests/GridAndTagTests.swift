@testable import DJCDomain
import Foundation
import Testing

@Suite("그리드 초안")
struct GridDraftTests {
    @Test func BPM_범위는_양끝을_포함한다() {
        #expect(GridDraft.bpmRange == 20...655.35)
        for bpm in [20.0, 655.35] {
            var draft = GridDraft(trackUUID: "t", grid: constantGrid())
            draft.setBPM(bpm, at: 1)
            #expect(draft.segments[0].bpm == bpm)
        }
    }

    @Test(arguments: [19.999, 655.351, 656, 999, Double.nan, .infinity, -.infinity])
    func BPM_범위_밖은_반올림_전에_거부한다(bpm: Double) {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        let original = draft
        draft.setBPM(bpm, at: 1)
        #expect(draft == original)
    }

    /// 120 BPM(0.5초 간격), 0.1초에서 시작하는 4/4 그리드. 첫 박은 1박.
    func constantGrid(count: Int = 40, start: Double = 0.1, bpm: Double = 120) -> BeatGrid {
        BeatGrid(beats: (0..<count).map { i in
            .init(number: i % 4 + 1, bpm: bpm, time: ((start + Double(i) * 60 / bpm) * 1000).rounded() / 1000)
        })
    }

    @Test func 고정_템포는_구간_하나로_묶이고_그대로_재현된다() {
        let grid = constantGrid()
        let draft = GridDraft(trackUUID: "t", grid: grid)
        #expect(draft.segments.count == 1)
        #expect(abs(draft.segments[0].bpm - 120) < 0.001)
        let rebuilt = draft.grid(duration: 20.2)
        for beat in grid.beats {
            #expect(abs(rebuilt.snap(beat.time) - beat.time) <= 0.001)
        }
        #expect(!draft.hasChanges)
    }

    @Test func 전체_이동() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        draft.shift(by: 0.01)
        #expect(draft.hasChanges)
        #expect(draft.grid(duration: 20).beats.first?.time == 0.11)
    }

    @Test func 여기를_1박으로() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        // 0.6초 박은 현재 2박 → 1박으로
        draft.setDownbeat(nearest: 0.62, duration: 20)
        let beats = draft.grid(duration: 20).beats
        #expect(beats.first { abs($0.time - 0.6) < 0.001 }?.number == 1)
        #expect(beats.first { abs($0.time - 0.1) < 0.001 }?.number == 4)
    }

    @Test func 여기서_그리드_시작() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        draft.setAnchor(at: 0.333)
        let beats = draft.grid(duration: 20).beats
        #expect(beats.contains { abs($0.time - 0.333) < 0.0005 && $0.number == 1 })
    }

    @Test func 변속_지점과_구간별_BPM() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        draft.addTempoChange(nearest: 10.1, duration: 20)
        #expect(draft.segments.count == 2)
        draft.setBPM(150, at: 12)
        let beats = draft.grid(duration: 20).beats
        let after = beats.filter { $0.time >= 10.1 }
        #expect(after.first?.bpm == 150)
        #expect(abs((after[1].time - after[0].time) - 0.4) < 0.0015)
        #expect(beats.filter { $0.time < 10.1 }.allSatisfy { $0.bpm == 120 })
        draft.removeTempoChange(at: 1)
        #expect(draft.segments.count == 1)
    }

    /// #207: Q를 끄면 변속 지점은 박 사이 위치 그대로 들어간다.
    @Test func 변속_지점을_박_사이_위치_그대로_넣는다() {
        var draft = GridDraft(trackUUID: "t", base: [], segments: [.init(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        let added = draft.addTempoChange(at: 10.625, duration: 20)
        #expect(added)
        #expect(draft.segments.count == 2)
        #expect(draft.segments[1].start == 10.625 && draft.segments[1].bpm == 120)
        // 경계에서 반 박 안쪽의 이전 박(10.5초, 1박)은 새 구간 첫 박이 대신한다.
        #expect(draft.segments[1].firstBeatNumber == 1)
        let beats = draft.grid(duration: 20).beats
        #expect(beats.filter { $0.time > 9.9 && $0.time < 11.2 }.map(\.time) == [10.0, 10.625, 11.125])
        #expect(beats.first { $0.time == 10.625 }?.number == 1)
        // 반 박보다 뒤면 이전 박(15.625초)은 남고 다음 박(16.125초, 4박)을 대신한다.
        let addedLater = draft.addTempoChange(at: 15.95, duration: 20)
        #expect(addedLater)
        #expect(draft.segments[2].firstBeatNumber == 4)
        #expect(draft.grid(duration: 20).beats.filter { $0.time > 15.5 && $0.time < 16.5 }.map(\.time) == [15.625, 15.95, 16.45])
    }

    /// 앞 구간의 박이 모두 사라지거나 새 구간에 박이 하나도 없는 자리는 넣지 않는다(쓰기 단계에서 막히는 모양).
    @Test(arguments: [10.7, 10.625, 10.4, 10.38, 0.3, 0.5, -1, 20, 25])
    func 이웃_변속_지점과_반_박_안쪽이나_곡_밖이면_넣지_않는다(time: Double) {
        var draft = GridDraft(trackUUID: "t", base: [], segments: [
            .init(start: 0.5, bpm: 120, firstBeatNumber: 1),
            .init(start: 10.625, bpm: 120, firstBeatNumber: 1),
        ])
        let original = draft
        let added = draft.addTempoChange(at: time, duration: 20)
        #expect(!added)
        #expect(draft == original)
    }

    @Test func 변속_경계에_가까운_이전_박은_새_구간의_첫_박으로_대체한다() {
        // 2026-09-28 rekordbox 7.2.18, DJC 다구간 BPM 실험 B 중간 구간.
        // 151 BPM으로 늘인 29.209초 박은 29.305초 경계 박과 중복해서 만들지 않는다.
        let draft = GridDraft(trackUUID: "t", base: [], segments: [
            .init(start: 0.494, bpm: 120, firstBeatNumber: 1),
            .init(start: 16.494, bpm: 151, firstBeatNumber: 1),
            .init(start: 29.305, bpm: 100, firstBeatNumber: 1),
        ])
        let beats = draft.grid(duration: 49).beats
        #expect(beats.count == 97)
        #expect(beats.filter { $0.time >= 28.8 && $0.time <= 29.4 }.map(\.time) == [28.812, 29.305])
    }

    @Test func 템포가_같아도_위상이_튀면_구간을_나눈다() {
        var beats = constantGrid(count: 20).beats
        beats += (0..<20).map { i in .init(number: i % 4 + 1, bpm: 120, time: 10.3 + Double(i) * 0.5) }
        let draft = GridDraft(trackUUID: "t", grid: BeatGrid(beats: beats))
        #expect(draft.segments.count == 2)
        #expect(draft.segments[1].start == 10.3)
    }

    @Test func BPM은_소수점_둘째_자리로_반올림하고_범위를_지킨다() {
        var draft = GridDraft(trackUUID: "t", grid: constantGrid())
        draft.setBPM(154.0123, at: 1)
        #expect(draft.segments[0].bpm == 154.01)
        draft.setBPM(5, at: 1)
        #expect(draft.segments[0].bpm == 154.01)
    }
}

@Suite("그리드 초안 — 리뷰 회귀")
struct GridDraftRegressionTests {
    func grid(bpm: Double = 153.9987) -> BeatGrid {
        BeatGrid(beats: (0..<600).map { i in
            .init(number: i % 4 + 1, bpm: (bpm * 100).rounded() / 100, time: ((0.2 + Double(i) * 60 / bpm) * 1000).rounded() / 1000)
        })
    }

    @Test func 표시값_BPM을_다시_넣어도_그리드는_그대로다() {
        var draft = GridDraft(trackUUID: "t", grid: grid())
        let shown = (draft.segments[0].bpm * 100).rounded() / 100   // BPM 칸에 보이는 154.00
        draft.setBPM(shown, at: 10)
        #expect(!draft.hasChanges)
    }

    @Test func 이동했다_되돌리면_변경이_아니다() {
        var draft = GridDraft(trackUUID: "t", grid: grid())
        draft.shift(by: 0.010)
        draft.shift(by: -0.010)
        #expect(!draft.hasChanges)
    }

    @Test func 구간_경계_근처의_1박_지정은_박이_속한_구간을_고친다() {
        var draft = GridDraft(trackUUID: "t", grid: grid(bpm: 120))
        draft.addTempoChange(nearest: 60.2, duration: 200)   // 60.2초 박부터 새 구간
        let before = draft.segments[0].firstBeatNumber
        draft.setDownbeat(nearest: 60.1, duration: 200)       // 가장 가까운 박은 60.2초(두 번째 구간)
        #expect(draft.segments[0].firstBeatNumber == before)
        #expect(draft.segments[1].firstBeatNumber == 1)
    }

}

@Suite("태그 초안")
struct TagDraftTests {
    func track() -> Track {
        Track(id: "1", uuid: "u", title: "Song", artist: "A", album: "Al", albumArtist: nil, genre: "Anime",
              composer: nil, releaseYear: 2013, trackNumber: 1, key: "1A", bpm: 154, lengthSeconds: 269,
              folderPath: "/x.m4a", comment: "TVA 테큐 OP 2", importedOn: "2023-11-21",
              analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    @Test func 변경된_필드만_잡는다() {
        var draft = TagDraft(track: track())
        #expect(!draft.hasChanges)
        #expect(draft.fields.year == "2013")
        draft.fields.genre = "애니송"
        draft.fields.comment = "TVA 테큐 OP 2 2013 4분기"
        #expect(draft.changedKeys == [.genre, .comment])
    }

    @Test func 안_고친_칸은_최신값을_받고_코멘트_초안을_보존한다() throws {
        var draft = TagDraft(track: track())
        draft.fields.comment = "내 코멘트"
        var current = draft.base
        current.title = "현재 제목"
        current.artist = "현재 아티스트"
        let rebased = try #require(draft.rebased(onto: current))
        #expect(rebased.base == current && rebased.fields.title == current.title && rebased.fields.artist == current.artist)
        #expect(rebased.fields.comment == "내 코멘트" && rebased.changedKeys == [.comment])
    }

    @Test func 같은_칸의_실제_변경과_앨범_의존칸은_동기화하지_않는다() {
        var draft = TagDraft(track: track())
        draft.fields.comment = "내 코멘트"
        var current = draft.base
        current.comment = "다른 코멘트"
        #expect(draft.rebased(onto: current) == nil)
        draft = TagDraft(track: track())
        draft.fields.albumArtist = "내 앨범 아티스트"
        current = draft.base
        current.album = "다른 앨범"
        #expect(draft.rebased(onto: current) == nil)
    }

    @Test func 이미_쓴_값은_다시_쓸_초안으로_남기지_않는다() throws {
        var draft = TagDraft(track: track())
        draft.fields.comment = "내 코멘트"
        var current = draft.base
        current.comment = draft.fields.comment
        #expect(try #require(draft.rebased(onto: current)).hasChanges == false)
    }

    @Test func 숫자_필드_검증() {
        var draft = TagDraft(track: track())
        draft.fields.year = "2013년"
        #expect(!draft.issues.isEmpty)
    }

    @Test(arguments: [TagFields.Key.year, .trackNumber])
    func 음수_입력은_초안에서도_쓰기_불가로_알린다(key: TagFields.Key) {
        var draft = TagDraft(track: track())
        draft.fields[key] = "-1"
        #expect(draft.issues.contains { $0.contains(key.label) && $0.contains("0") })
        draft.fields[key] = "0"
        #expect(draft.issues.isEmpty)
    }

    @Test func 앨범이_없는_새_앨범_아티스트는_쓰기_전에_알린다() {
        var draft = TagDraft(track: track())
        draft.fields.album = ""
        draft.fields.albumArtist = "새 아티스트"
        #expect(draft.issues.contains { $0.contains("앨범 아티스트") })
    }
}

@Suite("엑셀·시트 붙여넣기(TSV)")
struct TSVTests {
    @Test func 기본_표() {
        #expect(TSV.parse("a\tb\nc\td\n") == [["a", "b"], ["c", "d"]])
    }

    @Test func 따옴표_칸_안의_줄바꿈과_탭은_한_칸이다() {
        // 엑셀은 칸 안에 줄바꿈이 있으면 따옴표로 감싸서 복사한다. 나눠 버리면 뒤 곡들이 한 줄씩 밀린다.
        let text = "제목1\t\"줄1\n줄2\"\n제목2\t\"탭\t포함\"\n"
        #expect(TSV.parse(text) == [["제목1", "줄1\n줄2"], ["제목2", "탭\t포함"]])
    }

    @Test func 이중_따옴표와_CR_줄끝() {
        #expect(TSV.parse("\"말 \"\"인용\"\"\"\tx\r\ny\tz\r") == [["말 \"인용\"", "x"], ["y", "z"]])
    }

    @Test func 복사한_칸을_다시_붙이면_같다() {
        let cells = [["TVA 작품 OP", "줄\n바꿈"], ["탭\t있음", "\"따옴표\""]]
        let text = cells.map { $0.map(TSV.quote).joined(separator: "\t") }.joined(separator: "\n")
        #expect(TSV.parse(text) == cells)
    }
}

@Suite("그리드를 따라 큐 옮기기")
struct GridCarryTests {
    let old = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    @Test func 이동하면_같은_만큼() {
        let new = [GridSegment(start: 0.52, bpm: 120, firstBeatNumber: 1)]
        #expect(abs(GridDraft.carry(10.5, from: old, to: new, duration: 60) - 10.52) < 1e-9)
    }

    @Test func BPM을_바꾸면_같은_박으로() {
        // 120 → 121: 20박째(10.5초) 박은 새 그리드의 20박째로
        let new = [GridSegment(start: 0.5, bpm: 121, firstBeatNumber: 1)]
        #expect(abs(GridDraft.carry(10.5, from: old, to: new, duration: 60) - (0.5 + 20 * 60 / 121)) < 1e-9)
        // 박 사이(반 박)는 새 박 사이 같은 비율
        #expect(abs(GridDraft.carry(10.75, from: old, to: new, duration: 60) - (0.5 + 20.5 * 60 / 121)) < 1e-9)
    }

    @Test func 반_박_이동은_옮긴_방향으로() {
        let forward = [GridSegment(start: 0.75, bpm: 120, firstBeatNumber: 1)]
        #expect(abs(GridDraft.carry(10.5, from: old, to: forward, duration: 60) - 10.75) < 1e-9)
        let backward = [GridSegment(start: 0.25, bpm: 120, firstBeatNumber: 1)]
        #expect(abs(GridDraft.carry(10.5, from: old, to: backward, duration: 60) - 10.25) < 1e-9)
    }

    @Test func 시작점이_멀리_뛰어도_반_박_안에서만() {
        // "여기서 그리드 시작": 시작이 12.53초로 → 격자는 30ms만 밀린 것
        let new = [GridSegment(start: 12.53, bpm: 120, firstBeatNumber: 1)]
        #expect(abs(GridDraft.carry(10.5, from: old, to: new, duration: 60) - 10.53) < 1e-9)
    }

    @Test func 박_번호만_바꾸면_그대로() {
        let new = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 3)]
        #expect(GridDraft.carry(10.5, from: old, to: new, duration: 60) == 10.5)
    }

    @Test func 변속_지점을_더해도_박_위치가_같으면_그대로() {
        let new = old + [GridSegment(start: 20.5, bpm: 120, firstBeatNumber: 1)]
        #expect(abs(GridDraft.carry(30.5, from: old, to: new, duration: 60) - 30.5) < 1e-6)
    }

    @Test func 뒤쪽_변속_지점_추가에서_앞쪽_경계_박의_큐는_그대로다() {
        let original = [
            GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1),
            GridSegment(start: 1.7, bpm: 300, firstBeatNumber: 1),
            GridSegment(start: 11.7, bpm: 100, firstBeatNumber: 1),
        ]
        let added = original + [GridSegment(start: 25.7, bpm: 110, firstBeatNumber: 1)]
        let draft = GridDraft(trackUUID: "t", base: original, segments: added)
        #expect(draft.grid(duration: 49).beats.contains { $0.time == 1.5 })
        #expect(abs(GridDraft.carry(1.5, from: original, to: added, duration: 49) - 1.5) < 0.001)
        let removed = Array(original.prefix(2))
        #expect(GridDraft(trackUUID: "t", base: original, segments: removed).grid(duration: 49).beats.contains { $0.time == 1.5 })
    }
}

@Suite("그리드를 따라 큐 옮기기 — 어떤 큐가 움직이나")
struct CueCarryTests {
    let old = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]
    let moved = [GridSegment(start: 0.52, bpm: 120, firstBeatNumber: 1)]

    @Test func 핫큐와_메모리_큐와_루프_끝이_모두_따라간다() {
        var loop = EditableCue(kind: .hot(1), time: 20.5)
        loop.loop = EditableCue.Loop(end: 24.5, active: true, beats: 8)
        let cues = [EditableCue(kind: .memory, time: 10.5), EditableCue(kind: .hot(0), time: 12.5), loop]
        let carried = GridDraft.carried(cues, from: old, to: moved, duration: 60)
        #expect(carried.count == 3)
        for (before, after) in zip(cues, carried) {
            #expect(after.id == before.id)
            #expect(abs(after.time - (before.time + 0.02)) < 1e-9)
        }
        #expect(abs((carried[2].loop?.end ?? 0) - 24.52) < 1e-9)
        #expect(carried[2].loop?.active == true && carried[2].loop?.beats == 8)
    }

    @Test func 그리드가_같으면_아무것도_안_바뀐다() {
        #expect(GridDraft.carried([EditableCue(kind: .memory, time: 10.5)], from: old, to: old, duration: 60).isEmpty)
    }

    @Test func 곡_범위를_벗어나지_않는다() {
        let early = [GridSegment(start: 0.2, bpm: 120, firstBeatNumber: 1)]
        let carried = GridDraft.carried([EditableCue(kind: .memory, time: 0.1)], from: old, to: early, duration: 60)
        #expect(carried.first.map { $0.time >= 0 } == true)
    }
}
