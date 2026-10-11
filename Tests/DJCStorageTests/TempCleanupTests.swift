import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit
import Testing

/// #219: 비정상 종료 뒤 남은 임시 파일·폴더 청소. 데이터 폴더·임시 폴더는 모두 임시 폴더로 주입한다(사용자 폴더를 열지 않는다).
@Suite("임시 파일 청소")
struct TempCleanupTests {
    struct Scene {
        let root: URL
        var home: URL { root.appending(path: "home") }
        var tmp: URL { root.appending(path: "tmp") }
        var paths: DJCCachePaths { DJCCachePaths(root: home, snapshots: root.appending(path: "snapshots")) }

        @discardableResult
        func write(_ relative: String, under base: URL, age: TimeInterval = 0) throws -> URL {
            let url = base.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 10).write(to: url)
            try self.age(url, age)
            return url
        }

        func age(_ url: URL, _ seconds: TimeInterval) throws {
            let past = Date().addingTimeInterval(-seconds)
            let walker = FileManager.default.enumerator(atPath: url.path)
            for case let child as String in walker ?? FileManager.default.enumerator(atPath: "/var/empty")! {
                try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.appending(path: child).path)
            }
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        }

        func exists(_ relative: String, under base: URL) -> Bool {
            FileManager.default.fileExists(atPath: base.appending(path: relative).path)
        }
    }

    func scene() throws -> Scene {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-temp-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: "tmp"), withIntermediateDirectories: true)
        return Scene(root: root)
    }

    func journal(_ scene: Scene, session: String, state: UsbJournal.State, key: String = "V") throws {
        let changes = UsbChangeSet(session: session, label: "t", purpose: .export, formats: [.oneLibrary], requiredRules: [],
                                   databases: [], copies: [], writes: [], removals: [], base: nil,
                                   target: UsbTargetFingerprint(mustExist: [:], mustNotExist: []),
                                   stagingDirectory: scene.home.appending(path: "usb-staging/\(session)").path, idHighWater: [:])
        var journal = UsbJournal(changes: changes, volumeUUID: key, volumeName: "DJCTEST", now: .now)
        journal.state = state
        try FileManager.default.createDirectory(at: scene.home.appending(path: "usb-sessions"), withIntermediateDirectories: true)
        try UsbJournal.encoder().encode(journal).write(to: scene.home.appending(path: "usb-sessions/\(key).json"))
    }

    @Test func 오래된_미리_보기_파형_임시_파일만_지운다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.write("preview-waveforms.plist.sb-1a2b", under: scene.home, age: 3_600)
        try scene.write("preview-waveforms.plist.sb-new", under: scene.home)
        try scene.write("preview-waveforms.plist", under: scene.home, age: 3_600)
        try scene.write("loudness.json", under: scene.home, age: 3_600)

        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp)

        #expect(!scene.exists("preview-waveforms.plist.sb-1a2b", under: scene.home))
        #expect(scene.exists("preview-waveforms.plist.sb-new", under: scene.home), "방금 쓰는 중일 수 있다")
        #expect(scene.exists("preview-waveforms.plist", under: scene.home))
        #expect(scene.exists("loudness.json", under: scene.home))
    }

    @Test func 미리_보기_사본_폴더는_오래된_것만_지운다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let old = try scene.write("djc-preview-AAAA/master.db", under: scene.tmp)
        try scene.age(old.deletingLastPathComponent(), 7_200)
        try scene.write("djc-preview-BBBB/master.db", under: scene.tmp)
        try scene.write("other-app/x.bin", under: scene.tmp, age: 7_200)

        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp)

        #expect(!scene.exists("djc-preview-AAAA", under: scene.tmp))
        #expect(scene.exists("djc-preview-BBBB", under: scene.tmp))
        #expect(scene.exists("other-app/x.bin", under: scene.tmp), "djc 것이 아닌 폴더는 건드리지 않는다")
    }

    @Test func 시험_샌드박스는_주인_프로세스가_없을_때만_지운다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.write("djc-test-sandbox-111/a.db", under: scene.tmp)
        try scene.write("djc-test-sandbox-222/a.db", under: scene.tmp)
        try scene.write("djc-test-sandbox-notapid/a.db", under: scene.tmp)

        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp, isProcessAlive: { $0 == 222 })

        #expect(!scene.exists("djc-test-sandbox-111", under: scene.tmp))
        #expect(scene.exists("djc-test-sandbox-222", under: scene.tmp))
        #expect(scene.exists("djc-test-sandbox-notapid", under: scene.tmp), "pid를 읽지 못하면 남긴다")
    }

    /// USB 동기화 전용 DB 사본(클라우드 토큰 포함)은 앱이 죽으면 deinit이 지우지 못한다.
    @Test func USB_동기화_사본은_주인_프로세스가_없거나_오래된_옛_이름만_지운다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let mine = ProcessInfo.processInfo.processIdentifier
        let uuid = "12345678-0000-4000-8000-000000000000"
        for base in [scene.tmp.appending(path: "djc-usb-sync-snapshots"), scene.home.appending(path: "usb-sync-snapshots")] {
            try scene.write("111-\(uuid)/master.db", under: base)
            try scene.write("222-\(uuid)/master.db", under: base)
            try scene.write("\(mine)-\(uuid)/master.db", under: base)
            let old = try scene.write("\(uuid)/master.db", under: base)
            try scene.age(old.deletingLastPathComponent(), 172_800)
            try scene.write("87654321-0000-4000-8000-000000000000/master.db", under: base)
        }

        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp, isProcessAlive: { $0 == 222 })

        for base in [scene.tmp.appending(path: "djc-usb-sync-snapshots"), scene.home.appending(path: "usb-sync-snapshots")] {
            #expect(!scene.exists("111-\(uuid)", under: base))
            #expect(scene.exists("222-\(uuid)/master.db", under: base), "다른 실행이 쓰는 중")
            #expect(scene.exists("\(mine)-\(uuid)/master.db", under: base))
            #expect(!scene.exists("\(uuid)", under: base), "주인을 모르는 옛 이름은 오래된 것만")
            #expect(scene.exists("87654321-0000-4000-8000-000000000000/master.db", under: base))
        }
    }

    @Test func 내_프로세스의_샌드박스는_지우지_않는다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let mine = ProcessInfo.processInfo.processIdentifier
        try scene.write("djc-test-sandbox-\(mine)/a.db", under: scene.tmp)
        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp, isProcessAlive: { _ in false })
        #expect(scene.exists("djc-test-sandbox-\(mine)", under: scene.tmp))
    }

    @Test func USB_준비_폴더는_열린_저널이_가리키면_남기고_가리키지_않으면_지운다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let staging = scene.home.appending(path: "usb-staging")
        for name in ["openone", "openone-verify", "orphan", "orphan-verify"] {
            let file = try scene.write("\(name)/x.bin", under: staging)
            try scene.age(file.deletingLastPathComponent(), 172_800)
        }
        try journal(scene, session: "openone", state: .backedUp)

        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp)

        #expect(scene.exists("openone/x.bin", under: staging))
        #expect(scene.exists("openone-verify/x.bin", under: staging))
        #expect(!scene.exists("orphan", under: staging))
        #expect(!scene.exists("orphan-verify", under: staging))
        #expect(scene.exists("usb-sessions/V.json", under: scene.home), "저널은 건드리지 않는다")
    }

    @Test func 닫힌_저널의_준비_폴더는_지우고_갓_만든_폴더는_남긴다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let staging = scene.home.appending(path: "usb-staging")
        let old = try scene.write("done/x.bin", under: staging)
        try scene.age(old.deletingLastPathComponent(), 172_800)
        try scene.write("planning/x.bin", under: staging)
        try journal(scene, session: "done", state: .verified)

        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp)

        #expect(!scene.exists("done", under: staging))
        #expect(scene.exists("planning/x.bin", under: staging), "저널을 쓰기 전 계획 중일 수 있다")
    }

    @Test func 읽지_못하는_저널이_있거나_쓰기_잠금이_잡혀_있으면_준비_폴더는_통째로_남긴다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let staging = scene.home.appending(path: "usb-staging")
        let old = try scene.write("orphan/x.bin", under: staging)
        try scene.age(old.deletingLastPathComponent(), 172_800)
        try Data("{broken".utf8).write(to: try scene.write("usb-sessions/V.json", under: scene.home))
        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp)
        #expect(scene.exists("orphan/x.bin", under: staging))

        try FileManager.default.removeItem(at: scene.home.appending(path: "usb-sessions/V.json"))
        let lock = try UsbVolumeLock.acquire(directory: scene.home.appending(path: "usb-sessions"), key: "V")
        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp)
        #expect(scene.exists("orphan/x.bin", under: staging))
        lock.release()
        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp)
        #expect(!scene.exists("orphan", under: staging))
    }

    @Test func 초안_추가_목록_백업_저널은_어떤_경우에도_남는다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let kept = ["cue-drafts/a.json", "grid-drafts/a.json", "tag-drafts/a.json", "gain-drafts.json", "playlist-drafts.json",
                    "staged.json", "damaged-drafts/a.json", "usb-drafts/V.json", "rekordbox-backups/20260101-write/master.db",
                    "usb-backups/V/20260101-export/x.bin", "usb-physical-allow.json", "edits/a.wav"]
        for file in kept { try scene.write(file, under: scene.home, age: 999_999) }
        try journal(scene, session: "s1", state: .committing)
        DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp, isProcessAlive: { _ in false })
        for file in kept + ["usb-sessions/V.json"] { #expect(scene.exists(file, under: scene.home), "\(file)") }
    }

    @Test func 지운_것을_돌려준다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.write("preview-waveforms.plist.sb-x", under: scene.home, age: 3_600)
        let removed = DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp)
        #expect(removed.map(\.lastPathComponent) == ["preview-waveforms.plist.sb-x"])
        #expect(DJCTempCleanup.run(paths: scene.paths, temporaryDirectory: scene.tmp).isEmpty)
    }
}
