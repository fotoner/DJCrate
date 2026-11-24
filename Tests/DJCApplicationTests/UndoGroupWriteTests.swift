import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 여러 곡 역편집 묶음 쓰기(R12, #405 컨실 1라운드 S1·S2·G5·O2·G8): 저장 뒤 ⌘Z가 만든 여러 곡 역편집은 자동 저장이든 ⌘S든 묶음 밖 편집과 섞지 않고
/// 한 번의 `.allOrNothing` 쓰기로 넘긴다. 구성원·판이 묶었을 때와 다르면 쓰지 않고 보류한다. 키가 겹치는 묶음은 합친다.
@MainActor
@Suite("역편집 묶음 쓰기")
struct UndoGroupWriteTests {
    typealias H = ReflectionHarness

    /// 두 곡의 태그 역편집과 그 묶음
    func group(_ h: ReflectionHarness, _ uuids: [String], id: String = "undo-1") -> ReflectionUndoEdit {
        var tags: [TagDraft] = []
        for uuid in uuids {
            let tag = H.tag(uuid, title: "되돌린 제목")
            h.state.rows[uuid] = H.row(uuid)
            h.state.tagDrafts[uuid] = tag
            h.memory.save(tag)
            tags.append(tag)
        }
        return ReflectionUndoEdit(id: id, batch: DraftWriteBatch(tags: tags, commitPolicy: .allOrNothing), rowCount: uuids.count)
    }

    @Test func 수동_저장도_역편집_묶음을_따로_전부_아니면_전무로_쓴다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀌었습니다")]
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.rows["c"] = H.row("c")
        h.state.cueDraftUUIDs.insert("c")
        h.memory.save(H.cue("c", at: 12))
        _ = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        let calls = h.gateCalls.value
        #expect(!calls.writes.contains { $0.tags.contains { $0.trackUUID == "a" } }, "묶음의 한 곡만 쓰지 않는다")
        #expect(calls.previews.contains { $0.commitPolicy == .allOrNothing && Set($0.tags.map(\.trackUUID)) == ["a", "b"] && $0.drafts.isEmpty })
        #expect(calls.writes.contains { $0.drafts.map(\.trackUUID) == ["c"] && $0.tags.isEmpty }, "묶음 밖 편집은 따로 쓴다")
    }

    // MARK: - ⌘S의 역편집 묶음(컨실 2라운드 B: S1·O9·O10)

    /// 묶음의 곡을 다 고르지 않은 ⌘S는 그 묶음을 쓰지 않고(일부만 쓰지 않는다) 제외 줄에 이유를 남긴다
    @Test func 수동_저장은_묶음_구성원을_모두_고르지_않으면_쓰지_않고_제외_줄에_남긴다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        let outcome = await h.session.write(rows: [H.row("a")])
        #expect(!h.gateCalls.value.writes.contains { $0.tags.contains { $0.trackUUID == "a" } }, "묶음의 한 곡만 쓰지 않는다")
        guard case let .nothingWritable(preview, _) = outcome else { Issue.record("쓸 것이 없다고 알리지 않았다"); return }
        #expect(preview.exclusions.contains { $0.hasPrefix("• 곡 a:") && $0.contains("함께 되돌린 다른 곡") })
    }

    /// 묶음 구성원의 초안이 사라졌으면(바깥에서 버림) 남은 곡만 쓰지 않고 제외 줄에 이유를 남긴다
    @Test func 수동_저장은_묶음_구성원의_초안이_없으면_쓰지_않고_제외_줄에_남긴다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.memory.save(TagDraft(trackUUID: "b", base: TagFields()))
        h.state.tagDrafts["b"] = nil
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b")])
        #expect(!h.gateCalls.value.writes.contains { $0.tags.contains { $0.trackUUID == "a" } })
        guard case let .nothingWritable(preview, _) = outcome else { Issue.record("쓸 것이 없다고 알리지 않았다"); return }
        #expect(preview.exclusions.contains { $0.hasPrefix("• 곡 a:") && $0.contains("함께 되돌릴 다른 편집") })
    }

    /// 묶음도 보통 쓰기와 같은 사전 확인을 지난다: 저장하지 못한 태그가 있으면 쓰지 않는다
    @Test func 수동_저장의_묶음도_저장하지_못한_태그가_있으면_쓰지_않는다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.failedTagSaves = ["a"]
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b")])
        #expect(h.gateCalls.value.writes.isEmpty)
        guard case .failed = outcome else { Issue.record("막지 않았다"); return }
    }

    /// 묶음도 보통 쓰기와 같은 확인 창을 지난다(백업할 수 없음 등): 취소하면 쓰지 않는다
    @Test func 수동_저장의_묶음도_확인_창에서_취소하면_쓰지_않는다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.canBackUp = false
        h.answer = false
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b")])
        #expect(!h.prompts.isEmpty, "확인 창을 띄운다")
        #expect(h.gateCalls.value.writes.isEmpty)
        guard case .declined = outcome else { Issue.record("취소로 알리지 않았다"); return }
    }

    /// 묶음 쓰기와 나머지 쓰기는 결과를 합치지 않고 쓰기마다 따로 발행한다(그 쓰기의 백업·[복원]·활동 기록이 따로 남는다, 컨실 3라운드 S19).
    /// 쓴 묶음은 대기열에서 지운다
    @Test func 수동_저장은_묶음과_나머지_결과를_쓰기마다_따로_발행하고_쓴_묶음을_지운다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.rows["c"] = H.row("c")
        h.state.cueDraftUUIDs.insert("c")
        h.memory.save(H.cue("c", at: 12))
        _ = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        let written = h.published.compactMap { outcome -> RekordboxWriteReport? in if case let .written(report, _, _) = outcome { report } else { nil } }
        #expect(written.count == 2)
        #expect(Set((written.first?.tagOutcomes ?? []).map(\.trackUUID)) == ["a", "b"] && written.first?.outcomes.isEmpty == true, "묶음 결과")
        #expect(written.last?.outcomes.map(\.trackUUID) == ["c"] && (written.last?.tagOutcomes ?? []).isEmpty, "나머지 결과")
        #expect(h.session.ports.undoGroups.groups.isEmpty, "쓴 묶음은 지운다")
    }

    /// 묶음을 쓴 뒤 나머지 쓰기가 실패해도 앞서 쓴 묶음 결과는 발행돼 남는다(컨실 3라운드 S20·O15)
    @Test func 묶음을_쓴_뒤_나머지가_실패해도_묶음_결과를_발행한다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b", "c"].map { H.outcome($0, .written) }
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.rows["c"] = H.row("c")
        h.state.tagDrafts["c"] = H.tag("c")
        h.memory.save(H.tag("c"))
        h.onPublish = { [h] outcome in if case .written = outcome { h.state.failedTagSaves = ["c"] } }
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        #expect(h.published.contains { if case .written = $0 { true } else { false } }, "묶음 결과를 발행했다")
        #expect(h.published.contains { if case .failed = $0 { true } else { false } }, "나머지는 실패로 알린다")
        // 백업 전 실패라 이번 ⌘S는 쓴 결과로 돌려준다(엔진이 멈춤을 풀고 자기 쓰기로 기준을 잡는다, 컨실 4라운드 H)
        guard case .written = outcome else { Issue.record("쓴 결과를 돌려주지 않았다"); return }
    }

    /// 묶음을 쓴 뒤 나머지 쓰기의 준비 단계에서 취소해도 앞서 쓴 묶음 결과는 발행돼 남는다(컨실 3라운드 S20)
    @Test func 묶음을_쓴_뒤_나머지를_취소해도_묶음_결과를_발행한다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.rows["c"] = H.row("c")
        h.state.cueDraftUUIDs.insert("c")
        h.memory.save(H.cue("c", at: 12))
        h.onPublish = { [h] outcome in if case .written = outcome { h.previewHold.hold() } }
        let session = h.session
        let task = Task { await session.write(rows: [H.row("a"), H.row("b"), H.row("c")]) }
        for _ in 0..<4000 where !h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.previewHold.isWaiting)
        task.cancel()
        h.previewHold.release()
        let outcome = await task.value
        #expect(h.published.contains { if case .written = $0 { true } else { false } }, "묶음 결과를 발행했다")
        // 앞에서 쓴 것이 있으면 뒤 취소는 "아무것도 저장하지 않았습니다"를 띄우지 않고, 이번 ⌘S는 쓴 결과로 돌려준다(컨실 4라운드 H)
        #expect(!h.published.contains { if case .cancelled = $0 { true } else { false } })
        guard case .written = outcome else { Issue.record("쓴 결과를 돌려주지 않았다"); return }
    }

    /// 쓰지 못한 묶음의 제외 사유는 나머지 쓰기의 결과에 싣는다(일부만 저장해도 사유가 남는다, 컨실 3라운드 S22)
    @Test func 쓰지_못한_묶음의_제외_사유는_나머지_결과에_싣는다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.rows["c"] = H.row("c")
        h.state.cueDraftUUIDs.insert("c")
        h.memory.save(H.cue("c", at: 12))
        let outcome = await h.session.write(rows: [H.row("a"), H.row("c")])
        guard case let .written(_, _, followUp) = outcome else { Issue.record("쓴 것으로 알리지 않았다"); return }
        // 결과의 뒤따른 줄은 화면이 "• "를 붙인다: 제외 줄에 따로 붙이지 않는다(컨실 4라운드 G24)
        #expect(followUp.contains { $0.hasPrefix("곡 a:") && $0.contains("함께 되돌린 다른 곡") })
    }

    // MARK: - ⌘S 한 번을 대표하는 결과(컨실 4라운드 H·I·O17)

    func cue(_ h: ReflectionHarness, _ uuid: String) {
        h.state.rows[uuid] = H.row(uuid)
        h.state.cueDraftUUIDs.insert(uuid)
        h.memory.save(H.cue(uuid, at: 12))
    }

    /// 묶음을 쓴 뒤 나머지가 막혀 쓸 것이 없어도 돌려주는 결과는 쓴 결과다(엔진이 멈춤을 풀고 자기 쓰기로 조용함 기준을 다시 잡는다, H)
    @Test func 묶음을_쓴_뒤_나머지가_막혀도_돌려주는_결과는_쓴_결과다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .blocked, reason: "바뀌었습니다")]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        cue(h, "c")
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        guard case .written = outcome else { Issue.record("쓴 결과를 돌려주지 않았다"); return }
    }

    /// 뒤 쓰기가 백업을 뜬 뒤 실패하면 앞에서 쓴 묶음이 있어도 그 실패를 돌려준다(엔진이 멈춘다, H)
    @Test func 나머지가_백업_뒤_실패하면_그_실패를_돌려준다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.script.writeErrorFor = { batch in
            batch.drafts.contains { $0.trackUUID == "c" } ? RekordboxWriteGate.AfterBackupFailure(CocoaError(.fileWriteUnknown)) : nil
        }
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        cue(h, "c")
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        #expect(h.published.contains { if case .written = $0 { true } else { false } }, "묶음 결과는 따로 발행했다")
        guard case .failed = outcome else { Issue.record("백업 뒤 실패를 돌려주지 않았다"); return }
    }

    /// 막힌 묶음이 여럿이거나 묶음과 나머지가 함께 막히면 막힌 줄과 대상 곡을 모아 복구 시트 하나로 넘긴다(I)
    @Test func 막힌_묶음들과_나머지를_모아_복구_시트_하나로_넘긴다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀌었습니다"),
                                        H.outcome("c", .written), H.outcome("d", .blocked, reason: "바뀌었습니다")]
        h.script.preview.outcomes = [H.outcome("e", .blocked, reason: "바뀌었습니다")]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"], id: "1"))
        h.session.ports.undoGroups.enqueue(group(h, ["c", "d"], id: "2"))
        cue(h, "e")
        let outcome = await h.session.write(rows: ["a", "b", "c", "d", "e"].map { H.row($0) })
        guard case let .nothingWritable(preview, targets) = outcome else { Issue.record("막힌 결과를 돌려주지 않았다"); return }
        #expect(Set(preview.report.tagBlocked.map(\.trackUUID)) == ["b", "d"] && preview.report.blocked.map(\.trackUUID) == ["e"])
        #expect(Set(targets.map(\.track.uuid)).isSuperset(of: ["a", "b", "c", "d", "e"]))
    }

    /// 묶음이 막힌 뒤 나머지 확인 창에서 [취소]하면 복구 시트를 띄우지 않는다(O17)
    @Test func 묶음이_막힌_뒤_나머지_확인_창을_취소하면_복구_시트를_띄우지_않는다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀌었습니다")]
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        cue(h, "c")
        h.canBackUp = false
        h.answer = false
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        #expect(!h.prompts.isEmpty)
        guard case .declined = outcome else { Issue.record("취소로 돌려주지 않았다"); return }
    }

    /// 쓴 것 없이 묶음이 막힌 뒤 나머지가 백업 전에 실패하면 그 실패를 돌려준다: 실패 위에 복구 시트를 열지 않는다(컨실 5라운드 G25)
    @Test func 묶음이_막힌_뒤_나머지가_백업_전에_실패하면_그_실패를_돌려준다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀌었습니다"), H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.rows["c"] = H.row("c")
        h.state.tagDrafts["c"] = H.tag("c")
        h.memory.save(H.tag("c"))
        h.onPublish = { [h] outcome in if case .nothingWritable = outcome { h.state.failedTagSaves = ["c"] } }
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        guard case .failed = outcome else { Issue.record("실패를 돌려주지 않았다"); return }
    }

    /// 쓴 것 없이 묶음이 막힌 뒤 나머지를 진행 중에 취소하면 취소를 돌려준다: 취소했는데 복구 시트를 열지 않는다(G25)
    @Test func 묶음이_막힌_뒤_나머지를_취소하면_취소를_돌려준다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀌었습니다")]
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        cue(h, "c")
        h.onPublish = { [h] outcome in if case .nothingWritable = outcome { h.previewHold.hold() } }
        let session = h.session
        let task = Task { await session.write(rows: [H.row("a"), H.row("b"), H.row("c")]) }
        for _ in 0..<4000 where !h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.previewHold.isWaiting)
        task.cancel()
        h.previewHold.release()
        guard case .cancelled = await task.value else { Issue.record("취소를 돌려주지 않았다"); return }
    }

    /// 구성원을 모두 고르지 않은 묶음은 저장 실패 검사보다 먼저 뺀다: 고르지 않은 구성원(B)의 태그 저장 실패가 묶음 밖 곡(C)의 저장을 막지 않는다(컨실 5라운드 S28)
    @Test func 고르지_않은_구성원의_저장_실패는_묶음_밖_곡의_저장을_막지_않는다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.failedTagSaves = ["b"]
        cue(h, "c")
        let outcome = await h.session.write(rows: [H.row("a"), H.row("c")])
        #expect(h.gateCalls.value.writes.contains { $0.drafts.map(\.trackUUID) == ["c"] }, "묶음 밖 곡은 쓴다")
        #expect(!h.gateCalls.value.writes.contains { $0.tags.contains { $0.trackUUID == "a" } }, "묶음의 한 곡만 쓰지 않는다")
        guard case .written = outcome else { Issue.record("쓴 결과를 돌려주지 않았다"); return }
    }

    /// 묶음 구성원의 태그 초안을 보관하지 못했으면(다시 해도 실패) 구성원 없음 제외가 아니라 저장 실패로 막는다(G20)
    @Test func 묶음_구성원의_태그_저장_실패는_구성원_없음이_아니라_저장_실패로_막는다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        // b의 역편집은 보관하지 못했다(도장 없음)
        h.memory.save(TagDraft(trackUUID: "b", base: TagFields()))
        h.state.failedTagSaves = ["b"]
        cue(h, "c")
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        #expect(h.gateCalls.value.writes.isEmpty, "묶음 밖 곡만 쓰지 않는다")
        guard case .failed = outcome else { Issue.record("저장 실패로 막지 않았다"); return }
    }

    /// ⌘Z 직후 ⌘S: 보관 큐를 비우고 태그 저장을 다시 해 본 뒤 구성원 초안을 본다(보관 대기 중인 역편집을 빠진 것으로 보지 않는다, 컨실 3라운드 S21·G15)
    @Test func 수동_저장은_태그_저장을_다시_해_본_뒤_묶음_구성원을_본다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        let edit = group(h, ["a", "b"])
        // b의 역편집은 아직 보관하지 못했다(다시 해 보면 보관된다)
        h.memory.save(TagDraft(trackUUID: "b", base: TagFields()))
        h.onRetryTagSaves = { [h] in h.memory.save(H.tag("b", title: "되돌린 제목")) }
        h.session.ports.undoGroups.enqueue(edit)
        _ = await h.session.write(rows: [H.row("a"), H.row("b")])
        #expect(h.gateCalls.value.writes.contains { Set($0.tags.map(\.trackUUID)) == ["a", "b"] }, "묶음을 쓴다")
    }

    /// 손상 초안 확인은 고른 곡 전체로 한 번만 한다: 묶음 밖 곡의 초안 파일이 손상됐으면 묶음도 쓰지 않는다(컨실 3라운드 O13)
    @Test func 수동_저장은_고른_곡_전체의_손상_초안을_묶음보다_먼저_본다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.rows["c"] = H.row("c")
        h.state.cueDraftUUIDs.insert("c")
        h.memory.save(H.cue("c", at: 12))
        h.preserved = [DamagedDraftFile(name: "c.json", preserved: URL(filePath: "/tmp/damaged/c.json"), trackUUID: "c")]
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        #expect(h.gateCalls.value.writes.isEmpty)
        guard case .failed = outcome else { Issue.record("막지 않았다"); return }
    }

    /// 묶음이 막히면(한 곡이라도) 그 미리 보기를 마지막 발행에 남긴다(복구 시트로 고친다). 묶음은 대기열에 남는다
    @Test func 수동_저장의_묶음이_막히면_그_보고를_발행에_남긴다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀌었습니다")]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b")])
        #expect(h.gateCalls.value.writes.isEmpty)
        guard case let .nothingWritable(preview, targets) = outcome else { Issue.record("쓸 것이 없다고 알리지 않았다"); return }
        #expect(preview.report.tagOutcomes?.contains { $0.trackUUID == "b" && $0.status == .blocked } == true)
        #expect(Set(targets.map(\.track.uuid)) == ["a", "b"])
        #expect(h.session.ports.undoGroups.groups.count == 1)
    }

    @Test func 자동_저장_묶음의_구성원이나_판이_바뀌었으면_쓰지_않고_보류한다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        _ = group(h, ["a", "b"])
        let revisions = Dictionary(uniqueKeysWithValues: ["a", "b"].map { uuid in
            (uuid, [DraftKey(.tag, uuid): h.memory.stamp(DraftKey(.tag, uuid))!.revision])
        })
        // 묶은 뒤 b를 바깥에서 다시 저장했다(새 판)
        h.memory.save(H.tag("b", title: "바깥 제목"), origin: .cli)
        let chunk = AutoReflectionChunk(tracks: revisions, playlistSteps: 0, stepRevisions: [], rows: 2, allOrNothing: true)
        guard case .held = await h.session.autoWrite(chunk) else { Issue.record("보류하지 않았다"); return }
        #expect(h.gateCalls.value.previews.isEmpty && h.gateCalls.value.writes.isEmpty)
    }

    @Test func 키가_겹치는_역편집_묶음은_합친다() {
        let groups = ReflectionUndoGroups()
        let h = ReflectionHarness()
        groups.enqueue(group(h, ["a", "b"], id: "1"))
        groups.enqueue(group(h, ["b", "c"], id: "2"))
        groups.enqueue(group(h, ["d", "e"], id: "3"))
        #expect(groups.groups.count == 2)
        let merged = groups.groups.first { $0.keys.contains(DraftKey(.tag, "a")) }
        #expect(merged?.keys == Set(["a", "b", "c"].map { DraftKey(.tag, $0) }) && merged?.rows == 3 && merged?.revisions.isEmpty == true)
    }

    @Test func 전부_아니면_전무_쓰기가_모두_거절되면_쓴_것으로_알리지_않는다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        // 미리 보기 뒤 실제 쓰기에서 한 곡이 막혀 입구가 모두 거절했다
        var refused = RekordboxWriteReport(outcomes: [], dryRun: false, createdAt: "", finalUpdateCount: 1)
        refused.tagOutcomes = ["a", "b"].map { H.outcome($0, .blocked, reason: "함께 되돌릴 다른 편집이 막혔습니다") }
        h.script.write = refused
        _ = group(h, ["a", "b"])
        let revisions = Dictionary(uniqueKeysWithValues: ["a", "b"].map { uuid in
            (uuid, [DraftKey(.tag, uuid): h.memory.stamp(DraftKey(.tag, uuid))!.revision])
        })
        let chunk = AutoReflectionChunk(tracks: revisions, playlistSteps: 0, stepRevisions: [], rows: 2, allOrNothing: true)
        guard case let .nothingWritten(unwritten) = await h.session.autoWrite(chunk) else { Issue.record("쓴 것으로 알렸다"); return }
        #expect(unwritten.count == 2)
        #expect(!h.published.contains { if case .autoWritten = $0 { true } else { false } })
    }
}
