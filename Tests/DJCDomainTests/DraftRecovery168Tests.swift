import DJCDomain
import Foundation
import Testing

@Suite("종류별 현재값 복구")
struct DraftRecovery168Tests {
    @Test func 태그_비겹침_현재값을_보존한다() {
        var base = TagFields(); base.title = "원곡"
        var draft = TagDraft(trackUUID: "synthetic", base: base); draft.fields.comment = "내 편집"
        var current = base; current.title = "최신 제목"
        let result = TagDraftRecovery(draft: draft, current: current).resolve(.keepEditing)
        #expect(result.base == current && result.fields.title == current.title && result.fields.comment == "내 편집")
        #expect(draft.base == base)
    }
    @Test func 태그_같은_원하는값은_정리하고_진짜_충돌은_선택한다() {
        var base = TagFields(); base.title = "원곡"
        var draft = TagDraft(trackUUID: "synthetic", base: base); draft.fields.comment = "내 편집"
        var current = base; current.comment = "내 편집"
        #expect(!TagDraftRecovery(draft: draft, current: current).resolve(.keepEditing).hasChanges)
        current.comment = "외부 편집"
        let recovery = TagDraftRecovery(draft: draft, current: current)
        #expect(recovery.conflictingKeys == [.comment])
        #expect(recovery.resolve(.useCurrent).fields == current)
        #expect(recovery.resolve(.keepEditing).fields.comment == "내 편집")
    }
    @Test func 큐_새_현재값은_기존_ID로_대응하고_안고친_루프를_보존한다() throws {
        let old = EditableCue(sourceID: "cue-1", kind: .memory, time: 2, name: "원래", loop: .init(end: 4, active: true, beats: 4))
        var draft = CueDraft(trackUUID: "synthetic"); draft.base = [old]; draft.cues = [old]; draft.cues[0].name = "내 이름"
        var current = old; current.id = .init(); current.time = 3; current.loop?.end = 5
        let recovery = CueDraftRecovery(draft: draft, current: [current])
        let result = try recovery.resolve(.keepEditing)
        #expect(result.base.first?.time == 3 && result.base.first?.id == old.id)
        #expect(result.cues.first?.name == "내 이름" && result.cues.first?.time == 3)
        #expect(result.cues.first?.loop == current.loop && result.cues.first?.sourceID == "cue-1")
    }
    @Test func 큐_사라진_sourceID를_자동매칭하지_않는다() throws {
        let old = EditableCue(sourceID: "old-id", kind: .memory, time: 2, name: "CUE(Auto)")
        var draft = CueDraft(trackUUID: "synthetic"); draft.base = [old]; draft.cues = [old]; draft.cues[0].time = 3
        var current = old; current.sourceID = "new-id"; current.id = .init()
        #expect(throws: DraftRecoveryError.self) { try CueDraftRecovery(draft: draft, current: [current]).resolve(.keepEditing) }
        #expect(try !CueDraftRecovery(draft: draft, current: [current]).resolve(.useCurrent).hasChanges)
        #expect(draft.base.first?.sourceID == "old-id" && draft.cues.first?.time == 3)
    }
    @Test func 큐_외부추가와_미편집_자동큐를_보존한다() throws {
        let auto = EditableCue(sourceID: "auto", kind: .memory, time: 0, name: "CUE(Auto)")
        let extra = EditableCue(sourceID: "new", kind: .hot(2), time: 8, loop: .init(end: 10, active: true, beats: 4))
        var draft = CueDraft(trackUUID: "synthetic"); draft.base = [auto]; draft.cues = [auto, .init(kind: .memory, time: 5, name: "추가")]
        let result = try CueDraftRecovery(draft: draft, current: [auto, extra]).resolve(.keepEditing)
        #expect(result.cues.count == 3 && result.cues.contains(auto) && result.cues.contains(extra))
    }
    @Test func 큐_동일결과와_중복_ID를_구분한다() throws {
        let old = EditableCue(sourceID: "cue", kind: .memory, time: 2)
        var draft = CueDraft(trackUUID: "synthetic"); draft.base = [old]; draft.cues = [old]; draft.cues[0].name = "같음"
        var current = draft.cues[0]; current.id = .init()
        #expect(try !CueDraftRecovery(draft: draft, current: [current]).resolve(.keepEditing).hasChanges)
        #expect(throws: DraftRecoveryError.self) { try CueDraftRecovery(draft: draft, current: [current, current]).resolve(.keepEditing) }
    }
    @Test func 그리드_비겹침과_변속원형을_보존한다() throws {
        let base = [GridSegment(start: 0.2, bpm: 120, firstBeatNumber: 1), GridSegment(start: 6.2, bpm: 180, firstBeatNumber: 1)]
        var draft = GridDraft(trackUUID: "synthetic", base: base, segments: base); draft.segments[0].firstBeatNumber = 3
        var current = base; current[1].bpm = 160
        let result = try GridDraftRecovery(draft: draft, current: current).resolve(.keepEditing)
        #expect(result.base == current && result.segments[0].firstBeatNumber == 3 && result.segments[1].bpm == 160)
        #expect(result.segments.map(\.start) == base.map(\.start))
    }
    @Test func 그리드_대응모호함은_내편집을_그대로_남긴다() throws {
        let base = [GridSegment(start: 0.2, bpm: 120, firstBeatNumber: 1)]
        var draft = GridDraft(trackUUID: "synthetic", base: base, segments: base); draft.shift(by: 0.01)
        let original = draft
        let current = base + [.init(start: 4.2, bpm: 180, firstBeatNumber: 1)]
        #expect(throws: DraftRecoveryError.self) { try GridDraftRecovery(draft: draft, current: current).resolve(.keepEditing) }
        #expect(try !GridDraftRecovery(draft: draft, current: current).resolve(.useCurrent).hasChanges)
        #expect(draft == original)
    }
    @Test(arguments: [false, true])
    func 단일구간의_시각과_BPM_비겹침은_모두_보존한다(moveMine: Bool) throws {
        let base = [GridSegment(start: 0.2, bpm: 120, firstBeatNumber: 1)]
        var d = GridDraft(trackUUID: "synthetic", base: base, segments: base), current = base
        if moveMine { d.shift(by: 0.01); current[0].bpm = 160 }
        else { d.segments[0].bpm = 160; current[0].start = 0.3 }
        let result = try GridDraftRecovery(draft: d, current: current).resolve(.keepEditing)
        #expect(result.base == current && result.segments[0].bpm == 160)
        #expect(result.segments[0].start == (moveMine ? d.segments[0].start : current[0].start))
    }
    @Test(arguments: [EditableCue.Kind.memory, .hot(2)])
    func 새큐에_sourceID가_붙은_동일결과는_중복하지_않는다(kind: EditableCue.Kind) throws {
        var d = CueDraft(trackUUID: "synthetic")
        let added = EditableCue(kind: kind, time: 4, name: "추가", loop: .init(end: 6, active: true, beats: 4))
        d.cues = [added]
        var current = added; current.id = .init(); current.sourceID = "written-id"
        let result = try CueDraftRecovery(draft: d, current: [current]).resolve(.keepEditing)
        #expect(result.cues.count == 1 && !result.hasChanges && result.cues.first?.sourceID == "written-id")
    }

