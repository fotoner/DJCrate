import CryptoKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 내보내기 세션: 합성 로컬 사본 → 임시 폴더 볼륨(마운트 흉내)에 쓰기. 가드는 디스크 이미지 FAT32로 보이는 가짜,
/// 맥 쪽 폴더(백업·저널·준비·로컬 사본)는 모두 임시 폴더다. 실제 DJCrate 데이터 폴더는 읽거나 쓰지 않는다.
@Suite("USB 내보내기 세션")
struct UsbExportSessionTests {
    /// 시험 하나의 재료
    final class Env {
        let usb = UsbChangeSetFixture()
        let local: UsbExportFixture
        /// 세션 로컬 사본을 뜨는 곳(DJC_HOME/usb-snapshots 흉내)
        let copies: URL
        var appVersion: String? = "7.2.18"

        init(tracks: Int = 2) throws {
            local = try UsbExportFixture()
            copies = usb.home.appending(path: "usb-snapshots")
            for index in 0..<tracks {
                try local.addTrack(id: String(101 + index), artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
            }
        }

        deinit { usb.remove() }

        func session(database: URL? = nil, live: [URL] = [], fileSystem: FaultyUsbFileSystem? = nil,
                     localCopy: (@Sendable (URL, URL) throws -> URL)? = nil, gate: UsbPhysicalWriteGate = FakeUsbVolume.gate(),
                     protectedRoots: [URL] = [], root: URL? = nil) -> UsbExportSession {
            let version = appVersion
            return UsbExportSession(database: database ?? local.database, share: local.share, root: root ?? usb.usbURL,
                                    guard: usb.writeGuard(gate: gate, protectedRoots: protectedRoots),
                                    paths: usb.paths, engine: .live(fileSystem: fileSystem ?? usb.fileSystem()),
                                    device: .testing(extraLive: live, appVersion: version, localCopy: localCopy),
                                    localCopies: copies, now: { Date() })
        }

        /// 세션이 끝난 뒤 남은 로컬 사본 폴더(local-…)
        var leftoverCopies: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: copies.path)) ?? []).filter { $0.hasPrefix("local-") }
        }

        /// 남은 준비 폴더(usb-staging/<세션>)
        var leftoverStaging: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: usb.paths.staging.path)) ?? []
        }
    }

    static func options(_ configure: (inout UsbExportOptions) -> Void = { _ in }) -> UsbExportOptions {
        var options = UsbExportOptions()
        options.snapshotTime = "2100-01-01T00:00:00Z"
        configure(&options)
        return options
    }

    /// 진행 이벤트 기록
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [UsbProgress] = []
        func add(_ progress: UsbProgress) { lock.withLock { items.append(progress) } }
        var phases: [UsbProgress.Phase] {
            lock.withLock {
                items.map(\.phase).reduce(into: []) { result, phase in if result.last != phase { result.append(phase) } }
            }
        }
    }

    /// 로컬 사본을 떴는지 기록하고 실제 사본을 뜬다
    final class CopyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(database: URL, into: URL)] = []
        var all: [(database: URL, into: URL)] { lock.withLock { calls } }
        func record(_ database: URL, _ into: URL) throws -> URL {
            lock.withLock { calls.append((database, into)) }
            return try UsbDevice.liveLocalCopy(database, into)
        }
    }

    static let analysisTime = ISO8601DateFormatter().date(from: "2026-01-03T00:00:00Z")!

    /// 분석 파일이 `analysisTime`에 바뀐 곡 하나와, 이름에 뜬 시각(2026-01-02)이 적힌 사본
    static func namedSnapshot(_ env: Env, name: String = "master-2026-01-02T030405.db") throws -> URL {
        try env.local.addTrack(id: "201", artist: ("1", "합성 아티스트"), analysisModified: analysisTime)
        let folder = env.usb.folder.appending(path: "named")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: name)
        try FileManager.default.copyItem(at: env.local.database, to: copy)
        return copy
    }

    // MARK: - 스냅샷 시각

    @Test("스냅샷 시각은 사본 이름에서 푼다(세션이 다시 뜬 사본의 시각이 아니다)")
    func snapshotTimeFromNameNotCopyTime() throws {
        let env = try Env(tracks: 0)
        let named = try Self.namedSnapshot(env)
        let preview = try env.session(database: named).preview(selection: .tracks(["201"]), options: UsbExportOptions())
        #expect(preview.snapshotSource == .fileName)
        #expect(preview.blocks.contains { $0.code == "analysisNewerThanSnapshot" && $0.scope == .track("201") })
    }

    @Test("--snapshot-time이 이름보다 앞선다")
    func snapshotTimeExplicitOverrides() throws {
        let env = try Env(tracks: 0)
        let named = try Self.namedSnapshot(env)
        let later = try env.session(database: named).preview(selection: .tracks(["201"]), options: Self.options {
            $0.snapshotTime = "2026-02-01T00:00:00Z"
        })
        #expect(later.snapshotSource == .explicit)
        #expect(!later.blocks.contains { $0.code == "analysisNewerThanSnapshot" })
        let earlier = try env.session(database: named).preview(selection: .tracks(["201"]), options: Self.options {
            $0.snapshotTime = "2025-12-31T00:00:00Z"
        })
        #expect(earlier.blocks.contains { $0.code == "analysisNewerThanSnapshot" })
    }

    @Test("이름에 시각이 없으면 사본 파일 mtime")
    func snapshotTimeMtimeFallback() throws {
        let env = try Env(tracks: 0)
        let copy = try Self.namedSnapshot(env, name: "m.db")
        let before = ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: copy.path)
        let blocked = try env.session(database: copy).preview(selection: .tracks(["201"]), options: UsbExportOptions())
        #expect(blocked.snapshotSource == .modificationDate)
        #expect(blocked.blocks.contains { $0.code == "analysisNewerThanSnapshot" })
        let after = ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: after], ofItemAtPath: copy.path)
        let passed = try env.session(database: copy).preview(selection: .tracks(["201"]), options: UsbExportOptions())
        #expect(!passed.blocks.contains { $0.code == "analysisNewerThanSnapshot" })
    }

    // MARK: - 막힘

    @Test("라이브 master.db는 열지 않고 거부한다")
    func refusesLiveDatabase() throws {
        let env = try Env()
        let log = CopyLog()
        do {
            _ = try env.session(live: [env.local.database], localCopy: { try log.record($0, $1) })
                .preview(selection: .tracks(["101"]), options: Self.options())
            Issue.record("막히지 않음")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["liveDatabase"])
        }
        #expect(log.all.isEmpty)
    }

    @Test("확인하지 않은 로컬 rekordbox 버전이면 막는다")
    func refusesUnverifiedLocalVersion() throws {
        let env = try Env()
        env.appVersion = "6.8.5"
        let preview = try env.session().preview(selection: .tracks(["101"]), options: Self.options())
        let block = try #require(preview.blocks.first { $0.code == "localVersionUnverified" })
        #expect(block.scope == .volume && block.message.contains("6.8.5"))
        #expect(preview.changes == nil)
        #expect(throws: UsbError.self) {
            try env.session().write(selection: .tracks(["101"]), options: Self.options(), progress: { _ in }, isCancelled: { false })
        }
        env.appVersion = nil
        #expect(try env.session().preview(selection: .tracks(["101"]), options: Self.options()).blocks
            .contains { $0.code == "localVersionUnverified" })
        #expect(env.usb.tree().isEmpty)
    }

    @Test("이미 라이브러리가 있는 USB는 USB 수정으로 안내한다")
    func nonEmptyUsbRedirectsToEdit() throws {
        let env = try Env()
        env.usb.write(UsbLayout.exportPdb, Data(count: 4096))
        let preview = try env.session().preview(selection: .tracks(["101"]), options: Self.options())
        let block = try #require(preview.blocks.first { $0.code == "libraryExists" })
        #expect(block.message.contains("usb-edit"))
        #expect(preview.changes == nil)
    }

    @Test("DB는 없지만 PIONEER/ 아래에 무엇이 남아 있으면 막는다")
    func leftoverPioneerBlocks() throws {
        let env = try Env()
        env.usb.write("PIONEER/Artwork/00001/a1.jpg", Data([1, 2, 3]))
        let before = env.usb.tree()
        let preview = try env.session().preview(selection: .tracks(["101"]), options: Self.options())
        #expect(preview.blocks.map(\.code) == ["leftoverPioneer"])
        #expect(throws: UsbError.self) {
            try env.session().write(selection: .tracks(["101"]), options: Self.options(), progress: { _ in }, isCancelled: { false })
        }
        #expect(env.usb.tree() == before)
    }

    /// 관문이 막지 않았다면 쓸 선택(볼륨 이름 확인)
    static func physicalOptions() -> UsbExportOptions {
        options { $0.confirmName = "DJCPHYS" }
    }

    /// 관문·보호 경로에 막히는 볼륨(APFS 같은 볼륨 모양은 `UsbVolumePolicyTests`가 본다)
    enum RefusedVolume: String, CaseIterable, Sendable {
        /// 동의 없는 실물, 보호 폴더, 가드는 디스크 이미지라 하지만 임시 폴더 밖인 루트
        case physical, protectedRoot, outsideScratchRoot

        var code: String {
            switch self {
            case .physical, .outsideScratchRoot: "physicalDisabled"
            case .protectedRoot: "protectedPath"
            }
        }
    }

    /// 동의·이름 확인·볼륨 모양의 조합은 `UsbPhysicalWriteGateTests`·`UsbVolumePolicyTests`(도메인)와 `UsbWriteGuardTests`가 본다.
    /// 여기서는 세 세션이 함께 쓰는 미리 보기 판정(`environmentBlocks`: 보호 경로·임시 폴더 밖·실물 관문)을 지나 열거 전에 멈추는지 본다.
    @Test("관문·보호 경로에 막힌 볼륨은 내보내기·수정·옮기기 모두 라이브러리·PIONEER 확인 전에 멈춰 이름도 열거하지 않는다",
          arguments: RefusedVolume.allCases)
    func refusedVolumeNotListed(_ refused: RefusedVolume) throws {
        let env = try Env()
        env.usb.write(UsbLayout.exportPdb, Data(count: 4096))
        env.usb.write("PIONEER/Artwork/00001/a1.jpg", Data([1, 2, 3]))
        env.usb.write("Contents/합성/x.mp3", Data([4, 5, 6]))
        let before = env.usb.tree()
        let gate = FakeUsbVolume.gate()
        var protectedRoots: [URL] = []
        var root = env.usb.usbURL
        switch refused {
        case .physical: env.usb.volume = FakeUsbVolume.physicalFAT32()
        case .protectedRoot: protectedRoots = [env.usb.usbURL]
        // 없는 경로라 열거할 것도 없지만, 막히지 않으면 stat·list 기록이 남는다
        case .outsideScratchRoot: root = URL(filePath: "/djc-not-scratch-\(UUID().uuidString)")
        }
        let fileSystem = env.usb.fileSystem()
        let writeGuard = env.usb.writeGuard(gate: gate, protectedRoots: protectedRoots)
        let session = env.session(fileSystem: fileSystem, gate: gate, protectedRoots: protectedRoots, root: root)
        let preview = try session.preview(selection: .tracks(["101"]), options: Self.physicalOptions())
        #expect(preview.blocks.contains { $0.code == refused.code })
        #expect(!preview.blocks.contains { ["libraryExists", "leftoverPioneer"].contains($0.code) })
        #expect(preview.changes == nil)
        do {
            _ = try session.write(selection: .tracks(["101"]), options: Self.physicalOptions(), progress: { _ in }, isCancelled: { false })
            Issue.record("막히지 않음")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.contains { $0.code == refused.code })
        }

        // 수정·옮기기 세션도 같은 판정으로 먼저 멈춘다(USB DB 사본·로컬 사본을 뜨지 않는다)
        let options = UsbWriteOptions(confirmName: "DJCPHYS")
        let edit = UsbEditSession(root: root, database: env.local.database, share: env.local.share, guard: writeGuard, paths: env.usb.paths,
                                  engine: .live(fileSystem: fileSystem), device: .testing(), localCopies: env.copies,
                                  drafts: .live(directory: env.usb.home.appending(path: "usb-drafts")), now: { Date() })
        let edited = try edit.preview([.refreshTracks(usbContentIDs: [1], parts: [.info])], options: options,
                                      snapshotTime: "2100-01-01T00:00:00Z")
        #expect(edited.blocks.contains { $0.code == refused.code } && edited.changes == nil)
        // 수정 세션의 쓰기도 같은 판정으로 거부한다(쓰기 관문까지 가지 않는다)
        let editRefusal = #expect(throws: UsbError.self) {
            _ = try edit.write([.refreshTracks(usbContentIDs: [1], parts: [.info])], options: options, snapshotTime: "2100-01-01T00:00:00Z",
                               progress: { _ in }, isCancelled: { false })
        }
        if case let .writeRefused(blocks)? = editRefusal { #expect(blocks.contains { $0.code == refused.code }) } else { Issue.record("수정 쓰기가 막히지 않음") }
        let migrate = UsbMigrateSession(root: root, guard: writeGuard, paths: env.usb.paths, engine: .live(fileSystem: fileSystem),
                                        device: .testing(), copies: env.copies)
        let migrated = try migrate.preview(options: options)
        #expect(migrated.blocks.contains { $0.code == refused.code } && migrated.changes == nil)

        #expect(!fileSystem.calls.contains { $0.hasPrefix("list ") || $0.hasPrefix("stat ") })
        #expect(env.usb.tree() == before)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: env.copies.path)) ?? []).isEmpty)
    }

    // MARK: - 쓰기

    @Test("곡 5·목록 2(폴더 1)·My Tag: 쓰고 모든 검증기를 통과하고 트리가 목표와 같다")
    func endToEndInvariants1to7() throws {
        let env = try Env(tracks: 5)
        try env.local.local.addPlaylist(id: "800", name: "합성 폴더", seq: 1, attribute: 1)
        try env.local.local.addPlaylist(id: "801", name: "합성 목록", parentID: "800", seq: 1, contentIDs: ["101", "103", "105"])
        try env.local.local.addMyTag(id: "5001", name: "합성 분류", seq: 1, attribute: 1)
        try env.local.local.addMyTag(id: "5002", name: "합성 태그", seq: 1, attribute: 0, parentID: "5001")
        let session = env.session()
        let report = try session.write(selection: .both(playlists: ["800"], tracks: ["102", "104"]), options: Self.options(),
                                       progress: { _ in }, isCancelled: { false })
        #expect(report.outcome == .written)
        let preview = try #require(session.lastPreview)
        #expect(preview.plan.tracks.count == 5 && preview.plan.playlists.count == 2)
        let changes = try #require(preview.changes)
        let tree = try UsbTree.fingerprint(env.usb.root)
        #expect(Set(tree.files.keys) == Set(changes.target.mustExist.keys))
        #expect(tree.appleDoubleCount == 0)
        for (path, stamp) in changes.target.mustExist { #expect(tree.files[path]?.size == stamp.size) }
        // 쓴 USB를 검증기로 한 번 더 본다
        let scratch = env.usb.folder.appending(path: "verify")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        #expect(try UsbInvariantVerifier().verify(root: env.usb.root, changes: changes, fileSystem: env.usb.fileSystem(), scratch: scratch) == [])
        #expect(env.usb.journal()?.state == .verified)
        #expect(env.leftoverCopies.isEmpty)
        // 준비 폴더도 치운다
        #expect(!FileManager.default.fileExists(atPath: changes.stagingDirectory))
    }

    @Test("동의한 실물 USB(가짜 볼륨, 임시 폴더)에는 등록 없이 디스크 이미지와 같은 세션으로 내보낸다(확인 안 된 규칙은 막지 않음)")
    func physicalOpenGateExports() throws {
        let env = try Env(tracks: 2)
        env.usb.volume = FakeUsbVolume.physicalFAT32()
        let gate = FakeUsbVolume.gate(consented: true)
        let options = Self.options { $0.confirmName = "DJCPHYS" }
        let preview = try env.session(gate: gate).preview(selection: .tracks(["101", "102"]), options: options)
        #expect(preview.blocks.isEmpty)
        #expect(!UsbProvisionalRule.deviceCheckRules(preview.requiredRules).isEmpty)
        let report = try env.session(gate: gate).write(selection: .tracks(["101", "102"]), options: options, progress: { _ in },
                                                       isCancelled: { false })
        #expect(report.outcome == .written)
        #expect(env.usb.journal()?.state == .verified)
        #expect(try UsbTree.fingerprint(env.usb.root).appleDoubleCount == 0)
        #expect(!env.usb.backupFolders().isEmpty)
    }

    @Test("진행 순서: 계획 → 준비 → 백업 → 파일 → DB 교체 → 정리 → 검증")
    func progressOrder() throws {
        let env = try Env()
        let recorder = Recorder()
        _ = try env.session().write(selection: .tracks(["101", "102"]), options: Self.options(), progress: { recorder.add($0) },
                                    isCancelled: { false })
        #expect(recorder.phases == [.planning, .staging, .backup, .files, .commit, .cleanup, .verify])
    }

    @Test("Device Library 작성기가 거부할 곡은 미리 보기·쓰기를 멈추지 않고 그 곡만 로컬 ID로 막는다")
    func writerRefusalBlocksOnlyThatTrack() throws {
        let env = try Env()
        let db = try env.local.local.open()
        try db.run("UPDATE djmdContent SET ISRC = ? WHERE ID = '102'", [.text("ＪＰ－ＡＢＣ")])
        db.close()
        let session = env.session()
        let preview = try session.preview(selection: .tracks(["101", "102"]), options: Self.options())
        #expect(preview.blocks.filter { $0.code == "isrcNotASCIIForDeviceLibrary" }.map(\.scope) == [.track("102")])
        #expect(preview.stopping.isEmpty)
        #expect(preview.changes != nil)
        #expect(preview.plan.tracks.map(\.localContentID) == ["101"])
        let report = try session.write(selection: .tracks(["101", "102"]), options: Self.options(), progress: { _ in }, isCancelled: { false })
        #expect(report.outcome == .written)
        #expect(report.blocks.contains { $0.code == "isrcNotASCIIForDeviceLibrary" && $0.scope == .track("102") })
    }

    @Test("쓰기 전부터 있던 ._ 파일(루트 ._.Trashes, 사용자 음원 옆)은 검증에서 되돌리지 않는다")
    func preexistingAppleDoubleNotRolledBack() throws {
        let env = try Env()
        env.usb.write("._.Trashes", Data(count: 4096))
        env.usb.write("Contents/User/Album/x.mp3", Data([7, 7, 7]))
        env.usb.write("Contents/User/Album/._x.mp3", Data(count: 4096))
        let before = env.usb.tree()
        let report = try env.session().write(selection: .tracks(["101", "102"]), options: Self.options(), progress: { _ in },
                                             isCancelled: { false })
        #expect(report.outcome == .written)
        #expect(env.usb.journal()?.state == .verified)
        let after = env.usb.tree()
        for (path, hash) in before { #expect(after[path] == hash) }
    }

    /// USB를 그대로 두는 것은 `UsbWriterTests`가 본다. 세션은 저널을 dryRun으로 닫고 사본을 치운다.
    @Test("드라이 런은 저널을 dryRun으로 닫고, 그 뒤 같은 선택으로 쓰면 막히지 않는다")
    func dryRunThenWriteNotBlocked() throws {
        let env = try Env()
        let dryRun = try env.session().write(selection: .tracks(["101", "102"]), options: Self.options { $0.dryRun = true },
                                             progress: { _ in }, isCancelled: { false })
        #expect(dryRun.outcome == .dryRun)
        #expect(env.usb.tree().isEmpty && env.usb.directories().isEmpty)
        #expect(env.usb.journal()?.state == .dryRun)
        #expect(env.leftoverCopies.isEmpty)
        let report = try env.session().write(selection: .tracks(["101", "102"]), options: Self.options(), progress: { _ in },
                                             isCancelled: { false })
        #expect(report.outcome == .written)
        #expect(env.usb.journal()?.state == .verified)
    }

    // MARK: - 로컬 사본

    @Test("세션 사본은 넘긴 사본에서 세션 전용 폴더로만 뜨고, 기본 스냅샷 폴더는 건드리지 않는다")
    func sessionCopyNeverTouchesDefaultSnapshots() throws {
        // ① 미리 보기·쓰기가 각각 한 번, 넘긴 사본 → local-<세션>/
        let env = try Env()
        let log = CopyLog()
        _ = try env.session(localCopy: { try log.record($0, $1) }).preview(selection: .tracks(["101"]), options: Self.options())
        _ = try env.session(localCopy: { try log.record($0, $1) }).write(selection: .tracks(["101"]), options: Self.options(), progress: { _ in }, isCancelled: { false })
        #expect(log.all.count == 2)
        for call in log.all {
            #expect(call.database == env.local.database)
            #expect(call.into.deletingLastPathComponent().path == env.copies.path)
            #expect(call.into.lastPathComponent.hasPrefix("local-"))
        }
        // ③ 끝나면(성공) 세션 사본 폴더가 없다
        #expect(env.leftoverCopies.isEmpty)

        // ② 기본 사본 뜨기는 목적지 아래에만 만들고, 옆 폴더의 사본 이름·수·시각은 그대로
        let root = env.usb.folder.appending(path: "copyroot")
        let snapshots = root.appending(path: "snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        for name in ["master-2026-01-01T000000.db", "master-2026-01-02T000000.db"] {
            try Data("합성".utf8).write(to: snapshots.appending(path: name))
        }
        let stamp = { () -> [String: Date] in
            var result: [String: Date] = [:]
            for name in (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [] {
                result[name] = try? FileManager.default.attributesOfItem(atPath: snapshots.appending(path: name).path)[.modificationDate] as? Date
            }
            return result
        }
        let before = stamp()
        let into = root.appending(path: "local-test")
        let copy = try UsbDevice.liveLocalCopy(env.local.database, into)
        #expect(copy.deletingLastPathComponent().path == into.path)
        #expect(stamp() == before)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["snapshots", "local-test"])
    }

    @Test("실패·취소로 끝나도 세션 사본 폴더를 지운다")
    func sessionCopyRemovedOnFailure() throws {
        let env = try Env()
        env.usb.volume = FakeUsbVolume.physicalFAT32()
        #expect(throws: UsbError.self) {
            try env.session().write(selection: .tracks(["101"]), options: Self.options(), progress: { _ in }, isCancelled: { false })
        }
        #expect(env.leftoverCopies.isEmpty)
        let cancelled = try Env()
        #expect(throws: UsbError.self) {
            try cancelled.session().write(selection: .tracks(["101"]), options: Self.options(), progress: { _ in }, isCancelled: { true })
        }
        #expect(cancelled.leftoverCopies.isEmpty)
        #expect(cancelled.leftoverStaging.isEmpty)
        // 준비 중 취소: USB에 아무것도 쓰지 않고 저널도 만들지 않는다
        #expect(cancelled.usb.tree().isEmpty && cancelled.usb.journal() == nil)
        // 사본·준비를 마친 뒤 쓰기 절차가 막아도(rekordbox가 켜짐) 사본·준비 폴더를 남기지 않는다
        let refused = try Env()
        refused.usb.rekordboxRunning = true
        do {
            _ = try refused.session().write(selection: .tracks(["101"]), options: Self.options(), progress: { _ in }, isCancelled: { false })
            Issue.record("막히지 않음")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.contains { $0.code == "rekordboxRunning" })
        }
        #expect(refused.leftoverCopies.isEmpty && refused.leftoverStaging.isEmpty)
        #expect(refused.usb.tree().isEmpty)
    }

    @Test("쓰는 도중 볼륨이 사라지면 회복이 쓸 준비 폴더를 남기고 로컬 사본은 지운다")
    func volumeLostKeepsStagingForRecovery() throws {
        let env = try Env(tracks: 2)
        let fileSystem = env.usb.fileSystem()
        fileSystem.unmountAt = (op: .rename, occurrence: 2)
        #expect {
            try env.session(fileSystem: fileSystem).write(selection: .tracks(["101", "102"]), options: Self.options(), progress: { _ in },
                                                          isCancelled: { false })
        } throws: { error in
            if case UsbError.volumeLost = error { true } else { false }
        }
        #expect(env.leftoverCopies.isEmpty)
        #expect(env.leftoverStaging.count == 1)
        let journal = try #require(env.usb.journal())
        #expect(!journal.isClosed)
        #expect(FileManager.default.fileExists(atPath: journal.stagingDirectory))
    }
}
