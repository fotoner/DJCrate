@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 저장 뒤 ⌘Z(R12, #405)의 덱 몫: 덱 편집 → 자동 저장 → ⌘Z → 자동 저장 → DB 값이 편집 전과 같다(큐 ID 제외).
/// 자동 저장은 엔진이 고르는 길(`autoInventory` → `chunk` → `autoWrite`)로 실제 관문이 합성 사본에 쓴다. 덱은 쓴 뒤 다시 읽어도 ⌘Z를 잃지 않고,
/// 쓰기가 돌려준 새 큐 ID로 같은 큐를 찾는다. 실제 관문은 사용자 폴더를 쓰지 않아도 `DJC_HOME`이 있을 때만 돈다(다른 실제 관문 시험과 같다).
@MainActor
@Suite("덱 저장 뒤 ⌘Z", .serialized, .enabled(if: LiveDraftHome.isIsolated))
struct DeckUndoAfterSaveTests {
    @MainActor
    final class Rig {
        let fixture: RekordboxFixture
        let track: TrackSpec
        let store: LibraryStore
        let deck: DeckModel
        let undo = UndoManager()

        /// - Parameter beats: 주면 그 박의 분석 파일(DAT·EXT)을 두고 덱이 실제 분석 파일에서 그리드를 읽는다
        init(_ track: TrackSpec, beats: [BeatGridTags.Beat]? = nil) async throws {
            fixture = try RekordboxFixture()
            var track = track
            if beats != nil {
                track.fileType = 11
                track.length = 60
                track.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio).path
                track.analysisDataPath = "/PIONEER/USBANLZ/undo/ANLZ0000.DAT"
            }
            self.track = track
            try fixture.add(track)
            if let beats { try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats)) }
            let fixture = fixture, database = fixture.database
            store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("deck-undo"), persist: false),
                                      activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }),
                                      backupDirectory: fixture.backups, playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in },
                                      playlistImportURL: nil, stagingSaver: { _ in }, draftHome: fixture.root.appending(path: "drafts"),
                                      rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                      arguments: ["test"], environment: [:], takeLiveSnapshot: { _ in database },
                                      draftOrigin: .human)
            await store.load(snapshot: fixture.database)
            let storage = DeckStorage.memory(store.testDrafts)
            // 그리드는 실제 분석 파일에서 읽는다(쓰기 대상 share)
            deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, reader: beats == nil ? .memory(storage) : nil, runsAnalysis: false)
            let share = fixture.shareRoot
            deck.shareRoot = { share }
            // 앱 조립 지점(`AppComposition`)과 같은 연결: 덱 초안 변경을 저장 대기에, 쓰기 잠금·쓴 뒤 갱신을 덱에
            deck.onCueDraftChange = { [weak store] draft in store?.cueDraftChanged(draft) }
            deck.onDraftChange = { [weak store] uuid, kind, exists in store?.draftChanged(trackUUID: uuid, kind: kind, exists: exists) }
            store.connectWriteLocks(to: deck)
            deck.undoManager = undo
            store.undoManager = undo
            deck.load(store.rowsByUUID[track.uuid])
            #expect(await waitForState(until: { self.deck.draft != nil && (beats == nil || self.deck.gridDraft != nil) }), "덱이 곡을 읽지 못함")
        }

        /// 엔진이 고르는 길로 저장 대기를 자동으로 쓴다. 쓴 뒤 다시 읽고 덱이 새 값을 적용할 때까지 기다린다
        func autoSave() async throws {
            let session = store.session
            let inventory = await session.autoInventory(cancelled: [], needsConfirmation: [])
            let chunk = try #require(inventory.chunk(rowLimit: 200), "자동으로 쓸 편집이 없다: \(inventory)")
            guard case let .written(report, unwritten) = await session.autoWrite(chunk) else {
                Issue.record("자동 저장이 쓰지 못했다")
                return
            }
            #expect(unwritten.isEmpty && report.blocked.isEmpty && report.gainBlocked.isEmpty)
            #expect(await waitForState(until: { !self.deck.isEditLocked && self.store.writtenAwaitingReload.isEmpty }), "덱이 쓴 값을 적용하지 못함")
        }

        func cueRows() throws -> [[String: String]] {
            try fixture.rows("SELECT * FROM djmdCue WHERE ContentID = ? ORDER BY InMsec, Kind", [.text(track.id)])
        }

        /// 큐 행에서 ID·UUID·기록 시각을 뺀 칸(편집 전과 견준다)
        func cueValues() throws -> [[String: String]] {
            try cueRows().map { $0.filter { !["ID", "UUID", "created_at", "updated_at", "rb_local_usn", "usn"].contains($0.key) } }
        }

        /// 분석 파일의 박(ms·박 번호·BPM×100)
        func beats() throws -> [[Int]] {
            try BeatGrid.load(anlz: fixture.analysisURL(for: track)).beats.map { [Int(($0.time * 1000).rounded()), $0.number, Int(($0.bpm * 100).rounded())] }
        }

        func gainDB() throws -> Double {
            let row = try #require(fixture.rows("SELECT GainHigh, GainLow FROM djmdMixerParam WHERE ContentID = ?", [.text(track.id)]).first)
            return RekordboxAutoGain(gain: Double(RekordboxAutoGain.float(high: Int(row["GainHigh"]!)!, low: Int(row["GainLow"]!)!)), peak: 0).gainDB
        }
    }

    static func coloredHot() -> CueSpec {
        var hot = CueSpec(kind: 1, inMsec: 20000)
        hot.color = 16711680; hot.colorTableIndex = 3; hot.comment = "드롭"
        return hot
    }

    @Test func 옮긴_큐는_자동_저장과_다시_읽기가_끝나도_되돌리고_다시_저장하면_편집_전과_같다() async throws {
        var track = TrackSpec()
        track.cues = [CueSpec(kind: 0, inMsec: 10000), Self.coloredHot()]
        let rig = try await Rig(track)
        let original = try rig.cueValues()
        let hot = try #require(rig.deck.draft?.cues.first { $0.kind == .hot(0) })
        rig.deck.mutate(name: "큐 옮기기") { var moved = hot; moved.time = 25; $0.place(moved) }
        try await rig.autoSave()
        #expect(try rig.cueRows().contains { $0["InMsec"] == "25000" })

        #expect(rig.undo.canUndo, "쓴 뒤 다시 읽어도 ⌘Z가 남는다")
        rig.undo.undo()
        #expect(rig.deck.draft?.hasChanges == true && rig.deck.draft?.cues.first { $0.id == hot.id }?.time == 20)
        try await rig.autoSave()
        #expect(try rig.cueValues() == original)
        // 건드리지 않은 메모리 큐는 원래 ID 그대로다
        #expect(try rig.cueRows().contains { $0["ID"] == track.cues[0].id })
    }

    @Test func 지운_큐를_되살리면_ID만_새로_받고_위치_종류_이름_색은_지우기_전과_같다() async throws {
        var track = TrackSpec()
        track.cues = [CueSpec(kind: 0, inMsec: 10000), Self.coloredHot()]
        let rig = try await Rig(track)
        let original = try rig.cueValues()
        let hot = try #require(rig.deck.draft?.cues.first { $0.kind == .hot(0) })
        rig.deck.mutate(name: "큐 지우기") { $0.remove(hot.id) }
        try await rig.autoSave()
        #expect(try rig.cueRows().count == 1)

        rig.undo.undo()
        try await rig.autoSave()
        #expect(try rig.cueValues() == original)
        #expect(try !rig.cueRows().contains { $0["ID"] == track.cues[1].id })
    }

    @Test func 같은_시각의_메모리_큐와_메모리_루프_가운데_옮긴_루프만_되돌아간다() async throws {
        var track = TrackSpec()
        var loop = CueSpec(kind: 0, inMsec: 8000)
        loop.outMsec = 12000; loop.activeLoop = 0; loop.color = 255; loop.colorTableIndex = 0
        loop.beatLoopSize = 524289; loop.cueMicrosec = 0; loop.comment = ""
        track.cues = [CueSpec(kind: 0, inMsec: 8000), loop]
        let rig = try await Rig(track)
        let original = try rig.cueValues()
        let memoryLoop = try #require(rig.deck.draft?.cues.first { $0.loop != nil })
        rig.deck.mutate(name: "루프 옮기기") {
            var moved = memoryLoop
            moved.time = 9
            moved.loop?.end = 13
            $0.place(moved)
        }
        try await rig.autoSave()
        rig.undo.undo()
        try await rig.autoSave()
        #expect(try rig.cueValues() == original)
        // 메모리 큐는 건드리지 않아 ID가 그대로다(하나만 되돌아간다)
        #expect(try rig.cueRows().contains { $0["ID"] == track.cues[0].id })
    }

    /// 그리드를 옮기면 따라 옮긴 큐도 함께 되돌린다
    @Test func 그리드와_따라_옮긴_큐는_자동_저장_뒤_되돌리고_다시_저장하면_편집_전과_같다() async throws {
        var track = TrackSpec()
        track.cues = [CueSpec(kind: 0, inMsec: 2000)]
        let rig = try await Rig(track, beats: AnlzBuilder.beats(bpm: 120, first: 200, count: 120))
        let originalBeats = try rig.beats(), originalCues = try rig.cueValues()
        rig.deck.carryCues = true
        rig.deck.shiftGrid(ms: 10)
        #expect(rig.deck.gridDraft?.hasChanges == true && rig.deck.draft?.hasChanges == true)
        try await rig.autoSave()
        #expect(try rig.beats() != originalBeats && rig.cueValues() != originalCues)

        #expect(rig.undo.canUndo)
        rig.undo.undo()
        #expect(rig.deck.gridDraft?.hasChanges == true && rig.deck.draft?.hasChanges == true)
        try await rig.autoSave()
        #expect(try rig.beats() == originalBeats)
        #expect(try rig.cueValues() == originalCues)
    }

    @Test func 게인은_자동_저장_뒤_되돌리고_다시_저장하면_편집_전_값이다() async throws {
        var track = TrackSpec()
        let original = RekordboxAutoGain.halves(Float(pow(10, -6.0 / 20)))
        track.gain = (original.high, original.low)
        let rig = try await Rig(track)
        let before = try rig.gainDB()
        rig.deck.setTrackGain(-2)
        try await rig.autoSave()
        #expect(abs(try rig.gainDB() - -2) < 0.001)

        #expect(rig.undo.canUndo)
        rig.undo.undo()
        try await rig.autoSave()
        #expect(abs(try rig.gainDB() - before) < 0.000_001)
        let row = try #require(rig.fixture.rows("SELECT GainHigh, GainLow FROM djmdMixerParam WHERE ContentID = ?", [.text(track.id)]).first)
        #expect(row["GainHigh"] == String(original.high) && row["GainLow"] == String(original.low))
    }
}
