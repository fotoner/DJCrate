import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 바깥(CLI `djc draft playlist`)에서 바꾼 재생 목록 초안을 켜져 있는 앱이 받는다(#260).
/// 받으면 그 앞의 라이브러리 ⌘Z 기록(태그·재생 목록)을 비운다. 옛 초안으로 만든 앱의 변경이 CLI 초안을 덮지 않는다.
@Suite("외부 재생 목록 초안 다시 읽기")
@MainActor
struct ExternalPlaylistDraftTests {
    nonisolated static let layout = PlaylistLayout([
        (PlaylistLayout.Item(id: "A", name: "합성 목록"), 1),
        (PlaylistLayout.Item(id: "B", name: "다른 목록"), 2),
    ])

    @MainActor
    struct Harness {
        let store: LibraryStore
        let undo = UndoManager()
        let file: URL

        init() {
            let home = FileManager.default.temporaryDirectory.appending(path: "djc-external-playlist-\(UUID().uuidString)")
            store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, draftHome: home,
                                      movesDamagedDrafts: false)
            store.undoManager = undo
            store.phase = .loaded
            store.playlists.rekordboxPlaylists = ExternalPlaylistDraftTests.layout
            store.playlists.refreshPlaylists()
            file = DraftLocations(home: home).playlist
        }

        /// CLI처럼 디스크 초안에 편집을 더해 저장한다
        func cli(_ edits: [PlaylistEdit]) throws -> PlaylistDraft {
            var draft = try PlaylistDraftStore.read(url: file)
            for edit in edits { try draft.append(edit, rekordbox: ExternalPlaylistDraftTests.layout) }
            try PlaylistDraftStore.save(draft, url: file)
            return draft
        }
    }

    @Test func 바깥에서_바꾼_초안을_받고_라이브러리_이력을_비운다() async throws {
        let h = Harness()
        h.store.playlists.renamePlaylist("A", to: "앱에서 바꾼 이름")
        #expect(h.undo.canUndo)
        let external = try h.cli([.delete(playlist: .id("B"))])
        await h.store.refreshExternalDrafts()
        #expect(h.store.playlists.playlistDraft == external)
        #expect(h.store.playlists.playlistItem("B") == nil && h.store.playlists.playlistItem("A")?.name == "앱에서 바꾼 이름")
        #expect(!h.undo.canUndo)
        // 다시 확인해도 같은 초안이면 그대로다
        await h.store.refreshExternalDrafts()
        #expect(h.store.playlists.playlistDraft == external)
    }

    @Test func 편집하기_전에_바깥_초안을_받고_그_위에_쌓는다() throws {
        let h = Harness()
        h.store.playlists.renamePlaylist("A", to: "첫 이름")
        _ = try h.cli([.delete(playlist: .id("B"))])
        // 1초 확인보다 먼저 편집해도 CLI 초안을 덮지 않는다
        h.store.playlists.renamePlaylist("A", to: "둘째 이름")
        let disk = try PlaylistDraftStore.read(url: h.file)
        #expect(disk == h.store.playlists.playlistDraft)
        // 같은 목록의 이름은 마지막 것만 남는다(초안 규칙)
        #expect(disk.edits == [.delete(playlist: .id("B")), .rename(playlist: .id("A"), name: "둘째 이름")])
    }

    @Test func 옛_초안으로_되돌리면_바깥_초안을_받고_되돌리지_않는다() throws {
        let h = Harness()
        h.store.playlists.renamePlaylist("A", to: "앱에서 바꾼 이름")
        let external = try h.cli([.delete(playlist: .id("B"))])
        h.undo.undo()
        #expect(h.store.playlists.playlistDraft == external)
        #expect(try PlaylistDraftStore.read(url: h.file) == external)
        #expect(h.store.playlists.playlistMessage?.kind == .warning)
        #expect(!h.undo.canUndo && !h.undo.canRedo)
    }

    @Test func 곡_추가를_연결하기_전에_바깥_초안을_받고_그_위에_쌓는다() throws {
        let h = Harness()
        h.store.playlists.playlistImports.addFiles(["/fixtures/a"], to: .id("A"))
        _ = try h.cli([.delete(playlist: .id("B"))])
        // 1초 확인보다 먼저 연결해도 메모리 초안으로 저장해 CLI 초안을 덮지 않는다
        h.store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "1"])
        let disk = try PlaylistDraftStore.read(url: h.file)
        #expect(disk == h.store.playlists.playlistDraft)
        #expect(disk.edits == [.delete(playlist: .id("B")), .addTracks(playlist: .id("A"), contentIDs: ["1"])])
    }

    @Test func 쓰는_동안_초안_파일을_잡고_그_전에_바깥_초안을_받는다() throws {
        let h = Harness()
        let external = try h.cli([.delete(playlist: .id("B"))])
        h.store.setWriteLock(true)
        // 1초 확인보다 먼저 쓰기를 시작해도 CLI 초안을 받은 뒤 쓴다
        #expect(h.store.playlists.playlistDraft == external)
        // 쓰는 동안 CLI는 초안 파일을 잡지 못한다(`draft_busy`)
        #expect(PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: h.file)) == nil)
        h.store.setWriteLock(false)
        let release = try #require(PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: h.file)))
        release()
    }

    @Test func 쓰기를_시작할_때_CLI가_잠금을_들고_있으면_풀린_뒤_잡는다() async throws {
        let h = Harness()
        let cli = try #require(PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: h.file)))
        h.store.setWriteLock(true)
        cli()
        // 쓰는 동안 다시 잡아 본다(한 번 못 잡았다고 쓰기 내내 잠금 없이 두지 않는다)
        var held = false
        for _ in 0..<100 where !held {
            try await Task.sleep(for: .milliseconds(20))
            held = h.store.playlistDraftUnlock != nil
        }
        #expect(held)
        #expect(PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: h.file)) == nil)
        h.store.setWriteLock(false)
        try await Task.sleep(for: .milliseconds(60))
        #expect(h.store.playlistDraftUnlock == nil)
        let release = try #require(PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: h.file)))
        release()
    }

    @Test func CLI가_잠금을_든_채_쓰기가_끝나면_풀린_뒤에도_잡지_않는다() async throws {
        let h = Harness()
        let cli = try #require(PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: h.file)))
        h.store.setWriteLock(true)
        #expect(h.store.playlistDraftUnlock == nil)
        h.store.setWriteLock(false)
        cli()
        // 다시 잡기는 쓰기가 끝났으면 멈춘다(잠금을 쥔 채 남지 않는다)
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.store.playlistDraftUnlock == nil)
        let release = try #require(PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: h.file)))
        release()
    }

    @Test func 저장하지_못한_메모리_초안과_읽지_못한_파일은_받지_않는다() async throws {
        let h = Harness()
        h.store.playlists.renamePlaylist("A", to: "앱에서 바꾼 이름")
        let memory = h.store.playlists.playlistDraft
        h.store.playlists.playlistDraftUnsaved = true
        _ = try h.cli([.delete(playlist: .id("B"))])
        await h.store.refreshExternalDrafts()
        #expect(h.store.playlists.playlistDraft == memory)

        h.store.playlists.playlistDraftUnsaved = false
        try Data("{망가진".utf8).write(to: h.file)
        await h.store.refreshExternalDrafts()
        #expect(h.store.playlists.playlistDraft == memory)
        #expect(h.undo.canUndo)
    }
}
