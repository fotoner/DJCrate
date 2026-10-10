@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 사이드바·동기화 창의 iTunes 안내가 읽는 중과 읽기가 끝난 뒤를 구분하는지 본다.
/// 안내는 상태(`Status.message`)로 정해져 상태 코드를 비교한다. 문구는 String Catalog가 고정한다.
@MainActor
@Suite("iTunes 목록 안내 문구")
struct ITunesStatusLabelTests {
    private func store(_ fixture: RekordboxFixture) -> LibraryStore { store(root: fixture.root) }
    /// DB를 읽지 않는 시험은 임시 폴더만 준다(master.db 경로만 쓰고 파일은 만들지 않는다)
    private func store(root: URL) -> LibraryStore {
        let defaults = TestDefaults.make("itunes-status-label")
        return LibraryStore.test(settings: SettingsStore(defaults: defaults, persist: false),
                            resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                            backupDirectory: root.appending(path: "backups"), playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in },
                            playlistImportURL: nil, stagingSaver: { _ in }, draftHome: root.appending(path: "drafts"),
                            arguments: ["test", "--db", root.appending(path: "master.db").path], environment: [:])
    }

    @Test func 아직_읽기_전에는_미캡처가_아니라_진행_안내를_보인다() throws {
        #expect(store(root: try TemporaryFolder().url).music.library.status == .loading)
        #expect(SyncedITunesLibrary().status == .loading)
    }

    @Test func 동기화_창은_목록을_읽는_동안_미캡처로_안내하지_않는다() {
        #expect(ITunesSyncModel(ports: .closed).source.status == .loading)
    }

    @Test func 읽기가_끝난_명시적_사본은_미캡처_안내를_보인다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        if case .loaded = store.phase {} else { Issue.record("읽기가 끝나지 않았습니다") }
        #expect(store.music.library.status == .notCaptured)
    }

    @Test(arguments: [false, true])
    func 뒤에서_Music을_읽는_동안은_진행_안내를_보이고_끝나면_결과를_따른다(cancelled: Bool) async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        #expect(store.music.library.status == .notCaptured)

        let gate = DispatchSemaphore(value: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = try #require(store.music.startSimulatedRefresh(quiet: true) {
            signal.yield(())
            gate.waitOffPool()
            return ITunesLibrarySnapshot(status: .unavailable)
        })
        for await _ in started { break }
        #expect(store.music.library.status == .loading, "Music을 읽는 중인데 미캡처로 안내했습니다")
        if cancelled { task.cancel() }
        gate.signal()
        await task.value

        if cancelled {
            #expect(store.music.library.status == .notCaptured, "취소한 읽기가 진행 안내를 남겼습니다")
        } else {
            #expect(store.music.library.status == .unavailable)
            #expect(store.music.library.status != .loading)
        }
    }

    // MARK: 저장한 사본 호환

    @Test(arguments: ["ready", "stale", "notCaptured", "unavailable"])
    func 옛_사본의_상태_이름은_그대로_읽힌다(raw: String) throws {
        let folder = try TemporaryFolder()
        let json = #"{"version":1,"playlists":[],"status":"\#(raw)","unavailablePlaylistCount":0}"#
        try Data(json.utf8).write(to: ITunesLibrarySnapshot.url(for: folder.url.appending(path: "master.db")))
        let loaded = ITunesLibrarySnapshot.load(for: folder.url.appending(path: "master.db"))
        #expect(loaded.status.rawValue == raw)
        #expect((loaded.status.message == nil) == (raw == "ready"), "준비된 사본만 안내가 없다")
    }

    @Test func 사본_파일에_적힌_읽는_중은_읽지_못한_것으로_본다() throws {
        let folder = try TemporaryFolder()
        let json = #"{"version":1,"playlists":[],"status":"loading","unavailablePlaylistCount":0}"#
        try Data(json.utf8).write(to: ITunesLibrarySnapshot.url(for: folder.url.appending(path: "master.db")))
        #expect(ITunesLibrarySnapshot.load(for: folder.url.appending(path: "master.db")).status == .unavailable)
    }

    @Test func 사본_파일이_없으면_이전과_같이_미캡처다() throws {
        let folder = try TemporaryFolder()
        let loaded = ITunesLibrarySnapshot.load(for: folder.url.appending(path: "master.db"))
        #expect(loaded.status == .notCaptured)
    }
}
