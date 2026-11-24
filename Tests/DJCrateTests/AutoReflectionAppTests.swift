import DJCAdapters
import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

/// 자동 저장(#403)의 앱 쪽 연결: 쓰기 묶음을 만든 자리에서 재생 목록 단계를 얼려 쓰는 동안의 재생 목록 편집을 뒤에 쌓고(R21),
/// USB에 쓰는 동안 ⌘S를 이유와 함께 거절하며(R3 3번 줄), 앱 상태를 엔진의 보류 사유로 옮긴다(R16·R20).
@Suite("자동 저장 앱 연결")
@MainActor
struct AutoReflectionAppTests {
    static let rekordbox = PlaylistLayout([
        (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
        (PlaylistLayout.Item(id: "B", name: "나"), 2),
    ])

    /// 미리 보기를 멈춰 두는 곳(쓰는 동안의 화면을 본다)
    final class Latch: Sendable {
        private let state = Mutex<(arrived: Bool, waiting: CheckedContinuation<Void, Never>?)>((false, nil))
        var arrived: Bool { state.withLock { $0.arrived } }
        func wait() async {
            await withCheckedContinuation { continuation in state.withLock { $0 = (true, continuation) } }
        }
        func release() {
            state.withLock { state in
                state.waiting?.resume()
                state.waiting = nil
            }
        }
    }

    /// 재생 목록 단계 하나를 쓴 결과를 돌려주는 관문. 미리 보기는 풀어 줄 때까지 멈춘다
    static func gate(latch: Latch, written: PlaylistEdit) -> RekordboxWriteGate {
        let refused = DJCError.writeRefused("시험 관문")
        var made = RekordboxWriteReport(outcomes: [], backup: "/backups/w1", dryRun: false, createdAt: "", finalUpdateCount: 1)
        made.playlistOutcomes = [PlaylistOutcome(edit: written, playlistID: "B", name: "새 이름", status: .written)]
        let report = made
        return RekordboxWriteGate(write: { _, _, _, _ in report }, preview: { _, _, _, copied in
            await copied()
            await latch.wait()
            var preview = report
            preview.dryRun = true
            return preview
        }, restore: { _, _ in throw refused }, addTracks: { _, _, _ in throw refused }, deleteTracks: { _, _, _ in throw refused },
        restorePointSnapshot: { _, _, _, _, _ in throw refused }, writePlaylists: { _, _, _ in throw refused }, syncITunes: { _, _ in throw refused })
    }

    func store(draftOrigin: DraftOrigin = .unknown) -> LibraryStore {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-autosave-app-\(UUID().uuidString)")
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, draftHome: home, movesDamagedDrafts: false,
                                      takeLiveSnapshot: { _ in throw DJCError.snapshotNotFound }, draftOrigin: draftOrigin)
        store.phase = .loaded
        store.playlists.rekordboxPlaylists = Self.rekordbox
        store.playlists.refreshPlaylists()
        return store
    }

    /// R12(#405): 저장한 재생 목록 편집의 ⌘Z는 그 전 초안을 되살리지 않는다(쓴 단계를 다시 쌓지 않는다). 지금 보이는 목록이 그 편집 뒤 모양일 때만
    /// 거꾸로 하는 단계를 쌓는다. 여기서는 다시 읽기가 실패해 rekordbox 값이 옛 사본이라 거꾸로 할 모양이 아니다: 아무것도 쌓지 않는다
    @Test func 재생_목록_편집을_저장한_뒤의_실행_취소는_쓴_단계를_다시_쌓지_않는다() async throws {
        let store = store()
        let undo = UndoManager()
        store.undoManager = undo
        store.playlists.renamePlaylist("B", to: "새 이름")
        let written = try #require(store.playlists.playlistDraft.steps.first?.edit)
        #expect(undo.canUndo)
        let latch = Latch()
        latch.release()
        let coordinator = ReflectionCoordinator.test(store: store, gate: Self.gate(latch: latch, written: written))
        let writing = Task { await coordinator.write(rows: [], playlists: true) }
        for _ in 0..<2000 where !latch.arrived { try await Task.sleep(for: .milliseconds(5)) }
        latch.release()
        await writing.value
        #expect(store.playlists.playlistDraft.steps.isEmpty)
        undo.undo()
        #expect(store.playlists.playlistDraft.steps.isEmpty, "쓴 단계를 옛 초안으로 다시 쌓지 않는다")
    }

