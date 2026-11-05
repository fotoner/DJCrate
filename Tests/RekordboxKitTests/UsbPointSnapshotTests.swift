import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 시점 스냅샷 뜨기·목록·고정·지우기·보존 정리(#226). 임시 폴더 USB(마운트 흉내, 디스크 이미지로 보이는 가짜 가드)에
/// 합성 파일을 두고 뜬다. USB는 읽기만 하고 열지 않는 곳은 열거도 하지 않는다. 스냅샷 폴더도 임시 폴더다.
@Suite("USB 시점 스냅샷 뜨기")
struct UsbPointSnapshotTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let scoped = [UsbLayout.oneLibrary, UsbLayout.oneLibrary + "-wal", UsbLayout.exportPdb, UsbLayout.exportExtPdb,
                         "PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT", "PIONEER/USBANLZ/P000/00000001/ANLZ0000.EXT",
                         "PIONEER/Artwork/00001/a1.jpg", "PIONEER/Artwork/00001/b1_m.jpg", "PIONEER/MYSETTING.DAT", "PIONEER/DJMMYSETTING.DAT"]
    static let outside = ["Contents/시험/a.mp3", "PIONEER/rekordbox/playlists3.sync", "PIONEER/rekordbox/ImportedHistory.xml",
                          "PIONEER/rekordbox/export.pdb.bak", "PIONEER/USBANLZ/P000/00000001/._ANLZ0000.DAT"]
    static let locked = ["PIONEER/extracted/GCRED.DAT", "PIONEER/CDP/x", "PIONEER/djprofile.nxs"]

    final class Env {
        let usb = UsbChangeSetFixture()
        let fs: FaultyUsbFileSystem

        init(files: [String] = UsbPointSnapshotTests.scoped + UsbPointSnapshotTests.outside) {
            fs = usb.fileSystem()
            for (index, path) in files.enumerated() { usb.write(path, UsbChangeSetFixture.random(500 + index)) }
        }

        deinit { usb.remove() }

        var directory: URL { usb.home.appending(path: "usb-point-snapshots") }

        func create(_ name: String = "", at offset: Double = 0) throws -> UsbPointSnapshotEntry {
            try UsbPointSnapshot.create(name: name, root: usb.root, in: directory, paths: usb.paths, guard: usb.writeGuard(), fileSystem: fs,
                                        now: UsbPointSnapshotTests.date.addingTimeInterval(offset))
        }

        func refusal(_ body: () throws -> Void) -> [String] {
            do {
                try body()
            } catch let UsbError.writeRefused(blocks) {
                return blocks.map(\.code)
            } catch {
                return ["\(error)"]
            }
            return []
        }

        /// 남은 스냅샷 폴더 이름(반쯤 뜬 것 포함)
        var folders: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: directory.appending(path: usb.volumeKey).path)) ?? []
        }
    }

    @Test("범위 파일을 바이트 그대로 담고 음원·동기화 선택·._는 담지 않으며 USB는 바꾸지 않는다")
    func createCopiesScopeOnly() throws {
        let env = Env()
        for path in Self.locked { env.usb.write(path, Data("SECRET".utf8)) }
        let before = env.usb.tree()
        // 열지 않는 곳은 권한을 빼 둔다(읽으려 하면 실패한다)
        let lockedPaths = Self.locked + ["PIONEER/extracted", "PIONEER/CDP"]
        for path in lockedPaths { #expect(chmod(env.usb.usb(path).path, 0) == 0) }
        let created = Result { try env.create(" 공연 전 ") }
        for path in lockedPaths.reversed() { chmod(env.usb.usb(path).path, 0o755) }
        let entry = try created.get()
        #expect(entry.metadata.name == "공연 전" && entry.metadata.kind == .manual && !entry.metadata.pinned)
        #expect(entry.metadata.volumeUUID == env.usb.volumeKey && entry.metadata.createdAt == Self.date)
        #expect(Set(entry.metadata.files.keys) == Set(Self.scoped))
        for path in Self.scoped {
            let copy = entry.url.appending(path: "files").appending(path: path)
            #expect(try Data(contentsOf: copy) == env.usb.data(path), "\(path)")
            #expect(entry.metadata.files[path]?.sha256 == UsbChangeSetFixture.sha256(env.usb.data(path)!))
            #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: entry.url.path)[.posixPermissions] as? Int == 0o700)
        #expect(env.usb.tree() == before)
        // 열지 않는 곳은 이름도 보지 않는다(정해진 이름만 stat, 분석·아트워크 폴더만 내려간다)
        #expect(!env.fs.calls.contains { call in ["extracted", "CDP", "djprofile"].contains { call.contains($0) } })
        #expect(!env.fs.calls.contains { $0 == "list PIONEER" || $0.hasPrefix("list Contents") })
        #expect(UsbPointSnapshot.list(in: env.directory, volumeKey: env.usb.volumeKey) == [entry])
    }

    @Test("rekordbox가 켜져 있거나, 끝나지 않은 쓰기·임시 파일·링크가 있거나, 마운트 지점이 아니거나, Mac 쪽 폴더가 그 볼륨 안이거나 보호 폴더와 겹치거나, 라이브러리 DB가 없으면 뜨지 않는다")
    func createRefusals() throws {
        let running = Env()
        running.usb.rekordboxRunning = true
        #expect(running.refusal { _ = try running.create() } == ["rekordboxRunning"])
        #expect(!running.fs.calls.contains { $0.hasPrefix("copyDataNew") })

        let temp = Env()
        temp.usb.write("PIONEER/USBANLZ/P000/.djc-part-abcdefgh-000001", Data("x".utf8))
        #expect(temp.refusal { _ = try temp.create() } == ["tempFilesPresent"])
        #expect(temp.folders.isEmpty)

        let open = Env()
        let journal = UsbJournal(changes: open.usb.exportChanges(), volumeUUID: open.usb.volumeKey, volumeName: "DJCTEST", now: Self.date)
        try UsbDurableFile.write(UsbJournal.encoder().encode(journal), to: open.usb.paths.sessions.appending(path: open.usb.volumeKey + ".json"))
        #expect(open.refusal { _ = try open.create() } == ["recoveryNeeded"])

        let link = Env()
        try FileManager.default.createSymbolicLink(atPath: link.usb.usb("PIONEER/Artwork/00001/a9.jpg").path, withDestinationPath: "/etc/hosts")
        #expect(link.refusal { _ = try link.create() } == ["pointSnapshotUnreadable"])
        #expect(link.folders.isEmpty)

        let notMount = Env()
        notMount.fs.simulatedMountPoint = "/somewhere/else"
        #expect(notMount.refusal { _ = try notMount.create() } == ["notMountPoint"])

        // 스냅샷·저널 폴더가 그 볼륨 안이거나 보호 폴더와 겹치는 볼륨이면 Mac 쪽 폴더도 만들지 않고 막는다
        let inside = Env()
        let before = inside.usb.tree()
        let insideFolder = inside.usb.usbURL.appending(path: "djc-home/usb-point-snapshots")
        #expect(inside.refusal {
            _ = try UsbPointSnapshot.create(name: "", root: inside.usb.root, in: insideFolder, paths: inside.usb.paths, guard: inside.usb.writeGuard(),
                                            fileSystem: inside.fs)
        } == ["protectedPath"])
        #expect(inside.usb.tree() == before && !FileManager.default.fileExists(atPath: inside.usb.usbURL.appending(path: "djc-home").path))
        let guarded = inside.usb.writeGuard(protectedRoots: [inside.usb.usbURL.appending(path: "PIONEER")])
        #expect(inside.refusal {
            _ = try UsbPointSnapshot.create(name: "", root: inside.usb.root, in: inside.directory, paths: inside.usb.paths, guard: guarded,
                                            fileSystem: inside.fs)
        } == ["protectedPath"])
        #expect(inside.folders.isEmpty && !FileManager.default.fileExists(atPath: inside.usb.paths.sessions.path))

        // 라이브러리 DB가 없으면 되돌릴 수 없으므로 뜨지 않는다
        let noLibrary = Env(files: ["PIONEER/Artwork/00001/a1.jpg", "PIONEER/MYSETTING.DAT"])
        #expect(noLibrary.refusal { _ = try noLibrary.create() } == ["pointSnapshotNoDatabase"])
        #expect(noLibrary.folders.isEmpty)
    }

    @Test("뜨는 동안 USB 파일이 바뀌면 그 스냅샷은 버린다")
    func sourceChangedDiscards() throws {
        let env = Env()
        let target = env.usb.usb("PIONEER/Artwork/00001/a1.jpg")
        env.fs.onOperation = { op, url in
            if op == .copyDataNew, url.lastPathComponent == "a1.jpg" {
                try? (UsbChangeSetFixture.random(900)).write(to: target)
            }
        }
        #expect(env.refusal { _ = try env.create() } == ["sourceChangedDuringCopy"])
        #expect(env.folders.isEmpty)
        #expect(UsbPointSnapshot.list(in: env.directory, volumeKey: env.usb.volumeKey).isEmpty)
    }

    @Test("목록·찾기·고정·지우기와 보존 정리(볼륨마다 최근 5개 + 고정)")
    func listPinDeletePrune() throws {
        let env = Env(files: [UsbLayout.exportPdb, "PIONEER/Artwork/00001/a1.jpg"])
        let oldest = try env.create("처음")
        try UsbPointSnapshot.setPinned(true, oldest, in: env.directory)
        var made = [oldest.id]
        for index in 1...6 { made.append(try env.create(index == 3 ? "같은 이름" : "", at: Double(index) * 60).id) }
        _ = try env.create("같은 이름", at: 7 * 60)
        let listed = UsbPointSnapshot.list(in: env.directory, volumeKey: env.usb.volumeKey)
        // 최근 5개 + 고정한 가장 옛 것. 그 사이 것은 정리됐다
        #expect(listed.count == 6 && listed.last?.id == oldest.id && listed.last?.metadata.pinned == true)
        #expect(!listed.contains { $0.id == made[1] || $0.id == made[2] })
        #expect(UsbPointSnapshot.find(oldest.id, in: env.directory, volumeKey: env.usb.volumeKey)?.id == oldest.id)
        #expect(UsbPointSnapshot.find("처음", in: env.directory, volumeKey: env.usb.volumeKey)?.id == oldest.id)
        #expect(UsbPointSnapshot.find("같은 이름", in: env.directory, volumeKey: env.usb.volumeKey) == nil)
        #expect(UsbPointSnapshot.list(in: env.directory, volumeKey: "OTHER-VOLUME").isEmpty)

        let pinned = try #require(listed.last)
        #expect(env.refusal { try UsbPointSnapshot.delete(pinned, in: env.directory) } == ["pointSnapshotPinned"])
        let unpinned = try UsbPointSnapshot.setPinned(false, pinned, in: env.directory)
        try UsbPointSnapshot.delete(unpinned, in: env.directory)
        #expect(UsbPointSnapshot.list(in: env.directory, volumeKey: env.usb.volumeKey).count == 5)
        // 스냅샷 폴더 밖의 항목은 고치지도 지우지도 않는다
        let stranger = UsbPointSnapshotEntry(url: env.usb.folder.appending(path: "elsewhere"), metadata: listed[0].metadata)
        try FileManager.default.createDirectory(at: stranger.url, withIntermediateDirectories: true)
        #expect(env.refusal { try UsbPointSnapshot.delete(stranger, in: env.directory) } == ["pointSnapshotOutside"])
        #expect(FileManager.default.fileExists(atPath: stranger.url.path))
    }

    @Test("사건: 이 볼륨 스냅샷의 시각·DB 해시·사이드카")
    func snapshotEvents() throws {
        let env = Env(files: [UsbLayout.oneLibrary, UsbLayout.oneLibrary + "-wal", UsbLayout.exportPdb])
        let entry = try env.create()
        let events = UsbPointSnapshot.volumeEvents(in: env.directory, paths: env.usb.paths, volumeKey: env.usb.volumeKey)
        #expect(events == [.snapshot(date: Self.date, databases: entry.metadata.databases, sidecars: true)])
        #expect(UsbPointSnapshot.volumeEvents(in: env.directory, paths: env.usb.paths, volumeKey: "OTHER").isEmpty)
    }
}
