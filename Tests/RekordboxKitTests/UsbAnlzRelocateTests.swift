import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 기기 실험용 사본 준비: 한 곡의 분석 파일·두 DB 경로를 일부러 어긋나게 만든다(임시 폴더의 합성 사본만)
@Suite("USB 분석 파일 옮기기(실험 사본)")
struct UsbAnlzRelocateTests {
    static let folder = "P123/0ABCDEF0"
    static let newDAT = "/PIONEER/USBANLZ/P123/0ABCDEF0/ANLZ0000.DAT"

    func withCopy(_ configure: (inout UsbLibraryFixture) -> Void = { _ in }, _ body: (UsbTreeFixture) throws -> Void) throws {
        var usb = UsbLibraryFixture()
        configure(&usb)
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try usb.write(to: tree)
        try body(tree)
    }

    /// 두 DB가 곡 id → 분석 경로로 적은 값(사본을 떠서 읽는다)
    func databasePaths(_ tree: UsbTreeFixture) throws -> (oneLibrary: [Int: String], deviceLibrary: [Int: String]) {
        let out = FileManager.default.temporaryDirectory.appending(path: "djc-relocate-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let snapshot = try UsbSnapshot.take(root: tree.root, into: out)
        let ol = try OneLibraryReader.read(copyAt: #require(snapshot.oneLibrary))
        let (dl, report) = try #require(try PdbReader.read(snapshot: snapshot))
        #expect(report.issues.isEmpty)
        return (Dictionary(uniqueKeysWithValues: ol.tracks.map { ($0.id, $0.analysisDataPath) }),
                Dictionary(uniqueKeysWithValues: dl.tracks.map { ($0.id, $0.analysisDataPath) }))
    }

    func ppth(_ tree: UsbTreeFixture, _ path: String) throws -> String {
        try AnlzPathTag.decode(#require(try AnlzFile(data: Data(contentsOf: tree.url(String(path.dropFirst())))).tag("PPTH")).bytes)
    }

    func exists(_ tree: UsbTreeFixture, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: tree.url(String(path.dropFirst())).path)
    }

    func noSidecars(_ tree: UsbTreeFixture) -> Bool {
        UsbLayout.oneLibrarySidecarSuffixes.allSatisfy { !FileManager.default.fileExists(atPath: tree.url(UsbLayout.oneLibrary + $0).path) }
    }

    func siblings(_ dat: String) -> [String] {
        let base = String(dat.dropLast(4))
        return [".DAT", ".EXT", ".2EX"].map { base + $0 }
    }

    func hotCueA(_ tree: UsbTreeFixture, _ dat: String) throws -> UInt32? {
        let file = try AnlzFile(data: Data(contentsOf: tree.url(String(dat.dropFirst()))))
        for tag in file.tags where tag.fourcc == "PCOB" {
            let decoded = try AnlzCueTags.decodePCOB(tag.bytes)
            if decoded.kind == AnlzCueTags.hotList { return decoded.entries.first { $0.hotCue == 1 }?.inMsec }
        }
        return nil
    }

    // MARK: - 모드

    @Test func dbOnlyMovesFilesAndBothDatabasePaths() throws {
        try withCopy { tree in
            let old = UsbLibraryFixture.analysisPath(3)
            let changes = try UsbAnlzRelocate.apply(copy: tree.root, trackID: 3, newFolder: Self.folder, mode: .dbOnly)
            let paths = try databasePaths(tree)
            #expect(paths.oneLibrary[3] == Self.newDAT && paths.deviceLibrary[3] == Self.newDAT)
            // 다른 곡은 그대로
            #expect(paths.oneLibrary[2] == UsbLibraryFixture.analysisPath(2) && paths.deviceLibrary[2] == UsbLibraryFixture.analysisPath(2))
            // DB 경로 = 파일 위치, PPTH = 곡 경로(계산 폴더만 다르다)
            #expect(siblings(Self.newDAT).allSatisfy { exists(tree, $0) })
            #expect(siblings(old).allSatisfy { !exists(tree, $0) })
            #expect(try ppth(tree, Self.newDAT) == UsbLibraryFixture.trackPath(3))
            #expect(noSidecars(tree))
            #expect(!changes.isEmpty && changes.allSatisfy { $0.hasPrefix("곡 3") })
            #expect(changes.contains { $0.contains(Self.folder) })
            #expect(!changes.joined().contains("Contents") && !changes.joined().contains("P000"))
        }
    }

    @Test func filesOnlyPointsDatabasesToMissingFolder() throws {
        try withCopy { tree in
            let old = UsbLibraryFixture.analysisPath(3)
            let before = tree.tree().filter { $0.key.hasPrefix("PIONEER/USBANLZ") }
            _ = try UsbAnlzRelocate.apply(copy: tree.root, trackID: 3, newFolder: Self.folder, mode: .filesOnly)
            let paths = try databasePaths(tree)
            #expect(paths.oneLibrary[3] == Self.newDAT && paths.deviceLibrary[3] == Self.newDAT)
            // 파일은 그대로(DB 경로 ≠ 파일 위치)
            #expect(tree.tree().filter { $0.key.hasPrefix("PIONEER/USBANLZ") } == before)
            #expect(siblings(old).allSatisfy { exists(tree, $0) } && !exists(tree, Self.newDAT))
            #expect(Self.newDAT.utf8.count == old.utf8.count)
            #expect(noSidecars(tree))
        }
    }

    @Test func decoySlot0KeepsRealFileInSlot1() throws {
        try withCopy { tree in
            let old = UsbLibraryFixture.analysisPath(3)
            let slot1 = old.replacingOccurrences(of: "ANLZ0000.DAT", with: "ANLZ0001.DAT")
            let original = try Data(contentsOf: tree.url(String(old.dropFirst())))
            _ = try UsbAnlzRelocate.apply(copy: tree.root, trackID: 3, newFolder: "", mode: .decoySlot0)
            let paths = try databasePaths(tree)
            #expect(paths.oneLibrary[3] == slot1 && paths.deviceLibrary[3] == slot1)
            // 진짜는 1번, 계산 폴더의 0번은 PPTH가 다른 가짜
            #expect(try Data(contentsOf: tree.url(String(slot1.dropFirst()))) == original)
            #expect(siblings(slot1).allSatisfy { exists(tree, $0) } && siblings(old).allSatisfy { exists(tree, $0) })
            for file in siblings(old) {
                #expect(try ppth(tree, file) != UsbLibraryFixture.trackPath(3))
            }
            for file in siblings(slot1) { #expect(try ppth(tree, file) == UsbLibraryFixture.trackPath(3)) }
            #expect(noSidecars(tree))
        }
    }

    @Test func cueVariantDiffersOnlyInHotCueA() throws {
        try withCopy { tree in
            let old = UsbLibraryFixture.analysisPath(3)
            _ = try UsbAnlzRelocate.apply(copy: tree.root, trackID: 3, newFolder: Self.folder, mode: .cueVariant)
            let paths = try databasePaths(tree)
            #expect(paths.oneLibrary[3] == Self.newDAT && paths.deviceLibrary[3] == Self.newDAT)
            // 두 곳에 파일이 있고, DB가 가리키는 쪽 .DAT의 핫큐 A만 다르다
            #expect(siblings(old).allSatisfy { exists(tree, $0) } && siblings(Self.newDAT).allSatisfy { exists(tree, $0) })
            let before = try #require(try hotCueA(tree, old)), after = try #require(try hotCueA(tree, Self.newDAT))
            #expect(before == 3_000 && after != before)
            let a = try AnlzFile(data: Data(contentsOf: tree.url(String(old.dropFirst()))))
            let b = try AnlzFile(data: Data(contentsOf: tree.url(String(Self.newDAT.dropFirst()))))
            #expect(a.tags.map(\.fourcc) == b.tags.map(\.fourcc))
            #expect(zip(a.tags, b.tags).filter { $0.bytes != $1.bytes }.map(\.0.fourcc) == ["PCOB"])
            for ext in [".EXT", ".2EX"] {
                #expect(try Data(contentsOf: tree.url(String(old.dropFirst().dropLast(4)) + ext))
                    == Data(contentsOf: tree.url(String(Self.newDAT.dropFirst().dropLast(4)) + ext)))
            }
            #expect(noSidecars(tree))
        }
    }

    @Test func cueVariantAddsHotCueAWhenMissing() throws {
        try withCopy({ $0.hotCueA = [:] }) { tree in
            _ = try UsbAnlzRelocate.apply(copy: tree.root, trackID: 2, newFolder: Self.folder, mode: .cueVariant)
            let before = try hotCueA(tree, UsbLibraryFixture.analysisPath(2)), after = try hotCueA(tree, Self.newDAT)
            #expect(before == nil && after != nil)
        }
    }

    @Test func bothMovesFilesAndDatabases() throws {
        try withCopy { tree in
            _ = try UsbAnlzRelocate.apply(copy: tree.root, trackID: 1, newFolder: Self.folder, mode: .both)
            let paths = try databasePaths(tree)
            #expect(paths.oneLibrary[1] == Self.newDAT && paths.deviceLibrary[1] == Self.newDAT)
            #expect(siblings(Self.newDAT).allSatisfy { exists(tree, $0) })
        }
    }

    // MARK: - 거부

    /// 거부 이유(아무것도 바뀌지 않아야 한다)
    func refusedReason(_ tree: UsbTreeFixture?, copy: URL, trackID: Int = 3, folder: String = Self.folder,
                       mode: UsbAnlzRelocate.Mode = .dbOnly) -> String? {
        let before = tree?.tree()
        defer { if let tree { #expect(tree.tree() == before) } }
        do {
            _ = try UsbAnlzRelocate.apply(copy: UsbRoot(copy), trackID: trackID, newFolder: folder, mode: mode)
            return nil
        } catch let UsbError.pathRefused(_, reason) {
            return reason
        } catch let UsbError.readFailed(detail) {
            return detail
        } catch {
            return "\(error)"
        }
    }

    @Test func refusesVolumesPath() throws {
        #expect(refusedReason(nil, copy: URL(filePath: "/Volumes/DJCNOTEXIST-\(UUID().uuidString)")) != nil)
        // 볼륨 밑은 임시 폴더 밖, 임시 폴더에 붙인 볼륨의 맨 위도 받지 않는다
        #expect(UsbAnlzRelocate.refusal(resolved: "/Volumes/DJCTEST/copy", mountedOn: "/Volumes/DJCTEST") == "outsideScratch")
        let mounted = UsbScratchRoots.realPath(NSTemporaryDirectory())! + "/mnt"
        #expect(UsbAnlzRelocate.refusal(resolved: mounted, mountedOn: mounted) == "volumeRoot")
        // 임시 폴더에 붙인 볼륨의 하위 폴더도 받지 않는다(Mac 시동·데이터 볼륨 위의 폴더만)
        #expect(UsbAnlzRelocate.refusal(resolved: mounted + "/sub", mountedOn: mounted) == "onMountedVolume")
        #expect(UsbAnlzRelocate.refusal(resolved: "/private/tmp/x/mnt/sub", mountedOn: "/private/tmp/x/mnt") == "onMountedVolume")
        #expect(UsbAnlzRelocate.refusal(resolved: "/private/tmp/copy", mountedOn: "/") == nil)
        #expect(UsbAnlzRelocate.refusal(resolved: "/private/tmp/copy", mountedOn: "/System/Volumes/Data") == nil)
        #expect(UsbAnlzRelocate.refusal(resolved: "/private/tmp/copy", mountedOn: nil) == "unreadable")
    }

    @Test func refusesOutsideScratch() throws {
        #expect(refusedReason(nil, copy: URL(filePath: NSHomeDirectory())) == "outsideScratch")
        #expect(UsbAnlzRelocate.refusal(resolved: NSHomeDirectory() + "/Music/copy", mountedOn: "/System/Volumes/Data") == "outsideScratch")
    }

    @Test func refusesSymlinkedCopy() throws {
        try withCopy { tree in
            let link = FileManager.default.temporaryDirectory.appending(path: "djc-relocate-link-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.base)
            defer { try? FileManager.default.removeItem(at: link) }
            #expect(refusedReason(tree, copy: link) == "symlink")
        }
    }

    @Test func acceptsTmpAndPrivateTmpSpellings() throws {
        try withCopy { tree in
            let name = "djc-relocate-\(UUID().uuidString)"
            try FileManager.default.copyItem(at: tree.base, to: URL(filePath: "/private/tmp/" + name))
            defer { try? FileManager.default.removeItem(atPath: "/private/tmp/" + name) }
            _ = try UsbAnlzRelocate.apply(copy: UsbRoot(URL(filePath: "/tmp/" + name)), trackID: 1, newFolder: "P001/00000011", mode: .dbOnly)
            _ = try UsbAnlzRelocate.apply(copy: UsbRoot(URL(filePath: "/private/tmp/" + name)), trackID: 2, newFolder: "P001/00000012",
                                          mode: .dbOnly)
            #expect(FileManager.default.fileExists(atPath: "/private/tmp/\(name)/PIONEER/USBANLZ/P001/00000011/ANLZ0000.DAT"))
            #expect(FileManager.default.fileExists(atPath: "/private/tmp/\(name)/PIONEER/USBANLZ/P001/00000012/ANLZ0000.DAT"))
        }
    }

    @Test func samelengthRequired() throws {
        try withCopy({ $0.analysisPaths = [3: "/PIONEER/USBANLZ/P0/3/ANLZ0000.DAT"] }) { tree in
            let reason = refusedReason(tree, copy: tree.base)
            #expect(reason?.contains("length") == true)
        }
    }

    @Test func refusesBadFolderMissingTrackAndExistingTarget() throws {
        try withCopy { tree in
            for folder in ["../P123/0ABCDEF0", "P12/0ABCDEF0", "P123/0ABCDEF", "p123/0abcdef0", "P123/0ABCDEF0/x"] {
                #expect(refusedReason(tree, copy: tree.base, folder: folder) == "badFolder")
            }
            #expect(refusedReason(tree, copy: tree.base, trackID: 99) != nil)
            // 이미 있는 폴더로는 옮기지 않는다
            let existing = String(UsbLibraryFixture.analysisPath(2).dropFirst("/PIONEER/USBANLZ/".count).dropLast("/ANLZ0000.DAT".count))
            #expect(refusedReason(tree, copy: tree.base, folder: existing) != nil)
        }
    }

    @Test func oneLibraryNoSidecarsAfter() throws {
        try withCopy { tree in
            for (id, mode) in [(1, UsbAnlzRelocate.Mode.dbOnly), (2, .filesOnly), (3, .cueVariant)] {
                _ = try UsbAnlzRelocate.apply(copy: tree.root, trackID: id, newFolder: String(format: "P010/%08X", id), mode: mode)
                #expect(noSidecars(tree))
            }
            // 사이드카가 남은 사본은 받지 않는다
            tree.write(UsbLayout.oneLibrary + "-wal", Data())
            #expect(refusedReason(tree, copy: tree.base, trackID: 1, folder: "P010/00000021") != nil)
        }
    }
}
