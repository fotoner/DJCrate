@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import UniformTypeIdentifiers
import DJCStorage
import DJCTestKit
@testable import RekordboxKit
import Foundation
import Testing

@MainActor
@Suite("곡 추가와 목록 초안 연결")
struct PlaylistImportIntegrationTests {
    func store(saver: @escaping (PlaylistDraft) throws -> Void = { _ in }) -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("imports"), persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: saver,
                     playlistImportURL: nil, stagingSaver: { _ in })
    }

    @Test func 목록을_반영하면_새_ID로_연결하고_되돌리면_초안_키로_돌린다() throws {
        let store = store()
        store.playlists.playlistImports.addFiles(["/fixtures/a", "/fixtures/b"], to: .new("P"))
        try store.playlists.playlistDraft.append(.create(key: "P", name: "세트", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "1"])
        let written = store.playlists.playlistDraft
        store.finishPlaylistWrite(written, outcomes: written.edits.map {
            PlaylistOutcome(edit: $0, playlistID: "real", name: "세트", status: .written)
        })
        #expect(store.playlists.playlistImports.requests.first?.target == .id("real"))
        store.playlists.restorePlaylistEdits(written.edits)
        #expect(store.playlists.playlistImports.requests.first?.target == .new("P"))
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "1", "/fixtures/b": "2"])
        #expect(store.playlists.playlistDraft.project(onto: PlaylistLayout()).layout.item("new:P")?.trackIDs == ["1", "2"])
    }

    @Test func 곡_추가를_되돌리면_그_곡의_목록_초안도_다시_등록을_기다린다() throws {
        let store = store()
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.playlistImports.addFiles(["/fixtures/a", "/fixtures/b"], to: .id("P"))
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "1", "/fixtures/b": "2"])
        store.resetPlaylistImports(contentIDs: ["1"])
        #expect(store.playlists.playlistImports.pendingCount == 1)
        #expect(store.playlists.playlistDraft.project(onto: store.playlists.rekordboxPlaylists).layout.item("P")?.trackIDs == ["2"])
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "3", "/fixtures/b": "2"])
        #expect(store.playlists.playlistDraft.project(onto: store.playlists.rekordboxPlaylists).layout.item("P")?.trackIDs == ["3", "2"])
    }

    @Test func 부분_반영을_되돌려도_남은_순서_초안의_자리_번호가_맞는다() {
        let store = store()
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.playlistImports.addFiles(["/fixtures/a", "/fixtures/b"], to: .id("P"))
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/b": "2"])
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "1", "/fixtures/b": "2"])
        store.resetPlaylistImports(contentIDs: ["2"])
        let projection = store.playlists.playlistDraft.project(onto: store.playlists.rekordboxPlaylists)
        #expect(projection.blocked.compactMap { $0 }.isEmpty)
        #expect(projection.layout.item("P")?.trackIDs == ["1"])
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "1", "/fixtures/b": "3"])
        #expect(store.playlists.playlistDraft.project(onto: store.playlists.rekordboxPlaylists).layout.item("P")?.trackIDs == ["1", "3"])
    }

    @Test func 파일_URL_드롭을_읽어_대상_목록에_연결한다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-drop-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try AudioFixture.wav(seconds: 0.1, in: home)
        let store = store()
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.refreshPlaylists()
        store.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: file.path, title: "합성 곡", duration: 0.1, addedOn: "2026-09-27")]
        let provider = NSItemProvider(object: file as NSURL)
        let node = try #require(store.playlists.playlistIndex["P"])
        #expect(PlaylistDrop.perform([provider], on: node, store: store))
        for _ in 0..<100 where store.playlists.playlistImports.pendingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.playlists.playlistImports.pendingCount == 1)
        #expect(store.playlists.playlistImports.requests.first?.target == .id("P"))
    }

    @Test func 연결_파일을_저장하지_못했을_때_성공으로_안내하지_않는다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-import-failure-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try AudioFixture.wav(seconds: 0.1, in: home)
        let destination = home.appending(path: "blocked")
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                 playlistDraftSaver: { _ in }, playlistImportURL: destination, stagingSaver: { _ in })
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.refreshPlaylists()
        store.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: file.path, title: "합성 곡", duration: 0.1, addedOn: "2026-09-27")]
        await store.addFiles([file], toPlaylist: "P")
        #expect(store.stagingMessage?.kind == .failure)
        #expect(store.playlists.playlistImports.requests.isEmpty)
    }

    @Test func 초안을_저장하지_못하면_연결을_소비하지_않는다() {
        let store = store { _ in throw CocoaError(.fileWriteNoPermission) }
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.playlistImports.addFiles(["/fixtures/a"], to: .id("P"))
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "1"])
        #expect(store.playlists.playlistDraft.isEmpty && store.playlists.playlistImports.pendingCount == 1)
        #expect(store.playlists.playlistMessage?.kind == .warning)
    }

    @Test func 이미_추가한_파일도_목록_연결을_기억하고_컬렉션_등록_뒤에만_초안을_만든다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-import-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try AudioFixture.wav(seconds: 0.1, in: home)
        let store = store()
        store.phase = .loaded
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.refreshPlaylists()
        store.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: file.path, title: "합성 곡", duration: 0.1, addedOn: "2026-09-27")]
        await store.addFiles([file], toPlaylist: "P")
        #expect(store.playlists.playlistDraft.isEmpty && store.playlists.playlistImports.pendingCount == 1)
        #expect(store.staged.count == 1)
        store.playlists.resolvePlaylistImports(contentIDsByPath: [PlaylistImports.pathKey(file.path): "1"])
        #expect(store.playlists.playlistDraft.edits == [.addTracks(playlist: .id("P"), contentIDs: ["1"])])
        #expect(store.playlists.playlistImports.pendingCount == 0)
    }

    @Test func 반영_중이거나_폴더인_대상에는_파일을_추가하지_않는다() async {
        let store = store()
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "F", name: "폴더", isFolder: true), 1)])
        store.playlists.refreshPlaylists()
        await store.addFiles([], toPlaylist: "F")
        #expect(store.stagingMessage == nil && store.playlists.playlistImports.requests.isEmpty)
        store.isWritingRekordbox = true
        await store.addFiles([])
        #expect(store.stagingMessage == nil)
    }

    @Test func 가져오기_선택을_끄면_출처만_기억하고_목록은_만들지_않는다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-import-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try AudioFixture.wav(seconds: 0.1, in: home)
        let store = store()
        store.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: file.path, title: "합성 곡", duration: 0.1, addedOn: "2026-09-27")]
        let origin = AppleMusicOrigin(libraryID: "L", trackID: 1, playlists: [.init(id: "P", name: "세트", parentID: nil, position: 0)])
        await store.addFiles([file], appleMusicOrigins: [PlaylistImports.pathKey(file.path): [origin]])
        #expect(store.staged.first?.appleMusicOrigins == [origin])
        #expect(store.playlists.playlistImports.requests.isEmpty)
        await store.addFiles([file], appleMusicOrigins: [PlaylistImports.pathKey(file.path): [origin]], createPlaylists: true)
        #expect(store.playlists.playlistImports.pendingCount == 1 && store.playlists.playlistDraft.isEmpty)
    }
}
