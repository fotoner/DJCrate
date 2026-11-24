import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
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

    func store() -> LibraryStore {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-autosave-app-\(UUID().uuidString)")
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, draftHome: home, movesDamagedDrafts: false,
                                      takeLiveSnapshot: { _ in throw DJCError.snapshotNotFound })
        store.phase = .loaded
        store.playlists.rekordboxPlaylists = Self.rekordbox
        store.playlists.refreshPlaylists()
        return store
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
}
