import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// #182: 앱의 복원은 저장소가 쓰는 그 DB로만 되돌린다. 기본 라이브 DB로 새면 시험이 실제 라이브러리를 덮는다.
@MainActor
@Suite("복원 대상", .serialized)
struct RestoreTargetTests {
    func makeStore(_ fixture: RekordboxFixture) async -> LibraryStore {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("restore-target"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: fixture.root.appending(path: "drafts"), rekordboxDatabase: fixture.database,
                                 rekordboxShareRoot: fixture.shareRoot, arguments: ["test"], environment: [:],
                                 takeLiveSnapshot: { [database = fixture.database] _ in database })
        await store.load(snapshot: fixture.database)
        return store
    }

    func cueCount(_ fixture: RekordboxFixture) throws -> Int {
        Int(try fixture.rows("SELECT count(*) AS n FROM djmdCue WHERE rb_local_deleted = 0").first?["n"] ?? "") ?? -1
    }

    @Test func 복원은_쓴_사본으로_되돌리고_기본_라이브_자리는_건드리지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let spec = try fixture.add(TrackSpec())
        let store = await makeStore(fixture)
        var draft = CueDraft(trackUUID: spec.uuid)
        draft.place(EditableCue(kind: .memory, time: 4))
        store.testDrafts.saveCue(draft)
        store.testDrafts.flush()
        defer {
            store.testDrafts.removeCue(spec.uuid)
            store.testDrafts.flush()
        }
        _ = try await store.session.writeToRekordbox([draft])
        #expect(try cueCount(fixture) == 1)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first(where: { $0.isWrite }))
        try await store.session.restoreRekordbox(backup, keepingCurrentDrafts: true)
        #expect(try cueCount(fixture) == 0)
        #expect(!FileManager.default.fileExists(atPath: RekordboxWriter.liveDatabase.path))
    }
}
