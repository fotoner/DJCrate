@testable import DJCrate
import DJCAdapters
@testable import DJCApplication
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

/// #172: 곡 넣기·빼기의 백업은 저장소에 준 폴더로 가고, 초안 파일을 바꾸는 경로는 모두 `DraftWriter`를 거친다.
/// 초안·반영 묶음은 저장소마다 준 초안 폴더에 쓴다. 앱 기본 자리(백업 폴더)를 보는 시험만 `DJC_HOME`이 있을 때 돈다(사용자 폴더를 지키려고).
/// 넣기로 옮긴 초안을 되돌릴 때 지울지의 판정은 DJCApplicationTests `AddedTrackDraftsTests`(순수)가 보고, 여기에는 합성 DB에 실제로 넣고
/// 되돌리는 왕복(판정에 넣는 값·결과 적용, 백업 폴더·DraftWriter 기록·다시 읽기 실패·백업 저장 실패)만 남긴다.
@MainActor
@Suite("곡 넣기·빼기와 초안 정리 경로", .serialized)
struct TrackWritePathTests {
    /// 시험마다 새 저장 큐. 저장소와 시험이 같은 큐(저장 대기·실패 기록)를 본다.
    let writer = DraftWriter()
    /// 켜면 스냅샷 뜨기가 실패한다(쓴 뒤 다시 읽기 실패를 만든다)
    let snapshotFails = TestSwitch()

    /// - Parameter saveTagDrafts: 태그 초안 저장(기본은 메모리만). 다시 읽기가 디스크의 태그 초안을 읽으므로 앱처럼 저장해야 하는 시험만
    ///   nil을 줘 저장소의 초안 폴더에 쓴다.
    func makeStore(_ fixture: RekordboxFixture, saveTagDrafts: (([TagDraft]) -> Void)? = { _ in }) -> LibraryStore {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("trackwrite"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: saveTagDrafts, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: fixture.root.appending(path: "drafts"),
                                 // 미리 보기·쓰고 난 뒤 다시 읽기가 사용자 라이브러리가 아니라 합성 사본을 보게 한다.
                                 rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                 arguments: ["test"], environment: [:],
                                 takeLiveSnapshot: { [database = fixture.database, fails = snapshotFails] _ in
                                     if fails.isOn { throw CocoaError(.fileReadNoPermission) }
                                     return database
                                 }, writer: writer)
        return store
    }

    func loadedStore(_ fixture: RekordboxFixture, saveTagDrafts: (([TagDraft]) -> Void)? = { _ in }) async -> LibraryStore {
        let store = makeStore(fixture, saveTagDrafts: saveTagDrafts)
        await store.load(snapshot: fixture.database)
        return store
    }

    func cue(_ uuid: String, time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.place(EditableCue(kind: .memory, time: time))
        return draft
    }

