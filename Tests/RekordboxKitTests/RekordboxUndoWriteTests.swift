import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 저장 뒤 ⌘Z의 역편집이 기대는 쓰기 입구 규칙(#405, R12·R23).
/// - 쓴 큐는 ID가 바뀐다: 결과가 초안 큐(UUID) → 새 `djmdCue.ID`를 돌려줘 역편집이 같은 큐를 찾는다.
/// - 지운 큐를 되살리면 ID만 새로 받고 위치·종류·이름·색은 지우기 전과 같다. 색은 rekordbox가 적어 둔 값을 그대로 옮긴다
///   (옮긴 큐가 색을 이어받는 규칙과 같은 칸, 2026-09-26 실험: docs/rekordbox-internals.md "큐").
/// - 여러 곡 역편집은 한 곡이라도 막히면 아무것도 쓰지 않는다(`allOrNothing`).
/// - 게인 초안에 base가 있으면 지금 rekordbox 게인과 같을 때만 쓴다.
@Suite("rekordbox 쓰기 — 저장 뒤 ⌘Z")
struct RekordboxUndoWriteTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    func write(_ fixture: RekordboxFixture, drafts: [CueDraft] = [], gains: [String: Double] = [:], gainBases: [String: Double] = [:],
               allOrNothing: Bool = false) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, gains: gains, gainBases: gainBases, to: fixture.database, dryRun: false, now: now,
                                  backups: fixture.backups, shareRoot: fixture.shareRoot, allOrNothing: allOrNothing)
    }

    func cueRows(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> [[String: String]] {
        try fixture.rows("SELECT * FROM djmdCue WHERE ContentID = ? ORDER BY InMsec", [.text(track.id)])
    }

    func currentCues(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> [Cue] {
        try cueRows(fixture, track).map { row in
            // 시험 읽기는 NULL 칸을 "NULL"로 돌려준다
            Cue(id: row["ID"]!, contentID: track.id, kind: Int(row["Kind"]!)!, inMsec: Int(row["InMsec"]!)!,
                name: row["Comment"].flatMap { $0 == "NULL" ? nil : $0 } ?? "",
                colorTableIndex: Int(row["ColorTableIndex"] ?? ""), outMsec: Int(row["OutMsec"]!)!, color: Int(row["Color"] ?? ""),
                activeLoop: Int(row["ActiveLoop"] ?? "") ?? 0, beatLoopSize: Int(row["BeatLoopSize"] ?? "") ?? 0)
        }
    }

    @Test func 새로_넣은_큐마다_초안_큐에서_새_큐_ID를_돌려준다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.cues = [CueSpec(kind: 1, inMsec: 5000), CueSpec(kind: 0, inMsec: 20000)]
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        var moved = try #require(draft.cues.first { $0.kind == .hot(0) })
        moved.time = 6
        draft.place(moved)
        let added = EditableCue(kind: .memory, time: 40)
        draft.place(added)

        let report = try write(fixture, drafts: [draft])
        let outcome = try #require(report.written.first)
        let ids = try #require(outcome.cueIDs)
        // 옮긴 큐와 새 큐만(건드리지 않은 메모리 큐는 원래 ID 그대로라 적지 않는다)
        #expect(Set(ids.keys) == [moved.id.uuidString, added.id.uuidString])
        let rows = try cueRows(fixture, track)
        #expect(rows.first { $0["ID"] == ids[moved.id.uuidString] }?["InMsec"] == "6000")
        #expect(rows.first { $0["ID"] == ids[added.id.uuidString] }?["InMsec"] == "40000")
        #expect(rows.contains { $0["ID"] == track.cues[1].id })
    }

    @Test func 지운_큐를_되살리면_ID만_새로_받고_위치_종류_이름_색은_같다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        var hot = CueSpec(kind: 2, inMsec: 12000)
        hot.color = 16711680; hot.colorTableIndex = 3; hot.comment = "드롭"
        track.cues = [hot, CueSpec(kind: 0, inMsec: 30000)]
        try fixture.add(track)
        let before = try #require(cueRows(fixture, track).first { $0["ID"] == hot.id })

        // 편집: 핫큐 B를 지운다 → 저장
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        let deleted = try #require(draft.cues.first { $0.kind == .hot(1) })
        #expect(deleted.color == EditableCue.ColorMark(color: 16711680, tableIndex: 3, memory: false))
        draft.remove(deleted.id)
        _ = try write(fixture, drafts: [draft])
        #expect(try cueRows(fixture, track).allSatisfy { $0["Kind"] != "2" })

        // 역편집: 지금 rekordbox 큐를 base로, 지운 큐를 새 큐로 되살린다
        var undo = CueDraft(trackUUID: track.uuid, rekordboxCues: try currentCues(fixture, track))
        var restored = deleted
        restored.sourceID = nil
        undo.place(restored)
        let report = try write(fixture, drafts: [undo])
        let newID = try #require(report.written.first?.cueIDs?[restored.id.uuidString])
        let after = try #require(cueRows(fixture, track).first { $0["ID"] == newID })
        #expect(newID != hot.id)
        for column in ["Kind", "InMsec", "OutMsec", "Comment", "Color", "ColorTableIndex", "ActiveLoop", "BeatLoopSize"] {
            #expect(after[column] == before[column], "\(column)")
        }
    }

    @Test func 색이_없는_새_큐는_지금처럼_기본_색이다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .hot(0), time: 3))
        _ = try write(fixture, drafts: [draft])
        let row = try #require(cueRows(fixture, track).first)
        #expect(row["Color"] == "-1" && row["ColorTableIndex"] == "NULL")
    }

    @Test func 메모리_큐_색은_핫큐로_되살리지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        var cue = EditableCue(kind: .hot(0), time: 3)
        cue.color = EditableCue.ColorMark(color: 16711680, tableIndex: 3, memory: true)
        draft.place(cue)
        _ = try write(fixture, drafts: [draft])
        let row = try #require(cueRows(fixture, track).first)
        #expect(row["Color"] == "-1" && row["ColorTableIndex"] == "NULL")
    }

    @Test func 전부_아니면_전무면_한_곡이_막혀도_아무것도_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        var first = TrackSpec(id: "1"), second = TrackSpec(id: "2")
        first.cues = [CueSpec(kind: 0, inMsec: 10000)]
        second.cues = [CueSpec(kind: 0, inMsec: 10000)]
        try fixture.add(tracks: [first, second])
        let snapshot = { try fixture.rows("SELECT * FROM djmdCue ORDER BY ID") + fixture.rows("SELECT * FROM contentCue ORDER BY ID")
            + fixture.rows("SELECT * FROM djmdContent ORDER BY ID") + fixture.rows("SELECT * FROM agentRegistry") }
        let original = try snapshot()
        var good = CueDraft(trackUUID: first.uuid, rekordboxCues: first.rekordboxCues)
        good.place(EditableCue(kind: .memory, time: 50))
        var stale = CueDraft(trackUUID: second.uuid, rekordboxCues: second.rekordboxCues)
        stale.base[0].time = 11   // 역편집을 만든 뒤 rekordbox에서 바뀐 것처럼
        stale.place(EditableCue(kind: .memory, time: 60))

        let report = try write(fixture, drafts: [good, stale], allOrNothing: true)
        #expect(report.written.isEmpty)
        #expect(report.blocked.count == 2)
        #expect(try snapshot() == original)
        // 쓰지 않았으니 보고서의 카운터도 지금 카운터와 같다
        #expect(report.finalUpdateCount == (try fixture.localUpdateCount()))
        // 막히지 않은 곡의 이유는 함께 쓰지 않았다는 것
        #expect(report.blocked.first { $0.trackUUID == first.uuid }?.reason?.isEmpty == false)

        // 보통 쓰기는 막힌 곡만 빼고 쓴다(지금 동작)
        let partial = try write(fixture, drafts: [good, stale])
        #expect(partial.written.map(\.trackUUID) == [first.uuid] && partial.blocked.map(\.trackUUID) == [second.uuid])
    }

    @Test func 게인_base가_지금_rekordbox_값과_같으면_쓰고_다르면_막는다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        let original = RekordboxAutoGain.halves(Float(pow(10, -2.5 / 20)))
        track.gain = (original.high, original.low)
        try fixture.add(track)
        let gainRow = { try #require(fixture.rows("SELECT GainHigh, GainLow FROM djmdMixerParam WHERE ContentID = ?", [.text(track.id)]).first) }
        let untouched = try gainRow()

        let stale = try write(fixture, gains: [track.uuid: 1.0], gainBases: [track.uuid: -4.0])
        #expect(stale.gainWritten.isEmpty && stale.gainBlocked.first?.reason?.contains("바뀌었습니다") == true)
        #expect(try gainRow() == untouched)

        let written = try write(fixture, gains: [track.uuid: 1.0], gainBases: [track.uuid: -2.5])
        #expect(written.gainWritten.count == 1)
        let expected = RekordboxAutoGain.halves(Float(pow(10, 1.0 / 20)))
        #expect(try gainRow() == ["GainHigh": String(expected.high), "GainLow": String(expected.low)])
    }
}
