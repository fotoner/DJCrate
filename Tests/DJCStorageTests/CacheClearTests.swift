import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing

/// #215: 캐시 용량 보기·비우기. 데이터 폴더·스냅샷 폴더는 모두 임시 폴더로 주입한다(사용자 폴더를 열지 않는다).
@Suite("캐시 비우기")
struct CacheClearTests {
    struct Scene {
        let root: URL
        var paths: DJCCachePaths { DJCCachePaths(root: root.appending(path: "home"), snapshots: root.appending(path: "rb/djc-snapshots")) }
        var home: URL { paths.root }

        @discardableResult
        func write(_ relative: String, bytes: Int = 100, under base: URL? = nil) throws -> URL {
            let url = (base ?? home).appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
            return url
        }

        func exists(_ relative: String, under base: URL? = nil) -> Bool {
            FileManager.default.fileExists(atPath: (base ?? home).appending(path: relative).path)
        }
    }

    func scene() throws -> Scene {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-cache-clear-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Scene(root: root)
    }

    /// 사용자 데이터 자리마다 파일 하나(폴더면 그 안에)
    static let userData = [
        "cue-drafts/a.json", "grid-drafts/a.json", "tag-drafts/a.json", "artwork-drafts/a.json", "gain-drafts.json",
        "playlist-drafts.json", "staged.json", "playlist-imports.json", "damaged-drafts/a.json", "usb-drafts/V.json",
        "usb-sessions/V.lock", "usb-staging/s1/x.bin", "usb-physical-allow.json", "usb-physical-deny.json",
        "rekordbox-backups/20260101-write/master.db", "usb-backups/V/20260101-export/x.bin", "edits/a.wav",
        "reflection.json", "last-write-result.json",
    ]

    func seedCaches(_ scene: Scene) throws {
        try scene.write("waveforms/a-1.json", bytes: 1_000)
        try scene.write("analysis/a-1.json", bytes: 200)
        try scene.write("analysis/grid-estimates/a-1.json", bytes: 300)
        try scene.write("analysis/chroma/a-1.bin", bytes: 400)
        try scene.write("loudness.json", bytes: 50)
        try scene.write("preview-waveforms.plist", bytes: 60)
        try scene.write("usb-snapshots/V/20260101T000000/exportLibrary.db", bytes: 70)
        try scene.write("usb-snapshots/V/20260102T000000/exportLibrary.db", bytes: 80)
    }

