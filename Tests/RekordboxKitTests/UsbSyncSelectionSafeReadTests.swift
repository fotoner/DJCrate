import DJCDomain
import Darwin
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

struct UsbSyncSelectionSafeReadTests {
    @Test func 루트의_상위_링크가_canonical_확보_뒤_바뀌면_외부_읽기는_0회다() throws {
        let sandbox = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { sandbox.remove(); outside.remove() }
        let fixture = UsbTreeFixture(base: sandbox.url("parent/usb"))
        let external = UsbTreeFixture(base: outside.url("usb"))
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        fixture.write(path, UsbSyncSelectionFileTests.xml)
        external.write(path, "outside")
        var reads = 0, swapped = false
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbAnchoredFileReader.read(root: fixture.root, relativePath: path, maxBytes: 16 * 1024 * 1024,
                beforeOpen: { component in
                    if component == "", !swapped {
                        swapped = true
                        try FileManager.default.moveItem(at: sandbox.url("parent"), to: sandbox.url("original"))
                        sandbox.symlink("parent", to: outside.base.path)
                    }
                }, willRead: { _ in reads += 1 })
        }
        #expect(swapped && reads == 0)
    }

    @Test func 열린_절대경로_부모_fd가_옮겨지면_실제_루트_fd경로_대조로_읽기_전에_거부한다() throws {
        let sandbox = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { sandbox.remove(); outside.remove() }
        let fixture = UsbTreeFixture(base: sandbox.url("parent/usb"))
        let external = UsbTreeFixture(base: outside.url("usb"))
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        fixture.write(path, UsbSyncSelectionFileTests.xml)
        external.write(path, "outside")
        let canonical = try #require(UsbScratchRoots.realPath(fixture.base.path))
        var reads = 0, swapped = false
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbAnchoredFileReader.read(root: fixture.root, relativePath: path, maxBytes: 16 * 1024 * 1024,
                beforeOpen: { component in
                    if component == canonical, !swapped {
                        swapped = true
                        // parent의 fd를 쥔 뒤 이름을 바꾼다. openat은 옛 루트를 열어도 경로 대조에서 막혀야 한다.
                        try FileManager.default.moveItem(at: sandbox.url("parent"), to: sandbox.url("original"))
                        sandbox.symlink("parent", to: outside.base.path)
                    }
                }, willRead: { _ in reads += 1 })
        }
        #expect(swapped && reads == 0)
    }

    @Test func 같은_루트_경로를_일반_폴더로_바꿔도_캡처한_device_inode와_다르면_읽지_않는다() throws {
        let sandbox = UsbTreeFixture()
        defer { sandbox.remove() }
        let fixture = UsbTreeFixture(base: sandbox.url("usb"))
        let replacement = UsbTreeFixture(base: sandbox.url("replacement"))
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        fixture.write(path, UsbSyncSelectionFileTests.xml)
        replacement.write(path, "outside")
        var reads = 0, swapped = false
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbAnchoredFileReader.read(root: fixture.root, relativePath: path, maxBytes: 16 * 1024 * 1024,
                beforeOpen: { component in
                    if component == "", !swapped {
                        swapped = true
                        try FileManager.default.moveItem(at: fixture.base, to: sandbox.url("original"))
                        try FileManager.default.moveItem(at: replacement.base, to: fixture.base)
                    }
                }, willRead: { _ in reads += 1 })
        }
        #expect(swapped && reads == 0)
    }

    @Test func 루트_fd를_확보한_뒤_상위_경로가_바뀌어도_파일_읽기_전에_거부한다() throws {
        let sandbox = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { sandbox.remove(); outside.remove() }
        let fixture = UsbTreeFixture(base: sandbox.url("parent/usb"))
        let external = UsbTreeFixture(base: outside.url("usb"))
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        fixture.write(path, UsbSyncSelectionFileTests.xml)
        external.write(path, "outside")
        var reads = 0, swapped = false
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbAnchoredFileReader.read(root: fixture.root, relativePath: path, maxBytes: 16 * 1024 * 1024,
                beforeOpen: { component in
                    if component == "PIONEER", !swapped {
                        swapped = true
                        try FileManager.default.moveItem(at: sandbox.url("parent"), to: sandbox.url("original"))
                        sandbox.symlink("parent", to: outside.base.path)
                    }
                }, willRead: { _ in reads += 1 })
        }
        #expect(swapped && reads == 0)
    }

    @Test func 루트_상위에_이미_있는_사용자_링크도_정상_시스템_별칭으로_취급하지_않는다() throws {
        let sandbox = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { sandbox.remove(); outside.remove() }
        let external = UsbTreeFixture(base: outside.url("usb"))
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        external.write(path, "outside")
        sandbox.symlink("parent", to: outside.base.path)
        var reads = 0
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbAnchoredFileReader.read(root: UsbRoot(sandbox.url("parent/usb")), relativePath: path,
                maxBytes: 16 * 1024 * 1024, willRead: { _ in reads += 1 })
        }
        #expect(reads == 0)
    }

    @Test func 루트_자체가_링크인_입력은_canonical로_풀리더라도_읽지_않는다() throws {
        let sandbox = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { sandbox.remove(); outside.remove() }
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        outside.write(path, "outside")
        sandbox.symlink("usb", to: outside.base.path)
        var reads = 0
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbAnchoredFileReader.read(root: UsbRoot(sandbox.url("usb")), relativePath: path,
                maxBytes: 16 * 1024 * 1024, willRead: { _ in reads += 1 })
        }
        #expect(reads == 0)
    }

    @Test func tmp와_var_정상_별칭은_canonical_루트와_같은_fd정체로_읽는다() throws {
        for prefix in ["/tmp", "/var/tmp"] {
            let fixture = UsbTreeFixture(base: URL(fileURLWithPath: prefix + "/djc-sync-alias-" + UUID().uuidString))
            defer { fixture.remove() }
            let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
            fixture.write(path, UsbSyncSelectionFileTests.xml)
            let canonical = try #require(UsbScratchRoots.realPath(fixture.base.path))
            var info = Darwin.stat()
            #expect(lstat(canonical, &info) == 0)
            let result = try #require(try UsbAnchoredFileReader.read(root: fixture.root, relativePath: path,
                                                                maxBytes: 16 * 1024 * 1024))
            #expect(result.data == UsbSyncSelectionFileTests.xml)
            #expect(result.identity?.prefix(2).map { $0 } == [UInt64(truncatingIfNeeded: info.st_dev), UInt64(info.st_ino)])
            #expect(try UsbSyncSelectionBundle.readFile(root: UsbRoot(URL(fileURLWithPath: canonical)),
                                                       format: .deviceLibrary) == result.data)
        }
    }

    @Test func 부모_검사_뒤_링크로_바뀌어도_외부_파일의_바이트는_읽지_않는다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        fixture.write("PIONEER/rekordbox/playlists3.sync", UsbSyncSelectionFileTests.xml)
        outside.write("playlists3.sync", UsbSyncSelectionFileTests.xml)
        var reads = 0
        #expect(throws: (any Error).self) {
            _ = try UsbAnchoredFileReader.read(root: fixture.root, relativePath: UsbSyncSelectionFile.relativePath(for: .deviceLibrary),
                maxBytes: 16 * 1024 * 1024, beforeOpen: { component in
                    if component == "rekordbox" {
                        try FileManager.default.moveItem(at: fixture.url("PIONEER/rekordbox"), to: fixture.url("PIONEER/original"))
                        fixture.symlink("PIONEER/rekordbox", to: outside.base.path)
                    }
                }, willRead: { _ in reads += 1 })
        }
        #expect(reads == 0)
    }

    @Test func 파일_fd를_연_뒤_부모가_바뀌어도_붙잡은_파일만_읽는다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        fixture.write("PIONEER/rekordbox/playlists3.sync", UsbSyncSelectionFileTests.xml)
        outside.write("playlists3.sync", "outside")
        var outsideInfo = Darwin.stat()
        #expect(lstat(outside.url("playlists3.sync").path, &outsideInfo) == 0)
        var swapped = false, outsideReads = 0
        let result = try UsbAnchoredFileReader.read(root: fixture.root,
            relativePath: UsbSyncSelectionFile.relativePath(for: .deviceLibrary), maxBytes: 16 * 1024 * 1024,
            willRead: { descriptor in
                if !swapped {
                    swapped = true
                    try FileManager.default.moveItem(at: fixture.url("PIONEER/rekordbox"), to: fixture.url("PIONEER/original"))
                    fixture.symlink("PIONEER/rekordbox", to: outside.base.path)
                }
                var info = Darwin.stat()
                #expect(fstat(descriptor, &info) == 0)
                if info.st_dev == outsideInfo.st_dev, info.st_ino == outsideInfo.st_ino { outsideReads += 1 }
            })
        #expect(result?.data == UsbSyncSelectionFileTests.xml && outsideReads == 0)
        #expect(throws: (any Error).self) {
            try UsbSyncSelectionBundle.readFile(root: fixture.root, format: .deviceLibrary)
        }
    }

    @Test func Bundle의_주입된_읽기_직전_부모_교체도_거부한다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        fixture.write("PIONEER/rekordbox/playlists3.sync", UsbSyncSelectionFileTests.xml)
        outside.write("playlists3.sync", UsbSyncSelectionFileTests.xml)
        let fs = FaultyUsbFileSystem(root: fixture.base)
        var swapped = false
        fs.onOperation = { operation, _ in
            if operation == .read, !swapped {
                swapped = true
                try? FileManager.default.moveItem(at: fixture.url("PIONEER/rekordbox"), to: fixture.url("PIONEER/original"))
                fixture.symlink("PIONEER/rekordbox", to: outside.base.path)
            }
        }
        #expect(throws: (any Error).self) {
            try UsbSyncSelectionBundle.read(root: fixture.root, formats: [.deviceLibrary], fileSystem: fs)
        }
        #expect(swapped)
    }

    @Test func 보호_경로와_부모_참조는_stat이나_읽기_전에_거부한다() {
        let nonexistent = UsbRoot(URL(fileURLWithPath: "/synthetic-never-open"))
        for path in ["PIONEER/extracted/auth", "PIONEER/CDP/a", "PIONEER/djprofile.nxs", "../playlists3.sync", "/playlists3.sync"] {
            var opened = false, read = false
            #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
                try UsbAnchoredFileReader.read(root: nonexistent, relativePath: path, maxBytes: 10,
                    beforeOpen: { _ in opened = true }, willRead: { _ in read = true })
            }
            #expect(!opened && !read)
        }
    }

    @Test func 실제_fd의_종류와_크기를_읽기_전에_확인한다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        fixture.mkdir("PIONEER/rekordbox/playlists3.sync")
        var reads = 0
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbAnchoredFileReader.read(root: fixture.root, relativePath: UsbSyncSelectionFile.relativePath(for: .deviceLibrary),
                maxBytes: 10, willRead: { _ in reads += 1 })
        }
        try FileManager.default.removeItem(at: fixture.url("PIONEER/rekordbox/playlists3.sync"))
        fixture.write("PIONEER/rekordbox/playlists3.sync", "elevenbytes")
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbAnchoredFileReader.read(root: fixture.root, relativePath: UsbSyncSelectionFile.relativePath(for: .deviceLibrary),
                maxBytes: 10, willRead: { _ in reads += 1 })
        }
        #expect(reads == 0)
    }


    @Test func 두_형식을_읽는_동안_첫_파일이_바뀌면_오래된_쌍을_반환하지_않는다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        fixture.write("PIONEER/rekordbox/playlists3.sync", UsbSyncSelectionFileTests.xml)
        fixture.write("PIONEER/rekordbox/playlists3Plus.sync", UsbSyncSelectionFileTests.xml)
        let fs = FaultyUsbFileSystem(root: fixture.base)
        var reads = 0
        fs.onOperation = { operation, _ in
            if operation == .read {
                reads += 1
                if reads == 2 {
                    // 두 번째 형식을 읽기 직전에 이미 읽은 첫 형식(UsbFormat.allCases 순서)을 바꾼다.
                    fixture.write(UsbSyncSelectionFile.relativePath(for: UsbFormat.allCases[0]), Data(String(decoding: UsbSyncSelectionFileTests.xml, as: UTF8.self)
                        .replacingOccurrences(of: "AutomaticSync=\"0\"", with: "AutomaticSync=\"1\"").utf8))
                }
            }
        }
        #expect(throws: UsbSyncSelectionFile.ParseError.changedDuringRead) {
            try UsbSyncSelectionBundle.read(root: fixture.root, formats: UsbFormat.defaultSet, fileSystem: fs)
        }
    }

    @Test func 같은_바이트_크기_시각의_파일_교체도_정체로_발견한다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        let relative = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        fixture.write(relative, UsbSyncSelectionFileTests.xml)
        fixture.write("replacement.sync", UsbSyncSelectionFileTests.xml)
        var original = Darwin.stat()
        #expect(lstat(fixture.url(relative).path, &original) == 0)
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(utimensat(AT_FDCWD, fixture.url("replacement.sync").path, &times, AT_SYMLINK_NOFOLLOW) == 0)
        let fs = FaultyUsbFileSystem(root: fixture.base)
        var reads = 0
        fs.onOperation = { operation, _ in
            if operation == .read {
                reads += 1
                if reads == 2 {
                    try? FileManager.default.removeItem(at: fixture.url(relative))
                    try? FileManager.default.moveItem(at: fixture.url("replacement.sync"), to: fixture.url(relative))
                }
            }
        }
        #expect(throws: UsbSyncSelectionFile.ParseError.changedDuringRead) {
            try UsbSyncSelectionBundle.read(root: fixture.root, formats: [.deviceLibrary], fileSystem: fs)
        }
    }

    @Test func 안전_읽기_오류는_개인_루트_경로를_노출하지_않는다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        fixture.symlink("PIONEER/rekordbox", to: outside.base.path)
        do {
            _ = try UsbSyncSelectionBundle.readFile(root: fixture.root, format: .deviceLibrary)
            Issue.record("부모 링크를 거부하지 않았음")
        } catch {
            let message = String(describing: error)
            #expect(!message.contains(fixture.base.path) && !message.contains(outside.base.path))
        }
    }
}


