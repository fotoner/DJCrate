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

    /// 묶음 결과는 마지막 발행에 합친다: 쓴 묶음의 곡과 나머지 쓰기의 곡이 한 결과에 든다. 쓴 묶음은 대기열에서 지운다
    @Test func 수동_저장은_묶음_결과를_마지막_발행에_합치고_쓴_묶음을_지운다() async throws {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.tagOutcomes = ["a", "b"].map { H.outcome($0, .written) }
        h.script.preview.outcomes = [H.outcome("c", .written)]
        h.session.ports.undoGroups.enqueue(group(h, ["a", "b"]))
        h.state.rows["c"] = H.row("c")
        h.state.cueDraftUUIDs.insert("c")
        h.memory.save(H.cue("c", at: 12))
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        guard case let .written(report, _, _) = outcome else { Issue.record("쓴 것으로 알리지 않았다"); return }
        #expect(Set((report.tagOutcomes ?? []).map(\.trackUUID)) == ["a", "b"] && report.outcomes.map(\.trackUUID) == ["c"])
        #expect(h.session.ports.undoGroups.groups.isEmpty, "쓴 묶음은 지운다")
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
