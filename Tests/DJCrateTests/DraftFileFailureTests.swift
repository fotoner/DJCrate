import DJCApplication
@testable import DJCrate
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

/// #174: 게인·재생 목록·편집본 초안의 저장 실패와 손상된 초안 파일.
/// 저장 실패는 기록하고 같은 입력으로 다시 저장하며, 손상된 파일은 지우거나 빈 값으로 덮지 않고 옮겨 보관한 뒤 알린다.
@Suite("초안 저장 실패·손상 파일", .serialized)
struct DraftFileFailureTests {
    func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-draft-file-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    let broken = Data("{\"깨진".utf8)

    func preserved(in home: URL) -> [URL] {
        let root = home.appending(path: DamagedDrafts.folderName)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    func cue(_ uuid: String, time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.place(EditableCue(kind: .memory, time: time))
        return draft
    }

    // MARK: - 없음과 손상

    @Test func 초안_읽기는_없음과_손상을_구분한다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let missing = home.appending(path: "cue-drafts/없음.json")
        #expect(try DamagedDrafts.read(CueDraft.self, at: missing) == nil)
        // 초안 폴더 자리에 일반 파일이 있어도 그 안의 초안은 없는 것이다(저장은 따로 실패로 알린다).
        let plain = home.appending(path: "tag-drafts")
        try Data("x".utf8).write(to: plain)
        #expect(try DamagedDrafts.read(TagDraft.self, at: plain.appending(path: "곡.json")) == nil)
        let damaged = home.appending(path: "손상.json")
        try broken.write(to: damaged)
        #expect(throws: DraftFileDamaged.self) { try DamagedDrafts.read(CueDraft.self, at: damaged) }
        #expect(throws: DraftFileDamaged.self) { try GainDraftStore.read(url: damaged) }
    }

