@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 종료를 기다리는 중이면 쓴 뒤 다시 읽기를 미루고(#305), 종료를 취소하면 한 번 이어서 읽는다.
/// 세션이 미룰지 묻는 흐름은 DJCApplicationTests `ReflectionSessionPostponeTests`가 보고, 여기서는 앱 쪽 연결을 합성 사본으로 본다.
@MainActor
@Suite("종료 대기 중 미룬 다시 읽기", .serialized)
struct QuitPostponedReloadTests {
    struct ReloadFailure: Error {}

    final class Calls: @unchecked Sendable { var written: [Set<String>] = [] }

    /// 시험마다 새 저장 큐(저장소와 시험이 같은 큐를 본다)
    let writer = DraftWriter()

    func makeStore(_ fixture: RekordboxFixture) async -> (LibraryStore, Calls) {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("quit-postponed"), persist: false),
                                      activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }),
                                      backupDirectory: fixture.backups,
                                      playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                      draftHome: fixture.root.appending(path: "drafts"),
                                      rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                      arguments: ["test"], environment: [:],
                                      takeLiveSnapshot: { [database = fixture.database] _ in database }, writer: writer)
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

    /// 합성 사본에 곡 하나와 큐 초안 하나를 두고 쓴다(앱과 같은 연결의 세션)
    func write(_ store: LibraryStore, _ fixture: RekordboxFixture, uuid: String) async throws {
        let draft = cue(uuid, time: 4)
        writer.save(draft, directory: store.draftLocations.cue)
        writer.flush()
        _ = try await store.session.writeToRekordbox([draft], to: fixture.database, shareRoot: fixture.shareRoot)
    }

    // MARK: - 종료를 기다리지 않을 때

    @Test func 종료를_기다리지_않으면_쓴_뒤_바로_다시_읽는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        let before = store.completedLoadCount
        try await write(store, fixture, uuid: spec.uuid)
        #expect(store.completedLoadCount == before + 1 && calls.written == [[spec.uuid]])
        #expect(!store.reloadPostponedForQuit && store.writtenAwaitingReload.isEmpty)
    }

    // MARK: - 종료를 기다리는 중

    @Test func 종료를_기다리는_중이면_쓴_뒤_읽지_않고_덱에_알릴_곡만_기억해_둔다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        store.quitWait.begin(at: Date(timeIntervalSince1970: 0), onCancel: {})
        let before = store.completedLoadCount
        try await write(store, fixture, uuid: spec.uuid)
        // 쓰기는 끝났고(DB에 큐가 있다) 읽지는 않았다
        #expect(store.completedLoadCount == before && calls.written.isEmpty)
        #expect(store.reloadPostponedForQuit && store.writtenAwaitingReload == [spec.uuid])
        // 읽지 못한 것이 아니라 미룬 것이라 다시 읽기 실패 경고가 붙지 않는다
        #expect(store.writeFollowUp.isEmpty && store.lastError == nil)
    }

    @Test func 종료를_취소하면_미룬_읽기를_한_번_이어서_하고_덱에_알린다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        store.quitWait.begin(at: Date(timeIntervalSince1970: 0), onCancel: {})
        let before = store.completedLoadCount
        try await write(store, fixture, uuid: spec.uuid)
        store.quitWait.finish()
        // 취소 알림이 두 번 와도 읽기는 한 번이다
        let first = store.quitCancelled()
        let second = store.quitCancelled()
        #expect(first != nil && second == nil)
        await first?.value
        #expect(store.completedLoadCount == before + 1)
        #expect(calls.written == [[spec.uuid]] && store.writtenAwaitingReload.isEmpty && !store.reloadPostponedForQuit)
        // 새 스냅샷의 큐가 목록에 들어왔다
        #expect(store.rowsByUUID[spec.uuid]?.cues.contains { $0.inMsec == 4000 } == true)
        // 이미 이어서 읽었으니 다시 불러도 읽지 않는다
        #expect(store.quitCancelled() == nil && store.completedLoadCount == before + 1)
    }

    @Test func 이어_읽는_동안은_쓰기_잠금_안이라_다음_쓰기와_겹치지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, _) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        store.quitWait.begin(at: Date(timeIntervalSince1970: 0), onCancel: {})
        try await write(store, fixture, uuid: spec.uuid)
        store.quitWait.finish()
        #expect(!store.libraryBusy)
        let resumed = store.quitCancelled()
        // 평소 쓴 뒤 다시 읽기처럼 잠금 안에서 읽는다. 그동안 새 쓰기·초안 복구가 시작되지 않고(`libraryBusy`), 종료 판정은 다시 읽는 단계로 본다
        #expect(resumed != nil && store.libraryBusy && store.writeStage?.readsBack == true)
        await resumed?.value
        #expect(!store.libraryBusy && store.writeStage == nil)
    }

    @Test func 종료로_끝나는_중이면_미룬_읽기를_시작하지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        store.quitWait.begin(at: Date(timeIntervalSince1970: 0), onCancel: {})
        let before = store.completedLoadCount
        try await write(store, fixture, uuid: spec.uuid)
        // 쓰기 잠금이 풀려도 종료를 기다리는 중이면(곧 종료한다) 읽지 않는다
        store.setWriteLock(true)
        store.setWriteLock(false)
        #expect(store.resumePostponedReload() == nil)
        await drainMainActor()
        #expect(store.completedLoadCount == before && calls.written.isEmpty && store.reloadPostponedForQuit)
    }

    @Test func 쓰기_잠금이_걸린_채_종료를_취소하면_잠금이_풀릴_때_한_번_읽는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        store.setWriteLock(true)
        store.quitWait.begin(at: Date(timeIntervalSince1970: 0), onCancel: {})
        let before = store.completedLoadCount
        try await write(store, fixture, uuid: spec.uuid)
        store.quitWait.finish()
        // 아직 쓰는 중이라 읽지 않는다(쓰기와 읽기가 겹치지 않게)
        #expect(store.quitCancelled() == nil && store.completedLoadCount == before)
        store.setWriteLock(false)
        #expect(await waitForState { store.completedLoadCount == before + 1 })
        await drainMainActor()
        #expect(store.completedLoadCount == before + 1 && calls.written == [[spec.uuid]])
    }

    // MARK: - 종료 입구(AppDelegate)와 이어서

    /// [종료 취소]는 컨트롤러가 종료를 취소로 끝내며 `terminationCancelled`를 불러 저장소에 알린다(AppDelegate 연결).
    @Test func 종료_입구에서_취소하면_저장소가_미룬_읽기를_잠금이_풀릴_때_이어서_한다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        let delegate = AppDelegate()
        var terminations = 0
        delegate.terminateApp = { terminations += 1 }
        delegate.store = store
        store.isPoweringOff = false
        store.setWriteLock(true)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(store.quitWait.isWaiting)
        let before = store.completedLoadCount
        try await write(store, fixture, uuid: spec.uuid)
        #expect(store.completedLoadCount == before && store.reloadPostponedForQuit)
        // 사용자가 [종료 취소]를 눌렀다
        store.quitWait.cancel()
        #expect(!store.quitWait.isWaiting && store.completedLoadCount == before)
        store.writeStage = nil
        store.setWriteLock(false)
        #expect(await waitForState { store.completedLoadCount == before + 1 })
        await drainMainActor()
        #expect(store.completedLoadCount == before + 1 && calls.written == [[spec.uuid]] && terminations == 0)
    }

    /// 쓰기 잠금이 풀린 직후(앱이 종료를 다시 요청하기 전) [종료 취소]가 들어오는 틈: 취소가 미룬 읽기를 바로 이어서 한 번 한다.
    @Test func 쓰기가_끝난_직후_종료를_취소해도_미룬_읽기를_한_번_이어서_한다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, calls) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        let delegate = AppDelegate()
        var terminations = 0
        delegate.terminateApp = { terminations += 1 }
        delegate.store = store
        store.setWriteLock(true)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        let before = store.completedLoadCount
        try await write(store, fixture, uuid: spec.uuid)
        store.writeStage = nil
        store.setWriteLock(false)
        // 잠금은 풀렸지만 종료 기다림은 아직 풀리지 않았다(앱이 다시 요청하기 전). 이때 취소가 들어온다
        #expect(store.quitWait.isWaiting && store.completedLoadCount == before)
        store.quitWait.cancel()
        #expect(await waitForState { store.completedLoadCount == before + 1 })
        await drainMainActor()
        #expect(store.completedLoadCount == before + 1 && calls.written == [[spec.uuid]] && terminations == 0)
    }

    @Test func 종료_입구에서_쓰기가_끝나면_읽지_않고_종료를_다시_요청한다() async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let (store, _) = await makeStore(fixture)
        defer { clear(spec.uuid, in: store) }
        let delegate = AppDelegate()
        var terminations = 0
        delegate.terminateApp = { terminations += 1 }
        delegate.store = store
        store.setWriteLock(true)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        let before = store.completedLoadCount
        try await write(store, fixture, uuid: spec.uuid)
        // 쓰기 결과를 남긴 뒤 잠금이 풀리면 앱이 종료를 다시 요청한다. 읽기는 하지 않는다
        store.writeStage = nil
        store.setWriteLock(false)
        #expect(await waitForState { terminations == 1 })
        await drainMainActor()
        #expect(store.completedLoadCount == before && store.reloadPostponedForQuit)
    }
}
