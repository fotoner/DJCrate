import DJCDomain
import Foundation
import Testing

/// 덱에 올린 곡의 그리드 편집 진입 판정. 옛 `DeckPayloadGridTests`(합성 DB·ANLZ 파일)를 순수 값으로 옮겼다.
@Suite("덱 그리드 편집 진입")
struct DeckGridGateTests {
    /// 120BPM 박 10개(첫 박 500ms). 분석 파일(PQTZ)처럼 시각은 정수 ms다.
    static func original(shiftMs: Int = 0, at index: Int = 2) -> BeatGrid {
        BeatGrid(beats: (0..<10).map { k in
            let ms = 500 + k * 500 + (k == index ? shiftMs : 0)
            return BeatGrid.Beat(number: k % 4 + 1, bpm: 120, time: Double(ms) / 1000)
        })
    }

    @Test(arguments: [AnalysisGridRead.missing, .unreadable, .noBeats])
    func 분석_파일의_부재와_읽기_실패와_박_없음을_구분한다(read: AnalysisGridRead) throws {
        let gate = DeckGridGate(trackUUID: "analysis-issue", read: read, savedDraft: nil, duration: 5)
        let reason = try #require(gate.blockedReason)
        #expect(reason.contains(read == .missing ? "없" : read == .unreadable ? "읽지 못" : "박 정보"))
        #expect(reason.contains("rekordbox"))
        #expect(gate.sourceNotice == reason)
        #expect(gate.gridDraft == nil && gate.originalGrid == nil)
    }

    @Test func 원본이_없으면_적용해_둔_추정_그리드_초안을_쓴다() {
        let applied = GridDraft(trackUUID: "estimated", base: [], segments: [.init(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        let gate = DeckGridGate(trackUUID: "estimated", read: .missing, savedDraft: applied, duration: 5)
        #expect(gate.gridDraft == applied && gate.blockedReason == nil && gate.sourceNotice != nil)
        // 원본에 대한 대체 승인이 붙은 초안은 원본이 없어지면 쓸 수 없다.
        var approved = applied
        approved.replacementSource = "fingerprint"
        #expect(DeckGridGate(trackUUID: "estimated", read: .missing, savedDraft: approved, duration: 5).blockedReason != nil)
    }

    @Test(arguments: [(0.002).nextDown, 0.002, (0.002).nextUp, 0.00249, (0.003).nextDown, 0.003, (0.003).nextUp])
    func 부동소수점_주변값도_같은_ms로_판정한다(delta: Double) {
        let original = BeatGrid(beats: [.init(number: 1, bpm: 120, time: 1.5 + delta)])
        let rebuilt = BeatGrid(beats: [.init(number: 1, bpm: 120, time: 1.5)])
        #expect(GridEditEligibility.reconstructionErrorMilliseconds(original: original, rebuilt: rebuilt)
                == (delta < 0.0025 ? 2 : 3))
    }

    @Test(arguments: [0, 1, 2, 3])
    func 재생성_경계는_ANLZ_정수_ms로_판정한다(offset: Int) throws {
        let gate = DeckGridGate(trackUUID: "grid-boundary", read: .grid(Self.original(shiftMs: offset)), savedDraft: nil, duration: 5)
        #expect(gate.originalGrid == Self.original(shiftMs: offset))
        #expect(gate.gridDraft == GridDraft(trackUUID: "grid-boundary", grid: Self.original(shiftMs: offset)))
        #expect((gate.blockedReason != nil) == (offset > 2))
        #expect(gate.sourceNotice == nil)
    }

    @Test func 재현되지_않는_원본의_막힘_문구는_구간_수와_오차를_알린다() throws {
        let reason = try #require(DeckGridGate(trackUUID: "t", read: .grid(Self.original(shiftMs: 3)), savedDraft: nil, duration: 5).blockedReason)
        #expect(reason.contains("최대 3ms") && reason.contains("rekordbox에서 직접 편집하세요"))
    }

    @Test(arguments: [false, true])
    func 승인한_대체_초안을_저장하고_재로드해도_편집할_수_있다(sameSegments: Bool) throws {
        let original = Self.original(shiftMs: 3)
        var draft = GridDraft(trackUUID: "grid-replacement", grid: original)
        if !sameSegments { draft.segments = [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)] }
        let approved = try #require(draft.approvingReplacement(of: original, duration: 5))
        // 초안 파일(JSON)을 거쳐도 승인이 남는다.
        let saved = try JSONDecoder().decode(GridDraft.self, from: JSONEncoder().encode(approved))
        let gate = DeckGridGate(trackUUID: "grid-replacement", read: .grid(original), savedDraft: saved, duration: 5)
        #expect(gate.gridDraft == approved)
        #expect(gate.blockedReason == nil)
        // 구간화 결과가 같아도 interior 박이 바뀌면 승인은 재사용할 수 없다.
        let changed = Self.original(shiftMs: 2)
        #expect(GridDraft.segments(from: changed) == approved.base)
        let stale = DeckGridGate(trackUUID: "grid-replacement", read: .grid(changed), savedDraft: saved, duration: 5)
        #expect(stale.blockedReason?.contains("그리드 현재값 가져오기") == true)
        #expect(stale.gridDraft == saved)
    }

    @Test(arguments: ["legacy", "base", "marker", "shape", "uuid"])
    func 미검증_대체_초안은_편집_제한을_우회하지_못한다(invalid: String) throws {
        let original = Self.original(shiftMs: 3)
        var draft = GridDraft(trackUUID: "grid-invalid", grid: original)
        draft.segments = [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)]
        draft = try #require(draft.approvingReplacement(of: original, duration: 5))
        switch invalid {
        case "legacy": draft.replacementSource = nil
        case "base": draft.base[0].start += 0.01
        case "marker": draft.replacementSource = "invalid"
        case "shape": draft.segments.append(.init(start: 2, bpm: 140, firstBeatNumber: 1))
        case "uuid": draft.trackUUID = "another"
        default: Issue.record("알 수 없는 대조")
        }
        #expect(DeckGridGate(trackUUID: "grid-invalid", read: .grid(original), savedDraft: draft, duration: 5).blockedReason != nil)
        // 편집 뒤 다시 판정해도 같은 규칙이다.
        #expect(DeckGridGate.editBlockedReason(trackUUID: "grid-invalid", original: original, draft: draft, duration: 5) != nil)
    }

