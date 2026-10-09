import CryptoKit
import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("반영 미리보기 사본")
struct WritePreviewSnapshotTests {
    enum Kind: CaseIterable { case cue, grid, gain, tag, playlist }

    // 앱이 쓰는 사본 경계와 writer를 함께 실행한다. 합성 원본을 라이브로 보는 guard도 유지한다.
    func preview(_ fixture: RekordboxFixture, drafts: [CueDraft], grids: [GridDraft], gains: [String: Double],
                 tags: [TagDraft], playlists: [PlaylistEdit]) async throws -> RekordboxWriter.Report {
        let directory = fixture.root.appending(path: "preview")
        let result = try await WritePreviewSnapshot.withCopy(from: fixture.database, shareRoot: fixture.shareRoot,
                                                            grids: grids, directory: directory) { snapshot, share in
            try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, tags: tags, playlists: playlists,
                                      to: snapshot, dryRun: true, backups: fixture.backups, shareRoot: share,
                                      guard: WriteTargetGuardTests().guardFor(fixture))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        return result
    }

    @Test(arguments: Kind.allCases)
    func 대상별_미리보기는_원본을_보존하고_결과를_돌려준다(kind: Kind) async throws {
        let fixture = try RekordboxFixture()
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0")
        try fixture.insert("djmdMixerParam", ["ID": .text("gain"), "ContentID": .text(track.id), "GainHigh": .int(16256),
                                              "GainLow": .int(0), "PeakHigh": .int(16256), "PeakLow": .int(0), "rb_local_deleted": .int(0)])
        var grid = try RekordboxGridWriterTests().draft(fixture, track)
        grid.shift(by: 0.01)
        let tag = try RekordboxTagWriterTests().draft(fixture, track) { $0.title = "미리보기 제목" }
        let originals = [fixture.database, fixture.analysisURL(for: track), fixture.analysisURL(for: track, ext: "EXT"), URL(filePath: track.folderPath)]
        let before = try originals.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let report = try await preview(fixture, drafts: kind == .cue ? [WriteGuardTests().draft(track)] : [],
                                 grids: kind == .grid ? [grid] : [], gains: kind == .gain ? [track.uuid: -3] : [:],
                                 tags: kind == .tag ? [tag] : [],
                                 playlists: kind == .playlist ? [.create(key: "preview", name: "미리보기 목록", isFolder: false, parent: .root)] : [])
        let counts = [report.written.count, report.gridWritten.count, report.gainWritten.count, report.tagWritten.count,
                      report.playlistOutcomes?.filter { $0.status == .written }.count ?? 0]
        #expect(counts.reduce(0, +) == 1)
        #expect(report.dryRun && report.backup == nil)
        #expect(try originals.map { SHA256.hash(data: try Data(contentsOf: $0)) } == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path).isEmpty)
    }

