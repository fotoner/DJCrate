@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@MainActor
@Suite("재생 목록 초안 복구 흐름", .serialized)
struct PlaylistRecoveryTests {
    func makeStore(_ fixture: RekordboxFixture, save: @escaping (PlaylistDraft) throws -> Void = { _ in }) -> LibraryStore {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("recovery"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: save, playlistImportURL: nil, stagingSaver: { _ in },
                                 rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot)
        store.phase = .loaded
        return store
    }

    func prepare(_ fixture: RekordboxFixture, store: LibraryStore) throws -> PlaylistDraft {
        try fixture.add(tracks: [TrackSpec(id: "1"), TrackSpec(id: "2"), TrackSpec(id: "3")])
        try fixture.add(playlists: [PlaylistSpec(id: "A", name: "원래 목록", seq: 1, contentIDs: ["1", "2"]),
                                    PlaylistSpec(id: "B", name: "다른 목록", seq: 2)])
        let library = try RekordboxLibrary.load(snapshot: fixture.database)
        store.playlists.rekordboxPlaylists = PlaylistLayout(rekordbox: library.playlists)
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("A"), name: "내 이름"), rekordbox: store.playlists.rekordboxPlaylists)
        try draft.append(.rename(playlist: .id("B"), name: "다른 편집"), rekordbox: store.playlists.rekordboxPlaylists)
        store.playlists.playlistDraft = draft
        try fixture.execute("UPDATE djmdPlaylist SET Name = '외부 이름' WHERE ID = 'A'")
        try fixture.execute("UPDATE djmdPlaylist SET Name = '외부 다른 이름' WHERE ID = 'B'")
        store.playlists.rekordboxPlaylists = PlaylistLayout(rekordbox: try RekordboxLibrary.load(snapshot: fixture.database).playlists)
        store.playlists.refreshPlaylists()
        return draft
    }

    @Test func 비교와_취소는_그대로_두고_다시_적용은_저장과_미리_보기만_한다() async throws {
        let fixture = try RekordboxFixture()
        var saved: PlaylistDraft?
        let store = makeStore(fixture, save: { saved = $0 })
        let original = try prepare(fixture, store: store)
        let review = try await store.playlists.preparePlaylistRecovery(playlist: "A")
        #expect(store.playlists.playlistDraft == original && saved == nil)
        let details = RecoverySummary.playlistDetails(review)
        let line = RecoveryLine(request: .playlist("A"))
        #expect(line.label(for: .keep) == "다시 적용" && line.label(for: .useCurrent) == "초안 버리기")
        #expect(details.contains { $0.contains("외부 이름") })
        #expect(details.contains { $0.contains("내 이름") })
        try await store.playlists.applyPlaylistRecovery(review, reapply: true)
        #expect(saved == store.playlists.playlistDraft && store.playlists.blockedPlaylistEditCount == 1)
        #expect(store.playlists.playlistDraft.steps[1] == original.steps[1])
        let current = try RekordboxLibrary.load(snapshot: fixture.database)
        #expect(current.playlists.first { $0.id == "A" }?.name == "외부 이름")
        let preview = try RekordboxWriter.write(drafts: [], playlistDraft: store.playlists.playlistDraft, to: fixture.database,
                                              dryRun: true, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(preview.playlistWritten.count == 1 && preview.playlistBlocked.count == 1)
        #expect(try RekordboxLibrary.load(snapshot: fixture.database).playlists == current.playlists)
        // 다시 적용한 뒤의 재변경도 기존 쓰기 관문이 트랜잭션 안에서 막는다.
        try fixture.execute("UPDATE djmdPlaylist SET Name = 'さらに変更' WHERE ID = 'A'")
        let changed = try RekordboxWriter.write(drafts: [], playlistDraft: store.playlists.playlistDraft, to: fixture.database,
                                              dryRun: true, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(changed.playlistWritten.isEmpty)
        try fixture.execute("UPDATE djmdPlaylist SET Name = '외부 이름' WHERE ID = 'A'")
        let written = try RekordboxWriter.write(drafts: [], playlistDraft: store.playlists.playlistDraft, to: fixture.database,
                                              dryRun: false, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(written.playlistWritten.count == 1 && written.playlistBlocked.count == 1)
        let after = try RekordboxLibrary.load(snapshot: fixture.database)
        #expect(after.playlists.first { $0.id == "A" }?.name == "내 이름")
        #expect(after.playlists.first { $0.id == "B" }?.name == "외부 다른 이름")
    }

    @Test func 버리기는_선택한_막힌_편집만_지우고_다른_초안은_남긴다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture)
        let original = try prepare(fixture, store: store)
        let review = try await store.playlists.preparePlaylistRecovery(playlist: "A")
        try await store.playlists.applyPlaylistRecovery(review, reapply: false)
        #expect(store.playlists.playlistDraft.steps == [original.steps[1]])
        #expect(store.playlists.blockedPlaylistEditCount == 1)
    }

    @Test func 비교중_현재값_추가입력_저장실패는_원래_초안을_남긴다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture, save: { _ in throw CocoaError(.fileWriteNoPermission) })
        let original = try prepare(fixture, store: store)
        let review = try await store.playlists.preparePlaylistRecovery(playlist: "A")
        await #expect(throws: CocoaError.self) { try await store.playlists.applyPlaylistRecovery(review, reapply: true) }
        #expect(store.playlists.playlistDraft == original)
        try fixture.execute("UPDATE djmdPlaylist SET Name = '추가 변경' WHERE ID = 'A'")
        await #expect(throws: DJCError.self) { try await store.playlists.applyPlaylistRecovery(review, reapply: false) }
        #expect(store.playlists.playlistDraft == original)
        var newer = original
        try newer.append(.create(key: "new", name: "새 목록", isFolder: false, parent: .root), rekordbox: store.playlists.rekordboxPlaylists)
        store.playlists.playlistDraft = newer
        await #expect(throws: DJCError.self) { try await store.playlists.applyPlaylistRecovery(review, reapply: true) }
        #expect(store.playlists.playlistDraft == newer)
    }

    @Test func 목록은_그대로여도_넣을_곡이_사라지면_비교해_버릴_수_있다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture)
        try fixture.add(tracks: [TrackSpec(id: "1"), TrackSpec(id: "3")])
        try fixture.add(PlaylistSpec(id: "A", name: "합성 목록", seq: 1, contentIDs: ["1"]))
        let layout = PlaylistLayout(rekordbox: try RekordboxLibrary.load(snapshot: fixture.database).playlists)
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["3"]), rekordbox: layout)
        try fixture.execute("DELETE FROM djmdContent WHERE ID = '3'")
        store.playlists.rekordboxPlaylists = layout
        store.rowsByID = ["1": ReflectionPresenterTests.row("1")]
        store.playlists.playlistDraft = draft
        store.playlists.refreshPlaylists()
        #expect(store.playlists.blockedPlaylistRecoveryIDs == ["A"])
        let review = try await store.playlists.preparePlaylistRecovery(playlist: "A")
        #expect(review.recovery.reapplied.isEmpty && review.recovery.refused.count == 1)
        // 다시 적용할 편집이 없으면 시트 줄은 내 편집 유지를 고를 수 없고 초안 버리기만 고른다.
        let sheet = RecoverySheetModel(host: store, requests: [.playlist("A")])
        await sheet.load()
        let line = try #require(sheet.lines.first)
        #expect(line.options == [.useCurrent, .later] && line.choice == .later && !line.canKeep)
        try await store.playlists.applyPlaylistRecovery(review, reapply: false)
        #expect(store.playlists.playlistDraft.isEmpty)
    }

    @Test func 현재_목록에_새로_등록된_곡도_다시_적용한_화면에_보인다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture)
        _ = try prepare(fixture, store: store)
        store.rowsByID = Dictionary(uniqueKeysWithValues: ["1", "2", "3"].map { ($0, ReflectionPresenterTests.row($0)) })
        try fixture.add(TrackSpec(id: "4"))
        _ = try RekordboxWriter.write(drafts: [], playlists: [.addTracks(playlist: .id("A"), contentIDs: ["4"])],
                                     to: fixture.database, dryRun: false, backups: fixture.backups, shareRoot: fixture.shareRoot)
        store.sidebar = .playlist("A")
        let review = try await store.playlists.preparePlaylistRecovery(playlist: "A")
        try await store.playlists.applyPlaylistRecovery(review, reapply: true)
        #expect(store.displayRows.map(\.track.id) == ["1", "2", "4"])
    }

    @Test func 맨_위_목록_순서의_기준에는_사라진_부모를_표시하지_않는다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture)
        _ = try prepare(fixture, store: store)
        var draft = PlaylistDraft()
        try draft.append(.reorder(playlist: .id("A"), index: 1), rekordbox: store.playlists.rekordboxPlaylists)
        try fixture.add(PlaylistSpec(id: "C", name: "외부 새 목록", seq: 3))
        store.playlists.playlistDraft = draft
        store.playlists.rekordboxPlaylists = PlaylistLayout(rekordbox: try RekordboxLibrary.load(snapshot: fixture.database).playlists)
        store.playlists.refreshPlaylists()
        let review = try await store.playlists.preparePlaylistRecovery(playlist: "A")
        let details = RecoverySummary.playlistDetails(review)
        #expect(details.contains("함께 확인할 목록: 맨 위"))
        #expect(!details.contains("폴더: 사라진 목록"))
    }

    @Test func 비교화면에서_취소하면_쓰기와_저장이_없다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture, save: { _ in Issue.record("취소 뒤 저장") })
        let original = try prepare(fixture, store: store)
        // 시트를 열고 아무것도 고르지 않은 채 취소한다.
        let prompter = ScriptedPrompter()
        await ReflectionCoordinator.test(store: store, prompter: prompter).recover(requests: [.playlist("A")])
        #expect(store.playlists.playlistDraft == original && prompter.reviewed.count == 1 && prompter.shown.isEmpty)
    }
}
