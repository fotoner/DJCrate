@testable import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

/// 쓰기 잠금·쓰기 기록·미정리 목록의 실제 구현(R9·R11·R22)에 W0 계약 함수(`rekordboxWriteLockContract`·`journalKeepContract`·
/// `journalKeepOverlapContract`)를 돌린다. 가짜(`MemoryWriteLocks`·`RekordboxWriteGate.scripted`)는 DJCApplicationTests가 같은 함수로 본다.
/// 중단 기록은 실제 입구를 강제 종료 흉내(훅이 `RekordboxWriteStop`을 던진다)로 멈춰 만든다. 합성 사본으로만 한다.
@Suite("쓰기 기록·잠금 포트(실제)")
struct RekordboxWriteJournalLiveTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    static func copyGuard(hooks: RekordboxWriteHooks = .none, locks: RekordboxWriteLocks = .system) -> RekordboxWriteGuard {
        var writeGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })
        writeGuard.hooks = hooks
        writeGuard.locks = locks
        return writeGuard
    }

    func target(_ fixture: RekordboxFixture) -> RekordboxWriteTarget {
        RekordboxWriteTarget(database: fixture.database, shareRoot: fixture.shareRoot, backups: fixture.backups)
    }

    /// 큐 쓰기를 커밋 직후에 멈춰 중단 기록을 남긴다
    func interruptedWrite(_ fixture: RekordboxFixture, operation: DraftWriteOperation? = nil) throws {
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        let gate = RekordboxWriteGate.live(guard: Self.copyGuard(hooks: RekordboxWriteHooks(checkpoint: { moment in
            if moment == .after(.commit) { throw RekordboxWriteStop() }
        })))
        #expect(throws: RekordboxWriteStop.self) {
            _ = try gate.write(DraftWriteBatch(drafts: [draft], operation: operation), [:], target(fixture), false)
        }
    }

    func journalFile(_ fixture: RekordboxFixture) throws -> URL {
        RekordboxWriteJournal.url(resolvedDatabase: try RekordboxWriteLocks.resolve(fixture.database))
    }

    // MARK: 잠금

    @Test func 쓰기_잠금_실제_구현이_잠금_계약을_지킨다() throws {
        let a = try RekordboxFixture(), b = try RekordboxFixture()
        let folder = try TemporaryFolder(prefix: "djc-lock-contract")
        let fileLink = folder.url.appending(path: "master.db")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: a.database)
        let folderLink = folder.url.appending(path: "library")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: a.root)
        let lock = RekordboxWriteLock.live(RekordboxWriteLocks(folder: folder.url.appending(path: "djc-locks")))
        try rekordboxWriteLockContract(lock, database: a.database, other: b.database, links: [fileLink, folderLink.appending(path: "master.db")])
        withExtendedLifetime((a, b, folder)) {}
    }

    @Test func 관문의_쓰기_입구와_잠금_포트는_같은_잠금이다() throws {
        let fixture = try RekordboxFixture()
        let port = RekordboxWriteLock.live()
        let hold = try #require(try port.tryLock(try port.key(fixture.database)))
        #expect(try RekordboxWriter.judgeJournal(database: fixture.database, backups: fixture.backups, locked: false) == nil,
                "포트가 쥔 동안 관문은 잠금을 못 잡는다")
        hold.release()
        #expect(try RekordboxWriter.judgeJournal(database: fixture.database, backups: fixture.backups, locked: false) == RekordboxJournalJudgment.none)
    }

    // MARK: 기록 판정

    @Test func 관문의_기록_판정은_넘긴_잠금_아래에서_하고_다른_대상의_잠금이면_던진다() throws {
        let fixture = try RekordboxFixture(), other = try RekordboxFixture()
        try interruptedWrite(fixture)
        let gate = RekordboxWriteGate.live(guard: Self.copyGuard())
        let port = RekordboxWriteLock.live()
        guard case .interrupted = try gate.journal(target(fixture), nil) else { Issue.record("중단 판정이 아님"); return }
        let hold = try #require(try port.tryLock(try port.key(fixture.database)))
        defer { hold.release() }
        guard case let .interrupted(finding) = try gate.journal(target(fixture), hold) else { Issue.record("넘긴 잠금 아래 판정이 아님"); return }
        #expect(finding.journal.entry == .drafts && !finding.changedSince)
        let otherHold = try #require(try port.tryLock(try port.key(other.database)))
        defer { otherHold.release() }
        #expect(throws: DJCError.self) { try gate.journal(target(fixture), otherHold) }
        // 다른 쪽이 쥐고 있으면 판정하지 않는다(진행 중)
        #expect(try gate.journal(target(other), nil) == .inProgress)
    }

    @Test func 기록으로_복원하면_쓰기_전으로_돌아가고_요청이_다르면_하지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        let before = try fixture.rows("SELECT * FROM djmdCue ORDER BY 1")
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        let stopping = RekordboxWriteGate.live(guard: Self.copyGuard(hooks: RekordboxWriteHooks(checkpoint: { moment in
            if moment == .after(.commit) { throw RekordboxWriteStop() }
        })))
        #expect(throws: RekordboxWriteStop.self) { _ = try stopping.write(DraftWriteBatch(drafts: [draft]), [:], target(fixture), false) }
        let gate = RekordboxWriteGate.live(guard: Self.copyGuard())
        guard case let .interrupted(finding) = try gate.journal(target(fixture), nil) else { Issue.record("중단 판정이 아님"); return }
        #expect(try gate.restoreJournal(target(fixture), RekordboxJournalRequest(operationID: "다른 것", database: finding.database)) == .changed)
        guard case .restored = try gate.restoreJournal(target(fixture), finding.request) else { Issue.record("복원하지 않음"); return }
        #expect(try fixture.rows("SELECT * FROM djmdCue ORDER BY 1") == before)
        #expect(try gate.journal(target(fixture), nil) == .none)
        #expect(try gate.restoreJournal(target(fixture), finding.request) == .nothing)
    }

    // MARK: "이대로 둔다"

    @MainActor
    @Test func 이대로_두기_실제_관문이_순서_계약을_지킨다() throws {
        let fixture = try RekordboxFixture()
        try interruptedWrite(fixture)
        let gate = RekordboxWriteGate.live(guard: Self.copyGuard())
        guard case let .interrupted(finding) = try gate.journal(target(fixture), nil) else { Issue.record("중단 판정이 아님"); return }
        let file = try journalFile(fixture)
        try journalKeepContract(gate, target: target(fixture), matching: finding.request,
                                stale: RekordboxJournalRequest(operationID: finding.request.operationID + "-다름", database: finding.request.database),
                                journalExists: { FileManager.default.fileExists(atPath: file.path) })
        // 크기·시각이 다른 요청도 받지 않는다
        try interruptedWrite(fixture)
        guard case let .interrupted(next) = try gate.journal(target(fixture), nil) else { Issue.record("중단 판정이 아님"); return }
        var other = next.request
        other.database?.size += 1
        #expect(try gate.keepJournal(target(fixture), other) {} == .changed)
    }

    @Test func 겹친_이대로_두기는_한_잠금_안에서_한_번만_한다() async throws {
        let fixture = try RekordboxFixture()
        try interruptedWrite(fixture)
        let contended = Mutex(false)
        let gate = RekordboxWriteGate.live(guard: Self.copyGuard(locks: RekordboxWriteLocks(contended: { _ in contended.withLock { $0 = true } })))
        guard case let .interrupted(finding) = try gate.journal(target(fixture), nil) else {
            Issue.record("중단 판정이 아님")
            return
        }
        let file = try journalFile(fixture)
        try await journalKeepOverlapContract(gate, target: target(fixture), request: finding.request,
                                             journalExists: { FileManager.default.fileExists(atPath: file.path) },
                                             secondContended: { contended.withLock { $0 } })
    }

    // MARK: 미정리 목록(R22)

    @Test func 앱의_쓰기는_미정리_목록을_남기고_관문은_그_대상과_초안_저장소의_목록만_돌려준다() throws {
        let fixture = try RekordboxFixture()
        let home = fixture.root.appending(path: "drafts")
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        let key = DraftKey(.cue, track.uuid)
        let entry = DraftBatchEntry(stamp: DraftStamp(revision: DraftRevision(3), origins: [.human], contentHash: DraftContentHash(hex: "aa")),
                                    contentHash: DraftContentHash(hex: "bb"))
        let batch = DraftWriteBatch(drafts: [draft], revisions: DraftBatchRevisions(tracks: [key: entry]),
                                    operation: DraftWriteOperation(id: "op-앱", draftHome: home))
        let gate = RekordboxWriteGate.live(guard: Self.copyGuard())
        let report = try gate.write(batch, [:], target(fixture), false)
        let lists = try gate.cleanupLists(target(fixture), home)
        let list = try #require(lists.first)
        #expect(lists.count == 1 && list.operationID == "op-앱" && list.draftHome == home.path)
        #expect(list.target == (try RekordboxWriteLocks.key(fixture.database)))
        #expect(list.backupFolder == URL(filePath: try #require(report.backup)).lastPathComponent)
        #expect(list.written == [WrittenDraft(key: key, revision: DraftRevision(3), contentHash: DraftContentHash(hex: "bb"))])
        #expect(try gate.cleanupLists(target(fixture), fixture.root.appending(path: "다른 저장소")).isEmpty)
        // 쓴 백업 폴더는 목록이 남은 동안 솎기에서 빠진다
        #expect(try RekordboxBackups.live().protectedFolders(fixture.backups) == [list.backupFolder])
        try gate.removeCleanupList(list, target(fixture))
        #expect(try gate.cleanupLists(target(fixture), home).isEmpty)
        // CLI(작업 없음)는 목록을 남기지 않는다
        var cli = draft
        cli.place(EditableCue(kind: .memory, time: 40))
        _ = try gate.write(DraftWriteBatch(drafts: [cli]), [:], target(fixture), false)
        #expect(try RekordboxWriter.cleanupLists(in: fixture.backups).isEmpty)
    }

    @Test func 미정리_목록은_쓴_결과와_시도한_재생_목록_단계·새_목록_연결_ID를_적는다() throws {
        struct DraftJSON: Encodable {
            var steps: [PlaylistDraft.Step]
            var base: [String: PlaylistDraft.Base] = [:]
        }
        let steps = [PlaylistDraft.Step(edit: .create(key: "a", name: "새 목록", isFolder: false, parent: .root)),
                     PlaylistDraft.Step(edit: .rename(playlist: .id("9"), name: "막힘")),
                     PlaylistDraft.Step(edit: .create(key: "b", name: "또", isFolder: false, parent: .root))]
        let playlists = try JSONDecoder().decode(PlaylistDraft.self, from: JSONEncoder().encode(DraftJSON(steps: steps)))
        func entry(_ revision: UInt64) -> DraftBatchEntry {
            DraftBatchEntry(stamp: DraftStamp(revision: DraftRevision(revision), origins: [.human], contentHash: DraftContentHash(hex: "s\(revision)")),
                            contentHash: DraftContentHash(hex: "h\(revision)"))
        }
        let tag = DraftKey(.tag, "t1"), blockedTag = DraftKey(.tag, "t2"), grid = DraftKey(.grid, "g1")
        let batch = DraftWriteBatch(playlists: playlists,
                                    revisions: DraftBatchRevisions(tracks: [tag: entry(1), blockedTag: entry(2), grid: entry(3)],
                                                                   playlistSteps: [entry(10), entry(11)]),
                                    operation: DraftWriteOperation(id: "op", draftHome: URL(filePath: "/drafts")))
        var report = RekordboxWriteReport(outcomes: [], dryRun: false, createdAt: "")
        report.tagOutcomes = [.init(trackUUID: "t1", title: "", status: .written, removed: 0, added: 0),
                              .init(trackUUID: "t2", title: "", status: .blocked, reason: "막힘", removed: 0, added: 0)]
        report.analysisOutcomes = [.init(trackUUID: "g1", title: "", status: .written, removed: 0, added: 0)]
        report.playlistOutcomes = [PlaylistOutcome(edit: steps[0].edit, playlistID: "501", name: "새 목록", status: .written),
                                   PlaylistOutcome(edit: steps[1].edit, name: "막힘", status: .blocked, reason: "바뀜")]
        let record = try #require(batch.draftRecord)
        #expect(record.operationID == "op" && record.drafts?.written.count == 3 && record.drafts?.playlistSteps == [DraftRevision(10), DraftRevision(11)])
        let list = try #require(record.cleanupList(report))
        #expect(list.written.map(\.key) == [grid, tag].sorted())
        #expect(list.playlistSteps.map(\.outcome) == [.written, .blocked("바뀜")], "판을 아는 단계만, 시도한 결과와 함께")
        #expect(list.playlistSteps.map(\.contentHash) == [DraftContentHash(hex: "h10"), DraftContentHash(hex: "h11")])
        #expect(list.newPlaylistIDs == ["new:a": "501"])
    }

    @Test func 곡_넣기의_미정리_목록은_옛·새_UUID와_넣기로_쓴_값·막힌_칸을_적는다() throws {
        let plan = TrackAddPlan(path: "/music/a.mp3", fileName: "a.mp3", title: "A", comment: "", year: 0, trackNumber: 0, discNumber: 0, isrc: "",
                                lyricist: "", fileType: 1, fileSize: 1, fileID: "f", length: 1, duration: 1, dateCreated: "", stockDate: "")
        let cues = [EditableCue(kind: .memory, time: 4)]
        let segments = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]
        func entry(_ revision: UInt64) -> DraftBatchEntry {
            DraftBatchEntry(stamp: DraftStamp(revision: DraftRevision(revision), origins: [.human], contentHash: DraftContentHash(hex: "x")),
                            contentHash: DraftContentHash(hex: "c\(revision)"))
        }
        let batch = TrackAddBatch(plans: [plan], analyses: [plan.path: RekordboxTrackAnalysis(segments: segments, loudness: nil, peak: 1)],
                                  cues: [plan.path: cues], keys: [plan.path: "8A"], stagedUUIDs: [plan.path: "old"],
                                  revisions: DraftBatchRevisions(tracks: [DraftKey(.cue, "old"): entry(1), DraftKey(.grid, "old"): entry(2),
                                                                          DraftKey(.tag, "old"): entry(3)]),
                                  operation: DraftWriteOperation(id: "add-op", draftHome: URL(filePath: "/drafts")))
        let report = RekordboxTrackWriteReport(added: [.init(path: plan.path, contentID: "77", title: "A", written: true, uuid: "new",
                                                             cuesWritten: 1, keyReason: "키 줄이 없음")], dryRun: false)
        let record = try #require(batch.draftRecord)
        let list = try #require(record.cleanupList(report))
        let add = try #require(list.trackAdds.first)
        #expect(add.stagedUUID == "old" && add.trackUUID == "new")
        #expect(add.written.map { $0.key } == [DraftKey(.cue, "old"), DraftKey(.grid, "old")])
        #expect(add.values.cues == cues && add.values.grid == segments && add.values.musicalKey == nil)
        #expect(add.blockedFields == [TagFields.Key.musicalKey.rawValue])
    }

    // MARK: 백업 조건(R13)

    @Test func 자동_저장의_백업_조건은_클론과_여유_공간을_본다() throws {
        let database = URL(filePath: "/library/master.db"), backups = URL(filePath: "/library/backups")
        func condition(_ volume: RekordboxWriter.BackupVolume) -> RekordboxBackupCondition {
            RekordboxBackups.live(volume: { _, _ in volume }).autoSaveCondition(backups, database)
        }
        let gigabyte: Int64 = 1 << 30
        #expect(condition(.init(canClone: false, available: 10 * gigabyte, databaseSize: 1)) == .noClone)
        #expect(condition(.init(canClone: true, available: gigabyte - 1, databaseSize: 100)) == .lowSpace(available: gigabyte - 1, required: gigabyte))
        #expect(condition(.init(canClone: true, available: 3 * gigabyte, databaseSize: gigabyte + 1))
                == .lowSpace(available: 3 * gigabyte, required: 3 * (gigabyte + 1)))
        #expect(condition(.init(canClone: true, available: gigabyte, databaseSize: 100)) == .ready)
        #expect(condition(.init(canClone: true, available: nil, databaseSize: 100)) == .unknown)
    }

    @Test func 같은_볼륨의_백업_폴더는_클론이_되는지_잰다() throws {
        let fixture = try RekordboxFixture()
        let volume = RekordboxWriter.backupVolume(backups: fixture.backups, database: fixture.database)
        #expect(volume.databaseSize == (try FileManager.default.attributesOfItem(atPath: fixture.database.path)[.size] as? Int).map(Int64.init))
        #expect(volume.available != nil)
        #expect(volume.canClone == RekordboxPointSnapshot.canClone(from: fixture.database, to: fixture.backups))
    }
}