    @Test func 종류별_용량은_하위_폴더_파일까지_센다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try seedCaches(scene)
        try scene.write("master-2026-01-01T000000.db", bytes: 500, under: scene.paths.snapshots)
        let usage = Dictionary(uniqueKeysWithValues: DJCCache.usage(paths: scene.paths).map { ($0.kind, $0) })
        #expect(usage[.waveforms]?.bytes == 1_000 && usage[.waveforms]?.files == 1)
        #expect(usage[.analysis]?.bytes == 900 && usage[.analysis]?.files == 3)
        #expect(usage[.loudness]?.bytes == 50)
        #expect(usage[.previewWaveforms]?.bytes == 60)
        #expect(usage[.usbSnapshots]?.bytes == 150 && usage[.usbSnapshots]?.files == 2)
        #expect(usage[.snapshots]?.bytes == 500)
        #expect(DJCCache.usage(paths: scene.paths).map(\.kind) == DJCCacheKind.allCases, "순서는 종류 목록 그대로")
    }

    @Test func 모두_비워도_사용자_데이터는_그대로이고_캐시_폴더는_남는다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try seedCaches(scene)
        for file in Self.userData { try scene.write(file) }

        let outcomes = DJCCache.clear(DJCCacheKind.allCases, paths: scene.paths)

        for file in Self.userData { #expect(scene.exists(file), "\(file)") }
        for gone in ["waveforms/a-1.json", "analysis/a-1.json", "analysis/grid-estimates/a-1.json", "analysis/chroma/a-1.bin",
                     "loudness.json", "preview-waveforms.plist", "usb-snapshots/V/20260101T000000"] {
            #expect(!scene.exists(gone), "\(gone)")
        }
        for kept in ["waveforms", "analysis", "analysis/chroma", "analysis/grid-estimates"] {
            #expect(scene.exists(kept), "캐시를 다시 만들 폴더는 남긴다: \(kept)")
        }
        let freed = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.kind, $0.freedBytes) })
        #expect(freed[.waveforms] == 1_000 && freed[.analysis] == 900 && freed[.loudness] == 50 && freed[.previewWaveforms] == 60)
        #expect(freed[.usbSnapshots] == 70, "볼륨마다 가장 새 사본 하나는 남긴다")
        #expect(scene.exists("usb-snapshots/V/20260102T000000/exportLibrary.db"))
        #expect(outcomes.allSatisfy { $0.skipped == nil })
    }

    @Test func 읽기_스냅샷은_최신과_앱이_연_것을_남기고_진행_중인_사본은_건드리지_않는다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let folder = scene.paths.snapshots
        let opened = try scene.write("master-2026-01-01T000000.db", bytes: 10, under: folder)
        try scene.write("master-2026-01-02T000000.db", bytes: 20, under: folder)
        try scene.write("master-2026-01-02T000000.db.itunes.json", bytes: 1, under: folder)
        try scene.write("master-2026-01-02T000000.db-wal", bytes: 2, under: folder)
        try scene.write("master-2026-01-03T000000.db", bytes: 30, under: folder)
        try scene.write("master-2026-01-04T000000.db.part", bytes: 40, under: folder)

        let outcome = try #require(DJCCache.clear([.snapshots], paths: scene.paths, keepingSnapshots: [opened]).first)

        #expect(scene.exists("master-2026-01-03T000000.db", under: folder), "최신 하나")
        #expect(scene.exists("master-2026-01-01T000000.db", under: folder), "앱이 연 사본")
        #expect(scene.exists("master-2026-01-04T000000.db.part", under: folder), "뜨는 중인 사본")
        for gone in ["master-2026-01-02T000000.db", "master-2026-01-02T000000.db.itunes.json", "master-2026-01-02T000000.db-wal"] {
            #expect(!scene.exists(gone, under: folder), "\(gone)")
        }
        #expect(outcome.freedBytes == 23 && outcome.keptItems == 2)
    }

    @Test func USB_사본은_세션_폴더를_건드리지_않는다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try seedCaches(scene)
        for session in ["usb-snapshots/local-s1/master.db", "usb-snapshots/usb-s1/exportLibrary.db", "usb-snapshots/info-u1/export.pdb"] {
            try scene.write(session)
        }
        _ = DJCCache.clear([.usbSnapshots], paths: scene.paths)
        for session in ["usb-snapshots/local-s1/master.db", "usb-snapshots/usb-s1/exportLibrary.db", "usb-snapshots/info-u1/export.pdb"] {
            #expect(scene.exists(session), "\(session)")
        }
        #expect(!scene.exists("usb-snapshots/V/20260101T000000"))
    }

    @Test func 닫히지_않은_USB_저널이_있으면_USB_사본은_비우지_않는다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try seedCaches(scene)
        try Data("{\"state\":\"filesWritten\"}".utf8).write(to: try scene.write("usb-sessions/V.json"))

        let outcomes = DJCCache.clear([.usbSnapshots, .waveforms], paths: scene.paths)

        #expect(scene.exists("usb-snapshots/V/20260101T000000/exportLibrary.db"))
        #expect(outcomes.first { $0.kind == .usbSnapshots }?.skipped != nil)
        #expect(outcomes.first { $0.kind == .usbSnapshots }?.freedBytes == 0)
        #expect(!scene.exists("waveforms/a-1.json"), "USB와 상관없는 캐시는 비운다")
    }

    @Test func USB_쓰기_잠금이_잡혀_있으면_USB_사본은_비우지_않고_풀리면_비운다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try seedCaches(scene)
        let lock = try UsbVolumeLock.acquire(directory: scene.home.appending(path: "usb-sessions"), key: "V")

        #expect(DJCCache.clear([.usbSnapshots], paths: scene.paths).first?.skipped != nil)
        #expect(scene.exists("usb-snapshots/V/20260101T000000/exportLibrary.db"))
        lock.release()
        #expect(DJCCache.clear([.usbSnapshots], paths: scene.paths).first?.skipped == nil)
        #expect(!scene.exists("usb-snapshots/V/20260101T000000"))
    }

    @Test func 닫힌_USB_저널은_막지_않는다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try seedCaches(scene)
        let changes = UsbChangeSet(session: "abcdefgh", label: "t", purpose: .export, formats: [.oneLibrary], requiredRules: [],
                                   databases: [], copies: [], writes: [], removals: [], base: nil,
                                   target: UsbTargetFingerprint(mustExist: [:], mustNotExist: []),
                                   stagingDirectory: "/tmp/x", idHighWater: [:])
        var journal = UsbJournal(changes: changes, volumeUUID: "V", volumeName: "DJCTEST", now: .now)
        journal.state = .verified
        try UsbJournal.encoder().encode(journal).write(to: try scene.write("usb-sessions/V.json"))
        #expect(DJCCache.clear([.usbSnapshots], paths: scene.paths).first?.skipped == nil)
    }

    @Test func 미리_보기는_지울_양만_세고_아무것도_지우지_않는다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try seedCaches(scene)
        let outcomes = DJCCache.clear(DJCCacheKind.allCases, paths: scene.paths, dryRun: true)
        #expect(outcomes.first { $0.kind == .analysis }?.freedBytes == 900)
        for file in ["waveforms/a-1.json", "analysis/chroma/a-1.bin", "loudness.json", "preview-waveforms.plist",
                     "usb-snapshots/V/20260101T000000/exportLibrary.db"] {
            #expect(scene.exists(file), "\(file)")
        }
    }

    @Test func 비우는_중_정리가_함께_돌아도_사용자_데이터는_그대로다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        for index in 0..<200 { try scene.write("waveforms/w\(index)-1.json", bytes: 1_000) }
        for index in 0..<50 { try scene.write("analysis/chroma/c\(index)-1.bin", bytes: 1_000) }
        for file in Self.userData { try scene.write(file) }
        let paths = scene.paths
        async let pruned: Void = Task.detached { CacheMaintenance.prune(maxBytes: 10_000, paths: paths) }.value
        async let cleared = Task.detached { DJCCache.clear([.waveforms, .analysis], paths: paths) }.value
        _ = await (pruned, cleared)
        for file in Self.userData { #expect(scene.exists(file), "\(file)") }
        #expect(DJCCache.usage(paths: paths).first { $0.kind == .waveforms }?.files == 0)
    }

    @Test func 비운_뒤_파형은_다시_만들어진다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let audio = scene.root.appending(path: "audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let wav = try AudioFixture.wav(seconds: 1, in: audio)
        _ = try WaveformCache.load(fileAt: wav, key: "synthetic", paths: scene.paths)
        #expect(DJCCache.usage(paths: scene.paths).first { $0.kind == .waveforms }?.files == 1)
        _ = DJCCache.clear([.waveforms], paths: scene.paths)
        #expect(DJCCache.usage(paths: scene.paths).first { $0.kind == .waveforms }?.files == 0)
        _ = try WaveformCache.load(fileAt: wav, key: "synthetic", paths: scene.paths)
        #expect(DJCCache.usage(paths: scene.paths).first { $0.kind == .waveforms }?.files == 1)
    }
}
