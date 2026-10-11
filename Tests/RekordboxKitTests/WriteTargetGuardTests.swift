import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("라이브 쓰기 대상 판정")
struct WriteTargetGuardTests {
    func guardFor(_ fixture: RekordboxFixture, running: Bool = false, version: String = "7.2.18") -> RekordboxWriteGuard {
        RekordboxWriteGuard(isRekordboxRunning: { running }, appVersion: { version }, liveDirectories: [fixture.root])
    }

    func databaseAlias(_ live: RekordboxFixture, in copy: RekordboxFixture, symbolic: Bool) throws -> URL {
        let alias = copy.root.appending(path: "alias.db")
        if symbolic {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live.database)
        } else {
            try FileManager.default.linkItem(at: live.database, to: alias)
        }
        return alias
    }

    @Test(arguments: [false, true])
    func DB_링크도_라이브로_판정한다(symbolic: Bool) throws {
        let live = try RekordboxFixture(), copy = try RekordboxFixture()
        let alias = try databaseAlias(live, in: copy, symbolic: symbolic)
        let writeGuard = guardFor(live)
        #expect(writeGuard.isLive(alias))
        #expect(!writeGuard.isLive(copy.database))
        #expect(!writeGuard.isLive(copy.root.appending(path: "missing.db")))
    }

    @Test(arguments: [false, true], ["running", "wal", "version", "dryRun"])
    func DB_링크는_원래_라이브_검사를_통과해야_한다(symbolic: Bool, condition: String) throws {
        let live = try RekordboxFixture(), copy = try RekordboxFixture()
        let track = try live.add(TrackSpec())
        let alias = try databaseAlias(live, in: copy, symbolic: symbolic)
        if condition == "wal" { try Data([1]).write(to: URL(filePath: live.database.path + "-wal")) }
        let writeGuard = guardFor(live, running: condition == "running", version: condition == "version" ? "7.3.0" : "7.2.18")
        let reason = WriteGuardTests().refusal {
            _ = try RekordboxWriter.write(drafts: [WriteGuardTests().draft(track)], to: alias,
                                          dryRun: condition == "dryRun", backups: copy.backups, guard: writeGuard)
        }
        let expected = ["running": "켜져", "wal": "WAL", "version": "7.3.0", "dryRun": "스냅샷"]
        #expect(reason?.contains(expected[condition]!) == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.backups.path).isEmpty)
    }

    enum WriteKind: CaseIterable { case cues, grid, analysis, gain, tags, playlist, add, delete }
    enum ShareKind: CaseIterable { case direct, symbolic, descendant, symbolicDescendant, missingDescendant }

    /// 라이브 share(`PIONEER/USBANLZ/marker`)와 사본 폴더 안의 링크(`share-alias` → 라이브 share)를 두고 `shareKind` 표기의 share를 돌려준다.
    func mixedShare(live: URL, copy: URL, _ shareKind: ShareKind) throws -> (share: URL, marker: URL) {
        let liveShare = live.appending(path: "share")
        let child = liveShare.appending(path: "PIONEER/USBANLZ")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let marker = child.appending(path: "marker")
        try Data([1, 2, 3]).write(to: marker)
        let alias = copy.appending(path: "share-alias")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: liveShare)
        let share: URL = switch shareKind {
        case .direct: liveShare
        case .symbolic: alias
        case .descendant: child
        case .symbolicDescendant: alias.appending(path: "PIONEER/USBANLZ")
        case .missingDescendant: alias.appending(path: "not-created/child")
        }
        return (share, marker)
    }

    /// share 표기 판정은 DB 없이 관문에서 본다. 쓰기 입구가 모두 이 판정(`checkTargets`·`resolveShareRoot`)을 지나는 것은 아래 입구별 시험이 본다.
    @Test(arguments: ShareKind.allCases)
    func 사본_DB와_라이브_share의_어느_표기도_관문이_거부한다(shareKind: ShareKind) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-share-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let live = folder.appending(path: "live"), copy = folder.appending(path: "copy")
        let (share, marker) = try mixedShare(live: live, copy: copy, shareKind)
        let writeGuard = RekordboxWriteGuard(isRekordboxRunning: { false }, appVersion: { "7.2.18" }, liveDirectories: [live])
        let database = copy.appending(path: "master.db")
        for dryRun in [false, true] {
            let reason = WriteGuardTests().refusal { _ = try writeGuard.checkTargets(database, shareRoot: share, dryRun: dryRun) }
            #expect(reason?.contains("share") == true, "\(dryRun)")
        }
        #expect(WriteGuardTests().refusal { _ = try writeGuard.resolveShareRoot(database, shareRoot: share) }?.contains("share") == true)
        #expect(try Data(contentsOf: marker) == Data([1, 2, 3]))
    }

    /// 쓰기 입구마다 대표 하나: 입구가 관문을 지나 백업·쓰기 전에 거부하는지. share 표기는 입구마다 돌려 다섯 표기가 모두 한 번 이상 쓰인다.
    @Test(arguments: WriteKind.allCases)
    func 사본_DB와_라이브_share를_섞으면_모든_쓰기에서_거부한다(kind: WriteKind) async throws {
        let shareKind = ShareKind.allCases[WriteKind.allCases.firstIndex(of: kind)! % ShareKind.allCases.count]
        let live = try RekordboxFixture(), copy = try RekordboxFixture()
        let track = try copy.add(TrackSpec())
        let (share, marker) = try mixedShare(live: live.root, copy: copy.root, shareKind)
        let writeGuard = guardFor(live)
        var plan: TrackAddPlan?
        if kind == .add {
            let audio = try TestResources.url("mp3-tagged.mp3")
            plan = try TrackAddPlan.make(url: audio, tags: try await AudioTags.read(url: audio))
        }
        var tag = TagDraft(trackUUID: track.uuid, base: TagFields())
        tag.fields.title = "바꾼 제목"
        let segment = GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)
        let grid = GridDraft(trackUUID: track.uuid, base: kind == .analysis ? [] : [segment],
                             segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        let reason = WriteGuardTests().refusal {
            switch kind {
            case .add:
                _ = try RekordboxTrackWriter.add([try #require(plan)], to: copy.database, shareRoot: share, dryRun: false,
                                                 backups: copy.backups, guard: writeGuard)
            case .delete:
                _ = try RekordboxTrackWriter.delete(contentIDs: [track.id], from: copy.database, shareRoot: share,
                                                    dryRun: false, backups: copy.backups, guard: writeGuard)
            default:
                _ = try RekordboxWriter.write(
                    drafts: kind == .cues ? [WriteGuardTests().draft(track)] : [],
                    grids: kind == .grid || kind == .analysis ? [grid] : [],
                    gains: kind == .gain ? [track.uuid: 1] : [:], tags: kind == .tags ? [tag] : [],
                    playlists: kind == .playlist ? [.create(key: "test", name: "시험", isFolder: true, parent: .root)] : [],
                    to: copy.database, dryRun: false, backups: copy.backups, shareRoot: share, guard: writeGuard)
            }
        }
        #expect(reason?.contains("share") == true)
        #expect(try copy.localUpdateCount() == 1000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.backups.path).isEmpty)
        #expect(try Data(contentsOf: marker) == Data([1, 2, 3]))
    }

    @Test func 진짜_사본_share는_라이브와_이름이_비슷해도_쓸_수_있다() throws {
        let live = try RekordboxFixture(), copy = try RekordboxFixture()
        let share = live.root.appending(path: "share-copy")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let track = try copy.add(TrackSpec())
        let report = try RekordboxWriter.write(drafts: [WriteGuardTests().draft(track)], to: copy.database,
                                               dryRun: false, backups: copy.backups, shareRoot: share, guard: guardFor(live, running: true))
        #expect(report.written.count == 1)
    }

    @Test func 여러_라이브_루트도_DB와_share를_같은_라이브러리로_묶는다() throws {
        let first = try RekordboxFixture(), second = try RekordboxFixture()
        let writeGuard = RekordboxWriteGuard(isRekordboxRunning: { false }, appVersion: { "7.2.18" },
                                             liveDirectories: [first.root, second.root])
        #expect(writeGuard.isLive(first.database) && writeGuard.isLive(second.database))
        let resolved = try writeGuard.checkTargets(second.database, shareRoot: nil, dryRun: false)
        #expect(resolved == second.shareRoot)
        #expect(throws: DJCError.self) {
            try writeGuard.checkTargets(first.database, shareRoot: second.shareRoot, dryRun: false)
        }
    }

    @Test func 끊어진_상대_심볼릭_링크도_라이브로_판정한다() throws {
        let fixture = try RekordboxFixture()
        let missingRoot = fixture.root.appending(path: "missing")
        let alias = fixture.root.appending(path: "alias.db")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "missing/master.db")
        let writeGuard = RekordboxWriteGuard(isRekordboxRunning: { false }, appVersion: { "7.2.18" },
                                             liveDirectories: [missingRoot])
        #expect(writeGuard.isLive(alias))
    }

    @Test(arguments: [false, true])
    func 합치기도_사본_DB와_라이브_share를_섞으면_거부한다(symbolic: Bool) throws {
        let live = try RekordboxFixture()
        let copy = try DuplicateMergeWriterTests().fixture()
        let merge = try DuplicateMergeWriterTests().draft(copy)
        let alias = copy.root.appending(path: "share-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live.shareRoot)
        let reason = WriteGuardTests().refusal {
            _ = try RekordboxWriter.write(drafts: [], merges: [merge], to: copy.database, dryRun: false,
                                          backups: copy.backups, shareRoot: symbolic ? alias : live.shareRoot, guard: guardFor(live))
        }
        #expect(reason?.contains("share") == true)
        #expect(try copy.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] } == ["100", "200", "300"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.backups.path).isEmpty)
    }

    @Test(arguments: ["direct", "symbolic", "default"])
    func 복원도_사본_DB와_라이브_share를_섞으면_백업_전에_거부한다(kind: String) throws {
        let live = try RekordboxFixture(), copy = try RekordboxFixture()
        let backup = try RekordboxWriter.makeBackup(of: copy.database, in: copy.root.appending(path: "source-backups"), now: .now, label: "test")
        let track = try copy.add(TrackSpec())
        try FileManager.default.removeItem(at: copy.shareRoot)
        try FileManager.default.createSymbolicLink(at: copy.shareRoot, withDestinationURL: live.shareRoot)
        let share: URL? = kind == "default" ? nil : kind == "direct" ? live.shareRoot : copy.shareRoot
        let reason = WriteGuardTests().refusal {
            _ = try RekordboxWriter.restore(backup, to: copy.database, backups: copy.backups,
                                            guard: guardFor(live), shareRoot: share)
        }
        #expect(reason?.contains("share") == true)
        #expect(try copy.rows("SELECT ID FROM djmdContent").first?["ID"] == track.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.backups.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func 복원도_DB_링크의_라이브_실행_검사를_거친다(symbolic: Bool) throws {
        let live = try RekordboxFixture(), copy = try RekordboxFixture()
        let alias = try databaseAlias(live, in: copy, symbolic: symbolic)
        let reason = WriteGuardTests().refusal {
            _ = try RekordboxWriter.restore(copy.root.appending(path: "missing-backup"), to: alias, backups: copy.backups,
                                            guard: guardFor(live, running: true))
        }
        #expect(reason?.contains("켜져") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.backups.path).isEmpty)
    }

    @Test func 복원의_버전_예외는_유지하고_라이브_share를_같이_판정한다() throws {
        let live = try RekordboxFixture()
        let backup = try RekordboxWriter.makeBackup(of: live.database, in: live.root.appending(path: "source-backups"), now: .now, label: "test")
        try live.add(TrackSpec())
        let saved = try RekordboxWriter.restore(backup, to: live.database, backups: live.backups,
                                                guard: guardFor(live, version: "7.3.0"), shareRoot: live.shareRoot)
        #expect(FileManager.default.fileExists(atPath: saved.appending(path: "master.db").path))
        #expect(try live.rows("SELECT ID FROM djmdContent").isEmpty)
    }
}