extension UsbSyncSelectionSafeReadTests {
    private func swappingProbe(_ fixture: UsbTreeFixture, outside: UsbTreeFixture,
                               reads: @escaping () -> Void) -> UsbReadFileProbe {
        let probe = UsbReadFileProbe(base: FaultyUsbFileSystem(root: fixture.base))
        var swapped = false
        probe.onReadFile = { root, path, limit in
            try UsbAnchoredFileReader.read(root: root, relativePath: path, maxBytes: limit, beforeOpen: { component in
                if component == "rekordbox", !swapped {
                    swapped = true
                    try FileManager.default.moveItem(at: fixture.url("PIONEER/rekordbox"), to: fixture.url("PIONEER/original"))
                    fixture.symlink("PIONEER/rekordbox", to: outside.base.path)
                }
            }, willRead: { _ in reads() })
        }
        return probe
    }

    @Test func stage의_원문_대조는_부모_교체_뒤_외부_읽기와_URL_재해시를_하지_않는다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        fixture.write(path, UsbSyncSelectionFileTests.xml)
        outside.write("playlists3.sync", UsbSyncSelectionFileTests.xml)
        var reads = 0
        let probe = swappingProbe(fixture, outside: outside) { reads += 1 }
        let draft = UsbSyncSelectionDraft(localDBID: 42, sourceNodes: [], selection: .init(), enabled: true,
                                         playlistRefs: [:], baseFiles: [.deviceLibrary: UsbSyncSelectionFileTests.xml])
        #expect(throws: (any Error).self) {
            try UsbSyncSelectionStage.matchesBase(draft, formats: [.deviceLibrary], root: fixture.root, fileSystem: probe)
        }
        #expect(probe.anchoredCalls == 1 && reads == 0 && probe.urlReads == 0 && probe.urlHashes == 0)
    }

    @Test func XML검증기의_부모_교체는_외부_파일을_읽지_않고_문제로_남는다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        fixture.write(UsbSyncSelectionFile.relativePath(for: .deviceLibrary), UsbSyncSelectionFileTests.xml)
        outside.write("playlists3.sync", UsbSyncSelectionFileTests.xml)
        var reads = 0
        let probe = swappingProbe(fixture, outside: outside) { reads += 1 }
        let changesFixture = UsbChangeSetFixture()
        defer { changesFixture.remove() }
        var changes = changesFixture.exportChanges()
        let draft = UsbSyncSelectionDraft(localDBID: 42, sourceNodes: [], selection: .init(), enabled: true,
                                         playlistRefs: [:], baseFiles: [:])
        changes.syncSelection = .init(draft: draft, formats: [.deviceLibrary], playlistIDs: [:],
                                      contract: UsbSyncSelectionXMLTests.contract)
        let problems = try UsbSyncSelectionVerifier().verify(root: fixture.root, changes: changes, fileSystem: probe,
                                                             scratch: changesFixture.folder)
        #expect(problems.contains("sync selection semantics: PIONEER/rekordbox/playlists3.sync"))
        #expect(probe.anchoredCalls == 1 && reads == 0 && probe.urlReads == 0 && probe.urlHashes == 0)
    }

    @Test func 준비_XML도_준비_루트_아래_부모를_fd로_열어_교체를_거부한다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary), data = UsbSyncSelectionFileTests.xml
        fixture.write(path, data)
        outside.write("playlists3.sync", data)
        var reads = 0
        let probe = swappingProbe(fixture, outside: outside) { reads += 1 }
        let write = UsbFileWrite(staged: fixture.url(path).path, destination: path, sha256: UsbExportAssembly.sha256(data),
                                 size: Int64(data.count), modificationDate: nil, disposition: .create, afterDatabases: true)
        #expect(throws: (any Error).self) {
            try UsbSyncSelectionStage.readStagedSelection(write, stagingRoot: fixture.root, fileSystem: probe)
        }
        #expect(probe.anchoredCalls == 1 && reads == 0 && probe.urlReads == 0 && probe.urlHashes == 0)
    }
}


