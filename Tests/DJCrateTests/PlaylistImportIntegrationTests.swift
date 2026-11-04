@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import UniformTypeIdentifiers
import DJCStorage
import DJCTestKit
import RekordboxFixtures
@testable import RekordboxKit
import Foundation
import Testing

@MainActor
@Suite("곡 추가와 목록 초안 연결")
struct PlaylistImportIntegrationTests {
    func store(saver: @escaping (PlaylistDraft) throws -> Void = { _ in }) -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("imports"), persist: false),
                     activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: saver,
                     playlistImportURL: nil, stagingSaver: { _ in })
    }

    @Test func 목록을_반영하면_새_ID로_연결하고_되돌리면_초안_키로_돌린다() throws {
        let store = store()
        store.playlists.playlistImports.addFiles(["/fixtures/a", "/fixtures/b"], to: .new("P"))
        try store.playlists.playlistDraft.append(.create(key: "P", name: "세트", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
        // 앱 편집처럼 저장한다: 연결 전 바깥 초안 확인(#260)이 저장하지 않은 메모리 초안을 디스크 초안으로 바꾸지 않게
        store.playlists.savePlaylistDraft()
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
        store.staging.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: file.path, title: "합성 곡", duration: 0.1, addedOn: "2026-09-27")]
        let provider = NSItemProvider(object: file as NSURL)
        let node = try #require(store.playlists.playlistIndex["P"])
        #expect(PlaylistDrop.perform([provider], on: node, store: store, sidebar: PlaylistSidebarModel(playlists: store.playlists)))
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
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in },
                                 playlistDraftSaver: { _ in }, playlistImportURL: destination, stagingSaver: { _ in })
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.refreshPlaylists()
        store.staging.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: file.path, title: "합성 곡", duration: 0.1, addedOn: "2026-09-27")]
        await store.staging.addFiles([file], toPlaylist: "P")
        #expect(store.activityLog.latest?.kind == .failure)
        #expect(store.playlists.playlistImports.requests.isEmpty)
    }

    @Test func 초안을_저장하지_못하면_연결을_소비하지_않는다() {
        let store = store { _ in throw CocoaError(.fileWriteNoPermission) }
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.playlistImports.addFiles(["/fixtures/a"], to: .id("P"))
        store.playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "1"])
        #expect(store.playlists.playlistDraft.isEmpty && store.playlists.playlistImports.pendingCount == 1)
        #expect(store.activityLog.latest?.kind == .warning)
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
        store.staging.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: file.path, title: "합성 곡", duration: 0.1, addedOn: "2026-09-27")]
        await store.staging.addFiles([file], toPlaylist: "P")
        #expect(store.playlists.playlistDraft.isEmpty && store.playlists.playlistImports.pendingCount == 1)
        #expect(store.staging.staged.count == 1)
        store.playlists.resolvePlaylistImports(contentIDsByPath: [PlaylistImports.pathKey(file.path): "1"])
        #expect(store.playlists.playlistDraft.edits == [.addTracks(playlist: .id("P"), contentIDs: ["1"])])
        #expect(store.playlists.playlistImports.pendingCount == 0)
    }

    @Test func 반영_중이거나_폴더인_대상에는_파일을_추가하지_않는다() async {
        let store = store()
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "F", name: "폴더", isFolder: true), 1)])
        store.playlists.refreshPlaylists()
        await store.staging.addFiles([], toPlaylist: "F")
        #expect(store.activityLog.entries.isEmpty && store.playlists.playlistImports.requests.isEmpty)
        store.isWritingRekordbox = true
        await store.staging.addFiles([])
        #expect(store.activityLog.entries.isEmpty)
    }

    @Test func 가져오기_선택을_끄면_출처만_기억하고_목록은_만들지_않는다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-import-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try AudioFixture.wav(seconds: 0.1, in: home)
        let store = store()
        store.staging.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: file.path, title: "합성 곡", duration: 0.1, addedOn: "2026-09-27")]
        let origin = AppleMusicOrigin(libraryID: "L", trackID: 1, playlists: [.init(id: "P", name: "세트", parentID: nil, position: 0)])
        await store.staging.addFiles([file], appleMusicOrigins: [PlaylistImports.pathKey(file.path): [origin]])
        #expect(store.staging.staged.first?.appleMusicOrigins == [origin])
        #expect(store.playlists.playlistImports.requests.isEmpty)
        await store.staging.addFiles([file], appleMusicOrigins: [PlaylistImports.pathKey(file.path): [origin]], createPlaylists: true)
        #expect(store.playlists.playlistImports.pendingCount == 1 && store.playlists.playlistDraft.isEmpty)
    }

    // MARK: - 놓은 새 곡이 추가가 끝난 뒤 목록 초안에 들어간다(#335)

    /// 합성 사본(`fixture`)을 명시한 사본으로 여는 저장소. 초안·연결 기록·추가 목록은 `home`의 실제 파일로 저장한다(가짜 저장 없음)
    func readingStore(_ fixture: RekordboxFixture, home: URL) -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("imports-read"), persist: false),
                          activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in },
                          backupDirectory: fixture.backups, draftHome: home,
                          rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                          arguments: ["test", "--db", fixture.database.path], environment: ["DJC_REKORDBOX_DIR": fixture.root.path],
                          ports: Self.withoutAnalysis)
    }

    /// 실제 그리드·조성 분석(MusicUnderstanding)은 CI 러너에서 음원 읽기가 끝나지 않아 시험 전체가 멈춘다. 이 시험은 놓은 곡의 연결만 보므로 분석을 비운다
    static func withoutAnalysis(_ ports: inout LibraryPorts) {
        ports.analysis.estimateGrid = { _, _ in nil }
        ports.analysis.mainKey = { _, _, _, _, _ in .some(nil) }
    }

    /// 컬렉션에 없는 합성 음원을 목록 `P`에 놓은 채 읽어 둔 저장소. 음원은 `audio` 폴더에 있다
    func droppedStore(_ fixture: RekordboxFixture, audio: URL, home: URL, name: String = "silence.wav") async throws -> (LibraryStore, URL) {
        let file = try AudioFixture.wav(seconds: 0.1, in: audio, name: name)
        let store = readingStore(fixture, home: home)
        await store.load(snapshot: fixture.database)
        try #require(store.playlists.canEditTracks(of: "P"))
        await store.staging.startAddingFiles([file], toPlaylist: "P").value
        // 놓은 곡의 그리드·키 추정이 뒤에서 돈다: 끝낸 뒤 이어 간다(넣기가 분석을 붙이는 길과 안 붙이는 길 중 어디로 가는지 흔들리지 않게)
        await store.staging.gridTask?.value
        try #require(store.staging.staged.count == 1)
        try #require(store.playlists.playlistImports.pendingCount == 1)
        return (store, file)
    }

    func readAgain(_ store: LibraryStore, _ fixture: RekordboxFixture) async {
        let database = fixture.database
        await store.takeSnapshot(refreshITunes: false, snapshotDirectory: fixture.root, snapshotCopy: { _ in database })
    }

    func trackIDs(_ store: LibraryStore, in id: String = "P") -> [String]? {
        store.playlists.playlistDraft.project(onto: store.playlists.rekordboxPlaylists).layout.item(id)?.trackIDs
    }

    @Test func 목록에_놓은_새_곡은_직접_추가로_컬렉션에_들어간_뒤_다시_읽으면_그_목록_초안에_들어간다() async throws {
        let fixture = try RekordboxFixture(), audio = try TemporaryFolder(), home = try TemporaryFolder()
        try fixture.add(PlaylistSpec(id: "P", name: "세트", seq: 1))
        let (store, file) = try await droppedStore(fixture, audio: audio.url, home: home.url)
        // 직접 추가는 NFC 경로 그대로 컬렉션에 넣는다(`TrackAddPlan.make`)
        var spec = TrackSpec(id: "900")
        spec.folderPath = PlaylistImports.pathKey(file.path)
        try fixture.add(spec)
        await readAgain(store, fixture)
        #expect(store.rows.map(\.track.id) == ["900"])
        #expect(trackIDs(store) == ["900"])
        #expect(store.playlists.playlistImports.pendingCount == 0)
    }

    /// 앱의 `rekordbox에 넣기`와 같은 길(`ReflectionSession.addTracks(rows:)`: 쓰기 잠금 → 넣기 → 추가 목록 정리 → 잠금 안의 다시 읽기)로 넣는다.
    /// 합성 사본에 넣고 읽으며, 음원은 시험 폴더의 복사본이다
    func addThroughSession(_ store: LibraryStore) async -> ReflectionOutcome {
        await store.session.addTracks(rows: store.staging.stagedRows)
    }

    func sessionStore(_ fixture: RekordboxFixture, home: URL) -> LibraryStore {
        let database = fixture.database
        return LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("imports-session"), persist: false),
                                 activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }), saveTagDrafts: { _ in },
                                 backupDirectory: fixture.backups, draftHome: home,
                                 rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                 arguments: ["test"], environment: [:], takeLiveSnapshot: { _ in database }, ports: Self.withoutAnalysis)
    }

    @Test func 목록에_놓은_새_곡은_앱의_넣기_흐름이_끝나면_그_목록_초안에_들어간다() async throws {
        let fixture = try RekordboxFixture(), audio = try TemporaryFolder(), home = try TemporaryFolder()
        // 컬렉션이 비면 쓰기가 기기 정보를 알 수 없어 막는다: 기존 곡 하나를 둔다
        try fixture.add(TrackSpec(id: "1"))
        try fixture.add(PlaylistSpec(id: "P", name: "세트", seq: 1))
        let file = audio.url.appending(path: "합성.mp3")
        try FileManager.default.copyItem(at: try TestResources.url("mp3-notag-cbr.mp3"), to: file)
        let store = sessionStore(fixture, home: home.url)
        await store.load(snapshot: fixture.database)
        await store.staging.startAddingFiles([file], toPlaylist: "P").value
        await store.staging.gridTask?.value
        try #require(store.staging.staged.count == 1 && store.playlists.playlistImports.pendingCount == 1)

        let outcome = await addThroughSession(store)

        guard case .added = outcome else {
            Issue.record("넣기가 끝나지 않았다: \(outcome)")
            return
        }
        let added = store.rows.filter { PlaylistImports.pathKey($0.track.folderPath) == PlaylistImports.pathKey(file.path) }
        #expect(added.count == 1 && store.staging.staged.isEmpty)
        #expect(trackIDs(store) == added.map(\.track.id))
        #expect(store.playlists.playlistImports.pendingCount == 0)
        // 그 목록을 열면 초안으로 든 곡이 보인다
        store.sidebar = .playlist("P")
        #expect(store.displayRows.map(\.track.id) == added.map(\.track.id))
        #expect(store.playlists.playlistProjection.blocked.compactMap { $0 }.isEmpty)
    }

    /// 놓은 곡 이름이 한글 NFD(Finder가 주는 모양)이고 목록이 폴더 안에 있어도 같다. 놓기는 실제 사이드바 처리(`PlaylistDrop`)로 한다
    @Test func 한글_NFD_이름의_새_곡을_폴더_안_목록에_놓아도_넣기가_끝나면_들어간다() async throws {
        let fixture = try RekordboxFixture(), audio = try TemporaryFolder(), home = try TemporaryFolder()
        try fixture.add(TrackSpec(id: "1"))
        try fixture.add(PlaylistSpec(id: "F", name: "폴더", seq: 1, isFolder: true))
        try fixture.add(PlaylistSpec(id: "P", name: "세트", parentID: "F", seq: 1, contentIDs: ["1"]))
        let name = "한글 곡 ㅡ 가나다.mp3".decomposedStringWithCanonicalMapping
        let file = audio.url.appending(path: name)
        try FileManager.default.copyItem(at: try TestResources.url("mp3-notag-cbr.mp3"), to: file)
        let store = sessionStore(fixture, home: home.url)
        await store.load(snapshot: fixture.database)
        let node = try #require(store.playlists.playlistIndex["P"])
        let provider = NSItemProvider(object: file as NSURL)
        #expect(PlaylistDrop.perform([provider], on: node, store: store, sidebar: PlaylistSidebarModel(playlists: store.playlists)))
        // 놓기는 파일 주소를 읽은 뒤 뒤에서 추가한다: 연결이 남을 때까지 상태를 기다린다
        _ = await waitForState(until: { store.playlists.playlistImports.pendingCount == 1 })
        await store.staging.gridTask?.value
        try #require(store.staging.staged.count == 1 && store.playlists.playlistImports.pendingCount == 1)

        let outcome = await addThroughSession(store)

        guard case .added = outcome else {
            Issue.record("넣기가 끝나지 않았다: \(outcome)")
            return
        }
        let added = store.rows.filter { PlaylistImports.pathKey($0.track.folderPath) == PlaylistImports.pathKey(file.path) }
        #expect(added.count == 1)
        #expect(trackIDs(store) == ["1"] + added.map(\.track.id))
    }

    /// 놓은 목록이 아직 rekordbox에 없는 새 목록(초안으로 만든 것)이어도 같다
    @Test func 초안으로_만든_새_목록에_놓은_새_곡도_넣기가_끝나면_들어간다() async throws {
        let fixture = try RekordboxFixture(), audio = try TemporaryFolder(), home = try TemporaryFolder()
        try fixture.add(TrackSpec(id: "1"))
        let file = audio.url.appending(path: "합성.mp3")
        try FileManager.default.copyItem(at: try TestResources.url("mp3-notag-cbr.mp3"), to: file)
        let store = sessionStore(fixture, home: home.url)
        await store.load(snapshot: fixture.database)
        try store.playlists.playlistDraft.append(.create(key: "N", name: "새 목록", isFolder: false, parent: .root),
                                                rekordbox: store.playlists.rekordboxPlaylists)
        store.playlists.savePlaylistDraft()
        store.playlists.refreshPlaylists()
        await store.staging.startAddingFiles([file], toPlaylist: "new:N").value
        await store.staging.gridTask?.value
        try #require(store.staging.staged.count == 1 && store.playlists.playlistImports.pendingCount == 1)

        let outcome = await addThroughSession(store)

        guard case .added = outcome else {
            Issue.record("넣기가 끝나지 않았다: \(outcome)")
            return
        }
        let added = store.rows.filter { PlaylistImports.pathKey($0.track.folderPath) == PlaylistImports.pathKey(file.path) }
        #expect(added.count == 1)
        #expect(trackIDs(store, in: "new:N") == added.map(\.track.id))
    }

    /// 놓은 뒤 앱을 껐다 켜도(연결 기록·추가 목록을 파일에서 다시 읽어도) 같다
    @Test func 놓은_뒤_앱을_다시_열어도_넣기가_끝나면_그_목록_초안에_들어간다() async throws {
        let fixture = try RekordboxFixture(), audio = try TemporaryFolder(), home = try TemporaryFolder()
        try fixture.add(TrackSpec(id: "1"))
        try fixture.add(PlaylistSpec(id: "P", name: "세트", seq: 1))
        let file = audio.url.appending(path: "합성.mp3")
        try FileManager.default.copyItem(at: try TestResources.url("mp3-notag-cbr.mp3"), to: file)
        let first = sessionStore(fixture, home: home.url)
        await first.load(snapshot: fixture.database)
        await first.staging.startAddingFiles([file], toPlaylist: "P").value
        await first.staging.gridTask?.value
        try #require(first.playlists.playlistImports.pendingCount == 1)

        let store = sessionStore(fixture, home: home.url)
        await store.load(snapshot: fixture.database)
        try #require(store.staging.staged.count == 1 && store.playlists.playlistImports.pendingCount == 1)
        let outcome = await addThroughSession(store)

        guard case .added = outcome else {
            Issue.record("넣기가 끝나지 않았다: \(outcome)")
            return
        }
        let added = store.rows.filter { PlaylistImports.pathKey($0.track.folderPath) == PlaylistImports.pathKey(file.path) }
        #expect(added.count == 1)
        #expect(trackIDs(store) == added.map(\.track.id))
    }

    /// XML로 가져온 곡은 추가 목록에 남은 채 다음 읽기에서 컬렉션에 나타난다. 그때 잇고, 가져온 곡을 추가 목록에서 정리해도 목록 초안에 남는다
    @Test func XML로_가져온_곡은_다시_읽을_때_이어지고_추가_목록에서_정리해도_목록_초안에_남는다() async throws {
        let fixture = try RekordboxFixture(), audio = try TemporaryFolder(), home = try TemporaryFolder()
        try fixture.add(PlaylistSpec(id: "P", name: "세트", seq: 1))
        let (store, file) = try await droppedStore(fixture, audio: audio.url, home: home.url)
        var spec = TrackSpec(id: "900")
        spec.folderPath = PlaylistImports.pathKey(file.path)
        try fixture.add(spec)

        await readAgain(store, fixture)

        #expect(trackIDs(store) == ["900"])
        #expect(store.playlists.playlistImports.pendingCount == 0)
        // XML 경로는 추가 목록에서 저절로 빼지 않는다
        #expect(store.staging.staged.count == 1)
        store.staging.removeStaged(Set(store.staging.staged.map(\.id)))
        #expect(store.staging.staged.isEmpty)
        #expect(trackIDs(store) == ["900"])
    }
}