    @Test func 선택한_분석_파일과_XML만_독립_사본으로_만든다() async throws {
        let fixture = try RekordboxFixture()
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = try RekordboxGridWriterTests().draft(fixture, track)
        grid.shift(by: 0.01)
        let unrelated = fixture.shareRoot.appending(path: "unrelated.bin")
        try Data([1, 2, 3]).write(to: unrelated)
        let xml = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("<PLAYLISTS></PLAYLISTS>".utf8).write(to: xml)
        // 하드 링크도 복사 대상이 될 수 있지만, 목적지 inode는 원본과 달라야 한다.
        let dat = fixture.analysisURL(for: track), alias = fixture.root.appending(path: "analysis-alias")
        try FileManager.default.linkItem(at: dat, to: alias)
        let before = try Data(contentsOf: dat)
        let directory = fixture.root.appending(path: "preview")
        try await WritePreviewSnapshot.withCopy(from: fixture.database, shareRoot: fixture.shareRoot, grids: [grid], directory: directory) { database, share in
            let copied = try #require(RekordboxShare.analysisURL(track.analysisDataPath, root: share))
            #expect(!RekordboxWriteGuard.sameFile(database, fixture.database))
            #expect(!RekordboxWriteGuard.sameFile(copied, dat))
            #expect(!FileManager.default.fileExists(atPath: share.appending(path: "unrelated.bin").path))
            #expect(try Data(contentsOf: database.deletingLastPathComponent().appending(path: xml.lastPathComponent)) == Data(contentsOf: xml))
            try Data([9]).write(to: copied)
        }
        #expect(try Data(contentsOf: dat) == before && Data(contentsOf: alias) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: ["traversal", "file-link", "folder-link", "xml-link"])
    func 경로_이탈과_링크를_막고_불완전한_사본도_지운다(kind: String) async throws {
        let fixture = try RekordboxFixture()
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = try RekordboxGridWriterTests().draft(fixture, track)
        grid.shift(by: 0.01)
        let fm = FileManager.default
        let sentinel = fixture.root.appending(path: "source-sentinel")
        try Data([1, 2, 3]).write(to: sentinel)
        let dat = fixture.analysisURL(for: track)
        switch kind {
        case "traversal":
            try fixture.execute("UPDATE djmdContent SET AnalysisDataPath = '/../source-sentinel'")
        case "file-link":
            try fm.removeItem(at: dat)
            try fm.createSymbolicLink(at: dat, withDestinationURL: sentinel)
        case "folder-link":
            let parent = dat.deletingLastPathComponent(), moved = fixture.root.appending(path: "analysis")
            try fm.moveItem(at: parent, to: moved)
            try fm.createSymbolicLink(at: parent, withDestinationURL: moved)
        default:
            try fm.createSymbolicLink(at: fixture.root.appending(path: "masterPlaylists6.xml"), withDestinationURL: sentinel)
        }
        let before = try Data(contentsOf: fixture.database)
        let directory = fixture.root.appending(path: "preview")
        do {
            _ = try await WritePreviewSnapshot.withCopy(from: fixture.database, shareRoot: fixture.shareRoot, grids: [grid], directory: directory) { _, _ in
                Issue.record("위험한 파일 경로로 미리보기를 실행함")
            }
            Issue.record("위험한 경로를 거절하지 않음")
        } catch let DJCError.writeRefused(reason) {
            #expect(reason.contains("경로가 안전하지"))
        }
        #expect(try Data(contentsOf: sentinel) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func writer_실패와_취소_뒤_사본을_지우고_초안은_보존한다(cancel: Bool) async throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        let draftURL = fixture.root.appending(path: "user-draft.json")
        let draft = WriteGuardTests().draft(track)
        let draftData = try JSONEncoder().encode(draft)
        try draftData.write(to: draftURL)
        // 미리보기도 XML을 함께 읽어 실제 쓰기와 같은 실패를 내야 한다.
        try Data("broken XML".utf8).write(to: fixture.root.appending(path: "masterPlaylists6.xml"))
        let source = fixture.database, share = fixture.shareRoot, directory = fixture.root.appending(path: "preview")
        let before = try Data(contentsOf: source)
        let task = Task {
            try await WritePreviewSnapshot.withCopy(from: source, shareRoot: share, directory: directory) { db, copyShare in
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return
                }
                _ = try RekordboxWriter.write(drafts: [draft], playlists: [.create(key: "p", name: "시험 목록", isFolder: false, parent: .root)],
                                               to: db, dryRun: true, backups: directory.appending(path: "backups"), shareRoot: copyShare)
            }
        }
        do { try await task.value; Issue.record("실패 또는 취소가 전파되지 않음") }
        catch is CancellationError { #expect(cancel) }
        catch let DJCError.writeRefused(reason) { #expect(!cancel && reason.contains("masterPlaylists6.xml")) }
        #expect(try Data(contentsOf: source) == before)
        #expect(try Data(contentsOf: draftURL) == draftData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func EXT가_없으면_사본에서도_같은_이유로_막는다() async throws {
        let fixture = try RekordboxFixture()
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture, withEXT: false)
        var grid = try RekordboxGridWriterTests().draft(fixture, track)
        grid.shift(by: 0.01)
        let report = try await preview(fixture, drafts: [], grids: [grid], gains: [:], tags: [], playlists: [])
        #expect(report.gridWritten.isEmpty && report.gridBlocked.first?.reason?.contains("파형") == true)
    }


    @Test(arguments: ["USBANLZ", "Artwork"])
    func 분석_전_곡의_기존_폴더도_보존해_충돌을_숨기지_않는다(category: String) async throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        let folder = "PIONEER/\(category)/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))"
        let source = fixture.shareRoot.appending(path: folder)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([1]).write(to: source.appending(path: "existing-file"))
        let grid = GridDraft(trackUUID: track.uuid, base: [], segments: [.init(start: 0, bpm: 128, firstBeatNumber: 1)])
        try await WritePreviewSnapshot.withCopy(from: fixture.database, shareRoot: fixture.shareRoot, grids: [grid], directory: fixture.root) { _, share in
            #expect(FileManager.default.fileExists(atPath: share.appending(path: folder + "/existing-file").path))
        }
    }


    @Test(arguments: [false, true])
    func DB_별칭도_독립_사본으로_미리본다(symbolic: Bool) async throws {
        let live = try RekordboxFixture(), aliases = try RekordboxFixture()
        let track = try live.add(TrackSpec())
        let alias = try WriteTargetGuardTests().databaseAlias(live, in: aliases, symbolic: symbolic)
        let before = try Data(contentsOf: live.database)
        try await WritePreviewSnapshot.withCopy(from: alias, shareRoot: live.shareRoot, directory: aliases.root) { db, share in
            #expect(!RekordboxWriteGuard.sameFile(db, live.database))
            let result = try RekordboxWriter.write(drafts: [WriteGuardTests().draft(track)], to: db, dryRun: true,
                                                    backups: aliases.backups, shareRoot: share, guard: WriteTargetGuardTests().guardFor(live))
            #expect(result.written.count == 1)
        }
        #expect(try Data(contentsOf: live.database) == before)
    }

