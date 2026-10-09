import DJCDomain
import DJCEnvironment
import Foundation
import RekordboxKit
import Testing
@testable import djc

/// #231: 덮어쓰기·라이브 거부 규칙. 라이브 자리는 시험 프로세스의 임시 rekordbox 폴더(`RekordboxWriter.liveDatabase`)다.
@Suite("CLI 덮어쓰기·라이브 거부")
struct CLIRefusalTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func 라이브_DB는_오류로_거부하고_사본은_통과한다() throws {
        let live = RekordboxWriter.liveDatabase
        #expect(throws: CLIGuards.Refusal.self) { try CLIGuards.refuseLiveDatabase(live) }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 링크는 실제로 있는 파일을 가리킬 때만 풀린다(가짜 라이브 자리를 임시 폴더에 둔다)
        let fakeLive = dir.appending(path: "master.db")
        try Data().write(to: fakeLive)
        let link = dir.appending(path: "link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fakeLive)
        #expect(throws: CLIGuards.Refusal.self) { try CLIGuards.refuseLiveDatabase(link, live: fakeLive) }
        try CLIGuards.refuseLiveDatabase(dir.appending(path: "copy.db"))
    }

    @Test func 라이브_분석_폴더는_거부한다() throws {
        let live = LibrarySnapshot.rekordboxDirectory.appending(path: "share")
        #expect(throws: CLIGuards.Refusal.self) { try CLIGuards.refuseLiveShare(live) }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try CLIGuards.refuseLiveShare(dir)
    }

