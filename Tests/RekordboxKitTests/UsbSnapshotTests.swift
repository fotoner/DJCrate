import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("USB 라이브러리 사본 뜨기")
struct UsbSnapshotTests {
    static let db = "PIONEER/rekordbox/exportLibrary.db"

    static func output() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-usbsnap-\(UUID().uuidString)")
    }

    /// 곡 `ids`가 들어 있는 합성 OneLibrary를 USB 모양 트리에 둔다
    static func tree(ids: [Int] = [1, 2], journalMode: OneLibraryFixture.JournalMode = .wal) throws -> UsbTreeFixture {
        let fixture = try OneLibraryFixture(journalMode: journalMode)
        for id in ids { try fixture.add(track: OneLibraryTrackSpec(id: id)) }
        fixture.close()
        let tree = UsbTreeFixture()
        tree.write(db, try Data(contentsOf: fixture.url))
        return tree
    }

    /// 파일 접근을 기록하는 가짜(실제 동작은 posix)
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    @Test func copiesDbAndSidecarsSourceUnchanged() throws {
        let tree = try Self.tree()
        defer { tree.remove() }
        tree.write("PIONEER/rekordbox/export.pdb", "synthetic pdb")
        tree.write("PIONEER/rekordbox/exportExt.pdb", "synthetic ext pdb")
        tree.write("PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT", "synthetic anlz")
        let before = tree.tree()
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }

        let snapshot = try UsbSnapshot.take(root: tree.root, into: out)
        #expect(tree.tree() == before)
        #expect(snapshot.directory == out)
        #expect(snapshot.oneLibrary == out.appending(path: "exportLibrary.db"))
        #expect(try Data(contentsOf: #require(snapshot.exportPdb)) == Data("synthetic pdb".utf8))
        #expect(try Data(contentsOf: #require(snapshot.exportExtPdb)) == Data("synthetic ext pdb".utf8))
        // 지문은 원본 크기·SHA-256
        #expect(Set(snapshot.fingerprint.files.keys) == [Self.db, "PIONEER/rekordbox/export.pdb", "PIONEER/rekordbox/exportExt.pdb"])
        for (path, stamp) in snapshot.fingerprint.files {
            #expect(stamp.sha256 == before[path])
            #expect(stamp.size == Int64((try? FileManager.default.attributesOfItem(atPath: tree.url(path).path)[.size] as? Int) ?? -1))
        }
        #expect(snapshot.flags == UsbSnapshot.Flags(walPresent: false, journalPresent: false, shmPresent: false, walMerged: false,
                                                    journalRolledBack: false, headerMode: .wal))
        // 분석 파일은 복사하지 않는다
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "ANLZ0000.DAT").path))
        let library = try OneLibraryReader.read(copyAt: #require(snapshot.oneLibrary))
        #expect(library.tracks.map(\.id) == [1, 2])
    }

    @Test func pdbOnlyUsbHasNoOneLibrary() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write("PIONEER/rekordbox/export.pdb", "synthetic pdb")
        // 본 DB 없이 남은 사이드카는 복사하지 않는다
        tree.write("PIONEER/rekordbox/exportLibrary.db-shm", "stray")
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }
        let snapshot = try UsbSnapshot.take(root: tree.root, into: out)
        #expect(snapshot.oneLibrary == nil && snapshot.exportExtPdb == nil)
        #expect(snapshot.exportPdb != nil)
        #expect(snapshot.flags.headerMode == nil)
        #expect(Array(snapshot.fingerprint.files.keys) == ["PIONEER/rekordbox/export.pdb"])
    }

    @Test func walMergedOnCopy() throws {
        let fixture = try OneLibraryFixture()
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        fixture.close()
        // 자동 체크포인트를 끄고 커밋해 커밋 프레임을 -wal에만 남긴다(연결은 열어 둔다)
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")
        try fixture.add(track: OneLibraryTrackSpec(id: 2))
        let wal = URL(filePath: fixture.url.path + "-wal")
        #expect(((try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0) > 0)
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        for suffix in ["", "-wal", "-shm"] { tree.write(Self.db + suffix, try Data(contentsOf: URL(filePath: fixture.url.path + suffix))) }
        fixture.close()
        let before = tree.tree()
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }

        let snapshot = try UsbSnapshot.take(root: tree.root, into: out)
        #expect(tree.tree() == before)
        #expect(snapshot.flags.walPresent && snapshot.flags.shmPresent && snapshot.flags.walMerged)
        #expect(!snapshot.flags.journalPresent)
        #expect(snapshot.flags.headerMode == .wal)
        #expect(snapshot.fingerprint.files[Self.db + "-wal"]?.sha256 == before[Self.db + "-wal"])
        let library = try OneLibraryReader.read(copyAt: #require(snapshot.oneLibrary))
        #expect(library.tracks.map(\.id) == [1, 2])
    }

    @Test func hotJournalRolledBackOnCopy() throws {
        let fixture = try OneLibraryFixture(journalMode: .delete)
        for id in 1...3 { try fixture.add(track: OneLibraryTrackSpec(id: id)) }
        let committed = try Data(contentsOf: fixture.url)
        // 캐시를 작게 해 커밋 전에 바뀐 쪽을 DB 파일에 흘리게 한다(쓰기 도중 멈춘 모양)
        try fixture.execute("PRAGMA cache_size = 10")
        try fixture.execute("BEGIN")
        try fixture.execute("UPDATE content SET title = '바뀐 제목'")
        for id in 100..<400 {
            var spec = OneLibraryTrackSpec(id: id)
            spec.djComment = String(repeating: "x", count: 3000)
            try fixture.add(track: spec)
        }
        let journal = URL(filePath: fixture.url.path + "-journal")
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write(Self.db, try Data(contentsOf: fixture.url))
        tree.write(Self.db + "-journal", try Data(contentsOf: journal))
        try fixture.execute("ROLLBACK")
        fixture.close()
        // 복사한 DB 파일은 커밋한 모양과 다르다(롤백하지 않으면 잘못 읽는다)
        #expect(try Data(contentsOf: tree.url(Self.db)) != committed)
        let before = tree.tree()
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }

        let snapshot = try UsbSnapshot.take(root: tree.root, into: out)
        #expect(tree.tree() == before)
        #expect(snapshot.flags.journalPresent && snapshot.flags.journalRolledBack)
        #expect(snapshot.flags.headerMode == .rollback)
        let library = try OneLibraryReader.read(copyAt: #require(snapshot.oneLibrary))
        #expect(library.tracks.map(\.id) == [1, 2, 3])
        #expect(library.tracks.allSatisfy { $0.title.hasPrefix("시험 곡") })
    }

    @Test func shmCopyDeleted() throws {
        let tree = try Self.tree(journalMode: .delete)
        defer { tree.remove() }
        tree.write(Self.db + "-shm", "synthetic stale shm")
        let removed = Recorder()
        let posix = SnapshotFileAccess.posix
        let access = SnapshotFileAccess(stat: posix.stat, copyData: posix.copyData, sha256: posix.sha256,
                                        remove: { url in removed.append(url.lastPathComponent); try posix.remove(url) })
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }
        let snapshot = try UsbSnapshot.take(root: tree.root, into: out, fileSystem: access)
        #expect(snapshot.flags.shmPresent)
        #expect(removed.all == ["exportLibrary.db-shm"])
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "exportLibrary.db-shm").path))
        #expect(snapshot.fingerprint.files[Self.db + "-shm"] != nil)
        #expect(FileManager.default.fileExists(atPath: tree.url(Self.db + "-shm").path))
    }

    @Test func sourceChangedDuringCopyFails() throws {
        let tree = try Self.tree()
        defer { tree.remove() }
        let posix = SnapshotFileAccess.posix
        // 복사하는 동안 원본 크기가 바뀌는 가짜
        let access = SnapshotFileAccess(stat: posix.stat, copyData: { from, to in
            try posix.copyData(from, to)
            let handle = try FileHandle(forWritingTo: from)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("grow".utf8))
            try handle.close()
        }, sha256: posix.sha256, remove: posix.remove)
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }
        let error = #expect(throws: DJCError.self) { try UsbSnapshot.take(root: tree.root, into: out, fileSystem: access) }
        if let error, case .sourceChangedDuringCopy = error {} else { Issue.record("sourceChangedDuringCopy가 아님") }
        // 버린 사본을 남기지 않는다
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "exportLibrary.db").path))
    }

    @Test func symlinkDBRefused() throws {
        let tree = try Self.tree()
        defer { tree.remove() }
        let real = tree.url("elsewhere.db")
        try FileManager.default.moveItem(at: tree.url(Self.db), to: real)
        tree.symlink(Self.db, to: real.path)
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }
        let error = #expect(throws: UsbError.self) { try UsbSnapshot.take(root: tree.root, into: out) }
        if let error, case .readFailed = error {} else { Issue.record("readFailed가 아님") }

        // 일반 파일이 아니라고 답하는 stat도 거부한다
        let regular = try Self.tree()
        defer { regular.remove() }
        let posix = SnapshotFileAccess.posix
        let access = SnapshotFileAccess(stat: { url in
            try posix.stat(url).map { SnapshotFileStamp(size: $0.size, modificationDate: $0.modificationDate, isRegularFile: false) }
        }, copyData: posix.copyData, sha256: posix.sha256, remove: posix.remove)
        let out2 = Self.output()
        defer { try? FileManager.default.removeItem(at: out2) }
        let error2 = #expect(throws: UsbError.self) { try UsbSnapshot.take(root: regular.root, into: out2, fileSystem: access) }
        if let error2, case .readFailed = error2 {} else { Issue.record("readFailed가 아님") }
    }

    @Test func neverReadUntouched() throws {
        let tree = try Self.tree()
        defer { tree.remove() }
        tree.write("PIONEER/extracted/x", "SECRET")
        tree.write("PIONEER/CDP/x", "SECRET")
        tree.write("PIONEER/djprofile.nxs", "SECRET")
        let locked = ["PIONEER/extracted/x", "PIONEER/CDP/x", "PIONEER/djprofile.nxs", "PIONEER/extracted", "PIONEER/CDP"]
        for path in locked { #expect(chmod(tree.url(path).path, 0) == 0) }
        defer { for path in locked.reversed() { chmod(tree.url(path).path, 0o755) } }
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }
        let snapshot = try UsbSnapshot.take(root: tree.root, into: out)
        #expect(snapshot.oneLibrary != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).allSatisfy { !$0.contains("SECRET") && $0.hasPrefix("exportLibrary.db") })
    }

    @Test func integrityFailureIsReadFailed() throws {
        let tree = try Self.tree(ids: Array(1...20))
        defer { tree.remove() }
        // 세 번째 쪽 가운데를 망가뜨린다(암호화된 쪽의 HMAC가 맞지 않게 된다)
        let handle = try FileHandle(forUpdating: tree.url(Self.db))
        try handle.seek(toOffset: 4096 * 2 + 200)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 64))
        try handle.close()
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }
        let error = #expect(throws: UsbError.self) { try UsbSnapshot.take(root: tree.root, into: out) }
        if let error, case .readFailed = error {} else { Issue.record("readFailed가 아님") }
        // 버린 사본과 사본을 연 SQLite가 만든 사이드카를 남기지 않는다(같은 폴더로 다시 뜰 수 있게)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("exportLibrary.db") })
        let again = #expect(throws: UsbError.self) { try UsbSnapshot.take(root: tree.root, into: out) }
        if let again, case .readFailed(let detail) = again {
            #expect(!detail.contains("File exists"))
        } else {
            Issue.record("readFailed가 아님")
        }
    }

    /// 사본 폴더가 USB 안(뿌리 자신 포함)이면 폴더를 만들거나 SQLite로 열기 전에 거부한다.
    @Test func snapshotIntoRootRefused() throws {
        let tree = try Self.tree()
        defer { tree.remove() }
        tree.symlink("link-to-pioneer", to: tree.url("PIONEER").path)
        let before = tree.tree()
        let outside = Self.output()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let viaLink = outside.appending(path: "usb")
        try FileManager.default.createSymbolicLink(atPath: viaLink.path, withDestinationPath: tree.base.path)
        for directory in [tree.base, tree.url("PIONEER/copy"), tree.url("PIONEER/rekordbox"), tree.url("link-to-pioneer/copy"),
                          viaLink.appending(path: "PIONEER/copy"), tree.url("PIONEER/new/deeper")] {
            let error = #expect(throws: UsbError.self) { try UsbSnapshot.take(root: tree.root, into: directory) }
            if let error, case .readFailed = error {} else { Issue.record("readFailed가 아님: \(directory.lastPathComponent)") }
        }
        #expect(tree.tree() == before)
        #expect(!FileManager.default.fileExists(atPath: tree.url("PIONEER/copy").path))
        #expect(!FileManager.default.fileExists(atPath: tree.url("PIONEER/new").path))
        // ".."로 돌아 들어가는 경로도 거부한다
        let dotted = URL(filePath: outside.path + "/../" + outside.lastPathComponent + "/x")
        #expect(throws: UsbError.self) { try UsbSnapshot.take(root: tree.root, into: dotted) }
    }

    /// 사본 폴더에 남은 파일(짝 없는 -wal·-shm 등)이 있으면 SQLite가 그것을 집어 가므로 받지 않는다.
    @Test func snapshotIntoNonEmptyDirectoryRefused() throws {
        let tree = try Self.tree()
        defer { tree.remove() }
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("stale wal".utf8).write(to: out.appending(path: "exportLibrary.db-wal"))
        let error = #expect(throws: UsbError.self) { try UsbSnapshot.take(root: tree.root, into: out) }
        if let error, case .readFailed = error {} else { Issue.record("readFailed가 아님") }
        #expect(try Data(contentsOf: out.appending(path: "exportLibrary.db-wal")) == Data("stale wal".utf8))
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "exportLibrary.db").path))

        // 비어 있는 폴더는 받는다
        let empty = Self.output()
        defer { try? FileManager.default.removeItem(at: empty) }
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(try UsbSnapshot.take(root: tree.root, into: empty).oneLibrary != nil)
    }

    /// DB 파일 하나를 사이드카와 함께 새 폴더로 복사해 사본 안에서 정리한다. 원본은 그대로다.
    @Test func copyDatabaseLeavesSourceUnchanged() throws {
        let fixture = try OneLibraryFixture()
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        fixture.close()
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")
        try fixture.add(track: OneLibraryTrackSpec(id: 2))
        let source = UsbTreeFixture()
        defer { source.remove() }
        for suffix in ["", "-wal", "-shm"] { source.write("exportLibrary.db" + suffix, try Data(contentsOf: URL(filePath: fixture.url.path + suffix))) }
        fixture.close()
        let before = source.tree()
        #expect(before["exportLibrary.db-wal"] != nil)
        let out = Self.output()
        defer { try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let copy = try UsbSnapshot.copyDatabase(source.url("exportLibrary.db"), into: out)
        #expect(copy == out.appending(path: "exportLibrary.db"))
        #expect(source.tree() == before)
        // WAL은 사본에 합쳐졌고 -shm은 가져오지 않았다
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["exportLibrary.db"])
        #expect(try OneLibraryReader.read(copyAt: copy).tracks.map(\.id) == [1, 2])

        // 대상 자리에 이미 파일(사이드카 포함)이 있으면 거부한다
        let stale = Self.output()
        defer { try? FileManager.default.removeItem(at: stale) }
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appending(path: "exportLibrary.db-shm"))
        #expect(throws: UsbError.self) { try UsbSnapshot.copyDatabase(source.url("exportLibrary.db"), into: stale) }
        #expect(!FileManager.default.fileExists(atPath: stale.appending(path: "exportLibrary.db").path))
        // 링크는 복사하지 않는다
        source.symlink("linked.db", to: source.url("exportLibrary.db").path)
        #expect(throws: UsbError.self) { try UsbSnapshot.copyDatabase(source.url("linked.db"), into: Self.output()) }
        #expect(source.tree() == before)
    }
}
