import DJCDomain
import Foundation
import Testing
@testable import djc

/// #215: `djc cache [--clear <종류>…|all] [--dry-run]`. 폴더는 임시 폴더로 주입한다.
@Suite("djc cache")
struct CacheCommandTests {
    func paths() throws -> DJCCachePaths {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-cache-cmd-\(UUID())")
        let paths = DJCCachePaths(root: root.appending(path: "home"), snapshots: root.appending(path: "snapshots"))
        try FileManager.default.createDirectory(at: paths.waveforms, withIntermediateDirectories: true)
        try Data(count: 2_048).write(to: paths.waveforms.appending(path: "a-1.json"))
        try Data(count: 10).write(to: paths.loudness)
        try FileManager.default.createDirectory(at: paths.root.appending(path: "cue-drafts"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: paths.root.appending(path: "cue-drafts/a.json"))
        return paths
    }

    @Test func 인자를_읽는다() throws {
        #expect(try CacheCommand.Request(["cache"]) == .init(kinds: nil, dryRun: false))
        #expect(try CacheCommand.Request(["cache", "--clear", "waveforms", "loudness"]) == .init(kinds: [.waveforms, .loudness], dryRun: false))
        #expect(try CacheCommand.Request(["cache", "--clear", "all", "--dry-run"]) == .init(kinds: DJCCacheKind.allCases, dryRun: true))
        #expect(try CacheCommand.Request(["cache", "--dry-run", "--clear", "usb-snapshots"]) == .init(kinds: [.usbSnapshots], dryRun: true))
    }

    @Test func 모르는_종류와_빈_비우기는_거부한다() {
        #expect(throws: CacheCommand.Failure.self) { try CacheCommand.Request(["cache", "--clear", "cue-drafts"]) }
        #expect(throws: UsageError.self) { try CacheCommand.Request(["cache", "--clear"]) }
        #expect(throws: UsageError.self) { try CacheCommand.Request(["cache", "--dry-run"]) }
        #expect(throws: UsageError.self) { try CacheCommand.Request(["cache", "waveforms"]) }
    }

    @Test func 용량_보기는_종류마다_한_줄이고_아무것도_지우지_않는다() throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent()) }
        let text = try CacheCommand.run(["cache"], paths: paths)
        for kind in DJCCacheKind.allCases { #expect(text.contains(kind.rawValue), "\(kind)") }
        #expect(FileManager.default.fileExists(atPath: paths.waveforms.appending(path: "a-1.json").path))
    }

    @Test func 미리_보기는_지우지_않고_비우기는_고른_종류만_지운다() throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent()) }
        let preview = try CacheCommand.run(["cache", "--clear", "waveforms", "--dry-run"], paths: paths)
        #expect(preview.contains("waveforms"))
        #expect(FileManager.default.fileExists(atPath: paths.waveforms.appending(path: "a-1.json").path))

        _ = try CacheCommand.run(["cache", "--clear", "waveforms"], paths: paths)
        #expect(!FileManager.default.fileExists(atPath: paths.waveforms.appending(path: "a-1.json").path))
        #expect(FileManager.default.fileExists(atPath: paths.loudness.path), "고르지 않은 종류는 그대로")
        #expect(FileManager.default.fileExists(atPath: paths.root.appending(path: "cue-drafts/a.json").path))
    }
}