    @Test func 있는_출력은_overwrite_없이_거부한다() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "o.xml")
        try CLIGuards.refuseExistingOutput(out, overwrite: false)
        try Data("x".utf8).write(to: out)
        #expect(throws: CLIGuards.Refusal.self) { try CLIGuards.refuseExistingOutput(out, overwrite: false) }
        try CLIGuards.refuseExistingOutput(out, overwrite: true)
    }

    @Test func schema_dump와_reflection_dry_run은_있는_파일을_덮지_않는다() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "o.txt")
        try Data("원본".utf8).write(to: out)
        await #expect(throws: CLIGuards.Refusal.self) { try await MainCommands.schemaDump(["schema-dump", "/nonexistent.db", out.path]) }
        await #expect(throws: CLIGuards.Refusal.self) { try await MainCommands.reflectionDryRun(["reflection-dry-run", "--out", out.path]) }
        #expect(try String(contentsOf: out, encoding: .utf8) == "원본")
    }

    @Test func lab_쓰기_실험은_라이브_DB를_오류로_거부한다() async throws {
        let live = RekordboxWriter.liveDatabase.path
        await #expect(throws: CLIGuards.Refusal.self) { try await CueLab.gainWriteTest(["gain-write-test", live, "uuid", "1.0"]) }
        await #expect(throws: CLIGuards.Refusal.self) { try await CueLab.cueWriteSelftest(["cue-write-selftest", "--db", live]) }
        await #expect(throws: CLIGuards.Refusal.self) { try await TrackLab.tagWriteTest(["tag-write-test", "--db", live, "1:title=x"]) }
        await #expect(throws: CLIGuards.Refusal.self) { try await TrackLab.artworkWriteTest(["artwork-write-test", "--db", live, "--delete", "1"]) }
        let share = LibrarySnapshot.rekordboxDirectory.appending(path: "share").path
        await #expect(throws: CLIGuards.Refusal.self) {
            try await TrackLab.analysisAttachTest(["analysis-attach-test", "--db", "/tmp/not-live.db", "--share", share, "1"])
        }
        await #expect(throws: CLIGuards.Refusal.self) {
            try await TrackLab.analysisAttachTest(["analysis-attach-test", "--db", live, "--share", "/tmp/x", "1"])
        }
    }

    @Test func lab_그리드_쓰기_실험은_라이브_DB와_분석_폴더를_오류로_거부한다() async throws {
        let live = RekordboxWriter.liveDatabase.path
        let share = LibrarySnapshot.rekordboxDirectory.appending(path: "share").path
        await #expect(throws: CLIGuards.Refusal.self) {
            try await GridLab.gridWriteTest(["grid-write-test", live, "/tmp/not-live-share", "uuid", "128"])
        }
        await #expect(throws: CLIGuards.Refusal.self) {
            try await GridLab.gridWriteTest(["grid-write-test", "/tmp/not-live.db", share, "uuid", "128"])
        }
    }

    /// 재현 실험은 --work 폴더를 지우고 그 안 master.db에 쓴다: 작업 폴더가 라이브 rekordbox 폴더면 지우기 전에 거부한다
    @Test func lab_재현_실험은_라이브_폴더를_작업_폴더로_받지_않는다() async throws {
        let work = RekordboxWriter.liveDatabase.deletingLastPathComponent().path
        let old = "/tmp/djc-refusal-missing-old.db", new = "/tmp/djc-refusal-missing-new.db"
        await #expect(throws: CLIGuards.Refusal.self) {
            try await CueLab.loopRepro(["loop-repro", "--old", old, "--new", new, "--ids", "1", "--work", work])
        }
        await #expect(throws: CLIGuards.Refusal.self) { try await CueLab.vbrCueRepro(["vbr-cue-repro", "--work", work]) }
        await #expect(throws: CLIGuards.Refusal.self) {
            try await PlaylistLab.repro(["playlist-repro", "--old", old, "--new", new, "--edits", "/tmp/djc-refusal-missing.json", "--work", work])
        }
    }

    /// 임시 폴더 밖 표지 폴더(지워지면 안 되는 것). 시험이 틀려도 이 저장소 `.build/` 아래만 잃는다
    func outsideScratch() throws -> URL {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: ".build/djc-lab-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: url.appending(path: "keep.txt"))
        return url
    }

    /// 재현 실험의 --work는 통째로 지워진다: 임시 폴더 밖이면 지우기 전에 거부하고 아무것도 지우지 않는다
    @Test func lab_재현_실험은_임시_폴더_밖_작업_폴더를_지우지_않고_거부한다() async throws {
        let outside = try outsideScratch()
        defer { try? FileManager.default.removeItem(at: outside) }
        let keep = outside.appending(path: "keep.txt")
        let old = "/tmp/djc-refusal-missing-old.db", new = "/tmp/djc-refusal-missing-new.db"
        await #expect(throws: CLIGuards.Refusal.self) {
            try await CueLab.loopRepro(["loop-repro", "--old", old, "--new", new, "--ids", "1", "--work", outside.path])
        }
        #expect(FileManager.default.fileExists(atPath: keep.path))
        await #expect(throws: CLIGuards.Refusal.self) { try await CueLab.vbrCueRepro(["vbr-cue-repro", "--work", outside.path]) }
        #expect(FileManager.default.fileExists(atPath: keep.path))
        await #expect(throws: CLIGuards.Refusal.self) {
            try await PlaylistLab.repro(["playlist-repro", "--old", old, "--new", new, "--edits", "/tmp/djc-refusal-missing.json", "--work", outside.path])
        }
        #expect(FileManager.default.fileExists(atPath: keep.path))
        // 임시 폴더 안의 링크가 밖을 가리켜도 거부한다
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appending(path: "work")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: CLIGuards.Refusal.self) { try LabWorkFolder.reset(link.path) }
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    /// 임시 폴더 안이어도 rekordbox 폴더·DJCrate 데이터 폴더와 그 위, 임시 폴더 뿌리 자체는 거부한다(지우기 전 판정만 본다)
    @Test func lab_작업_폴더는_라이브_폴더의_상위와_DJCrate_데이터_폴더를_거부한다() throws {
        let rekordbox = LibrarySnapshot.rekordboxDirectory
        let home = FileManager.default.homeDirectoryForCurrentUser
        let refused = [rekordbox, rekordbox.deletingLastPathComponent(), rekordbox.appending(path: "share"),
                       DJCIdentity.dataDirectory, DJCIdentity.dataDirectory.deletingLastPathComponent(),
                       home.appending(path: "Library/Pioneer"), home.appending(path: "Library"),
                       DJCIdentity.userSupportDirectory, home,
                       URL(filePath: NSTemporaryDirectory()), URL(filePath: "/tmp"), URL(filePath: "/private/var/folders")]
        for folder in refused {
            #expect(throws: CLIGuards.Refusal.self, "\(folder.path)") { try LabWorkFolder.check(folder.path) }
        }
    }

    @Test func lab_작업_폴더가_보호_폴더를_품으면_지우지_않고_거부한다() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appending(path: "a/protected")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let keep = inner.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: keep)
        #expect(throws: CLIGuards.Refusal.self) { try LabWorkFolder.reset(dir.path, protected: [inner]) }
        #expect(throws: CLIGuards.Refusal.self) { try LabWorkFolder.reset(dir.appending(path: "a").path, protected: [inner]) }
        #expect(throws: CLIGuards.Refusal.self) { try LabWorkFolder.reset(inner.path, protected: [inner]) }
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func lab_작업_폴더는_임시_폴더_안이면_비우고_다시_만든다() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: work.appending(path: "old.txt"))
        let made = try LabWorkFolder.reset(work.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: made.path).isEmpty)
        let fresh = try LabWorkFolder.reset(dir.appending(path: "new/nested").path)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}
