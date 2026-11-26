#if DEBUG
@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@MainActor
@Suite(.serialized)
struct LibraryWriteSelfTestTests {
    let guardForCopy = RekordboxWriteGuard(isRekordboxRunning: { false }, appVersion: { nil }, liveDirectories: [])

    func store(_ fixture: RekordboxFixture) async -> LibraryStore {
        let directory = fixture.root.appending(path: "snapshots")
        var location = LibraryLocation.resolve(arguments: ["test"], environment: ["DJC_REKORDBOX_DIR": fixture.root.path])
        location.snapshotDirectory = directory
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("selftest-copy"), persist: false),
            backupDirectory: fixture.backups, draftHome: fixture.root.appending(path: "drafts"),
            writeGate: .live(guard: guardForCopy), rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot, location: location,
            takeLiveSnapshot: { [database = fixture.database, guardForCopy] force in try LibrarySnapshot.take(from: database, into: directory, force: force, guard: guardForCopy) },
            ports: {
                $0.analysis.estimateGrid = { _, _ in GridEstimate(segments: [.init(start: 0, bpm: 120, firstBeatNumber: 1)],
                                                                  medianResidualMs: 0, inlierRatio: 1, downbeatConfidence: 1) }
                $0.analysis.mainKey = { _, _, _, _, _ in .some(nil) }
            })
        await store.takeSnapshot(refreshITunes: false)
        return store
    }

    @Test(arguments: ["없음", "큐 쓰기", "덱 갱신"])
    func 반영_자가시험이_다시_읽은_값과_복원본을_확인한다(failure: String) async throws {
        let fixture = try RekordboxFixture()
        try PlaylistWriteFixtureCapture().populate(fixture, at: fixture.root, writeSelfTest: true)
        let library = await store(fixture)
        let deck = try DeckHarness()
        library.onLoadToDeck = { deck.deck.load($0) }
        library.connectWriteLocks(to: deck.deck)
        if failure == "큐 쓰기" {
            let write = library.testReflection.gate.write
            library.testReflection.gate.write = { batch, inputs, target, preview in
                var partial = batch
                partial.drafts = []
                return try write(partial, inputs, target, preview)
            }
        }
        if failure == "덱 갱신" { library.onRekordboxWritten = { _ in } }
        var lines: [String] = []
        func log(_ line: String) { lines.append(line); print(line) }
        let code = await DevSelfTests.selfTestExitCode(passLine: "쓰기·되돌림 시험 통과", log: log) {
            try await DevSelfTests.runWriteSelfTest(store: library, deck: deck.deck, session: library.session,
                playlistSidebar: PlaylistSidebarModel(playlists: library.playlists), log: log)
        }
        #expect(library.deckTrackID == "106", "태그·그림 대상보다 큐 대상 곡을 덱에 올린다")
        #expect(code == (failure == "없음" ? 0 : 1))
        #expect(lines.contains("쓰기·되돌림 시험 통과") == (failure == "없음"))
        if failure == "큐 쓰기" { #expect(lines.last?.hasPrefix("실패 · 큐 쓰기") == true) }
        if failure == "덱 갱신" { #expect(lines.last?.hasPrefix("실패 · 덱 큐 갱신") == true) }
    }

    @Test(arguments: ["없음", "빼기", "핫큐"])
    func 곡_자가시험이_두_곡의_큐와_파일을_확인한다(failure: String) async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let files = try [AudioFixture.wav(seconds: 8, in: fixture.audio, name: "first.wav"),
                         AudioFixture.mp3(TestResources.url("mp3-notag-cbr.mp3"), artwork: ImageFixture.image(width: 320, height: 320), in: fixture.audio)]
        let library = await store(fixture)
        if failure == "빼기" {
            let delete = library.testReflection.gate.deleteTracks
            library.testReflection.gate.deleteTracks = { ids, target, _ in try delete(ids, target, true) }
        }
        if failure == "핫큐" {
            let add = library.testReflection.gate.addTracks
            library.testReflection.gate.addTracks = { batch, target, dryRun in
                var partial = batch
                partial.cues = batch.cues.mapValues { $0.filter { $0.kind != .hot(0) } }
                return try add(partial, target, dryRun)
            }
        }
        let coordinator = ReflectionCoordinator.test(store: library, prompter: AgreeingPrompter(log: { print($0) }))
        var lines: [String] = []
        func log(_ line: String) { lines.append(line); print(line) }
        let code = await DevSelfTests.selfTestExitCode(passLine: "곡 넣기·빼기 시험 통과", log: log) {
            try await DevSelfTests.runTrackSelfTest(files: files, store: library, coordinator: coordinator, outsideGuard: guardForCopy, log: log)
        }
        #expect(code == (failure == "없음" ? 0 : 1))
        #expect(lines.contains("곡 넣기·빼기 시험 통과") == (failure == "없음"))
        if failure == "빼기" { #expect(lines.last?.hasPrefix("실패 · 빼기 · 컬렉션") == true) }
        if failure == "핫큐" { #expect(lines.last?.hasPrefix("실패 · 넣기 큐") == true) }
        if failure == "없음" {
            #expect(lines.contains("빼기 되돌림 · 2곡 · 분석·그림 9개"))
            #expect(lines.contains("빼기 되돌림 큐 · 2곡의 핫큐·메모리 큐 다시 읽기"))
        }
        #expect(await waitForState { library.staging.gridJob == nil })
    }
}
#endif
