import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 임시 폴더는 `/tmp`·`/private/tmp`, `/var/folders`·`/private/var/folders` 두 표기로 불린다(#136).
/// 사본을 어느 표기로 줘도 분석 파일 백업·복원·미리 보기 경로 검사가 같은 규칙으로 통과하고, 막을 경로는 그대로 막는다.
@Suite("임시 폴더 사본 경로")
struct RekordboxTempCopyPathTests {
    /// 사본을 둘 폴더. `$TMPDIR`(`/var/folders/…`)는 `/private`를 붙인 표기도 함께 본다.
    static let parents: [String] = {
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return ["/tmp", "/private/tmp", temp] + (temp.hasPrefix("/var/") ? ["/private" + temp] : [])
    }()

    /// 같은 폴더의 다른 표기(`/tmp/x` ↔ `/private/tmp/x`)
    func alias(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
    }

    func alias(_ url: URL) -> URL { URL(filePath: alias(url.path)) }

    /// 쓰기·복원을 끝까지 도는 시험은 표기를 둘씩 나눠 쓴다(#167): `/private`가 없는 표기와 있는 표기. 네 표기가 이 시험들 전체에서
    /// 한 번 이상 쓰인다. 표기마다 같은 상대 경로가 되는지는 DB 없이 네 표기를 모두 보는 `절대_경로는_…`가, 같은 시험 안의 다른 표기는
    /// `alias`가 본다.
    static let plainParents = [parents[0], parents[2]]
    static let privateParents = [parents[1], parents[parents.count - 1]]
    /// 옛 절대 경로 복원: 표기마다 한 번, 다른 표기로 적기는 번갈아
    static let oldPathCases = parents.enumerated().map { ($0.element, $0.offset % 2 == 1) }

    @Test func 쓰기_시험은_모든_표기를_한_번_이상_쓴다() {
        #expect(Set(Self.plainParents + Self.privateParents) == Set(Self.parents))
        #expect(Set(Self.oldPathCases.map(\.0)) == Set(Self.parents) && Set(Self.oldPathCases.map(\.1)) == [false, true])
    }

    @Test(arguments: parents)
    func 절대_경로는_임시_폴더의_어느_표기로_적어도_같은_상대_경로가_된다(_ parent: String) throws {
        let fixture = try RekordboxFixture(parent: URL(filePath: parent))
        let folder = fixture.shareRoot.appending(path: "PIONEER/USBANLZ/abc/def")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("현재".utf8).write(to: folder.appending(path: "ANLZ0000.DAT"))
        // 있는 파일, 없는 파일, 아직 없는 폴더 아래 파일(분석 붙이기로 만들 자리)
        let relatives = ["PIONEER/USBANLZ/abc/def/ANLZ0000.DAT", "PIONEER/USBANLZ/abc/def/ANLZ0000.EXT", "PIONEER/USBANLZ/new/folder/ANLZ0000.DAT"]
        for root in [fixture.shareRoot, alias(fixture.shareRoot)] {
            var targets = Set<String>()
            for relative in relatives {
                for spelled in [relative, fixture.shareRoot.path + "/" + relative, alias(fixture.shareRoot.path) + "/" + relative] {
                    let target = try RekordboxWriter.backupTarget(spelled, shareRoot: root)
                    #expect(target.relative == relative, "\(spelled)")
                    targets.insert(target.url.path)
                }
            }
            // 표기만 다른 같은 파일은 같은 대상이 된다(중복 대상 검사가 놓치지 않게).
            #expect(targets.count == relatives.count)
        }
    }

    @Test(arguments: privateParents)
    func 그리드_쓰기의_분석_파일_백업과_되돌리기가_통과한다(_ parent: String) throws {
        let fixture = try RekordboxFixture(parent: URL(filePath: parent))
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        let files = [fixture.analysisURL(for: track), fixture.analysisURL(for: track, ext: "EXT")]
        let originals = try files.map { try Data(contentsOf: $0) }
        var grid = try RekordboxGridWriterTests().draft(fixture, track)
        grid.shift(by: 0.010)
        let report = try RekordboxWriter.write(drafts: [], grids: [grid], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        #expect(try files.map { try Data(contentsOf: $0) } != originals)
        let backup = URL(filePath: try #require(report.backup))
        let paths = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: backup.appending(path: "anlz/manifest.json")))
        #expect(!paths.isEmpty && paths.values.allSatisfy { $0.hasPrefix("PIONEER/USBANLZ/") })
        try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(try files.map { try Data(contentsOf: $0) } == originals)
    }

    @Test(arguments: plainParents)
    func 분석_붙이기로_만든_파일도_되돌리고_다시_살린다(_ parent: String) async throws {
        let attach = RekordboxAnalysisAttachTests()
        let fixture = try RekordboxFixture(parent: URL(filePath: parent))
        try fixture.add(TrackSpec())   // 기기 정보를 읽을 기존 곡
        let plan = try await attach.plan(try AudioFixture.wav(seconds: 20, in: fixture.audio))
        let (_, uuid) = try attach.addBare(fixture, plan)
        let grid = GridDraft(trackUUID: uuid, base: [], segments: attach.segments)
        let report = try attach.attach(fixture, [grid], inputs: [uuid: .init(duration: plan.duration, loudness: -9, peak: 1)])
        let created = (report.createdFiles ?? []).map { URL(filePath: $0) }
        #expect(created.count == 3 && created.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let backup = URL(filePath: try #require(report.backup))
        let saved = try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(created.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups, shareRoot: alias(fixture.shareRoot))
        #expect(created.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test(arguments: oldPathCases)
    func 옛_절대_경로는_다른_표기로_적혀도_복원한다(_ parent: String, _ aliased: Bool) throws {
        let paths = RekordboxBackupPathTests()
        let (fixture, backup, target) = try paths.setup(parent: URL(filePath: parent))
        try paths.manifest(["0.DAT": aliased ? alias(target.path) : target.path], backup)
        let saved = try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(try Data(contentsOf: target) == Data("백업".utf8))
        let savedManifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: saved.appending(path: "anlz/manifest.json")))
        #expect(Array(savedManifest.values) == [paths.relative])
    }

    /// 막는 경우마다 표기 하나: 표기를 돌려 네 표기가 모두 한 번 이상 쓰인다. 표기 × 경우 전체(24가지)는 같은 규칙(`backupTarget`)을
    /// 되풀이할 뿐이라 줄였다(#167). 표기마다 같은 상대 경로가 되는 것은 위 `절대_경로는_…` 시험이 본다.
    static let refusedKinds = ["outside", "sibling", "traversal", "other-folder", "link", "duplicate"]
    static let refusedCases = refusedKinds.enumerated().map { (parents[$0.offset % parents.count], $0.element) }

    @Test func 막는_경우는_모든_표기를_한_번_이상_쓴다() {
        #expect(Set(Self.refusedCases.map(\.0)) == Set(Self.parents))
        #expect(Self.refusedCases.map(\.1) == Self.refusedKinds)
    }

    @Test(arguments: refusedCases)
    func 임시_폴더에서도_루트_밖_이동_링크_중복은_막는다(_ parent: String, _ kind: String) throws {
        let paths = RekordboxBackupPathTests()
        let (fixture, backup, target) = try paths.setup(parent: URL(filePath: parent))
        let fm = FileManager.default
        let share = alias(fixture.shareRoot.path)
        let sentinel = fixture.root.appending(path: "ANLZ0000.DAT")
        try Data("보존".utf8).write(to: sentinel)
        var manifest = ["0.DAT": alias(target.path)]
        switch kind {
        case "outside": manifest["0.DAT"] = alias(sentinel.path)
        case "sibling":
            // 이름 앞부분만 같은 옆 폴더(share-other)는 share 안이 아니다.
            let other = fixture.root.appending(path: "share-other/PIONEER/USBANLZ/abc/def/ANLZ0000.DAT")
            try fm.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("보존".utf8).write(to: other)
            manifest["0.DAT"] = alias(other.path)
        case "traversal": manifest["0.DAT"] = share + "/PIONEER/USBANLZ/abc/def/../../../../ANLZ0000.DAT"
        case "other-folder": manifest["0.DAT"] = share + "/PIONEER/USBANLZ-other/abc/ANLZ0000.DAT"
        case "link":
            let link = fixture.shareRoot.appending(path: "PIONEER/USBANLZ"), moved = fixture.root.appending(path: "moved")
            try fm.moveItem(at: link, to: moved)
            try fm.createSymbolicLink(at: link, withDestinationURL: moved)
        default: manifest["1.DAT"] = target.path
        }
        try paths.manifest(manifest, backup)
        try paths.refused(fixture, backup)
        #expect(try Data(contentsOf: sentinel) == Data("보존".utf8))
    }

    @Test(arguments: plainParents)
    func 미리_보기_사본은_없는_분석_파일과_폴더도_같은_규칙으로_본다(_ parent: String) async throws {
        let fixture = try RekordboxFixture(parent: URL(filePath: parent))
        // EXT가 없는 곡과 분석 전 곡(UUID 폴더가 아직 없음)
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture, withEXT: false)
        var grid = try RekordboxGridWriterTests().draft(fixture, track)
        grid.shift(by: 0.01)
        let bare = try fixture.add(TrackSpec())
        let attachGrid = GridDraft(trackUUID: bare.uuid, base: [], segments: RekordboxAnalysisAttachTests().segments)
        let directory = fixture.root.appending(path: "preview")
        try await WritePreviewSnapshot.withCopy(from: fixture.database, shareRoot: fixture.shareRoot, grids: [grid, attachGrid],
                                                directory: directory) { _, share in
            let copied = try #require(RekordboxShare.analysisURL(track.analysisDataPath, root: share))
            #expect(FileManager.default.fileExists(atPath: copied.path))
            #expect(!FileManager.default.fileExists(atPath: copied.deletingPathExtension().appendingPathExtension("EXT").path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: privateParents)
    func 곡을_뺄_때_같은_분석_폴더를_가리키는_다른_곡은_표기와_상관없이_알아챈다(_ parent: String) throws {
        let deletion = RekordboxDeletionFilesTests()
        let fixture = try RekordboxFixture(parent: URL(filePath: parent))
        var track = TrackSpec(id: "100", uuid: deletion.uuid)
        track.dataStatus = 0
        track.analysisDataPath = deletion.relative
        try fixture.add(track)
        let dat = try #require(RekordboxShare.analysisURL(deletion.relative, root: fixture.shareRoot))
        try FileManager.default.createDirectory(at: dat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dat)
        // 다른 곡이 같은 폴더의 아직 없는 파일을 가리킨다.
        var other = TrackSpec(id: "200")
        other.analysisDataPath = deletion.relative.replacingOccurrences(of: "ANLZ0000.DAT", with: "ANLZ0001.DAT")
        try fixture.add(other)
        let report = try RekordboxTrackWriter.delete(contentIDs: ["100"], from: fixture.database, shareRoot: fixture.shareRoot,
                                                     dryRun: false, backups: fixture.backups)
        #expect(report.deleted.first?.reason == RekordboxWriter.fileOwnershipWarning)
        #expect(FileManager.default.fileExists(atPath: dat.path))
    }

    @Test(arguments: parents)
    func 라이브_폴더를_다른_표기로_줘도_라이브로_본다(_ parent: String) throws {
        let fixture = try RekordboxFixture(parent: URL(filePath: parent))
        let copy = try RekordboxFixture(parent: URL(filePath: parent))
        // DJC_REKORDBOX_DIR을 다른 표기로 준 경우: 같은 라이브러리면 라이브 검사(rekordbox 실행 등)를 그대로 받는다.
        let writeGuard = RekordboxWriteGuard(isRekordboxRunning: { true }, appVersion: { "7.2.18" }, liveDirectories: [alias(fixture.root)])
        #expect(writeGuard.isLive(fixture.database))
        #expect(throws: DJCError.self) { try writeGuard.checkTargets(fixture.database, shareRoot: nil, dryRun: false) }
        // 사본 DB에 라이브 share를 다른 표기로 붙여도 막는다.
        #expect(!writeGuard.isLive(copy.database))
        #expect(throws: DJCError.self) { try writeGuard.checkTargets(copy.database, shareRoot: fixture.shareRoot, dryRun: true) }
        #expect(try writeGuard.checkTargets(copy.database, shareRoot: alias(copy.shareRoot), dryRun: true) == alias(copy.shareRoot))
    }
}
