import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 시점 스냅샷 → 변경 묶음(#226). 합성 두 형식 라이브러리(곡 1·2·3, 분석 파일 셋, 그림, 음원)를 둔 임시 폴더 USB에서
/// 스냅샷을 뜨고 USB를 바꾼 뒤 계획을 `UsbWriter.write`로 쓴다(새 쓰기 길이 아니다). 음원은 담지 않고 건드리지 않는다.
@Suite("USB 시점 스냅샷 되돌리기")
struct UsbPointRestoreTests {
    final class Env {
        let usb = UsbChangeSetFixture()
        let fs: FaultyUsbFileSystem
        let session = UsbLayout.newSessionID()

        init(formats: Set<UsbFormat> = UsbFormat.defaultSet) throws {
            fs = usb.fileSystem()
            var fixture = UsbLibraryFixture()
            fixture.formats = formats
            try fixture.write(to: UsbTreeFixture(base: usb.usbURL))
            usb.write("PIONEER/MYSETTING.DAT", UsbChangeSetFixture.random(148))
        }

        deinit { usb.remove() }

        var directory: URL { usb.home.appending(path: "usb-point-snapshots") }
        var staging: URL { usb.paths.staging.appending(path: session) }

        func snapshot() throws -> UsbPointSnapshotEntry {
            try UsbPointSnapshot.create(name: "", root: usb.root, in: directory, paths: usb.paths, guard: usb.writeGuard(), fileSystem: fs)
        }

        func plan(_ entry: UsbPointSnapshotEntry, base: UsbFingerprint? = nil) throws -> UsbPointRestoreResult {
            try UsbPointRestore.plan(entry, root: usb.root, fileSystem: fs, base: base ?? UsbWriter.databaseFingerprint(root: usb.root),
                                     staging: staging, session: session, highWater: ["content": 41])
        }

        func write(_ changes: UsbChangeSet) throws -> UsbWriteReport {
            try UsbWriter.write(changes, root: usb.root, paths: usb.paths, guard: usb.writeGuard(), fileSystem: fs,
                                verifiers: [UsbFingerprintVerifier()], ppthReader: UsbExportAssembly.ppthReader)
        }

        static func codes(_ result: UsbPointRestoreResult) -> [String] { result.blocks.map(\.code) }
    }

    static let artwork = "PIONEER/Artwork/00001/a1.jpg"
    static let dat2 = String(UsbLibraryFixture.analysisPath(2).dropFirst())
    static let newTrack = "PIONEER/USBANLZ/P000/00000009/ANLZ0000"

    @Test("되돌리면 범위 파일이 스냅샷 때와 같고 지우지 못하는 파일·음원은 남는다. 그 쓰기는 usb-restore로 다시 되돌린다")
    func restoreThroughWriter() throws {
        let env = try Env()
        let entry = try env.snapshot()
        let atSnapshot = env.usb.tree()
        // 편집 흉내: pdb 바꿈, 그림 지움, 같은 곡 분석 파일 바꿈, 새 곡 분석 셋·설정 파일·음원 더함
        env.usb.write(UsbLayout.exportPdb, UsbChangeSetFixture.random(4096))
        try FileManager.default.removeItem(at: env.usb.usb(Self.artwork))
        env.usb.write(Self.dat2, UsbLibraryFixture.dat(path: UsbLibraryFixture.trackPath(2), hotCueA: 9_999))
        env.usb.write(Self.newTrack + ".DAT", UsbLibraryFixture.dat(path: "/Contents/new.mp3", hotCueA: nil))
        env.usb.write(Self.newTrack + ".EXT", UsbLibraryFixture.ext(path: "/Contents/new.mp3"))
        env.usb.write("PIONEER/MYSETTING2.DAT", UsbChangeSetFixture.random(148))
        env.usb.write("PIONEER/MYSETTING.DAT", UsbChangeSetFixture.random(148))
        env.usb.write("Contents/new.mp3", UsbChangeSetFixture.random(300))
        env.usb.write("PIONEER/extracted/GCRED.DAT", Data("SECRET".utf8))
        let edited = env.usb.tree()

        let result = try env.plan(entry)
        #expect(Env.codes(result).isEmpty)
        #expect(result.databases == 1 && result.created == 1 && result.overwritten == 2 && result.removed == 2 && result.kept == 1)
        #expect(result.missingAudio == 0)
        // 기기가 USB에 저장한 설정일 수 있어 덮는 설정 파일은 따로 알린다
        #expect(result.notes.contains { $0.contains("설정 파일 1개") })
        let changes = try #require(result.changes)
        #expect(changes.purpose == .edit && changes.label == UsbPointRestore.label(for: entry) && changes.base != nil)
        #expect(UsbPointRestore.restoredSnapshot(label: changes.label) == entry.id)
        #expect(changes.idHighWater == ["content": 41] && changes.requiredRules.isEmpty && changes.copies.isEmpty)
        #expect(changes.databases.map(\.destination) == [UsbLayout.exportPdb])
        // 계획은 열지 않는 곳을 열거하지 않는다
        #expect(!env.fs.calls.contains { $0.contains("extracted") || $0 == "list PIONEER" || $0.hasPrefix("list Contents") })

        let report = try env.write(changes)
        #expect(report.outcome == .written)
        var expected = atSnapshot
        for kept in ["PIONEER/MYSETTING2.DAT", "Contents/new.mp3", "PIONEER/extracted/GCRED.DAT"] { expected[kept] = edited[kept] }
        #expect(env.usb.tree() == expected)
        #expect(!FileManager.default.fileExists(atPath: env.usb.usb("PIONEER/USBANLZ/P000/00000009").path))

        // 되돌리기도 쓰기 절차라 쓰기 전 백업이 남는다: usb-restore로 되돌리기 직전으로 돌아간다
        let undone = try UsbWriter.restore(root: env.usb.root, paths: env.usb.paths, backup: nil, guard: env.usb.writeGuard(),
                                           fileSystem: env.usb.fileSystem())
        #expect(undone.outcome == .restored)
        #expect(env.usb.tree() == edited)

        // 사건: 스냅샷, 시점 되돌리기 쓰기(그대로 돌려놓음), 그 쓰기를 되돌린 usb-restore. 지금은 기기 변경을 흉내 낸 상태라 바뀐 것으로 본다
        let events = UsbPointSnapshot.volumeEvents(in: env.directory, paths: env.usb.paths, volumeKey: env.usb.volumeKey)
        #expect(events.count == 3)
        #expect(events.contains {
            if case let .write(_, _, _, _, after, .exact(snapshot), .written) = $0 { after == entry.metadata.databases && snapshot == entry.id } else { false }
        })
        #expect(events.contains { if case .restore = $0 { true } else { false } })
        let current = try UsbWriter.databaseFingerprint(root: env.usb.root)
        #expect(UsbPointSnapshotRules.deviceChanged(since: entry, events: events, current: current))
    }

    @Test("실제 쓰기 기록으로 판정: 스냅샷 뒤 DJCrate 수정만 있었으면 아니고, 그 뒤 기기가 바꾸면 바뀌었고, 이 스냅샷으로 되돌리면 다시 아니다")
    func deviceChangeFromWriteRecords() throws {
        let env = try Env()
        let entry = try env.snapshot()
        func changed() throws -> Bool {
            let events = UsbPointSnapshot.volumeEvents(in: env.directory, paths: env.usb.paths, volumeKey: env.usb.volumeKey)
            return UsbPointSnapshotRules.deviceChanged(since: entry, events: events, current: try UsbWriter.databaseFingerprint(root: env.usb.root))
        }
        // DJCrate 수정 흉내: 쓰기 절차로 export.pdb를 바꾼다(기기 행을 잇는 수정류)
        let staged = env.usb.stage("edit/export.pdb", UsbChangeSetFixture.random(4096))
        let edit = UsbChangeSet(session: UsbLayout.newSessionID(), label: "edit", purpose: .edit, formats: [.deviceLibrary], requiredRules: [],
                                databases: [UsbDatabaseReplacement(format: .deviceLibrary, destination: UsbLayout.exportPdb, staged: staged.path,
                                                                   sha256: staged.sha256, size: staged.size)],
                                copies: [], writes: [], removals: [], base: try UsbWriter.databaseFingerprint(root: env.usb.root),
                                target: UsbTargetFingerprint(mustExist: [UsbLayout.exportPdb: UsbTreeStamp(size: staged.size, sha256: staged.sha256)],
                                                             mustNotExist: []),
                                stagingDirectory: env.usb.staging.path, idHighWater: [:])
        #expect(try env.write(edit).outcome == .written)
        #expect(try !changed())
        // 그 뒤 기기가 바꾼 것처럼
        env.usb.write(UsbLayout.exportExtPdb, UsbChangeSetFixture.random(2048))
        #expect(try changed())
        // 버린다는 동의를 받고 이 스냅샷으로 되돌린 뒤에는 잃을 것이 없다
        let restore = try #require(try env.plan(entry).changes)
        #expect(try env.write(restore).outcome == .written)
        #expect(try !changed())
    }

    @Test("판정한 지문과 계획할 때 USB DB가 다르면 막는다(판정하지 않은 상태를 덮지 않는다)")
    func staleBaseBlocks() throws {
        let env = try Env()
        let entry = try env.snapshot()
        let judged = try UsbWriter.databaseFingerprint(root: env.usb.root)
        env.usb.write(UsbLayout.exportPdb, UsbChangeSetFixture.random(4096))
        let result = try env.plan(entry, base: judged)
        #expect(Env.codes(result) == ["usbChanged"] && result.changes == nil)
        #expect(!FileManager.default.fileExists(atPath: env.staging.path))
    }

    @Test("지금 USB가 스냅샷과 같으면 쓸 것이 없고 준비 폴더도 남지 않는다")
    func unchanged() throws {
        let env = try Env()
        let entry = try env.snapshot()
        let result = try env.plan(entry)
        #expect(result.isUnchanged && result.changes == nil)
        #expect(!FileManager.default.fileExists(atPath: env.staging.path))
    }

    @Test("OneLibrary 사이드카가 생겼으면 OneLibrary를 다시 써서 사이드카를 지운다")
    func sidecarRemoved() throws {
        let env = try Env()
        let entry = try env.snapshot()
        let atSnapshot = env.usb.tree()
        env.usb.write(UsbLayout.oneLibrary + "-shm", UsbChangeSetFixture.random(32_768))
        let result = try env.plan(entry)
        let changes = try #require(result.changes)
        #expect(changes.databases.map(\.destination) == [UsbLayout.oneLibrary])
        #expect(changes.target.mustNotExist.contains(UsbLayout.oneLibrary + "-shm"))
        _ = try env.write(changes)
        #expect(env.usb.tree() == atSnapshot)
    }

    @Test("스냅샷 뒤에 생긴 DB는 지울 수 없어 막는다")
    func newDatabaseBlocks() throws {
        let env = try Env(formats: [.deviceLibrary])
        let entry = try env.snapshot()
        env.usb.write(UsbLayout.oneLibrary, UsbChangeSetFixture.random(8192))
        let result = try env.plan(entry)
        #expect(Env.codes(result) == ["pointSnapshotNewDatabase"] && result.changes == nil)
        #expect(!FileManager.default.fileExists(atPath: env.staging.path))
    }

    @Test("스냅샷 파일이 바뀌었거나 정보가 범위 밖을 가리키면 막는다")
    func damagedSnapshotBlocks() throws {
        let env = try Env()
        let entry = try env.snapshot()
        try FileManager.default.removeItem(at: env.usb.usb(Self.artwork))
        let copy = entry.url.appending(path: "files").appending(path: Self.dat2)
        try UsbChangeSetFixture.random(100).write(to: copy)
        #expect(Env.codes(try env.plan(entry)) == ["pointSnapshotDamaged"])

        var metadata = entry.metadata
        metadata.files["Contents/시험 아티스트/시험 앨범/test1.mp3"] = metadata.files[Self.artwork]
        let outside = UsbPointSnapshotEntry(url: entry.url, metadata: metadata)
        #expect(Env.codes(try env.plan(outside)) == ["pointSnapshotDamaged"])
    }

    @Test("스냅샷 DB의 곡 중 지금 USB에 음원이 없는 곡을 센다(음원은 담지 않는다)")
    func missingAudioCounted() throws {
        let env = try Env()
        let entry = try env.snapshot()
        try FileManager.default.removeItem(at: env.usb.usb(String(UsbLibraryFixture.trackPath(2).dropFirst())))
        try FileManager.default.removeItem(at: env.usb.usb(Self.artwork))
        let result = try env.plan(entry)
        #expect(result.missingAudio == 1)
        #expect(result.notes.contains { $0.contains("음원") })
    }
}
