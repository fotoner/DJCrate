@testable import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 쓰기 기록 `master.db.djc-write`(R11)·미정리 목록(R22)의 형식과 이름, 쓰기 잠금 키·준비 폴더 이름(R9·R10).
/// 형식은 다른 실행(앱·`DJC_HOME`이 다른 CLI)이 읽으므로 왕복이 같아야 하고, 모르는 판은 읽지 않는다(옛 판은 없다).
@Suite("쓰기 기록·미정리 목록 형식")
struct RekordboxWriteJournalTests {
    private static let hash = DraftContentHash(hex: String(repeating: "a", count: 64))
    private static let key = RekordboxWriteLockKey(device: 0x1000004, inode: 0x2a)

    private static func journal() -> RekordboxWriteJournal {
        var journal = RekordboxWriteJournal(operationID: "op-1", kind: .counter, entry: .drafts)
        journal.basis = .init(writeBackup: "/b/2026-11-24_120000", pointSnapshot: nil, iTunesSyncBefore: nil)
        journal.files = [.init(path: "/r/share/PIONEER/USBANLZ/a/b/ANLZ0000.EXT", original: "/b/2026-11-24_120000/anlz/0.EXT"),
                         .init(path: "/r/share/PIONEER/Artwork/x.jpg", original: nil)]
        journal.drafts = .init(home: "/h/drafts",
                               written: [WrittenDraft(key: DraftKey(.cue, "t1"), revision: DraftRevision(3), contentHash: hash)],
                               playlistSteps: [DraftRevision(5), DraftRevision(6)])
        journal.startCounter = 1200
        journal.database = RekordboxFileStamp(size: 4096, modifiedNanoseconds: 1_764_000_000_123_456_789)
        journal.restoreCopy = RekordboxFileStamp(size: 4000, modifiedNanoseconds: 1_764_000_000_000_000_001)
        journal.marks = [.restoring, .recovering]
        journal.pointRestore = .init(snapshotBeforeRestore: "/s/before", temporaryFolders: [".djc-restore-1", ".djc-old-1"])
        return journal
    }

    @Test func 쓰기_기록은_master_db_옆의_이름이다() {
        let database = URL(filePath: "/r/master.db")
        #expect(RekordboxWriteJournal.url(database: database).path == "/r/master.db.djc-write")
    }

    @Test func 쓰기_기록은_왕복이_같다() throws {
        let journal = Self.journal()
        let data = try RekordboxWriteJournal.encoder.encode(journal)
        #expect(try RekordboxWriteJournal.decode(data) == journal)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""version":1"#) && text.contains(#""kind":"counter""#) && text.contains(#""entry":"drafts""#))
        // 표시는 정한 차례로 적는다(같은 기록이면 같은 파일)
        #expect(text.contains(#""marks":["recovering","restoring"]"#))
        // 빈 기록(파일 쓰기, 근거·파일 없음)도 오간다
        let bare = RekordboxWriteJournal(operationID: "op-2", kind: .files, entry: .iTunesSync)
        #expect(try RekordboxWriteJournal.decode(RekordboxWriteJournal.encoder.encode(bare)) == bare)
    }

    @Test func 모르는_판은_읽지_않는다() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: RekordboxWriteJournal.encoder.encode(Self.journal())) as? [String: Any])
        object["version"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try RekordboxWriteJournal.decode(data) }
        object.removeValue(forKey: "version")
        #expect(throws: (any Error).self) { try RekordboxWriteJournal.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func 미정리_목록은_왕복이_같고_백업_폴더_안_이름이다() throws {
        var list = DraftCleanupList(operationID: "op-1", target: Self.key, draftHome: "/h/drafts")
        list.written = [WrittenDraft(key: DraftKey(.grid, "t2"), revision: DraftRevision(9), contentHash: Self.hash)]
        list.playlistSteps = [.init(revision: DraftRevision(5), contentHash: Self.hash, outcome: .written),
                              .init(revision: DraftRevision(6), contentHash: Self.hash, outcome: .blocked("목록이 바뀌었습니다")),
                              .init(revision: DraftRevision(7), contentHash: Self.hash, outcome: .notTried)]
        list.newPlaylistIDs = ["new:a": "123"]
        list.trackAdds = [.init(stagedUUID: "s1", trackUUID: "t9",
                                written: [WrittenDraft(key: DraftKey(.cue, "s1"), revision: DraftRevision(2), contentHash: Self.hash)],
                                values: .init(cues: [EditableCue(kind: .hot(0), time: 1)], musicalKey: "8A", tags: nil),
                                blockedFields: ["musicalKey"])]
        let data = try DraftCleanupList.encoder.encode(list)
        #expect(try DraftCleanupList.decode(data) == list)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 0
        #expect(throws: (any Error).self) { try DraftCleanupList.decode(JSONSerialization.data(withJSONObject: object)) }
        let url = DraftCleanupList.url(backups: URL(filePath: "/b"), operationID: "op-1")
        #expect(url.path == "/b/draft-cleanup/op-1.json")
    }

    /// 실제 실행의 훅은 아무것도 하지 않는다(재확인은 실제 확인을 쓴다)
    @Test func 쓰기_훅의_기본값은_주입_없음이다() throws {
        let hooks = RekordboxWriteHooks.none
        for step in RekordboxWriteStep.allCases {
            try hooks.checkpoint(.before(step))
            hooks.timing(.after(step), ContinuousClock().now)
        }
        #expect(hooks.isRekordboxRunning == nil)
        let injected = RekordboxWriteHooks(checkpoint: { if $0 == .after(.commit) { throw FixtureError("커밋 직후 멈춤") } },
                                           isRekordboxRunning: { $0 == .fileReplace })
        #expect(throws: (any Error).self) { try injected.checkpoint(.after(.commit)) }
        #expect(injected.isRekordboxRunning?(.fileReplace) == true && injected.isRekordboxRunning?(.commit) == false)
    }

    @Test func 잠금_키는_이름으로_오가고_준비_폴더는_루트마다_대상_키_아래다() throws {
        #expect(Self.key.name == "1000004-2a")
        #expect(RekordboxWriteLockKey(name: Self.key.name) == Self.key)
        #expect(RekordboxWriteLockKey(name: "1000004") == nil && RekordboxWriteLockKey(name: "x-2a") == nil)
        #expect(Self.key.lockFileName == "1000004-2a.lock")
        #expect(RekordboxWriteLockKey.folderName == "djc-locks" && RekordboxWriteLockKey.folderMode == 0o700)
        #expect(try JSONDecoder().decode(RekordboxWriteLockKey.self, from: JSONEncoder().encode(Self.key)) == Self.key)
        let staging = RekordboxStaging.folder(root: URL(filePath: "/r/share"), key: Self.key)
        #expect(staging.path == "/r/share/.djc-staging/1000004-2a")
        // SQLite·rekordbox가 같은 폴더에 쓰는 이름과 겹치지 않는다(가정 절)
        for name in [RekordboxStaging.folderName, "master.db" + RekordboxWriteJournal.fileSuffix] {
            #expect(!name.hasSuffix("-journal") && !name.hasSuffix("-wal") && !name.hasSuffix("-shm"))
            #expect(!name.hasPrefix("master.backup") && !name.hasPrefix("automixPlaylist"))
        }
    }
}