    @Test(arguments: [false, true])
    func 합치기_삭제_파일을_사본에서_검사하고_원본을_보존한다(unsafe: Bool) async throws {
        let fixture = try DuplicateMergeWriterTests().fixture()
        let path = "/PIONEER/USBANLZ/u20/0/ANLZ0000.DAT"
        try fixture.execute("UPDATE djmdContent SET AnalysisDataPath = '\(path)' WHERE ID = '200'")
        let file = try #require(RekordboxShare.analysisURL(path, root: fixture.shareRoot))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3])
        if unsafe {
            let sentinel = fixture.root.appending(path: "sentinel")
            try bytes.write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel)
        } else { try bytes.write(to: file) }
        let merge = try DuplicateMergeWriterTests().draft(fixture)
        let before = try Data(contentsOf: fixture.database)
        let directory = fixture.root.appending(path: "preview")
        do {
            try await WritePreviewSnapshot.withCopy(from: fixture.database, shareRoot: fixture.shareRoot, merges: [merge], directory: directory) { db, share in
                #expect(!unsafe)
                let copied = try #require(RekordboxShare.analysisURL(path, root: share))
                #expect(try Data(contentsOf: copied) == bytes)
                #expect(!RekordboxWriteGuard.sameFile(copied, file))
                let result = try RekordboxWriter.write(drafts: [], merges: [merge], to: db, dryRun: true,
                                                       backups: fixture.backups, shareRoot: share, guard: WriteTargetGuardTests().guardFor(fixture))
                #expect(result.mergeWritten.count == 1)
            }
            #expect(!unsafe)
        } catch let DJCError.writeRefused(reason) { #expect(unsafe && reason.contains("경로가 안전하지")) }
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: ["USBANLZ", "Artwork"], [false, true])
    func 분석_붙이기의_기존_파일과_하위폴더_차단_결과가_같다(category: String, subfolder: Bool) async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let helper = RekordboxAnalysisArtworkTests()
        let plan = try await helper.plan(fixture)
        let (id, uuid) = try helper.addBare(fixture, plan)
        let folder = fixture.shareRoot.appending(path: "PIONEER/\(category)/\(uuid.prefix(3))/\(uuid.dropFirst(3))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appending(path: "existing")
        if subfolder { try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true) }
        else { try Data([1]).write(to: existing) }
        let grid = GridDraft(trackUUID: uuid, base: [], segments: helper.segments)
        let before = try Data(contentsOf: fixture.database)
        let original = try helper.attach(fixture, uuid: uuid, helper.input(plan), dryRun: true)
        let copied = try await WritePreviewSnapshot.withCopy(from: fixture.database, shareRoot: fixture.shareRoot, grids: [grid], directory: fixture.root) { db, share in
            // 아트워크 존재 조건은 바이트를 만들기 전의 계획에서도 같아야 한다.
            let reader = try CipherDatabase(path: db.path, key: RekordboxKey.derive())
            defer { reader.close() }
            if category == "Artwork" {
                #expect(try !RekordboxWriter.hasNoArtwork(id, uuid: uuid, share: share, reader: reader))
            }
            return try RekordboxWriter.write(drafts: [], grids: [grid], analysisInputs: [uuid: helper.input(plan)], to: db, dryRun: true,
                                             backups: fixture.backups, shareRoot: share)
        }
        #expect(copied.analysisWritten.count == original.analysisWritten.count)
        #expect(copied.analysisBlocked.map(\.reason) == original.analysisBlocked.map(\.reason))
        #expect(try Data(contentsOf: fixture.database) == before)
    }


    @Test func 사본_트랜잭션_도중_실패하면_롤백하고_원본에_복원하지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        try fixture.execute("CREATE TRIGGER preview_failure BEFORE UPDATE OF int_1 ON agentRegistry BEGIN SELECT RAISE(ABORT, 'preview transaction failure'); END")
        let before = try Data(contentsOf: fixture.database)
        let directory = fixture.root.appending(path: "preview")
        do {
            try await WritePreviewSnapshot.withCopy(from: fixture.database, shareRoot: fixture.shareRoot, directory: directory) { db, share in
                do {
                    _ = try RekordboxWriter.write(drafts: [WriteGuardTests().draft(track)], to: db, dryRun: true,
                                                   backups: fixture.backups, shareRoot: share)
                    Issue.record("실패 트리거를 통과함")
                } catch {
                    let reader = try CipherDatabase(path: db.path, key: RekordboxKey.derive())
                    defer { reader.close() }
                    #expect(try RekordboxWriter.scalar(reader, "SELECT count(*) FROM djmdCue", []) == 0)
                    throw error
                }
            }
            Issue.record("트랜잭션 실패가 전파되지 않음")
        } catch { #expect(String(describing: error).contains("preview transaction failure")) }
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path).isEmpty)
    }

}
