import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// rekordbox 7.2.18에서 직접 편집해 확인한 쓰기 모양을 고정한다(docs/rekordbox-internals.md).
/// 구조만 있는 합성 DB(실데이터 없음)에 쓰고 칸마다 비교한다. ID·UUID는 무작위라 비교하지 않는다.
@Suite("rekordbox 쓰기 — 실험으로 확인한 모양")
struct RekordboxWriterGoldenTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let stamp = "2026-09-25 12:00:00.000 +00:00"
    let jsonStamp = "2026-09-25T12:00:00.000+00:00"

    func write(_ fixture: RekordboxFixture, drafts: [CueDraft] = [], grids: [GridDraft] = [], gains: [String: Double] = [:])
        throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, to: fixture.database, dryRun: false, now: now,
                                  backups: fixture.backups, shareRoot: fixture.shareRoot)
    }

    func newCueRow(_ fixture: RekordboxFixture, track: TrackSpec, except ids: Set<String>) throws -> [String: String] {
        let rows = try fixture.rows("SELECT * FROM djmdCue WHERE ContentID = ?", [.text(track.id)]).filter { !ids.contains($0["ID"]!) }
        try #require(rows.count == 1)
        return rows[0]
    }

    // MARK: 큐

    @Test func 메모리_큐를_더하면_rekordbox_7이_새로_찍은_큐와_같은_모양() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 1000)
        var track = TrackSpec()
        track.cues = [.autoCue(at: 1024)]
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        draft.place(EditableCue(kind: .memory, time: 20.123))

        let report = try write(fixture, drafts: [draft])
        #expect(report.written.count == 1 && report.written[0].added == 1 && report.written[0].removed == 0)

        let row = try newCueRow(fixture, track: track, except: [track.cues[0].id])
        let expected: [String: String] = [
            "InMsec": "20123", "InFrame": "3018", "InMpegFrame": "0", "InMpegAbs": "0",
            "OutMsec": "-1", "OutFrame": "0", "OutMpegFrame": "0", "OutMpegAbs": "0",
            "Kind": "0", "Color": "-1", "ColorTableIndex": "NULL", "ActiveLoop": "NULL", "Comment": "NULL",
            "BeatLoopSize": "NULL", "CueMicrosec": "NULL", "InPointSeekInfo": "NULL", "OutPointSeekInfo": "NULL",
            "ContentUUID": track.uuid, "rb_data_status": "0", "rb_local_data_status": "0", "rb_local_deleted": "0",
            "rb_local_synced": "0", "usn": "NULL", "rb_local_usn": "NULL", "created_at": stamp, "updated_at": stamp,
        ]
        for (key, value) in expected { #expect(row[key] == value, "\(key)") }

        // contentCue 먼저(1001), djmdContent 다음(1002), 카운터는 마지막 값
        let record = try #require(fixture.rows("SELECT * FROM contentCue WHERE ContentID = ?", [.text(track.id)]).first)
        #expect(record["rb_local_usn"] == "1001" && record["rb_data_status"] == "257" && record["rb_cue_count"] == "2")
        let content = try #require(fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(track.id)]).first)
        #expect(content["rb_local_usn"] == "1002" && content["rb_data_status"] == "257" && content["CueUpdated"] == "2")
        #expect(try fixture.localUpdateCount() == 1002)

        // JSON: 원래 객체는 그대로, 새 객체는 끝에 rekordbox 칸 순서로(NULL 칸 없음)
        let objects = try CueJSON.parse(record["Cues"]!)
        #expect(objects.count == 2)
        #expect(objects[1].fields.map(\.key) == ["ID", "ContentID", "ContentUUID", "InMsec", "InFrame", "InMpegFrame", "InMpegAbs",
                                                   "OutMsec", "OutFrame", "OutMpegFrame", "OutMpegAbs", "Kind", "Color",
                                                   "UUID", "created_at", "updated_at"])
        #expect(objects[1]["created_at"] == .string(jsonStamp))
        #expect(report.backup != nil)
    }

    @Test func 루프_핫큐는_ときめき分類学_실험과_같은_모양() throws {
        // 2026-09-26 실험: 9038~13038ms 8박 루프 핫큐 A(MP3 CBR)
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.cues = [.autoCue(at: 1038)]
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        var loop = EditableCue(kind: .hot(0), time: 9.038)
        loop.loop = EditableCue.Loop(end: 13.038, active: false, beats: 8)
        draft.place(loop)

        _ = try write(fixture, drafts: [draft])
        let row = try newCueRow(fixture, track: track, except: [track.cues[0].id])
        let expected: [String: String] = [
            "InMsec": "9038", "InFrame": "1355", "OutMsec": "13038", "OutFrame": "1955", "Kind": "1",
            "Color": "255", "ColorTableIndex": "0", "ActiveLoop": "0", "Comment": "", "BeatLoopSize": "524289",
            "CueMicrosec": "0", "InPointSeekInfo": "NULL", "OutPointSeekInfo": "NULL",
        ]
        for (key, value) in expected { #expect(row[key] == value, "\(key)") }
        let json = try #require(fixture.rows("SELECT Cues FROM contentCue WHERE ContentID = ?", [.text(track.id)]).first?["Cues"])
        let object = try CueJSON.parse(json)[1]
        #expect(object.fields.map(\.key).contains("Comment") == false, "빈 코멘트는 JSON에 적지 않는다")
        #expect(object["ActiveLoop"] == .int(0) && object["BeatLoopSize"] == .int(524289) && object["CueMicrosec"] == .int(0))
    }

    @Test func 활성_루프는_ActiveLoop_1() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        var loop = EditableCue(kind: .hot(0), time: 1.024)
        loop.loop = EditableCue.Loop(end: 5.028, active: true, beats: 8)
        draft.place(loop)
        _ = try write(fixture, drafts: [draft])
        let row = try newCueRow(fixture, track: track, except: [])
        #expect(row["ActiveLoop"] == "1" && row["OutFrame"] == "754" && row["BeatLoopSize"] == "524289")
    }

    @Test func 반_박_루프의_BeatLoopSize() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        var loop = EditableCue(kind: .memory, time: 30)
        loop.loop = EditableCue.Loop(end: 30.25, active: false, beats: 0.5)
        draft.place(loop)
        _ = try write(fixture, drafts: [draft])
        #expect(try newCueRow(fixture, track: track, except: [])["BeatLoopSize"] == "65538")
    }

    @Test func 옮긴_큐는_지우고_새로_넣고_지정한_색을_이어받는다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        var hot = CueSpec(kind: 1, inMsec: 5000)
        hot.color = 16711680; hot.colorTableIndex = 3   // 사용자가 고른 색
        track.cues = [hot]
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        var moved = draft.cues[0]
        moved.time = 6.0
        draft.place(moved)

        let report = try write(fixture, drafts: [draft])
        #expect(report.written.first?.removed == 1 && report.written.first?.added == 1)
        let rows = try fixture.rows("SELECT * FROM djmdCue WHERE ContentID = ?", [.text(track.id)])
        #expect(rows.count == 1 && rows[0]["ID"] != hot.id)
        #expect(rows[0]["InMsec"] == "6000" && rows[0]["Color"] == "16711680" && rows[0]["ColorTableIndex"] == "3")
    }

    /// #73: 그리드를 따라 큐가 1ms 미만 움직인 초안. `CueDraft.changes`는 그 큐를 바꾸지 않은 것으로 보는데
    /// 검증이 초안 시각을 반올림해 비교하면(89.065984 → 89066ms, rekordbox 89065ms) 반영 묶음 전체가 중단됐다.
    @Test func 큐가_1ms_미만_움직였으면_rekordbox_값을_그대로_두고_쓴다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        var loop = CueSpec(kind: 2, inMsec: 120_000)
        loop.outMsec = 128_000; loop.activeLoop = 0; loop.beatLoopSize = 8 << 16 | 1; loop.color = 255; loop.colorTableIndex = 0
        track.cues = [CueSpec(kind: 0, inMsec: 46603), CueSpec(kind: 0, inMsec: 89065), CueSpec(kind: 1, inMsec: 177_681), loop]
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        let drift = [46603: 0.001155, 89065: 0.000984, 177_681: 0.000627, 120_000: 0.0004]   // 따라가기로 움직인 만큼
        draft.cues = draft.cues.map { cue in
            var cue = cue
            cue.time += drift[Int((cue.time * 1000).rounded())] ?? 0
            cue.loop?.end += 0.0006   // 128.0006 → 128001ms
            return cue
        }
        #expect(draft.changes.count == 1)   // 1ms 넘게 움직인 46.603만

        let report = try write(fixture, drafts: [draft])
        #expect(report.written.count == 1 && report.written[0].removed == 1 && report.written[0].added == 1)
        let rows = try fixture.rows("SELECT ID, InMsec, OutMsec FROM djmdCue WHERE ContentID = ?", [.text(track.id)])
        let kept = Set(track.cues.dropFirst().map(\.id))
        #expect(Set(rows.filter { kept.contains($0["ID"]!) }.map { "\($0["InMsec"]!)/\($0["OutMsec"]!)" })
            == ["89065/-1", "177681/-1", "120000/128000"])
        #expect(rows.filter { !kept.contains($0["ID"]!) }.map { $0["InMsec"] } == ["46604"])
    }

    @Test func 옛_JSON의_칸_순서는_건드리지_않는다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.legacyJSON = true
        track.cues = [.autoCue(at: 1000), CueSpec(kind: 0, inMsec: 30000)]
        try fixture.add(track)
        let before = try CueJSON.parse(try #require(fixture.rows("SELECT Cues FROM contentCue").first?["Cues"]))
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        draft.place(EditableCue(kind: .hot(2), time: 50))
        _ = try write(fixture, drafts: [draft])
        let after = try CueJSON.parse(try #require(fixture.rows("SELECT Cues FROM contentCue").first?["Cues"]))
        #expect(CueJSON.serialize(Array(after.prefix(2))) == CueJSON.serialize(before))
    }

    // MARK: 자동 큐 (#145)

    /// rekordbox가 분석 때 넣는 자동 큐 2개(CUE(Auto)·1.1Bars: Kind 0, Color 255, ColorTableIndex 0, ActiveLoop·BeatLoopSize·CueMicrosec 0)와
    /// 직접 찍은 메모리 큐 하나인 곡. 자동 큐는 전용 쓰기 규칙 없이 메모리 큐로 다룬다.
    func autoCueTrack() -> TrackSpec {
        var track = TrackSpec()
        var named = CueSpec.autoCue(at: 350)
        named.comment = "CUE(Auto)"
        track.cues = [named, .autoCue(at: 7_850), CueSpec(kind: 0, inMsec: 30_000)]
        return track
    }

    func cueRows(_ fixture: RekordboxFixture, _ track: TrackSpec, ids: Set<String>) throws -> [[String: String]] {
        try fixture.rows("SELECT * FROM djmdCue WHERE ContentID = ? ORDER BY ID", [.text(track.id)]).filter { ids.contains($0["ID"]!) }
    }

    func cueObjects(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> [CueJSON.Object] {
        try CueJSON.parse(try #require(fixture.rows("SELECT Cues FROM contentCue WHERE ContentID = ?", [.text(track.id)]).first?["Cues"]))
    }

    @Test func 건드리지_않은_자동_큐는_행과_JSON이_바이트_그대로다() throws {
        let fixture = try RekordboxFixture()
        let track = autoCueTrack()
        try fixture.add(track)
        let autoIDs = Set(track.cues.prefix(2).map(\.id))
        let rows = try cueRows(fixture, track, ids: autoIDs)
        let json = CueJSON.serialize(try cueObjects(fixture, track).prefix(2).map { $0 })
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        #expect(draft.cues.filter(\.isAutoGenerated).count == 2 && !draft.hasChanges)
        draft.move(try #require(draft.cues.first { $0.sourceID == track.cues[2].id }).id, to: 31)
        draft.place(EditableCue(kind: .memory, time: 60))

        let report = try write(fixture, drafts: [draft])
        #expect(report.written.count == 1 && report.written[0].removed == 1 && report.written[0].added == 2)
        #expect(try cueRows(fixture, track, ids: autoIDs) == rows)
        #expect(CueJSON.serialize(try cueObjects(fixture, track).prefix(2).map { $0 }) == json)
    }

    /// 고친 자동 큐는 같은 칸 값(Color 255·ColorTableIndex 0 …)을 가진 직접 찍은 큐를 옮길 때와 칸까지 같게 쓴다(Comment는 비움).
    /// rekordbox에서 자동 큐를 옮겼을 때와 같은지는 아직 실험하지 않았다.
    @Test func 고친_자동_큐는_같은_칸의_직접_찍은_큐를_옮길_때와_같게_쓴다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 1000)
        var auto = TrackSpec()
        auto.cues = [.autoCue(at: 7_850)]
        var manual = TrackSpec()
        var same = CueSpec.autoCue(at: 7_850)
        same.comment = ""
        manual.cues = [same]
        try fixture.add(auto)
        try fixture.add(manual)
        let drafts = [auto, manual].map { track in
            var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
            draft.move(draft.cues[0].id, to: 9.2)
            return draft
        }
        #expect(drafts[0].cues[0].name.isEmpty && drafts[0].cues[0].sourceID == auto.cues[0].id)

        let report = try write(fixture, drafts: drafts)
        #expect(report.written.count == 2 && report.written.allSatisfy { $0.removed == 1 && $0.added == 1 })
        let ids: Set = ["ID", "ContentID", "ContentUUID", "UUID"]
        let written = try [auto, manual].map { try newCueRow(fixture, track: $0, except: [$0.cues[0].id]).filter { !ids.contains($0.key) } }
        #expect(written[0] == written[1])
        #expect(written[0]["InMsec"] == "9200" && written[0]["Comment"] == "NULL" && written[0]["Color"] == "-1"
            && written[0]["ColorTableIndex"] == "NULL" && written[0]["ActiveLoop"] == "NULL")
        let objects = try [auto, manual].map { try #require(cueObjects(fixture, $0).first).fields.filter { !ids.contains($0.key) } }
        #expect(objects[0].map(\.key) == objects[1].map(\.key) && objects[0].map(\.value) == objects[1].map(\.value))
    }

    @Test func 자동_큐를_지우면_그_행만_지운다() throws {
        let fixture = try RekordboxFixture()
        let track = autoCueTrack()
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        draft.remove(try #require(draft.cues.first { $0.name == "CUE(Auto)" }).id)
        let report = try write(fixture, drafts: [draft])
        #expect(report.written.first?.removed == 1 && report.written.first?.added == 0)
        let ids = try fixture.rows("SELECT ID FROM djmdCue WHERE ContentID = ?", [.text(track.id)]).compactMap { $0["ID"] }
        #expect(Set(ids) == Set(track.cues.dropFirst().map(\.id)))
    }

    /// #145 이전 초안은 자동 큐를 빼고 base를 만들었다. 막지 않고 자동 큐 행을 그대로 두며, 한도는 자동 큐까지 센다(예전과 같은 결과).
    @Test func 자동_큐_없이_만든_옛_초안도_쓰고_자동_큐를_남긴다() throws {
        let fixture = try RekordboxFixture()
        let track = autoCueTrack()
        try fixture.add(track)
        let manual = track.rekordboxCues.filter { !$0.isAutoGenerated }
        var old = CueDraft(trackUUID: track.uuid, rekordboxCues: manual)
        old.place(EditableCue(kind: .memory, time: 60))
        let report = try write(fixture, drafts: [old])
        #expect(report.written.count == 1 && report.blocked.isEmpty && report.written[0].added == 1)
        let ids = Set(try fixture.rows("SELECT ID FROM djmdCue WHERE ContentID = ?", [.text(track.id)]).compactMap { $0["ID"] })
        #expect(ids.count == 4 && ids.isSuperset(of: track.cues.map(\.id)))

        // 자동 큐 2 + 메모리 1 + 새로 찍은 8 = 11
        let other = try RekordboxFixture()
        try other.add(track)
        var full = CueDraft(trackUUID: track.uuid, rekordboxCues: manual)
        for i in 0..<8 { full.place(EditableCue(kind: .memory, time: 40 + Double(i) * 5)) }
        #expect(try blockedReason(other, full)?.contains("11개") == true)
    }

    // MARK: 막는 경우

    func blockedReason(_ fixture: RekordboxFixture, _ draft: CueDraft) throws -> String? {
        let report = try write(fixture, drafts: [draft])
        return report.blocked.first?.reason
    }

    @Test func 파일은_CBR인데_비트레이트가_0이면_막는다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.bitRate = 0
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 10))
        #expect(try blockedReason(fixture, draft)?.contains("VBR") == true)
        #expect(try fixture.rows("SELECT * FROM djmdCue").isEmpty)
    }

    @Test func 분석_전_곡은_비트레이트가_0이어도_CBR이면_큐를_쓴다() throws {
        // rekordbox는 분석 전 곡을 BitRate 0으로 넣는다(2026-09-26 분석 전 추가 실험). VBR 표시가 아니다.
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.bitRate = 0
        track.analysed = 0
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 0.5))
        let report = try write(fixture, drafts: [draft])
        #expect(report.blocked.isEmpty && report.written.first?.added == 1)
        #expect(try newCueRow(fixture, track: track, except: [])["InMpegFrame"] == "0")
    }

    @Test func VBR_MP3는_큐마다_MPEG_칸을_적는다() throws {
        // rekordbox 7.2.18은 Xing 머리가 있는 VBR 파일을 BitRate 32로 적기도 한다
        // (2026-09-26 凸凹スピードスター 추가 실험, 라이브러리의 BitRate 32 곡은 모두 Xing VBR이고 큐에 MPEG 위치가 있다).
        // MPEG 칸 규칙은 라이브러리 VBR 큐 1,118개·루프 끝 6개와 전수 일치(`djc lab seekinfo-check`).
        let fixture = try RekordboxFixture()
        var vbr = TrackSpec()
        vbr.bitRate = 32
        let url = try TestResources.url("mp3-lame-vbr.mp3")
        vbr.folderPath = url.path
        try fixture.add(vbr)
        var draft = CueDraft(trackUUID: vbr.uuid)
        draft.place(EditableCue(kind: .memory, time: 0.5))
        var loop = EditableCue(kind: .hot(1), time: 0.3)
        loop.loop = EditableCue.Loop(end: 0.7, active: false, beats: 0)
        draft.place(loop)
        let report = try write(fixture, drafts: [draft])
        #expect(report.blocked.isEmpty && report.written.first?.added == 2)
        // LAME 정보 프레임도 센다. 칸 = InFrame/2(1/75초) → ms 올림 → MPEG 프레임(버림) − 8 → 첫 프레임 기준 바이트 위치
        let offsets = try #require(SeekInfo.mp3Frames(url: url)).offsets
        func expected(_ msec: Int) -> (Int, Int) {
            let mpegFrame = msec * 150 / 1000 / 2
            let ms = Int((Double(mpegFrame) * 1000 / 75).rounded(.up))
            return (mpegFrame, offsets[max(0, ms * 44_100 / 1000 / 1152 - 8)] - offsets[0])
        }
        let rows = try fixture.rows("SELECT * FROM djmdCue WHERE ContentID = ? ORDER BY InMsec", [.text(vbr.id)])
        #expect(rows.count == 2)
        let (loopIn, loopOut, memory) = (expected(300), expected(700), expected(500))
        #expect(rows[0]["InMpegFrame"] == "\(loopIn.0)" && rows[0]["InMpegAbs"] == "\(loopIn.1)")
        #expect(rows[0]["OutMpegFrame"] == "\(loopOut.0)" && rows[0]["OutMpegAbs"] == "\(loopOut.1)")
        #expect(rows[1]["InMpegFrame"] == "\(memory.0)" && rows[1]["InMpegAbs"] == "\(memory.1)" && memory.1 > 0)
        #expect(rows[1]["OutMpegFrame"] == "0" && rows[1]["OutMpegAbs"] == "0", "루프가 아니면 끝은 0")
        #expect(rows.allSatisfy { $0["InPointSeekInfo"] == "NULL" })
        // JSON에도 같은 값(쓰기 검증이 행과 JSON을 칸마다 비교한다)
        let json = try #require(try fixture.rows("SELECT Cues FROM contentCue").first?["Cues"])
        #expect(json.contains("\"InMpegAbs\":\(memory.1)"))
    }

    @Test func 음원_파일이_없으면_VBR인지_몰라_막는다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.folderPath = "/tmp/djc-없는-파일.mp3"
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 0.5))
        #expect(try blockedReason(fixture, draft)?.contains("음원 파일") == true)
    }

    @Test func 초안을_만든_뒤_rekordbox에서_바뀐_곡은_막는다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.cues = [CueSpec(kind: 0, inMsec: 10000)]
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        draft.base[0].time = 11   // rekordbox 쪽이 달라진 것처럼
        draft.place(EditableCue(kind: .memory, time: 30))
        #expect(try blockedReason(fixture, draft)?.contains("바뀌었습니다") == true)
    }

    @Test func 메모리_큐는_곡당_10개까지() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.cues = (0..<10).map { CueSpec(kind: 0, inMsec: 10_000 + $0 * 5000) }
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        draft.place(EditableCue(kind: .memory, time: 150))
        #expect(try blockedReason(fixture, draft)?.contains("10개") == true)
    }

    @Test func 활성_루프는_곡당_하나() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        var active = CueSpec(kind: 1, inMsec: 10000)
        active.outMsec = 14000; active.activeLoop = 1; active.color = 255; active.colorTableIndex = 0
        active.beatLoopSize = 524289; active.cueMicrosec = 0; active.comment = ""
        track.cues = [active]
        try fixture.add(track)
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        var second = EditableCue(kind: .hot(1), time: 40)
        second.loop = EditableCue.Loop(end: 44, active: true, beats: 8)
        draft.place(second)
        #expect(try blockedReason(fixture, draft)?.contains("활성 루프") == true)
    }

    @Test func 곡_길이를_넘는_큐는_막는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 500))   // 곡은 200초
        #expect(try blockedReason(fixture, draft)?.contains("곡 길이") == true)
    }

    // MARK: 게인·되돌리기

    @Test func 오토게인은_삭제되지_않은_행의_두_칸만_바꾼다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 500)
        var track = TrackSpec()
        let original = RekordboxAutoGain.halves(1.0)
        track.gain = (original.high, original.low)
        try fixture.add(track)
        let report = try write(fixture, gains: [track.uuid: -3.0])
        #expect(report.gainWritten.count == 1)
        let row = try #require(fixture.rows("SELECT * FROM djmdMixerParam WHERE ContentID = ?", [.text(track.id)]).first)
        let expected = RekordboxAutoGain.halves(Float(pow(10, -3.0 / 20)))
        #expect(row["GainHigh"] == String(expected.high) && row["GainLow"] == String(expected.low))
        #expect(row["PeakHigh"] == "16256" && row["rb_data_status"] == "257" && row["rb_local_usn"] == "501")
        #expect(row["updated_at"] == stamp)
    }

    @Test func 되돌리면_쓰기_전과_칸까지_같다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.cues = [.autoCue(at: 1024), CueSpec(kind: 1, inMsec: 8000)]
        try fixture.add(track)
        let snapshot = { try fixture.rows("SELECT * FROM djmdCue ORDER BY ID") + fixture.rows("SELECT * FROM contentCue")
            + fixture.rows("SELECT * FROM djmdContent") + fixture.rows("SELECT * FROM agentRegistry") }
        let before = try snapshot()
        var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        draft.remove(try #require(draft.cues.first { $0.kind == .hot(0) }).id)
        draft.place(EditableCue(kind: .memory, time: 60))
        let report = try write(fixture, drafts: [draft])
        #expect(try snapshot() != before)
        _ = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try snapshot() == before)
    }
}
