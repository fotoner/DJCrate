@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Synchronization
import Testing

/// #175: 쓰기 뒤 다시 읽기·복원·XML 확인이 실패나 새 초안을 넘기고 성공처럼 이어지지 않는다.
/// 초안·반영 묶음은 저장소마다 준 초안 폴더에 쓴다(사용자 폴더를 건드리지 않게).
@MainActor
@Suite("쓰기 뒤 다시 읽기·복원·XML 확인", .serialized)
struct WriteFollowUpTests {
    struct ReloadFailure: Error {}

    final class Calls: @unchecked Sendable { var written: [Set<String>] = [] }

    /// 시험마다 새 저장 큐(저장소와 시험이 같은 큐를 본다)
    let writer = DraftWriter()
    /// 켜면 스냅샷 뜨기가 실패한다(쓴 뒤 다시 읽기 실패를 만든다)
    let snapshotFails = TestSwitch()

    func makeStore(_ fixture: RekordboxFixture) async -> (LibraryStore, Calls) {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("follow-up"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: fixture.root.appending(path: "drafts"),
                                 // 쓰고 난 뒤 다시 읽기가 사용자 라이브러리가 아니라 합성 사본을 보게 한다.
                                 rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                 arguments: ["test"], environment: [:],
                                 takeLiveSnapshot: { [database = fixture.database, fails = snapshotFails] _ in
                                     if fails.isOn { throw ReloadFailure() }
                                     return database
                                 }, writer: writer)
        let calls = Calls()
        store.onRekordboxWritten = { calls.written.append($0) }
        await store.load(snapshot: fixture.database)
        return (store, calls)
    }

    func cue(_ uuid: String, time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.place(EditableCue(kind: .memory, time: time))
        return draft
    }

    func clear(_ uuid: String, in store: LibraryStore) {
        writer.removeCue(trackUUID: uuid, directory: store.draftLocations.cue)
        writer.flush()
    }

    // MARK: - 쓰기 뒤 다시 읽기(B48)