    func grid(_ uuid: String, bpm: Double = 120) -> GridDraft {
        GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: bpm, firstBeatNumber: 1)])
    }

    /// 저장소의 초안 폴더에 큐·그리드 초안을 저장한다(`write`를 주면 그것으로 써서 실패를 만든다).
    func saveDraft(_ draft: CueDraft, in store: LibraryStore, write: (@Sendable (CueDraft, URL) throws -> Void)? = nil) {
        if let write { writer.save(draft, directory: store.draftLocations.cue, write: write) }
        else { writer.save(draft, directory: store.draftLocations.cue) }
    }

    func saveDraft(_ draft: GridDraft, in store: LibraryStore, write: (@Sendable (GridDraft, URL) throws -> Void)? = nil) {
        if let write { writer.save(draft, directory: store.draftLocations.grid, write: write) }
        else { writer.save(draft, directory: store.draftLocations.grid) }
    }

    /// 저장에 실패해 디스크에는 옛 초안이, DraftWriter에는 최신 입력이 남은 상태를 만든다.
    func leaveFailedSaves(for uuid: String, in store: LibraryStore) {
        saveDraft(cue(uuid, time: 1), in: store)
        saveDraft(grid(uuid), in: store)
        writer.flush()
        saveDraft(cue(uuid, time: 2), in: store, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        saveDraft(grid(uuid, bpm: 125), in: store, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
    }

    func clearDrafts(_ uuid: String, in store: LibraryStore) {
        writer.removeCue(trackUUID: uuid, directory: store.draftLocations.cue)
        writer.removeGrid(trackUUID: uuid, directory: store.draftLocations.grid)
        writer.flush()
    }

    func stagedTrack(path: String) throws -> StagedTrack {
        try JSONDecoder().decode(StagedTrack.self, from: Data("""
            {"uuid":"\(UUID().uuidString)","path":"\(path)","title":"합성 추가 곡","comment":"","duration":2,"addedOn":"2026-10-01"}
            """.utf8))
    }

    /// 추가한 곡 하나를 미리 보고 합성 사본에 넣는다.
    func addStagedTrack(to store: LibraryStore, _ fixture: RekordboxFixture) async throws -> (preview: TrackAddPreview, report: RekordboxTrackWriter.Report) {
        let staged = try stagedTrack(path: try TestResources.url("mp3-notag-cbr.mp3").path)
        store.staging.staged = [staged]
        let preview = try await store.session.previewAdd(rows: [TrackRow(track: staged.track, cues: [], playCount: 0)])
        let report = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        return (preview, report)
    }

    /// 메모리 큐 11개: 메모리 큐 한도(10)에 걸려 곡은 들어가도 큐는 막힌다(막힌 큐는 새 곡의 큐 초안으로 옮겨진다).
    func manyCues(_ uuid: String) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        for index in 0..<11 { draft.place(EditableCue(kind: .memory, time: Double(index) + 0.5)) }
        return draft
    }

    struct Added {
        var staged: StagedTrack
        /// 넣은 새 곡 UUID
        var uuid: String
        var backup: RekordboxWriter.Backup
        var preview: TrackAddPreview
        var report: RekordboxTrackWriter.Report
        /// 넣기 전 추가한 곡에 만들어 둔 큐·그리드 초안(옛 UUID)
        var cueDraft: CueDraft?
        var gridDraft: GridDraft?
    }

    /// 추가한 곡에 큐·그리드 초안을 만들어 둔 채 미리 보고 합성 사본에 넣는다(`path`를 주지 않으면 합성 MP3).
    func addWithDrafts(_ store: LibraryStore, _ fixture: RekordboxFixture, path: String? = nil, cue makeCue: ((String) -> CueDraft)? = nil,
                       grid makeGrid: ((String) -> GridDraft)? = nil) async throws -> Added {
        let staged = try stagedTrack(path: try path ?? TestResources.url("mp3-notag-cbr.mp3").path)
        store.staging.staged = [staged]
        let cueDraft = makeCue?(staged.uuid), gridDraft = makeGrid?(staged.uuid)
        if let cueDraft { saveDraft(cueDraft, in: store) }
        if let gridDraft { saveDraft(gridDraft, in: store) }
        writer.flush()
        let preview = try await store.session.previewAdd(rows: [TrackRow(track: staged.track, cues: [], playCount: 0)])
        let report = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let uuid = try #require(report.added.first?.uuid)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        return Added(staged: staged, uuid: uuid, backup: backup, preview: preview, report: report, cueDraft: cueDraft, gridDraft: gridDraft)
    }

    /// 사용자 백업 폴더(앱 기본 폴더)에 이 곡 넣기·빼기의 백업이 생겼는지
    func defaultBackups(containing matches: (RekordboxTrackWriter.Report) -> Bool) -> Bool {
        RekordboxWriter.backups(in: DJCPaths.rekordboxBackups).contains { $0.trackReport.map(matches) == true }
    }

    // MARK: - 곡 넣기·빼기 백업

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡_넣기의_백업은_저장소에_준_폴더에_남는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())   // 라이브러리 공통값을 가져올 기존 곡
        let store = await loadedStore(fixture)
        let staged = try stagedTrack(path: try TestResources.url("mp3-notag-cbr.mp3").path)
        store.staging.staged = [staged]
        let preview = try await store.session.previewAdd(rows: [TrackRow(track: staged.track, cues: [], playCount: 0)])
        #expect(preview.report.added.first?.written == true)
        // 미리 보기는 백업을 뜨지 않는다.
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
        let report = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let path = try #require(report.added.first?.path)
        #expect(report.added.first?.written == true)
        let backups = RekordboxWriter.backups(in: fixture.backups)
        #expect(backups.count == 1 && backups.first?.isWrite == true)
        #expect(backups.first?.trackReport?.added.map(\.path) == [path])
        #expect(report.backup.map { URL(filePath: $0).deletingLastPathComponent().resolvingSymlinksInPath().path }
                == fixture.backups.resolvingSymlinksInPath().path)
        #expect(!defaultBackups { $0.added.contains { $0.path == path } })
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡_빼기의_백업은_저장소에_준_폴더에_남는다() async throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.dataStatus = 0  // 곡 빼기 규칙은 동기화하지 않은 곡으로만 확인했다(#196)
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let preview = try await store.session.previewDelete(rows: [row])
        #expect(preview.report.deleted.first?.written == true)
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
        let report = try await store.session.deleteTracksFromRekordbox(preview, from: fixture.database, shareRoot: fixture.shareRoot)
        #expect(report.deleted.first?.written == true)
        let backups = RekordboxWriter.backups(in: fixture.backups)
        #expect(backups.count == 1 && backups.first?.isWrite == true)
        #expect(backups.first?.trackReport?.deleted.compactMap(\.contentID) == [spec.id])
        #expect(!defaultBackups { $0.deleted.contains { $0.contentID == spec.id } })
    }

    /// 합치기 초안 단계는 같은 음원인지 비교만 보인다. 잃는 것은 쓸 때 한 번만 경고로 묻는다(#212).
    @Test func 합치기_초안_창은_비교만_보이고_손실_경고는_쓸_때_한다() async throws {
        let fixture = try RekordboxFixture()
        for (id, title) in [("100", "남길 곡"), ("200", "뺄 곡")] {
            var spec = TrackSpec(id: id, uuid: "u" + id)
            spec.title = title; spec.dataStatus = 0; spec.fileType = 11; spec.length = 30
            spec.folderPath = try AudioFixture.wav(seconds: 30, in: fixture.audio, name: id + ".wav").path
            try fixture.add(spec)
        }
        let store = await loadedStore(fixture)
        let prompter = ScriptedPrompter()
        prompter.answer = false
        await store.prepareMerge(keeping: "100", removing: ["200"], prompter: prompter)
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.confirm != nil && !prompt.destructive && !prompt.critical)
        #expect(!(prompt.text + prompt.details.joined()).contains(DuplicateMerge.lossNotice))
        #expect(prompt.details.contains { $0.contains("남길 곡") } && prompt.details.contains { $0.contains("뺄 곡") })
        #expect(store.mergeDrafts.isEmpty)
    }

    /// 합치기 초안을 만들지 못한 알림은 남길 곡이 아니라 지울 원본의 이름으로 이유를 알린다(#196 리뷰: 남길 곡을 빼야 하는 것처럼 읽혔다).
    @Test func 합치기_초안_알림은_지울_원본의_이름으로_막은_이유를_알린다() async throws {
        let fixture = try RekordboxFixture()
        for (id, title, status) in [("100", "남길 곡", 0), ("200", "뺄 곡", 256)] {
            var spec = TrackSpec(id: id, uuid: "u" + id)
            spec.title = title; spec.dataStatus = status; spec.fileType = 11; spec.length = 30
            spec.folderPath = try AudioFixture.wav(seconds: 30, in: fixture.audio, name: id + ".wav").path
            try fixture.add(spec)
        }
        let store = await loadedStore(fixture)
        let prompter = ScriptedPrompter()
        await store.prepareMerge(keeping: "100", removing: ["200"], prompter: prompter)
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "합치기 초안을 만들지 않았습니다" && prompt.confirm == nil)
        #expect(prompt.text == RekordboxWriter.mergeSourceReason(RekordboxTrackWriter.syncedTrackReason, title: "뺄 곡"))
        #expect(prompt.text.contains("‘뺄 곡’") && !prompt.text.contains("남길 곡"))
        #expect(store.mergeDrafts.isEmpty)
    }

    // MARK: - 곡 넣기 + 키 (#5)

    /// 이 시험이 남긴 태그 초안을 지운다(변경 없는 초안을 저장하면 파일을 지운다).
    func clearTagDrafts(_ uuids: [String], in store: LibraryStore) {
        writer.save(uuids.map { TagDraft(trackUUID: $0, base: TagFields()) }, directory: store.tagDraftDirectory)
        writer.flush()
    }

    /// 합성 라이브러리(공통값 곡 하나 + 8A 키 줄)와 키를 고른 추가한 곡. 태그 초안은 앱처럼 저장소의 초안 폴더에 저장한다(다시 읽기가 디스크를 읽는다).
    func keyedStaged(_ fixture: RekordboxFixture, key: String) async throws -> (store: LibraryStore, staged: StagedTrack, row: TrackRow) {
        try fixture.add(TrackSpec())
        try fixture.insert("djmdKey", ["ID": .text("1486464042"), "ScaleName": .text("8A"), "Seq": .int(1), "UUID": .text("k-8a"),
                                       "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(1)])
        let store = await loadedStore(fixture, saveTagDrafts: nil)
        let staged = try stagedTrack(path: try TestResources.url("mp3-notag-cbr.mp3").path)
        store.staging.staged = [staged]
        let row = TrackRow(track: staged.track, cues: [], playCount: 0)
        store.tags.setTag(.musicalKey, key, rows: [row])
        return (store, staged, row)
    }

    @Test func 키를_고른_추가한_곡은_넣을_때_키도_쓰고_되돌리면_추가_목록과_키_초안이_돌아온다() async throws {
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "8A")
        var owned = [staged.uuid]
        defer { clearTagDrafts(owned, in: store) }
        let preview = try await store.session.previewAdd(rows: [row])
        let report = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.keyWritten == "8A" && outcome.keyReason == nil)
        let id = try #require(outcome.contentID), uuid = try #require(outcome.uuid)
        owned.append(uuid)
        let stored = try #require(try fixture.rows("SELECT KeyID, TrackInfoUpdated FROM djmdContent WHERE ID = ?", [.text(id)]).first)
        #expect(stored == ["KeyID": "1486464042", "TrackInfoUpdated": "1"])
        // 다시 읽은 목록: 넣은 곡의 키가 8A이고, 새 곡에는 키 초안이 없다(이미 썼다)
        #expect(store.rowsByUUID[uuid]?.track.key == "8A" && store.tagDrafts[uuid] == nil)
        #expect(store.staging.staged.isEmpty)
        let lines = WriteResult.tracks(report, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis).text
        #expect(lines.contains("키 8A"), "\(lines)")

        // 쓰기 전으로 복원: 곡이 빠지고 추가 목록에 돌아오며, 키를 고른 초안도 그대로 남아 다시 넣을 수 있다
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: true)
        #expect(try fixture.rows("SELECT ID FROM djmdContent WHERE ID = ?", [.text(id)]).isEmpty)
        #expect(store.staging.staged.map(\.uuid) == [staged.uuid] && store.tags.confirmedStagedKey(uuid: staged.uuid) == "8A")
        #expect(store.tagDrafts[uuid] == nil)
    }

    @Test func 키가_막힌_채_넣은_직후_다시_읽기가_실패해도_새_곡의_키_초안을_남긴다() async throws {
        // #197: 결과 창은 "키는 쓰기 대기"라고 알린다. 다시 읽기(그 사이 rekordbox를 켬 등)가 실패해 새 곡 행이 없어도
        // 초안은 만들어져야 하고(기준은 쓰기 결과에서 온다), 다음에 읽어 새 곡이 보이면 그 행의 값과 맞아 쓸 수 있어야 한다.
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "12B")
        var owned = [staged.uuid]
        defer { clearTagDrafts(owned, in: store) }
        let preview = try await store.session.previewAdd(rows: [row])
        let database = fixture.database
        snapshotFails.set(true)
        let report = try await store.session.addTracksToRekordbox(preview, to: database, shareRoot: fixture.shareRoot)
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.keyWritten == nil && outcome.keyReason != nil)
        let uuid = try #require(outcome.uuid)
        owned.append(uuid)
        #expect(store.rowsByUUID[uuid] == nil && store.lastError != nil, "다시 읽기가 실패해 새 곡 행이 아직 없다")
        let moved = try #require(store.tagDrafts[uuid], "결과 창이 알린 대로 키 초안이 있어야 한다")
        #expect(moved.changedKeys == [.musicalKey] && moved.fields.musicalKey == "12B")
        #expect(TagDraftStore.load(trackUUID: uuid, directory: store.tagDraftDirectory)?.fields.musicalKey == "12B", "디스크에도 저장했다")
        let result = WriteResult.tracks(report, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis)
        #expect(result.text.contains("키는 쓰기 대기"), "\(result.text)")

        // 나중에 읽으면 새 곡이 보이고, 초안의 기준은 그 곡의 값이라 쓰기에서 기준 어긋남으로 막히지 않는다
        snapshotFails.set(false)
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        let reloaded = try #require(store.rowsByUUID[uuid])
        let draft = try #require(store.tagDrafts[uuid])
        #expect(draft.fields.musicalKey == "12B" && draft.base == reloaded.tagFields)
        // 이제 키 줄이 생겼다고 하고(막힌 이유 해소) 쓰기 시험: 기준이 어긋나 있으면 여기서 막힌다
        try fixture.insert("djmdKey", ["ID": .text("1486464043"), "ScaleName": .text("12B"), "Seq": .int(2), "UUID": .text("k-12b"),
                                       "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(1)])
        let dry = try RekordboxWriter.write(drafts: [], tags: [draft], to: database, dryRun: true, backups: fixture.backups,
                                            shareRoot: fixture.shareRoot)
        #expect(dry.tagWritten.count == 1 && dry.tagBlocked.isEmpty, "\(dry.tagBlocked)")
    }

    @Test func 넣기_백업에_추가한_곡의_초안이_담기고_넣은_뒤_옛_UUID의_초안은_정리돼_복원이_되살린다() async throws {
        // #197: 넣기 백업이 추가한 곡의 초안(태그·큐)을 담고 있어 "쓰기 전으로 복원…"이 곡과 함께 되살린다.
        // #202: 그 초안은 넣기에 쓰였고 백업이 가졌으니, 넣은 뒤 연결 안 된 초안으로 남기지 않고 정리한다(사용자가 버리지 않아도 된다).
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "8A")
        let original = cue(staged.uuid, time: 1)
        saveDraft(original, in: store)
        writer.flush()
        defer {
            clearTagDrafts([staged.uuid], in: store)
            clearDrafts(staged.uuid, in: store)
        }
        let preview = try await store.session.previewAdd(rows: [row])
        let report = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        #expect(report.added.first?.keyWritten == "8A" && report.added.first?.cuesWritten == 1)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        #expect(RekordboxWriter.tagDrafts(in: backup.url).map(\.trackUUID) == [staged.uuid], "백업에 추가한 곡의 태그 초안")
        #expect(RekordboxWriter.contents(of: backup.url).drafts.map(\.trackUUID) == [staged.uuid], "백업에 추가한 곡의 큐 초안")

        // 넣은 뒤: 옛 UUID의 초안은 이미 정리돼 연결 안 된 초안으로 보이지 않고, 알릴 경고도 없다
        writer.flush()
        #expect(CueDraftStore.load(trackUUID: staged.uuid, directory: store.draftLocations.cue) == nil && TagDraftStore.load(trackUUID: staged.uuid, directory: store.tagDraftDirectory) == nil)
        #expect(store.tagDrafts[staged.uuid] == nil)
        #expect(!store.unlinkedDraftUUIDs.contains(staged.uuid) && store.writeFollowUp.isEmpty, "\(store.writeFollowUp)")

        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: true)
        writer.flush()
        #expect(store.staging.staged.map(\.uuid) == [staged.uuid])
        #expect(store.tags.confirmedStagedKey(uuid: staged.uuid) == "8A", "고른 키가 다시 넣을 수 있게 돌아온다")
        #expect(CueDraftStore.load(trackUUID: staged.uuid, directory: store.draftLocations.cue) == original, "큐 초안도 돌아온다")
        #expect(!store.unlinkedDraftUUIDs.contains(staged.uuid), "되돌린 곡이 추가 목록에 있어 이어진 초안이다")
    }

    // #197 되돌리기의 태그 초안 배선: 판정(`AddedTrackDrafts.kept`)은 DJCApplicationTests가 보고, 여기서는 판정에 넣는 값
    // (추가 목록 곡의 고른 키 `confirmedStagedKey`)과 결과 적용(지우기·남김 알림)이 실제 넣기 → 되돌리기에서 이어지는지 본다.

    @Test func 곡_넣기를_되돌릴_때_옮겨_둔_키만_있는_초안은_지우고_알리지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "12B")
        var owned = [staged.uuid]
        defer { clearTagDrafts(owned, in: store) }
        let preview = try await store.session.previewAdd(rows: [row])
        let report = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let uuid = try #require(report.added.first?.uuid)
        owned.append(uuid)
        #expect(store.tagDrafts[uuid]?.changedKeys == [.musicalKey], "막힌 키가 새 곡의 키 초안으로 옮겨졌다")
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: true)
        writer.flush()
        #expect(store.tagDrafts[uuid] == nil && TagDraftStore.load(trackUUID: uuid, directory: store.tagDraftDirectory) == nil)
        #expect(store.tags.confirmedStagedKey(uuid: staged.uuid) == "12B", "고른 키는 추가 목록 곡에 돌아온다")
        #expect(!store.unlinkedDraftUUIDs.contains(uuid) && !store.writeFollowUp.contains { $0.contains("연결되지 않은 초안") })
    }

    @Test func 곡_넣기를_되돌려도_넣은_뒤_새_곡에_만든_태그_초안은_지우지_않고_알린다() async throws {
        // 막힌 키를 옮긴 초안에 사용자가 넣은 뒤 더한 편집이 있으면 알림 없이 지우지 않는다. 연결 안 된 초안으로 남기고 복원 결과가 알린다.
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "12B")
        var owned = [staged.uuid]
        defer { clearTagDrafts(owned, in: store) }
        let preview = try await store.session.previewAdd(rows: [row])
        let report = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let uuid = try #require(report.added.first?.uuid)
        owned.append(uuid)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        store.tags.setTag(.comment, "넣은 뒤 고친 코멘트", rows: [try #require(store.rowsByUUID[uuid])])
        writer.flush()

        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: true)
        writer.flush()
        #expect(store.staging.staged.map(\.uuid) == [staged.uuid] && store.tags.confirmedStagedKey(uuid: staged.uuid) == "12B")
        #expect(store.tagDrafts[uuid]?.fields.comment == "넣은 뒤 고친 코멘트", "사용자가 만든 초안은 지우지 않는다")
        #expect(TagDraftStore.load(trackUUID: uuid, directory: store.tagDraftDirectory)?.fields.comment == "넣은 뒤 고친 코멘트", "디스크에도 남아 있다")
        #expect(store.unlinkedDraftUUIDs.contains(uuid), "연결 안 된 초안으로 남아 쓰기 대기 목록에서 버릴 수 있다")
        #expect(store.writeFollowUp.contains { $0.contains("연결되지 않은 초안") }, "\(store.writeFollowUp)")
    }

    // MARK: - 복원 확인 창의 곡 이름

    @Test func 복원_확인_창은_넣기_백업의_충돌을_넣은_곡의_제목으로_보인다() async throws {
        // #197: 넣기 백업에는 쓰기 보고서가 없고, 넣은 추가 목록 곡은 더는 목록의 곡 행이 아니다. 제목을 못 찾으면 UUID가 보였다.
        // 넣은 뒤 그 곡의 연결 안 된 큐 초안을 새로 편집한 채 그 백업으로 되돌리려는 경우다(넣기 → 되돌리기 → 큐 고침 → 다시 넣기 → 첫 백업으로 되돌리기와 같다).
        let fixture = try RekordboxFixture()
        let (store, staged, row) = try await keyedStaged(fixture, key: "8A")
        saveDraft(cue(staged.uuid, time: 1), in: store)
        writer.flush()
        defer {
            clearTagDrafts([staged.uuid], in: store)
            clearDrafts(staged.uuid, in: store)
        }
        let preview = try await store.session.previewAdd(rows: [row])
        _ = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        #expect(backup.report == nil && backup.trackReport != nil && store.rowsByUUID[staged.uuid] == nil)
        #expect(store.session.restoreConflictDetails(backup).isEmpty)

        saveDraft(cue(staged.uuid, time: 9), in: store)
        writer.flush()
        let line = try #require(store.session.restoreConflictDetails(backup).first)
        #expect(store.session.restoreConflictDetails(backup).count == 1)
        #expect(line == "• \(staged.title) — 큐", "\(line)")
        #expect(!line.contains(staged.uuid))
    }

    // MARK: - 반영 확인

    @Test func 반영_확인은_저장_실패_기록이_남은_곡의_대기_초안도_정리한다() async throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.cues = [CueSpec(kind: 0, inMsec: 4000)]
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        // 가져오기 전(큐 없음)의 초안으로 계획을 만든다. 가져온 뒤 rekordbox에는 그 큐가 들어 있다.
        let plan = Reflection.plan(track: row.track, rawCues: [], cueDraft: cue(spec.uuid, time: 4), gridDraft: nil)
        leaveFailedSaves(for: spec.uuid, in: store)
        defer { clearDrafts(spec.uuid, in: store) }
        #expect(writer.pendingCue(trackUUID: spec.uuid, directory: store.draftLocations.cue) != nil && writer.pendingGrid(trackUUID: spec.uuid, directory: store.draftLocations.grid) != nil)
        store.reflectionBatch = ReflectionXMLBatch(createdAt: "2026-10-01 00:00:00", xmlPath: "", plans: [plan], checks: [:])
        store.verifyReflection()
        writer.flush()
        #expect(store.reflectionMessage?.kind == .success)
        // 디스크와 DraftWriter의 기록이 같이 비어야 덱·쓰기 전 확인이 옛 초안을 다시 읽지 않는다.
        #expect(CueDraftStore.load(trackUUID: spec.uuid, directory: store.draftLocations.cue) == nil && GridDraftStore.load(trackUUID: spec.uuid, directory: store.draftLocations.grid) == nil)
        #expect(writer.pendingCue(trackUUID: spec.uuid, directory: store.draftLocations.cue) == nil && writer.pendingGrid(trackUUID: spec.uuid, directory: store.draftLocations.grid) == nil)
        #expect(!writer.failures(in: store.draftLocations).contains { $0.trackUUID == spec.uuid })
        #expect(writer.unsavedUUIDs(in: store.draftLocations).isDisjoint(with: [spec.uuid]))
        #expect(!store.pendingUUIDs.contains(spec.uuid))
    }

    @Test func 반영_확인은_초안_파일이_없는_곡을_정리_실패로_알리지_않는다() async throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.cues = [CueSpec(kind: 0, inMsec: 4000)]
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let plan = Reflection.plan(track: row.track, rawCues: [], cueDraft: cue(spec.uuid, time: 4), gridDraft: nil)
        defer { clearDrafts(spec.uuid, in: store) }
        #expect(CueDraftStore.load(trackUUID: spec.uuid, directory: store.draftLocations.cue) == nil && GridDraftStore.load(trackUUID: spec.uuid, directory: store.draftLocations.grid) == nil)
        store.reflectionBatch = ReflectionXMLBatch(createdAt: "2026-10-01 00:00:00", xmlPath: "", plans: [plan], checks: [:])
        store.verifyReflection()
        writer.flush()
        #expect(store.reflectionMessage?.kind == .success)
        #expect(!writer.failures(in: store.draftLocations).contains { $0.trackUUID == spec.uuid })
    }

    @Test func 반영_확인이_초안을_정리하지_못하면_경고로_알린다() async throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.cues = [CueSpec(kind: 0, inMsec: 4000)]
        try fixture.add(spec)
        let store = await loadedStore(fixture)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let draft = cue(spec.uuid, time: 4)
        let plan = Reflection.plan(track: row.track, rawCues: [], cueDraft: draft, gridDraft: nil)
        saveDraft(draft, in: store)
        writer.flush()
        // 이 곡의 파일만 잠가 정리(삭제) 실패를 만든다(다른 시험의 초안과 섞이지 않게).
        let file = store.draftLocations.cue.appending(path: "\(spec.uuid).json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            clearDrafts(spec.uuid, in: store)
        }
        store.reflectionBatch = ReflectionXMLBatch(createdAt: "2026-10-01 00:00:00", xmlPath: "", plans: [plan], checks: [:])
        store.verifyReflection()
        #expect(store.reflectionMessage?.kind == .warning)
        #expect(store.reflectionMessage?.text.contains("초안을 정리하지 못했습니다") == true)
        #expect(writer.failures(in: store.draftLocations).contains { $0.trackUUID == spec.uuid && $0.kind == .cue })
    }

    // MARK: - 추가 곡 복원

    /// 넣을 때 큐가 막혀 새 곡으로 옮긴 큐 초안과 같은 모양(넣은 쪽·되돌리는 쪽이 같은 규칙으로 만든다).
    func movedCue(_ added: Added) throws -> CueDraft { AddedTrackDrafts.movedCueDraft(from: try #require(added.cueDraft), to: added.uuid) }

    @Test func 넣을_때_큐가_막혀_새_곡으로_옮긴_큐_초안은_되돌릴_때_지우고_추가한_곡의_초안이_돌아온다() async throws {
        // 옮긴 사본은 되돌릴 때 백업에서 되살아나는 추가한 곡의 초안과 같으니 남겨 두면 중복이다. 알리지도 않는다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        let added = try await addWithDrafts(store, fixture, cue: manyCues)
        defer {
            clearDrafts(added.uuid, in: store)
            clearDrafts(added.staged.uuid, in: store)
        }
        let outcome = try #require(added.report.added.first)
        #expect(outcome.written && outcome.cuesWritten == nil && outcome.cueReason != nil)
        #expect(CueDraftStore.load(trackUUID: added.uuid, directory: store.draftLocations.cue) == (try movedCue(added)), "막힌 큐가 새 곡의 큐 초안으로 옮겨졌다")

        try await store.session.restoreRekordbox(added.backup, keepingCurrentDrafts: true)
        writer.flush()
        #expect(CueDraftStore.load(trackUUID: added.uuid, directory: store.draftLocations.cue) == nil && writer.pendingCue(trackUUID: added.uuid, directory: store.draftLocations.cue) == nil)
        #expect(CueDraftStore.load(trackUUID: added.staged.uuid, directory: store.draftLocations.cue) == added.cueDraft, "추가한 곡의 큐는 돌아온다")
        #expect(store.staging.staged.map(\.uuid) == [added.staged.uuid])
        #expect(!store.unlinkedDraftUUIDs.contains(added.uuid) && store.writeFollowUp.isEmpty, "\(store.writeFollowUp)")
    }

    @Test func 곡_넣기를_되돌려도_넣은_뒤_새_곡에_만든_큐_그리드_초안은_지우지_않고_알린다() async throws {
        // #202: 되돌리면 새 곡이 사라지지만, 넣은 뒤 사용자가 그 곡에 만든 큐·그리드 초안을 알림 없이 지우지 않는다(태그 초안과 같다, #197).
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        let added = try await addWithDrafts(store, fixture)
        defer {
            clearDrafts(added.uuid, in: store)
            clearDrafts(added.staged.uuid, in: store)
        }
        let editedCue = cue(added.uuid, time: 3), editedGrid = grid(added.uuid, bpm: 125)
        saveDraft(editedCue, in: store)
        saveDraft(editedGrid, in: store)
        writer.flush()

        try await store.session.restoreRekordbox(added.backup, keepingCurrentDrafts: true)
        writer.flush()
        #expect(store.staging.staged.map(\.uuid) == [added.staged.uuid])
        #expect(CueDraftStore.load(trackUUID: added.uuid, directory: store.draftLocations.cue) == editedCue, "큐 초안을 지우지 않는다")
        #expect(GridDraftStore.load(trackUUID: added.uuid, directory: store.draftLocations.grid) == editedGrid, "그리드 초안을 지우지 않는다")
        #expect(store.unlinkedDraftUUIDs.contains(added.uuid), "연결 안 된 초안으로 남아 쓰기 대기 목록에서 버릴 수 있다")
        let notice = try #require(store.writeFollowUp.first { $0.contains("연결되지 않은 초안") })
        #expect(notice == ReflectionSession.keptNewTrackDraftsText(1, kinds: [.cue, .grid]), "\(notice)")
        #expect(notice.contains("큐·그리드") && !notice.contains("새 곡에 만든"), "\(notice)")
    }

    @Test func 분석을_못_붙여_새_곡으로_옮긴_그리드_초안은_되돌릴_때_지우고_알리지_않는다() async throws {
        // 96kHz ALAC은 분석 붙이기 규칙을 확인하지 못해 곡만 넣고 그리드 초안을 새 곡의 초안으로 옮긴다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        let alac = try AudioFixture.alac(seconds: 2, sampleRate: 96_000, in: fixture.audio, name: "alac96.m4a")
        let added = try await addWithDrafts(store, fixture, path: alac.path, grid: { grid($0) })
        defer {
            clearDrafts(added.uuid, in: store)
            clearDrafts(added.staged.uuid, in: store)
        }
        let outcome = try #require(added.report.added.first)
        #expect(outcome.written && added.preview.withoutAnalysis[outcome.path] != nil, "분석 없이 넣었다")
        let moved = AddedTrackDrafts.movedGridDraft(from: try #require(added.gridDraft), to: added.uuid)
        #expect(GridDraftStore.load(trackUUID: added.uuid, directory: store.draftLocations.grid) == moved, "그리드 초안이 새 곡의 초안으로 옮겨졌다")

        try await store.session.restoreRekordbox(added.backup, keepingCurrentDrafts: true)
        writer.flush()
        #expect(GridDraftStore.load(trackUUID: added.uuid, directory: store.draftLocations.grid) == nil && writer.pendingGrid(trackUUID: added.uuid, directory: store.draftLocations.grid) == nil)
        #expect(GridDraftStore.load(trackUUID: added.staged.uuid, directory: store.draftLocations.grid) == added.gridDraft, "추가한 곡의 그리드는 돌아온다")
        #expect(!store.unlinkedDraftUUIDs.contains(added.uuid) && store.writeFollowUp.isEmpty, "\(store.writeFollowUp)")
    }

    @Test func 곡_넣기를_되돌릴_때_옮긴_사본이_아닌_저장_못_한_새_입력은_지우지_않고_알린다() async throws {
        // 옮긴 사본은 디스크에 있지만, 저장에 실패해 DraftWriter에만 남은 새 입력은 사용자 작업이다(비교는 저장 못 한 입력을 먼저 본다).
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        let added = try await addWithDrafts(store, fixture, cue: manyCues)
        defer { clearDrafts(added.uuid, in: store); clearDrafts(added.staged.uuid, in: store) }
        var edited = try movedCue(added)
        edited.place(EditableCue(kind: .hot(1), time: 2.5))
        saveDraft(edited, in: store, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        #expect(CueDraftStore.load(trackUUID: added.uuid,
                                   directory: store.draftLocations.cue) == (try movedCue(added)) && writer.pendingCue(trackUUID: added.uuid,
                                   directory: store.draftLocations.cue) == edited)

        let result = store.session.restoreStaged(from: added.backup)
        writer.flush()
        #expect(result.keptDrafts == 1 && result.keptKinds == [.cue])
        #expect(writer.pendingCue(trackUUID: added.uuid, directory: store.draftLocations.cue) == edited, "저장 못 한 새 입력을 지우지 않는다")
        #expect(writer.failures(in: store.draftLocations).contains { $0.trackUUID == added.uuid && $0.kind == .cue })
        #expect(store.lastError?.contains("초안을 저장하지 못했습니다") == true, "\(store.lastError ?? "")")
    }

    @Test func 곡_넣기를_되돌리면_옮긴_큐_초안의_저장_실패_기록도_정리한다() async throws {
        // #172: 초안 파일을 직접 지우지 않고 DraftWriter로 지워, 저장 실패로 남은 기록(같은 내용)까지 함께 비운다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        let added = try await addWithDrafts(store, fixture, cue: manyCues)
        defer { clearDrafts(added.uuid, in: store); clearDrafts(added.staged.uuid, in: store) }
        saveDraft(try movedCue(added), in: store, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        #expect(writer.pendingCue(trackUUID: added.uuid,
                                  directory: store.draftLocations.cue) != nil && writer.failures(in: store.draftLocations).contains { $0.trackUUID == added.uuid })

        let result = store.session.restoreStaged(from: added.backup)
        writer.flush()
        #expect(result.keptDrafts == 0)
        #expect(CueDraftStore.load(trackUUID: added.uuid, directory: store.draftLocations.cue) == nil && writer.pendingCue(trackUUID: added.uuid, directory: store.draftLocations.cue) == nil)
        #expect(!writer.failures(in: store.draftLocations).contains { $0.trackUUID == added.uuid })
        #expect(store.lastError == nil)
    }

    @Test func 곡_넣기를_되돌릴_때_옮긴_큐_초안을_정리하지_못하면_알린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        let added = try await addWithDrafts(store, fixture, cue: manyCues)
        // 이 곡의 파일만 잠가 정리(삭제) 실패를 만든다(다른 시험의 초안과 섞이지 않게).
        let file = store.draftLocations.cue.appending(path: "\(added.uuid).json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            clearDrafts(added.uuid, in: store)
            clearDrafts(added.staged.uuid, in: store)
        }
        _ = store.session.restoreStaged(from: added.backup)
        #expect(store.lastError?.contains("초안을 저장하지 못했습니다") == true)
        #expect(writer.failures(in: store.draftLocations).contains { $0.trackUUID == added.uuid && $0.kind == .cue })
    }

    // MARK: - 넣기 백업과 옛 UUID 초안 (#202)

    @Test func 넣기_백업에_추가_목록을_저장하지_못하면_결과에_경고로_알린다() async throws {
        // 넣기는 이미 끝났으니 실패로 바꾸지 않는다. 다만 이 백업으로 되돌려도 곡이 추가 목록으로 돌아오지 못하니 알린다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        store.testReflection.backupFileWriter = { data, url in
            if url.lastPathComponent == RekordboxBackups.stagedFileName { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        store.writeFollowUp = ["지난 결과의 경고"]
        let added = try await addWithDrafts(store, fixture)
        let outcome = try #require(added.report.added.first)
        #expect(outcome.written && store.staging.staged.isEmpty, "넣기는 그대로 끝난다")
        #expect(RekordboxBackups.live().stagedTracks(added.backup.url) == nil)
        #expect(store.writeFollowUp == [ReflectionSession.stagedBackupFailureText], "\(store.writeFollowUp)")
        let result = WriteResult.tracks(added.report, preview: added.preview.report, adding: true,
                                        withoutAnalysis: added.preview.withoutAnalysis).followedUp(store.writeFollowUp)
        #expect(result.kind == .warning && result.text.hasSuffix("• \(ReflectionSession.stagedBackupFailureText)"), "\(result.text)")

        // 경고가 알린 대로 곡은 추가 목록으로 돌아오지 못한다
        try await store.session.restoreRekordbox(added.backup, keepingCurrentDrafts: true)
        #expect(store.staging.staged.isEmpty)
    }

    @Test func 백업에_초안_사본을_못_남기면_그_초안은_지우지_않고_연결_안_된_초안으로_알린다() async throws {
        // 백업이 가진 초안만 정리한다. 사본을 못 남긴 큐 초안은 되돌릴 때 이어질 유일한 사본이라 그대로 두고, 그렇다고 알린다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = await loadedStore(fixture)
        store.testReflection.backupFileWriter = { data, url in
            if url.deletingLastPathComponent().lastPathComponent == "cue-drafts" { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        let added = try await addWithDrafts(store, fixture, cue: { cue($0, time: 1) }, grid: { grid($0) })
        defer { clearDrafts(added.uuid, in: store); clearDrafts(added.staged.uuid, in: store) }
        let original = try #require(added.cueDraft)
        writer.flush()
        #expect(RekordboxWriter.contents(of: added.backup.url).drafts.isEmpty, "큐 사본은 백업에 없다")
        #expect(RekordboxWriter.gridDrafts(in: added.backup.url).map(\.trackUUID) == [added.staged.uuid], "그리드 사본은 백업에 있다")
        #expect(CueDraftStore.load(trackUUID: added.staged.uuid, directory: store.draftLocations.cue)?.cues == original.cues, "백업에 없는 큐 초안은 지우지 않는다")
        #expect(GridDraftStore.load(trackUUID: added.staged.uuid, directory: store.draftLocations.grid) == nil, "백업에 있는 그리드 초안은 정리한다")
        #expect(store.unlinkedDraftUUIDs.contains(added.staged.uuid))
        #expect(store.writeFollowUp == [ReflectionSession.stagedDraftsBackupFailureText(1)], "\(store.writeFollowUp)")

        // 되돌리면 곡이 추가 목록에 돌아오고 남겨 둔 큐 초안이 다시 이어진다
        try await store.session.restoreRekordbox(added.backup, keepingCurrentDrafts: true)
        writer.flush()
        #expect(store.staging.staged.map(\.uuid) == [added.staged.uuid])
        #expect(CueDraftStore.load(trackUUID: added.staged.uuid, directory: store.draftLocations.cue)?.cues == original.cues)
        #expect(GridDraftStore.load(trackUUID: added.staged.uuid, directory: store.draftLocations.grid) == added.gridDraft)
        #expect(!store.unlinkedDraftUUIDs.contains(added.staged.uuid))
    }

    // MARK: - 추가 곡 그리드 추정

    final class Calls: Sendable {
        let count = Mutex(0)
    }

    func estimate(bpm: Double = 125) throws -> GridEstimator.Estimate {
        var estimate = try #require(GridEstimator.estimate(beats: (0..<40).map { 0.5 + Double($0) * 0.5 }, bars: [0.5, 2.5, 4.5], duration: 20))
        estimate.segments[0].bpm = bpm
        return estimate
    }

    func estimatedStore(returning estimate: GridEstimator.Estimate, calls: Calls) throws -> (LibraryStore, GridJobItem, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-estimate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = try AudioFixture.wav(seconds: 1, in: directory)
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("estimate"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: directory.appending(path: "backups"),
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: directory.appending(path: "drafts"), writer: writer,
                                 ports: { $0.analysis.estimateGrid = { _, _ in calls.count.withLock { $0 += 1 }; return estimate } })
        return (store, GridJobItem(uuid: UUID().uuidString, path: wav.path, staged: false), directory)
    }

    func runQueue(_ store: LibraryStore, _ item: GridJobItem) async {
        store.staging.enqueueGrid([item])
        await store.staging.gridTask?.value
    }

    @Test func 그리드_추정_저장은_DraftWriter_기록과_디스크가_같다() async throws {
        let calls = Calls()
        let (store, item, directory) = try estimatedStore(returning: estimate(), calls: calls)
        defer { try? FileManager.default.removeItem(at: directory); clearDrafts(item.uuid, in: store) }
        await runQueue(store, item)
        #expect(calls.count.withLock { $0 } == 1)
        let saved = try #require(GridDraftStore.load(trackUUID: item.uuid, directory: store.draftLocations.grid))
        let state = try #require(writer.state(.grid, trackUUID: item.uuid, directory: store.draftLocations.grid))
        #expect(state.savedRevision == state.revision && state.failure == nil)
        #expect(writer.pendingGrid(trackUUID: item.uuid, directory: store.draftLocations.grid) == nil && saved.segments.first?.bpm == 125)
        #expect(store.pendingUUIDs.contains(item.uuid) && store.lastError == nil)
    }

    @Test func 그리드_추정_저장이_실패하면_기록하고_알린다() async throws {
        let calls = Calls()
        let (store, item, directory) = try estimatedStore(returning: estimate(), calls: calls)
        // 파일 자리에 폴더를 둬 저장 실패를 만든다.
        let blocker = store.draftLocations.grid.appending(path: "\(item.uuid).json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: blocker)
            try? FileManager.default.removeItem(at: directory)
            clearDrafts(item.uuid, in: store)
        }
        await runQueue(store, item)
        let failure = try #require(writer.failures(in: store.draftLocations).first { $0.trackUUID == item.uuid && $0.kind == .grid })
        #expect(writer.pendingGrid(trackUUID: item.uuid, directory: store.draftLocations.grid)?.segments.first?.bpm == 125)
        #expect(store.lastError == failure.message)
        // 저장에 실패한 초안이 있는 곡은 곡 넣기 전 확인이 막는다(#170).
        #expect { try store.testDrafts.requireSaved([item.uuid]) } throws: { $0.localizedDescription.contains(failure.message) }
    }

    @Test func 그리드_추정은_저장_실패로_대기_중인_덱_편집을_덮지_않는다() async throws {
        let calls = Calls()
        let (store, item, directory) = try estimatedStore(returning: estimate(), calls: calls)
        defer { try? FileManager.default.removeItem(at: directory); clearDrafts(item.uuid, in: store) }
        // 덱에서 고친 그리드가 저장에 실패해 디스크에는 없고 DraftWriter에만 있다.
        let edited = grid(item.uuid, bpm: 140)
        saveDraft(edited, in: store, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        #expect(GridDraftStore.load(trackUUID: item.uuid, directory: store.draftLocations.grid) == nil && writer.pendingGrid(trackUUID: item.uuid, directory: store.draftLocations.grid) == edited)
        await runQueue(store, item)
        #expect(calls.count.withLock { $0 } == 0)
        #expect(writer.pendingGrid(trackUUID: item.uuid, directory: store.draftLocations.grid) == edited)
        #expect(GridDraftStore.load(trackUUID: item.uuid, directory: store.draftLocations.grid) == nil)
    }
}