    @Test func 사라진_큐는_사용자가_고른_행에만_재적용한다() throws {
        let old = EditableCue(sourceID: "old", kind: .memory, time: 2, name: "원래")
        var d = CueDraft(trackUUID: "synthetic"); d.base = [old]; d.cues = [old]; d.cues[0].name = "내 이름"
        let current = EditableCue(sourceID: "new", kind: .memory, time: 3, name: "현재", loop: .init(end: 5, active: true, beats: 4))
        let result = try CueDraftRecovery(draft: d, current: [current], sourceMappings: ["old": "new"]).resolve(.keepEditing)
        #expect(result.base[0].sourceID == "new" && result.cues[0].sourceID == "new")
        #expect(result.cues[0].time == 3 && result.cues[0].name == "내 이름" && result.cues[0].loop == current.loop)
        #expect(throws: DraftRecoveryError.self) { try CueDraftRecovery(draft: d, current: [current], sourceMappings: ["old": "missing"]).resolve(.keepEditing) }
        #expect(d.base[0] == old && d.cues[0].sourceID == "old")
    }

    @Test(arguments: TagFields.Key.allCases)
    func 태그_아홉칸_기준과_안고친_현재값을_함께_맞춘다(key: TagFields.Key) {
        var base = TagFields()
        for field in TagFields.Key.allCases { base[field] = "원래 " + field.rawValue }
        var draft = TagDraft(trackUUID: "synthetic", base: base); draft.fields[key] = "내 편집"
        var current = base
        for field in TagFields.Key.allCases where field != key { current[field] = "최신 " + field.rawValue }
        let result = TagDraftRecovery(draft: draft, current: current).resolve(.keepEditing)
        #expect(result.base == current && result.fields[key] == "내 편집")
        #expect(TagFields.Key.allCases.filter { $0 != key }.allSatisfy { result.fields[$0] == current[$0] })
    }

    @Test(arguments: [false, true])
    func 외부에서_지운_루프는_루프를_고쳤을_때만_명시_재적용한다(editLoop: Bool) throws {
        let old = EditableCue(sourceID: "loop", kind: .memory, time: 2, name: "원래", loop: .init(end: 4, active: true, beats: 4))
        var draft = CueDraft(trackUUID: "synthetic"); draft.base = [old]; draft.cues = [old]
        if editLoop { draft.cues[0].loop?.end = 6 } else { draft.cues[0].name = "내 이름" }
        var current = old; current.id = .init(); current.loop = nil; current.name = "최신 이름"
        let result = try CueDraftRecovery(draft: draft, current: [current]).resolve(.keepEditing)
        #expect(result.cues[0].loop == (editLoop ? draft.cues[0].loop : nil))
        #expect(result.cues[0].name == (editLoop ? current.name : "내 이름"))
        #expect(draft.base[0] == old)
    }

}