    @Test func 쓰는_동안_재생_목록_편집은_얼린_단계_뒤에_쌓이고_쓴_뒤에도_남는다() async throws {
        let store = store()
        store.playlists.renamePlaylist("B", to: "새 이름")
        let written = try #require(store.playlists.playlistDraft.steps.first?.edit)
        let latch = Latch()
        let coordinator = ReflectionCoordinator.test(store: store, gate: Self.gate(latch: latch, written: written))
        let writing = Task { await coordinator.write(rows: [], playlists: true) }
        for _ in 0..<2000 where !latch.arrived { try await Task.sleep(for: .milliseconds(5)) }
        #expect(latch.arrived)
        // 쓰기 묶음을 만든 자리에서 얼렸다: 쓰는 중이어도 재생 목록 편집을 받는다(R21)
        #expect(store.libraryBusy && !store.playlists.isEditBlocked)
        store.playlists.renamePlaylist("A", to: "새 가")
        #expect(store.playlists.playlistDraft.steps.map(\.edit) == [written, .rename(playlist: .id("A"), name: "새 가")])
        latch.release()
        await writing.value
        // 쓴 단계만 판으로 빼고 쓰는 동안 더한 단계는 남는다(R22)
        #expect(store.playlists.playlistDraft.steps.map(\.edit) == [.rename(playlist: .id("A"), name: "새 가")])
        #expect(try store.useCases.playlists.loadDraft().steps.map(\.edit) == [.rename(playlist: .id("A"), name: "새 가")])
    }

