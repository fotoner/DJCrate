import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 재시작 정리(R22)의 재생 목록 몫과 잠금: 메모리에만 있는 재생 목록 편집을 디스크 결과로 덮지 않고, 초안 파일 잠금을 쥔 채 정리한다.
/// CLI 쓰기 전 정리도 쓰기 잠금 아래에서 기록을 판정한 뒤 기록이 없을 때만 한다.
@MainActor
@Suite("반영 세션: 재시작 정리")
struct ReflectionSessionResumeCleanupTests {
    let h = ReflectionHarness()

    static let layout = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 1)])

    /// 디스크 초안에 A 이름 바꾸기(쓴 단계, 미정리 목록에 있다), 메모리에는 저장하지 못한 B 이름 바꾸기가 더 있다
    static func unsavedPlaylistEdit(_ h: ReflectionHarness) throws -> DraftCleanupList {
        var disk = PlaylistDraft()
        _ = try disk.append(.rename(playlist: .id("A"), name: "새 가"), rekordbox: layout)
        try h.memory.store.savePlaylistDraft(disk)
        let saved = h.memory.store.playlistDraft()
        let stamp = try #require(h.memory.playlistStamps.first)
        let hash = try DraftContentHash(step: saved.steps[0], in: saved)
        var memory = saved
        _ = try memory.append(.rename(playlist: .id("B"), name: "새 나"), rekordbox: layout)
        h.state.rekordboxPlaylists = layout
        h.state.playlistDraft = memory
        h.state.playlistDraftUnsaved = true
        return DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: h.session.target.database), draftHome: "/drafts",
                                backupFolder: "w1", playlistSteps: [.init(revision: stamp.revision, contentHash: hash, outcome: .written)])
    }

    /// 디스크와 메모리가 같은 초안(A 이름 바꾸기를 썼다)
    func writtenPlaylistStep() throws -> DraftCleanupList {
        var disk = PlaylistDraft()
        _ = try disk.append(.rename(playlist: .id("A"), name: "새 가"), rekordbox: Self.layout)
        try h.memory.store.savePlaylistDraft(disk)
        let saved = h.memory.store.playlistDraft()
        let stamp = try #require(h.memory.playlistStamps.first)
        h.state.rekordboxPlaylists = Self.layout
        h.state.playlistDraft = saved
        return DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: h.session.target.database), draftHome: "/drafts",
                                backupFolder: "w1",
                                playlistSteps: [.init(revision: stamp.revision, contentHash: try DraftContentHash(step: saved.steps[0], in: saved),
                                                      outcome: .written)])
    }

    // MARK: - S2

    @Test func 저장하지_못한_재생_목록_편집이_메모리에_있으면_재생_목록_정리를_미루고_목록을_남긴다() async throws {
        h.script.cleanupLists = [try Self.unsavedPlaylistEdit(h)]
        let memory = h.state.playlistDraft
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.holds.contains(.cleanupPending) && h.gateCalls.value.removedCleanupLists.isEmpty)
        #expect(h.state.playlistDraft == memory, "메모리의 저장하지 못한 편집을 디스크 결과로 덮지 않는다")
        #expect(h.memory.store.playlistDraft().steps.count == 1, "디스크 정리도 미룬다")
    }

    // MARK: - S3

    @Test func 재생_목록_초안_파일을_다른_곳이_쥐었으면_정리를_미루고_목록을_남긴다() async throws {
        h.script.cleanupLists = [try writtenPlaylistStep()]
        h.playlistLockHeld.value = true
        let held = await h.session.resumeCleanups()
        #expect(held.holds.contains(.cleanupPending) && h.gateCalls.value.removedCleanupLists.isEmpty)
        #expect(h.memory.store.playlistDraft().steps.count == 1)
        h.playlistLockHeld.value = false
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.finished == 1 && h.memory.store.playlistDraft().steps.isEmpty)
        #expect(h.log.contains("playlist lock") && h.log.last("playlist unlock")! > h.log.first("playlist lock")!)
    }

    // MARK: - S1(CLI 쓰기 전 정리)

    @Test func CLI_쓰기_전_정리는_쓰기_잠금_아래에서_기록을_판정하고_중단이면_초안을_지우지_않는다() async throws {
        h.state.rows["a"] = ReflectionHarness.row("a")
        h.memory.save(ReflectionHarness.cue("a"))
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "a")))
        let written = WrittenDraft(key: DraftKey(.cue, "a"), revision: stamp.revision, contentHash: try DraftContentHash(of: ReflectionHarness.cue("a")))
        h.script.cleanupLists = [DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: h.session.target.database), draftHome: "/drafts",
                                                  backupFolder: "w1", written: [written])]
        h.script.journal = .interrupted(RekordboxJournalFinding(journal: RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts),
                                                                changedSince: false, database: nil))
        let locks = MemoryWriteLocks()
        try await h.session.cleanUpBeforeWrite(to: h.session.target, lock: locks.port)
        #expect(h.memory.cue("a") != nil && h.gateCalls.value.removedCleanupLists.isEmpty)
        #expect(h.gateCalls.value.journalHolds == [MemoryWriteLocks.key(for: h.session.target.database)], "쥔 잠금 아래에서 판정한다")
        #expect(locks.heldKeys.isEmpty)
    }

    // MARK: - 2라운드 S2

    @Test func 초안_파일_잠금을_기다리는_사이_재생_목록_저장이_실패하면_정리를_미룬다() async throws {
        h.script.cleanupLists = [try writtenPlaylistStep()]
        let memory = h.state.playlistDraft
        h.playlistSaveFailsDuringLock.value = true
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.holds.contains(.cleanupPending) && h.gateCalls.value.removedCleanupLists.isEmpty)
        #expect(h.state.playlistDraft == memory && h.memory.store.playlistDraft().steps.count == 1)
    }
}