    @Test func 승인한_대체_초안은_원본이_없어지면_막는다() throws {
        let original = Self.original(shiftMs: 3)
        var draft = GridDraft(trackUUID: "grid-invalid", grid: original)
        draft.segments = [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)]
        let approved = try #require(draft.approvingReplacement(of: original, duration: 5))
        #expect(DeckGridGate(trackUUID: "grid-invalid", read: .missing, savedDraft: approved, duration: 5).blockedReason != nil)
    }

    @Test func 편집_뒤_판정은_곡_불러오기_판정과_같다() {
        for shift in [0, 3] {
            let original = Self.original(shiftMs: shift)
            let loaded = DeckGridGate(trackUUID: "t", read: .grid(original), savedDraft: nil, duration: 5)
            #expect(DeckGridGate.editBlockedReason(trackUUID: "t", original: original, draft: loaded.gridDraft, duration: 5)
                    == loaded.blockedReason)
        }
    }
}

@Suite("덱 불러오기 위치·템포")
struct DeckLoadPositionTests {
    @Test func 첫_메모리_큐에서_대기하고_없으면_0초다() {
        let cues = [EditableCue(kind: .hot(0), time: 2), EditableCue(kind: .memory, time: 12), EditableCue(kind: .memory, time: 8)]
        #expect(DeckCuePoint.onLoad(cues: cues, duration: 180) == 8)
        #expect(DeckCuePoint.onLoad(cues: [EditableCue(kind: .hot(0), time: 2)], duration: 180) == 0)
        #expect(DeckCuePoint.onLoad(cues: [], duration: 180) == 0)
    }

    @Test func 곡_길이_밖의_메모리_큐는_곡_안으로_당긴다() {
        #expect(DeckCuePoint.onLoad(cues: [EditableCue(kind: .memory, time: 200)], duration: 180) == 180)
        #expect(DeckCuePoint.onLoad(cues: [EditableCue(kind: .memory, time: -1)], duration: 180) == 0)
    }

    @Test func 재생_위치가_있는_템포_구간의_BPM() {
        let grid = BeatGrid(beats: [.init(number: 1, bpm: 120, time: 1), .init(number: 2, bpm: 120, time: 1.5),
                                    .init(number: 3, bpm: 140, time: 2), .init(number: 4, bpm: 140, time: 2.43)])
        #expect(grid.bpm(at: 0) == 120)
        #expect(grid.bpm(at: 1.7) == 120)
        // 박 시각에서 1ms 안쪽이면 그 박의 템포로 본다(재생선이 박 위에 놓였을 때).
        #expect(grid.bpm(at: 1.9995) == 140)
        #expect(grid.bpm(at: 2) == 140)
        #expect(grid.bpm(at: 10) == 140)
        #expect(BeatGrid(beats: []).bpm(at: 1) == nil)
    }
}