    @Test func 다시_읽기가_실패하면_덱을_갱신하지_않고_따로_알린_뒤_다음_읽기에서_잇는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        let draft = cue(spec.uuid, time: 4)
        writer.save(draft, directory: store.draftLocations.cue)
        writer.flush()
        snapshotFails.set(true)
        let report = try await store.session.writeToRekordbox([draft], to: fixture.database, shareRoot: fixture.shareRoot)
        #expect(report.written.map(\.trackUUID) == [spec.uuid])
        // 쓰기는 성공했지만 옛 스냅샷을 새것으로 보지 않는다: 덱에 알리지 않고, 결과와 나눠 알린다.
        #expect(calls.written.isEmpty)
        #expect(store.writeFollowUp == [ReflectionSession.reloadFailureText(restoring: false)])
        #expect(store.lastError?.contains(ReflectionSession.reloadFailureText(restoring: false)) == true)
        #expect(store.writtenAwaitingReload == [spec.uuid])
        // 다음 읽기가 성공하면 그때 덱에 알린다.
        snapshotFails.set(false)
        #expect(await store.reloadAfterWrite())
        #expect(calls.written == [[spec.uuid]])
        #expect(store.writtenAwaitingReload.isEmpty)
    }

    @Test func 다시_읽기가_성공하면_새_스냅샷으로_덱에_알리고_경고가_없다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        let draft = cue(spec.uuid, time: 4)
        writer.save(draft, directory: store.draftLocations.cue)
        writer.flush()
        _ = try await store.session.writeToRekordbox([draft], to: fixture.database, shareRoot: fixture.shareRoot)
        #expect(calls.written == [[spec.uuid]])
        #expect(store.writeFollowUp.isEmpty && store.lastError == nil)
        // 덱이 다시 읽을 때 목록 줄은 이미 새 스냅샷의 큐를 갖고 있다.
        #expect(store.rowsByUUID[spec.uuid]?.cues.contains { $0.inMsec == 4000 } == true)
    }

    @Test func 뒤따른_경고가_있으면_성공_결과도_경고로_바꾸고_줄을_더한다() {
        let result = WriteResult(kind: .success, title: "rekordbox에 썼습니다 · 큐 1곡", text: "• 곡 — 큐 쓰기 완료")
        #expect(result.followedUp([]) == result)
        let note = ReflectionSession.reloadFailureText(restoring: false)
        let followed = result.followedUp([note])
        #expect(followed.kind == .warning && followed.title == result.title)
        #expect(followed.shortfall == note)
        #expect(followed.text == "• 곡 — 큐 쓰기 완료\n• \(note)")
    }

    // MARK: - 복원(B49)

    @Test func 복원은_쓴_뒤_새로_만든_초안을_덮지_않고_고르면_백업_초안으로_바꾼다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, _) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        let cues = store.draftLocations.cue
        let written = cue(spec.uuid, time: 4)
        writer.save(written, directory: cues)
        writer.flush()
        _ = try await store.session.writeToRekordbox([written], to: fixture.database, shareRoot: fixture.shareRoot)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first(where: { $0.isWrite }))
        #expect(store.session.restoreConflictDetails(backup).isEmpty)
        // 쓴 뒤 같은 곡을 새로 편집했다.
        let row = try #require(store.rowsByUUID[spec.uuid])
        var latest = CueDraft(trackUUID: spec.uuid, rekordboxCues: row.cues)
        latest.place(EditableCue(kind: .memory, time: 8))
        writer.save(latest, directory: cues)
        writer.flush()
        let details = store.session.restoreConflictDetails(backup)
        #expect(details.count == 1 && details.first?.hasSuffix("— 큐") == true)
        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: true)
        #expect(CueDraftStore.load(trackUUID: spec.uuid, directory: cues) == latest)
        #expect(store.writeFollowUp == [ReflectionSession.keptDraftsText(1)])
        // 고르면 백업의 초안으로 바꾼다(지금 초안은 사라진다).
        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: false)
        #expect(CueDraftStore.load(trackUUID: spec.uuid, directory: cues) == written)
        #expect(store.writeFollowUp.isEmpty)
    }

    // MARK: - 연결되지 않은 초안(B30)

    @Test func 연결되지_않은_초안은_자동으로_지우지_않고_보여_주며_고른_것만_버린다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-unlinked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let cues = home.appending(path: "cue-drafts"), grids = home.appending(path: "grid-drafts")
        let tags = home.appending(path: "tag-drafts"), gain = home.appending(path: "gain-drafts.json")
        let orphan = "orphan-cue-tag", other = "orphan-grid", gainOnly = "orphan-gain"
        try CueDraftStore.save(cue(spec.uuid, time: 1), directory: cues)
        try CueDraftStore.save(cue(orphan, time: 2), directory: cues)
        var tag = TagDraft(trackUUID: orphan, base: TagFields())
        tag.fields.title = "사라진 곡"
        try TagDraftStore.save(tag, directory: tags)
        try GridDraftStore.save(GridDraft(trackUUID: other, base: [], segments: [GridSegment(start: 1, bpm: 120, firstBeatNumber: 1)]),
                                directory: grids)
        try GainDraftStore.save(-2, trackUUID: gainOnly, url: gain)
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("unlinked"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { [writer] in writer.save($0, directory: tags) }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: home, writer: writer)
        await store.load(snapshot: fixture.database)
        // 읽기만으로는 아무것도 지우지 않는다.
        #expect(store.unlinkedDraftUUIDs == [orphan, other, gainOnly])
        #expect(CueDraftStore.load(trackUUID: orphan, directory: cues) != nil)
        let listed = Dictionary(uniqueKeysWithValues: store.unlinkedDrafts().map { ($0.uuid, $0) })
        #expect(listed[orphan]?.kinds == [.cue, .tag] && listed[orphan]?.title == "사라진 곡")
        #expect(listed[other]?.kinds == [.grid] && listed[gainOnly]?.kinds == [.gain])
        // 라이브러리에 있는 곡은 골라도 버리지 않는다.
        #expect(store.discardUnlinkedDrafts([orphan, gainOnly, spec.uuid]) == nil)
        #expect(CueDraftStore.load(trackUUID: orphan, directory: cues) == nil && TagDraftStore.load(trackUUID: orphan, directory: tags) == nil)
        #expect(GainDraftStore.load(trackUUID: gainOnly, url: gain) == nil)
        #expect(CueDraftStore.load(trackUUID: spec.uuid, directory: cues) != nil)
        #expect(GridDraftStore.load(trackUUID: other, directory: grids) != nil)
        #expect(store.unlinkedDraftUUIDs == [other])
    }

    // MARK: - XML 반영 확인(B50)

    @Test func 스냅샷에_없는_곡은_확인하지_못함으로_남기고_묶음을_비우지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let (store, _) = await makeStore(fixture)
        let missing = ReflectionPresenterTests.row("not-in-snapshot")
        let plan = Reflection.plan(track: missing.track, rawCues: [], cueDraft: cue(missing.track.uuid, time: 2), gridDraft: nil)
        store.reflectionBatch = ReflectionXMLBatch(createdAt: "2026-10-02 10:00:00", xmlPath: "/tmp/x.xml", plans: [plan], checks: [:])
        store.verifyReflection()
        #expect(store.reflectionBatch?.plans == [plan])
        #expect(store.testPorts.batches.load()?.plans == [plan])
        #expect(FileManager.default.fileExists(atPath: store.draftLocations.reflection.path), "저장소에 준 초안 폴더에 남긴다(사용자 폴더가 아니라)")
        #expect(store.reflectionMessage?.kind == .warning)
        #expect(store.reflectionMessage?.text.contains("확인하지 못함 1") == true)
    }
}