    @Test func iTunes_동기화_쓰기도_엔진의_차례를_받는다() async throws {
        let store = store()
        let calls = Mutex(0)
        var gate = RekordboxWriteGate.restoringOnly
        gate.syncITunes = { _, _ in
            calls.withLock { $0 += 1 }
            return Data()
        }
        let coordinator = ReflectionCoordinator.test(store: store, gate: gate)
        let home = try TemporaryFolder(prefix: "djc-autosave-itunes")
        let ports = AutoReflectionPorts(clock: .live, runState: { .stopped },
                                        quietStamps: { _ in LibraryQuietStamps(walSize: nil, shmExists: false, database: nil, playlistsXML: nil) },
                                        writeLock: .live(RekordboxWriteLocks(folder: home.url.appending(path: "locks"))),
                                        records: .live(home: home.url), pointSnapshot: { .satisfied }, appHolds: { [] })
        let engine = AutoReflection(session: coordinator.session, ports: ports, run: .off(.debugBuild))
        coordinator.engine = engine
        // 앞 쓰기(자동 저장·⌘S)가 쓰는 중이다
        let latch = Latch()
        let first = Task { await engine.exclusive { () async -> ReflectionOutcome in
            await latch.wait()
            return .declined
        } }
        for _ in 0..<2000 where !latch.arrived { try await Task.sleep(for: .milliseconds(5)) }
        let write = try #require(store.music.write)
        let sync = Task { try await write(ITunesSyncWrite(base: Data(), source: [], selection: ITunesSyncSelection(selectedIDs: []))) }
        for _ in 0..<200 where calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls.withLock { $0 } == 0, "앞 쓰기가 끝날 때까지 기다린다(쓰기 잠금·얼림을 겹쳐 풀지 않게)")
        latch.release()
        _ = await first.value
        _ = try await sync.value
        #expect(calls.withLock { $0 } == 1)
        withExtendedLifetime((coordinator, home)) {}
    }

    @Test func 백업_뒤_실패_표시가_실린_오류도_원래_오류의_문구를_보인다() {
        for error in [DJCError.queryFailed(sql: "COMMIT", message: "주입") as any Error, CocoaError(.fileWriteNoPermission), DJCError.writeRefused("이유")] {
            #expect(AppErrorMessage.message(for: RekordboxWriteGate.AfterBackupFailure(error)) == AppErrorMessage.message(for: error))
        }
    }

    @Test func 잠금_아래_판정을_못_한_저장은_rekordbox가_켜져_있으면_rekordbox_문구로_알린다() async throws {
        let store = store()
        var gate = RekordboxWriteGate.restoringOnly
        // 잠금을 잡았지만 rekordbox가 켜져 있어 기록을 판정하지 못한다(진행 중으로 본다)
        gate.journal = { _, _ in .inProgress }
        let coordinator = ReflectionCoordinator.test(store: store, running: true, gate: gate)
        let home = try TemporaryFolder(prefix: "djc-autosave-o19")
        let ports = AutoReflectionPorts(clock: .live, runState: { .running },
                                        quietStamps: { _ in LibraryQuietStamps(walSize: nil, shmExists: false, database: nil, playlistsXML: nil) },
                                        writeLock: .live(RekordboxWriteLocks(folder: home.url.appending(path: "locks"))),
                                        records: .live(home: home.url), pointSnapshot: { .satisfied }, appHolds: { [] })
        let engine = AutoReflection(session: coordinator.session, ports: ports, run: .off(.debugBuild))
        engine.start()
        coordinator.engine = engine
        for _ in 0..<2000 where !engine.isParked { try await Task.sleep(for: .milliseconds(5)) }
        await coordinator.write(rows: [], playlists: true)
        #expect(store.toast?.title == String(ui: "rekordbox가 켜져 있어 저장하지 않았습니다"), "\(String(describing: store.toast))")
        engine.stop()
        withExtendedLifetime((coordinator, home)) {}
    }

    @Test func 저장_거절_문구는_엔진이_메인_밖에서_본_실행_상태로_고른다() async throws {
        let store = store()
        var gate = RekordboxWriteGate.restoringOnly
        gate.journal = { _, _ in .inProgress }
        // 화면 쪽 실행 확인(프로세스 목록)은 부르지 않는다: 꺼졌다고 답해도 엔진이 본 켜짐으로 고른다
        let coordinator = ReflectionCoordinator.test(store: store, running: false, gate: gate)
        let home = try TemporaryFolder(prefix: "djc-autosave-s29")
        let ports = AutoReflectionPorts(clock: .live, runState: { .running },
                                        quietStamps: { _ in LibraryQuietStamps(walSize: nil, shmExists: false, database: nil, playlistsXML: nil) },
                                        writeLock: .live(RekordboxWriteLocks(folder: home.url.appending(path: "locks"))),
                                        records: .live(home: home.url), pointSnapshot: { .satisfied }, appHolds: { [] })
        let engine = AutoReflection(session: coordinator.session, ports: ports, run: .off(.debugBuild))
        engine.start()
        coordinator.engine = engine
        for _ in 0..<2000 where !engine.isParked { try await Task.sleep(for: .milliseconds(5)) }
        await coordinator.write(rows: [], playlists: true)
        #expect(store.toast?.title == String(ui: "rekordbox가 켜져 있어 저장하지 않았습니다"), "\(String(describing: store.toast))")
        engine.stop()
        withExtendedLifetime((coordinator, home)) {}
    }

    @Test func USB에_쓰는_동안_저장은_이유를_보이고_시작하지_않는다() {
        let store = store()
        let coordinator = ReflectionCoordinator.test(store: store, gate: .restoringOnly)
        coordinator.isWritingUsb = { true }
        coordinator.startWrite(rows: [])
        #expect(store.writeTask == nil)
        #expect(store.toast?.title == String(ui: "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요"))
    }

    @Test func 앱_상태를_자동_저장의_보류_사유로_옮긴다() {
        let store = store()
        let app = AppComposition(store: store, deck: DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false))
        #expect(app.autoReflection == nil, "화면 시험 조립은 엔진을 만들지 않는다")
        #expect(app.autoReflectionHolds().subtracting([.editing]).isEmpty)
        store.writeBlock = .counters
        store.phase = .loading("읽는 중")
        let holds = app.autoReflectionHolds()
        #expect(holds.contains(.unwritable(.counters)) && holds.contains(.libraryReading))
    }

    @Test func 실행_인자로_자동_저장_실행_조건을_정한다() {
        let location = LibraryLocation(rekordboxDirectory: URL(filePath: "/lib"), rekordboxDirectoryOverridden: false,
                                       snapshotDirectory: URL(filePath: "/snapshots"), opensExplicitCopy: true,
                                       explicitCopy: URL(filePath: "/opened/master.db"), database: URL(filePath: "/lib/master.db"),
                                       shareRoot: nil, backupDirectory: URL(filePath: "/backups"), draftHome: URL(filePath: "/drafts"),
                                       movesDamagedDrafts: false)
        let facts = AppComposition.autoReflectionFacts(arguments: ["djcrate", "--db=/opened/master.db"], environment: [:], location: location)
        #expect(facts.opensExplicitCopy && !facts.isDiagnosticRun && facts.selfTestPlaces == nil)
        #expect(AutoReflectionRun.decide(facts) == .off(.explicitCopy) || AutoReflectionRun.decide(facts) == .off(.debugBuild))
        // 자가 테스트 인자는 DJC_HOME이 없으면 확인 자리가 없어 쓰지 않는다
        let selfTest = AppComposition.autoReflectionFacts(arguments: ["djcrate", "--auto-reflect-selftest=save"], environment: [:], location: location)
        #expect(selfTest.selfTestPlaces == nil && !AutoReflectionRun.decide(selfTest).autoSaves)
    }

    /// 자가 테스트 자리 확인(R18·SAFE-8·SAFE-9): 쓰기 대상 DB 파일·분석 루트·DJC_HOME을 파일 단위로, 없는 경로는 가장 가까운 존재 조상까지 링크를
    /// 풀어 본다. 실제 자리 대신 임시 폴더의 "실제" 폴더를 준다(이 Mac의 라이브러리·사용자 폴더를 건드리지 않는다)
    enum UnsafePlace: CaseIterable { case databaseLink, shareLink, pioneerLink, homeUnderLink, shareMissing }

    @Test(arguments: [nil] + UnsafePlace.allCases.map(Optional.some))
    func 자가_테스트_자리는_DB_파일_링크와_상위_폴더_링크와_없는_DJC_HOME_아래_링크를_거른다(_ unsafe: UnsafePlace?) throws {
        let folder = try TemporaryFolder(prefix: "djc-selftest-places")
        let root = folder.url, files = FileManager.default
        let live = root.appending(path: "live/rekordbox"), userData = root.appending(path: "userdata")
        let copy = root.appending(path: "copy/rekordbox")
        for dir in [live.appending(path: "share/PIONEER/USBANLZ"), userData, copy] {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data().write(to: live.appending(path: "master.db"))
        var home = root.appending(path: "home")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        switch unsafe {
        case .shareMissing: break
        case .shareLink:
            try files.createSymbolicLink(at: copy.appending(path: "share"), withDestinationURL: live.appending(path: "share"))
        case .pioneerLink:
            try files.createDirectory(at: copy.appending(path: "share"), withIntermediateDirectories: true)
            try files.createSymbolicLink(at: copy.appending(path: "share/PIONEER"), withDestinationURL: live.appending(path: "share/PIONEER"))
        default:
            try files.createDirectory(at: copy.appending(path: "share/PIONEER/USBANLZ"), withIntermediateDirectories: true)
        }
        if unsafe == .databaseLink {
            try files.createSymbolicLink(at: copy.appending(path: "master.db"), withDestinationURL: live.appending(path: "master.db"))
        } else {
            try Data().write(to: copy.appending(path: "master.db"))
        }
        if unsafe == .homeUnderLink {
            // 아직 없는 DJC_HOME의 조상이 사용자 폴더를 가리키는 링크다
            try files.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: userData)
            home = root.appending(path: "linked/sub/home")
        }
        let location = LibraryLocation(rekordboxDirectory: copy, rekordboxDirectoryOverridden: true, snapshotDirectory: root.appending(path: "snapshots"),
                                       opensExplicitCopy: false, explicitCopy: nil, database: copy.appending(path: "master.db"), shareRoot: nil,
                                       backupDirectory: home.appending(path: "rekordbox-backups"), draftHome: home, movesDamagedDrafts: false)
        let places = try #require(AppComposition.selfTestPlaces(location: location, environment: ["DJC_HOME": home.path], live: live,
                                                                userData: userData))
        #expect(places.allowsWriting == (unsafe == nil), "\(String(describing: unsafe)): \(places)")
    }

    // MARK: - 곡 넣기 뒤 정리(R22, 합성 DB·실제 관문)

    /// 정리 전에 멈춤: 관문이 미정리 목록을 적고 쓰기 기록을 지운 직후 멈춘다(넣은 뒤 처리가 돌지 않는다). 다시 켜 첫 읽기 뒤 재시작 정리가 같은 결과를 낸다
    @Test(arguments: [false, true])
    func 넣는_동안_CLI가_더한_핫큐는_새_곡의_제안으로_남고_저장하면_A_하나와_B가_된다(stopsBeforeCleanup: Bool) async throws {
        let fixture = try RekordboxFixture()
        _ = try fixture.add(TrackSpec())   // 라이브러리 공통값을 가져올 기존 곡
        let home = fixture.root.appending(path: "drafts", directoryHint: .isDirectory)
        let staged = try JSONDecoder().decode(StagedTrack.self, from: Data("""
            {"uuid":"\(UUID().uuidString)","path":"\(try TestResources.url("mp3-notag-cbr.mp3").path)","title":"합성 추가 곡","comment":"","duration":2,"addedOn":"2026-10-01"}
            """.utf8))
        let hotA = EditableCue(id: UUID(), kind: .hot(0), time: 0.5), hotB = EditableCue(id: UUID(), kind: .hot(1), time: 1.0)
        var first = CueDraft(trackUUID: staged.uuid)
        first.place(hotA)
        var later = first
        later.place(hotB)
        // 넣는 동안(관문이 넣기 직전) CLI가 같은 초안 폴더에 B를 더한 새 판을 저장한다
        let cli = DraftStore.live(writer: DraftWriter(), home: home, origin: .cli)
        let stopped = Mutex(false)
        var writeGuard = RekordboxWriteGuard.system
        writeGuard.hooks = RekordboxWriteHooks(checkpoint: { moment in
            guard stopsBeforeCleanup, moment == .after(.journalRemove), !stopped.withLock({ $0 }) else { return }
            stopped.withLock { $0 = true }
            throw RekordboxWriteStop()
        })
        var gate = RekordboxWriteGate.live(guard: writeGuard)
        let realAdd = gate.addTracks
        gate.addTracks = { [later] batch, target, dryRun in
            if !dryRun {
                cli.saveCue(later)
                cli.flush()
            }
            return try realAdd(batch, target, dryRun)
        }
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("autosave-add"), persist: false),
                                      activityLog: ActivityLog(url: nil), backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                      mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in }, draftHome: home,
                                      writeGate: gate, rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                      arguments: ["test"], environment: [:], takeLiveSnapshot: { [database = fixture.database] _ in database })
        await store.load(snapshot: fixture.database)
        store.staging.staged = [staged]
        store.testDrafts.saveCue(first)
        store.testDrafts.flush()
        let preview = try await store.session.previewAdd(rows: [TrackRow(track: staged.track, cues: [], playCount: 0)])
        let id: String, uuid: String
        if stopsBeforeCleanup {
            await #expect(throws: RekordboxWriteStop.self) {
                try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
            }
            #expect(try RekordboxWriter.cleanupLists(in: fixture.backups).count == 1, "목록만 남고 정리하지 않았다")
            // 다시 켠 뒤 첫 읽기와 재시작 정리
            await store.load(snapshot: fixture.database)
            let resumed = await store.session.resumeCleanups()
            #expect(resumed.holds.isEmpty && resumed.finished == 1)
            let row = try #require(try fixture.rows("SELECT ID, UUID FROM djmdContent WHERE FolderPath = ?", [.text(staged.path)]).first)
            id = try #require(row["ID"])
            uuid = try #require(row["UUID"])
        } else {
            let report = try await store.session.addTracksToRekordbox(preview, to: fixture.database, shareRoot: fixture.shareRoot)
            let outcome = try #require(report.added.first)
            id = try #require(outcome.contentID)
            uuid = try #require(outcome.uuid)
            #expect(outcome.cuesWritten == 1)
        }
        #expect(try fixture.rows("SELECT ID FROM djmdCue WHERE ContentID = ?", [.text(id)]).count == 1, "넣기는 A만 썼다")
        // 새 판은 새 곡의 제안으로 남고 옛 UUID에는 남지 않는다
        let moved = try #require(store.testDrafts.cueDraft(uuid))
        #expect(moved.changes.count == 1 && store.testDrafts.suggestion(DraftKey(.cue, uuid)) != nil)
        #expect(store.testDrafts.cueDraft(staged.uuid) == nil)
        #expect(try RekordboxWriter.cleanupLists(in: fixture.backups).isEmpty, "정리를 마치고 미정리 목록을 지웠다")
        // 새 곡에서 ⌘S: 제안도 함께 쓴다. A 하나와 B가 된다
        await store.refreshExternalDrafts()
        let row = try #require(store.rowsByUUID[uuid])
        let written = await store.session.write(rows: [row])
        guard case .written = written else { Issue.record("저장했다: \(written)"); return }
        let cues = try fixture.rows("SELECT Kind FROM djmdCue WHERE ContentID = ? ORDER BY Kind", [.text(id)])
        #expect(cues.map { $0["Kind"] } == ["1", "2"])
    }
}