    @Test func 손상된_곡_초안은_저장_전에_옮겨_보관하고_새_입력을_쓴다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let uuid = UUID().uuidString
        let cues = home.appending(path: "cue-drafts"), grids = home.appending(path: "grid-drafts"), tags = home.appending(path: "tag-drafts")
        for directory in [cues, grids, tags] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try broken.write(to: directory.appending(path: "\(uuid).json"))
        }
        try CueDraftStore.save(cue(uuid, time: 3), directory: cues)
        try GridDraftStore.save(GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: 120, firstBeatNumber: 1)]),
                                directory: grids)
        var tag = TagDraft(trackUUID: uuid, base: TagFields())
        tag.fields.comment = "새 코멘트"
        try TagDraftStore.save(tag, directory: tags)
        #expect(CueDraftStore.load(trackUUID: uuid, directory: cues)?.cues.map(\.time) == [3])
        #expect(TagDraftStore.load(trackUUID: uuid, directory: tags) == tag)
        // 덮은 세 파일의 원래 바이트가 모두 남아 있고, 옮긴 기록을 한 번만 돌려준다.
        let kept = preserved(in: home)
        #expect(kept.count == 3 && kept.allSatisfy { (try? Data(contentsOf: $0)) == broken })
        let entries = DamagedDrafts.take(home: home)
        #expect(Set(entries.map(\.name)) == ["cue-drafts/\(uuid).json", "grid-drafts/\(uuid).json", "tag-drafts/\(uuid).json"])
        #expect(entries.allSatisfy { $0.trackUUID == uuid })
        #expect(DamagedDrafts.take(home: home).isEmpty)
    }

    @Test func 손상된_곡_초안을_지우기로_없애지_않는다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let uuid = UUID().uuidString, cues = home.appending(path: "cue-drafts")
        try FileManager.default.createDirectory(at: cues, withIntermediateDirectories: true)
        try broken.write(to: cues.appending(path: "\(uuid).json"))
        try CueDraftStore.save(CueDraft(trackUUID: uuid), directory: cues)
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        _ = DamagedDrafts.take(home: home)
    }

    // MARK: - 게인

    @Test func 손상된_게인_파일을_새_값만으로_덮지_않는다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "gain-drafts.json")
        try broken.write(to: url)
        try GainDraftStore.save(-2.5, trackUUID: "A", url: url)
        #expect(GainDraftStore.all(url: url) == ["A": -2.5])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["gain-drafts.json"])
    }

    @Test func 게인_파일을_읽지_못하면_저장을_실패로_던지고_덮지_않는다() throws {
        let home = try home()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appending(path: "gain-drafts.json").path)
            try? FileManager.default.removeItem(at: home)
        }
        let url = home.appending(path: "gain-drafts.json")
        try GainDraftStore.save(1, trackUUID: "A", url: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try GainDraftStore.save(2, trackUUID: "B", url: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(GainDraftStore.all(url: url) == ["A": 1])
        #expect(preserved(in: home).isEmpty)
    }

    @Test func 게인_저장_실패를_기록하고_같은_입력으로_다시_저장한다() throws {
        let writer = DraftWriter()
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        // 데이터 폴더 자리에 일반 파일이 있어 저장할 수 없다.
        let folder = home.appending(path: "data")
        try Data("x".utf8).write(to: folder)
        let url = folder.appending(path: "gain-drafts.json")
        let uuid = UUID().uuidString
        let reported = Mutex<DraftSaveFailure?>(nil)
        let places = DraftLocations(home: folder)
        writer.save(gain: -3, trackUUID: uuid, url: url, completion: { failure in reported.withLock { $0 = failure } })
        writer.flush()
        let failure = try #require(reported.withLock { $0 })
        #expect(failure.kind == .gain && failure.message.contains("게인 초안을 저장하지 못했습니다."))
        #expect(writer.failures(in: places).contains(failure))
        #expect(writer.unsavedUUIDs(in: places).contains(uuid))
        #expect(writer.pendingGain(trackUUID: uuid, url: url) == .some(-3))
        // 폴더를 고치면 기록한 입력 그대로 다시 저장한다.
        try FileManager.default.removeItem(at: folder)
        #expect(writer.retry(.gain, trackUUID: uuid, directory: url))
        writer.flush()
        #expect(GainDraftStore.load(trackUUID: uuid, url: url) == -3)
        #expect(writer.failures(in: places).isEmpty && writer.unsavedUUIDs(in: places).isEmpty)
        #expect(writer.pendingGain(trackUUID: uuid, url: url) == nil)
    }

    @Test @MainActor func 덱은_게인_저장_실패를_보이고_지금_값으로_다시_저장한다() async throws {
        let attempts = Mutex<[Double?]>([])
        let fails = Mutex(true)
        var drafts = MemoryDrafts().store
        drafts.saveGain = { gain, uuid, completion in
            attempts.withLock { $0.append(gain) }
            completion(fails.withLock { $0 } ? DraftSaveFailure(kind: .gain, trackUUID: uuid, revision: 1, reason: "합성 실패") : nil)
        }
        let storage = DeckStorage.memory(drafts)
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        let plain = ReflectionPresenterTests.row("gain-failure")
        deck.row = TrackRow(track: plain.track, cues: [], playCount: 0, autoGain: RekordboxAutoGain(gain: 0.5, peak: 1))
        deck.setTrackGain(-4)
        for _ in 0..<100 where deck.currentDraftSaveFailures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(deck.currentDraftSaveFailures.map(\.kind) == [.gain])
        #expect(deck.gainDraft == -4)
        fails.withLock { $0 = false }
        deck.retryDraftSaves()
        for _ in 0..<100 where !deck.currentDraftSaveFailures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(deck.currentDraftSaveFailures.isEmpty)
        #expect(attempts.withLock { $0 } == [-4, -4])
    }

    @Test @MainActor func 게인_저장_실패가_있으면_미리_보기와_실제_쓰기가_막힌다() async throws {
        let writer = DraftWriter()
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 draftHome: fixture.root.appending(path: "drafts"),
                                 arguments: ["test", "--db", fixture.database.path], environment: [:], writer: writer)
        // 게인 초안은 저장소의 초안 폴더(`draftHome`)에 쓴다
        let gains = store.draftLocations.gain
        writer.save(gain: -6, trackUUID: spec.uuid, url: gains, write: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        defer { writer.removeGain(trackUUID: spec.uuid, url: gains); writer.flush() }
        let failure = try #require(writer.failures(in: store.draftLocations).first { $0.trackUUID == spec.uuid && $0.kind == .gain })
        await store.load(snapshot: fixture.database)
        let row = try #require(store.rowsByUUID[spec.uuid])
        // 게인 저장만 실패한 곡도 쓰기 대상이고, "쓸 초안이 없음" 대신 저장 실패 이유로 막힌다.
        #expect(store.writeTargets([row]).map(\.track.uuid) == [spec.uuid])
        do {
            _ = try await store.session.previewWrite(rows: [row], playlists: false)
            Issue.record("게인 저장 실패가 있는데 미리 보기가 통과했다")
        } catch { #expect(error.localizedDescription.contains(failure.message)) }
        do {
            _ = try await store.session.writeToRekordbox([], gains: [spec.uuid: -6], to: fixture.database, shareRoot: fixture.shareRoot)
            Issue.record("게인 저장 실패가 있는데 실제 쓰기가 통과했다")
        } catch { #expect(error.localizedDescription.contains(failure.message)) }
        #expect(writer.pendingGain(trackUUID: spec.uuid, url: gains) == .some(-6))
    }

    // MARK: - 손상된 파일 알리기

    @Test @MainActor func 읽을_때_손상된_초안_파일을_옮기고_닫을_때까지_알린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let tags = home.appending(path: "tag-drafts")
        try FileManager.default.createDirectory(at: tags, withIntermediateDirectories: true)
        try broken.write(to: tags.appending(path: "손상-태그.json"))
        try broken.write(to: home.appending(path: "playlist-drafts.json"))
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in }, draftHome: home,
                                 arguments: ["test", "--db", fixture.database.path], environment: [:])
        await store.load(snapshot: fixture.database)
        #expect(store.draftFileMessage?.kind == .warning)
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(2))
        #expect(!FileManager.default.fileExists(atPath: tags.appending(path: "손상-태그.json").path))
        #expect(preserved(in: home).count == 2 && preserved(in: home).allSatisfy { (try? Data(contentsOf: $0)) == broken })
        // 다시 읽어도 안내는 남는다(다음 읽기의 오류 줄 정리가 지우지 않는다).
        await store.load(snapshot: fixture.database)
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(2))
    }

    @Test @MainActor func 쓰기_전에_손상된_대상_초안을_옮기고_조용히_빼지_않는다() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let uuid = UUID().uuidString, other = UUID().uuidString
        let cues = home.appending(path: "cue-drafts")
        try FileManager.default.createDirectory(at: cues, withIntermediateDirectories: true)
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, playlistDraftSaver: { _ in }, draftHome: home)
        store.draftChanged(trackUUID: uuid, kind: .cue, exists: true)
        // 다른 곡의 파일만 깨졌으면 대상 쓰기는 막지 않고 알리기만 한다.
        try broken.write(to: cues.appending(path: "\(other).json"))
        #expect(store.preserveDamagedDraftFiles().map(\.trackUUID) == [other])
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(1))
        // 읽은 뒤 대상 곡의 파일이 깨졌다: 미리 보기(반영 세션)가 조용히 빼지 않고 막는다.
        try broken.write(to: cues.appending(path: "\(uuid).json"))
        let row = TrackRow(track: Track(id: "1", uuid: uuid, title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                                        releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "/x/1.mp3",
                                        comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        do {
            _ = try await store.session.previewWrite(rows: [row], playlists: false)
            Issue.record("손상된 초안을 빼고 쓰기 전 확인이 통과했다")
        } catch { #expect(error.localizedDescription.contains("damaged-drafts")) }
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(2))
        #expect(!store.pendingUUIDs.contains(uuid))
        #expect(preserved(in: home).filter { $0.lastPathComponent.hasPrefix(uuid) }.map { try? Data(contentsOf: $0) } == [broken])
    }

    // MARK: - 재생 목록

    final class FlakySaver: @unchecked Sendable {
        var fails = true
        var last: PlaylistDraft?
        func save(_ draft: PlaylistDraft) throws {
            if fails { throw CocoaError(.fileWriteNoPermission) }
            last = draft
        }
    }

    @MainActor func playlistStore(_ saver: FlakySaver) -> LibraryStore {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("playlist-save"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, playlistDraftSaver: { try saver.save($0) },
                                 draftHome: FileManager.default.temporaryDirectory.appending(path: "djc-playlist-save-\(UUID())"))
        store.phase = .loaded
        for id in ["1", "2", "3", "4"] { store.rowsByID[id] = PlaylistEditingTests.row(id) }
        store.rekordboxPlaylists = PlaylistEditingTests.rekordbox
        store.refreshPlaylists()
        return store
    }

    @Test @MainActor func 재생_목록_저장_실패는_넣은_결과에_가리지_않고_쓰기_전에_다시_저장한다() async throws {
        let saver = FlakySaver()
        let store = playlistStore(saver)
        store.addTracks([PlaylistEditingTests.row("4")], toPlaylist: "A")
        // 입력은 메모리에 남고, 넣은 결과 안내가 저장 실패 경고를 덮지 않는다.
        #expect(store.playlistDraft.edits == [.addTracks(playlist: .id("A"), contentIDs: ["4"])])
        #expect(store.playlistDraftUnsaved)
        #expect(store.playlistMessage?.kind == .warning)
        #expect(store.playlistMessage?.text.contains(LibraryStore.playlistSaveFailureText) == true)
        // 쓰기 전 확인은 다시 저장해 보고, 그래도 안 되면 쓰지 않는다.
        #expect(!store.ensurePlaylistDraftSaved())
        saver.fails = false
        #expect(store.ensurePlaylistDraftSaved())
        #expect(!store.playlistDraftUnsaved && saver.last == store.playlistDraft)
    }

    @Test @MainActor func 저장하지_못한_재생_목록_초안을_다시_읽기가_덮지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let saver = FlakySaver()
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups, playlistDraftSaver: { try saver.save($0) },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in }, draftHome: try home(),
                                 arguments: ["test", "--db", fixture.database.path], environment: [:])
        await store.load(snapshot: fixture.database)
        _ = store.createPlaylist(isFolder: false, name: "새 목록")
        let draft = store.playlistDraft
        #expect(!draft.isEmpty && store.playlistDraftUnsaved)
        await store.load(snapshot: fixture.database)
        #expect(store.playlistDraft == draft)
    }

    // MARK: - 편집본 넣기

    func stage(home: URL) async throws -> StagedTrack {
        let output = try AudioFixture.wav(seconds: 4, in: home, name: "원곡 (Edit).wav")
        let edit = try TrackEdit(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], sourceDuration: 4, bars: BarRange.list("1-1"))
        return try await StageEdit.put(output, grid: [edit.outputGrid], cues: [EditableCue(kind: .memory, time: 0.5)], source: nil, home: home)
    }

    func draftFiles(_ home: URL) -> Set<String> {
        Set(["cue-drafts", "grid-drafts", "tag-drafts"].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: folder).path)) ?? []).map { "\(folder)/\($0)" }
        })
    }

    @Test func 편집본_넣기가_태그_저장에서_실패하면_이번에_만든_초안만_되돌린다() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        // 원래 있던 다른 곡의 초안은 남아야 한다.
        try CueDraftStore.save(cue("기존", time: 1), directory: home.appending(path: "cue-drafts"))
        try Data("x".utf8).write(to: home.appending(path: "tag-drafts"))
        await #expect(throws: (any Error).self) { _ = try await stage(home: home) }
        #expect(draftFiles(home) == ["cue-drafts/기존.json"])
        #expect(CueDraftStore.load(trackUUID: "기존", directory: home.appending(path: "cue-drafts"))?.cues.map(\.time) == [1])
        #expect(StagedTrackFile.load(url: home.appending(path: "staged.json")).isEmpty)
    }

    @Test func 편집본_넣기가_추가_목록_저장에서_실패하면_세_초안을_모두_되돌린다() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "staged.json"), withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { _ = try await stage(home: home) }
        #expect(draftFiles(home).isEmpty)
    }
}