extension UsbSyncSelectionSafeReadTests {
    @Test func 준비_XML의_안전읽기_결과로만_크기와_SHA256을_확인한다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary), data = UsbSyncSelectionFileTests.xml
        fixture.write(path, data)
        let probe = UsbReadFileProbe(base: FaultyUsbFileSystem(root: fixture.base))
        var write = UsbFileWrite(staged: fixture.url(path).path, destination: path, sha256: UsbExportAssembly.sha256(data),
                                 size: Int64(data.count), modificationDate: nil, disposition: .create, afterDatabases: true)
        #expect(try UsbSyncSelectionStage.readStagedSelection(write, stagingRoot: fixture.root, fileSystem: probe) == data)
        write.sha256 = UsbExportAssembly.sha256(Data("다른 원문".utf8))
        #expect(throws: UsbSyncSelectionFile.ParseError.changedDuringRead) {
            try UsbSyncSelectionStage.readStagedSelection(write, stagingRoot: fixture.root, fileSystem: probe)
        }
        #expect(probe.anchoredCalls == 2 && probe.urlReads == 0 && probe.urlHashes == 0)
    }

    @Test func 준비_루트_밖_파일은_안전읽기_입구를_부르기_전부터_거부한다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary), data = UsbSyncSelectionFileTests.xml
        outside.write(path, data)
        let probe = UsbReadFileProbe(base: FaultyUsbFileSystem(root: fixture.base))
        let write = UsbFileWrite(staged: outside.url(path).path, destination: path, sha256: UsbExportAssembly.sha256(data),
                                 size: Int64(data.count), modificationDate: nil, disposition: .create, afterDatabases: true)
        #expect(throws: UsbSyncSelectionFile.ParseError.unsafePath) {
            try UsbSyncSelectionStage.readStagedSelection(write, stagingRoot: fixture.root, fileSystem: probe)
        }
        #expect(probe.anchoredCalls == 0 && probe.urlReads == 0 && probe.urlHashes == 0)
    }
}
