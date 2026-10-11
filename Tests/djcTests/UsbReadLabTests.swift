import DJCAdapters
import DJCApplication
import RekordboxFixtures
@testable import djc
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit
import Testing

@Suite("USB 읽기 실험 명령")
struct UsbReadLabTests {
    func run(_ arguments: [String]) throws -> (Int32, String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-labhome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["lab"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["DJC_HOME": home.path, "DJC_LANG": "ko"]) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func oneLibrarySQLReadsTemporaryCopyAndBlocksCredentials() throws {
        let marker = "synthetic-private-value"
        let fixture = try OneLibraryFixture(statements: OneLibrarySchema.ddl() + ["CREATE TABLE uuidIDMap(value varchar)"])
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        try fixture.add(track: OneLibraryTrackSpec(id: 2))
        try fixture.execute("INSERT INTO uuidIDMap VALUES ('\(marker)')")
        fixture.close()
        let before = try Data(contentsOf: fixture.url)

        let (status, output) = try run(["onelib-sql", fixture.url.path, "SELECT count(*) FROM content"])
        #expect(status == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        let (_, integrity) = try run(["onelib-sql", fixture.url.path, "PRAGMA cipher_integrity_check"])
        #expect(integrity.isEmpty)
        // key 표의 칸 보기는 키 PRAGMA가 아니다
        let (_, keyTable) = try run(["onelib-sql", fixture.url.path, "PRAGMA table_info(key)"])
        #expect(keyTable.split(separator: "\n").count == 2)
        for sql in ["SELECT * FROM uuidIDMap", "SELECT * FROM agentRegistry", "PRAGMA rekey = 'x'", "PRAGMA key='x'", " pragma hexkey = \"x\""] {
            let (_, refused) = try run(["onelib-sql", fixture.url.path, sql])
            #expect(!refused.contains(marker))
            #expect(refused.contains("허용하지 않는 쿼리"))
        }
        // 원본은 그대로
        #expect(try Data(contentsOf: fixture.url) == before)
    }

    @Test func oneLibrarySQLRefusesPathOutsideScratch() throws {
        let (status, output) = try run(["onelib-sql", "/etc/hosts", "SELECT 1"])
        #expect(status != 0)
        #expect(output.contains("outsideScratch"))
    }

    @Test func usbDiffOfSameTreeIsZero() throws {
        let fixture = try OneLibraryFixture()
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        try fixture.add(playlist: 10, name: "시험 목록", entries: [1])
        fixture.close()
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write("PIONEER/rekordbox/exportLibrary.db", try Data(contentsOf: fixture.url))
        let before = tree.tree()
        let (status, output) = try run(["usb-diff", "--onelibrary", tree.base.path, tree.base.path])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.last == "차이 0")
        #expect(lines.contains("content 1/1행 일치"))
        #expect(lines.contains("playlist 1/1행 일치"))
        #expect(!output.contains("시험"))
        #expect(tree.tree() == before)

        // 기본 모드는 있는 형식 모두(여기서는 OneLibrary만)
        let (bothStatus, both) = try run(["usb-diff", tree.base.path, tree.base.path])
        #expect(bothStatus == 0)
        #expect(both.split(separator: "\n").last == "차이 0")
        let (usageStatus, usage) = try run(["usb-diff", tree.base.path])
        #expect(usageStatus == 0)
        #expect(usage.contains("사용법"))
    }

    @Test("usb-migrate-check: 옮긴 USB의 OneLibrary는 pdb 변환과 차이 0, 한 형식만 있으면 안내만 한다")
    func migrateCheckOfMigratedUsbIsZero() throws {
        let usb = UsbChangeSetFixture()
        defer { usb.remove() }
        var fixture = UsbLibraryFixture()
        fixture.formats = [.deviceLibrary]
        fixture.myTagLinks = []
        try fixture.write(to: UsbTreeFixture(base: usb.usbURL))
        let (_, only) = try run(["usb-migrate-check", usb.usbURL.path])
        #expect(only.contains("두 형식"))
        let session = UsbMigrateSession(root: usb.usbURL, guard: usb.writeGuard(), paths: usb.paths, engine: .live(fileSystem: usb.fileSystem()),
                                        device: .testing(), copies: usb.home.appending(path: "usb-snapshots"))
        _ = try session.write(options: UsbWriteOptions(), progress: { _ in }, isCancelled: { false })
        let before = usb.tree()
        let (status, output) = try run(["usb-migrate-check", usb.usbURL.path])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.contains("형식 불일치 변환 0") && lines.contains("content 3/3행 일치") && lines.last == "차이 0")
        #expect(!output.contains("시험") && !output.contains("Contents/"))
        #expect(usb.tree() == before)
    }

    /// 합성 Device Library(곡 2·목록 1·태그 1). 모든 값은 지어낸 것이다.
    static func pdbFiles(brokenGenres: Bool = false) -> (export: Data, exportExt: Data) {
        var export = PdbBuilder(kind: .export)
        for id in [1, 2] { export.add(.tracks, PdbBuilder.trackRow(PdbTrackSpec(id: id))) }
        var dead = PdbBuilder.trackRow(PdbTrackSpec(id: 9))
        dead.live = false
        export.add(.tracks, dead)
        export.add(.genres, PdbBuilder.idNameRow(1, "시험 장르"))
        export.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 10, name: "시험 목록"))
        export.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: 1, trackID: 2, playlistID: 10))
        export.add(.history19, PdbBuilder.propertyRow(count: 2, date: "2026-01-03"))
        var ext = PdbBuilder(kind: .exportExt)
        ext.add(.tags, PdbBuilder.tagRow(id: 7, name: "시험 분류", position: 0, isCategory: true))
        ext.add(.myTagProperty, PdbBuilder.myTagPropertyRow(masterDBID: 123_456))
        var built = export.build()
        if brokenGenres {
            let genres = PdbTableType.genres.rawValue
            built.setU32(page: built.dataPages[genres]![0], offset: 0x04, 999)
        }
        return (built.data, ext.build().data)
    }

    @Test func pdbDumpPrintsCountsWithoutValues() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        let files = Self.pdbFiles()
        tree.write(UsbLayout.exportPdb, files.export)
        tree.write(UsbLayout.exportExtPdb, files.exportExt)
        let before = tree.tree()

        let (status, output) = try run(["pdb-dump", tree.url(UsbLayout.exportPdb).path])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.last == "issues 0")
        #expect(lines.contains("far_shape_rows 0"))
        #expect(lines.contains { $0.contains("tables 20") && $0.contains("flag10 5") })
        #expect(lines.contains { $0.hasPrefix("table 0 tracks") && $0.contains("2/3") })
        #expect(lines.contains { $0.hasPrefix("table 19 history19") && $0.contains("1/1") })
        #expect(!output.contains("시험") && !output.contains("test1"))

        let (_, ext) = try run(["pdb-dump", tree.url(UsbLayout.exportExtPdb).path])
        #expect(ext.split(separator: "\n").contains { $0.hasPrefix("table 3 exportExt.tags") && $0.contains("1/1") })
        #expect(ext.split(separator: "\n").last == "issues 0")

        let (_, pages) = try run(["pdb-dump", tree.url(UsbLayout.exportPdb).path, "--pages"])
        #expect(pages.contains("flags 0x64") && pages.contains("flags 0x34"))

        let (_, rows) = try run(["pdb-dump", tree.url(UsbLayout.exportPdb).path, "--rows", "tracks"])
        let rowLines = rows.split(separator: "\n").filter { $0.contains("slot ") }
        #expect(rowLines.count == 3)
        #expect(rowLines.contains { $0.contains("dead") } && rowLines.contains { $0.contains("shift 0x0020") })
        #expect(rowLines.contains { $0.contains("utf16LE") && $0.contains("shortASCII") })
        #expect(!rows.contains("시험") && !rows.contains("test1"))
        // 원본은 그대로
        #expect(tree.tree() == before)
    }

    @Test func pdbDumpRefusesPathOutsideScratch() throws {
        let (status, output) = try run(["pdb-dump", "/etc/hosts"])
        #expect(status != 0)
        #expect(output.contains("outsideScratch"))
    }

    @Test func usbDiffDeviceLibraryAndBoth() throws {
        let fixture = try OneLibraryFixture()
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        try fixture.add(track: OneLibraryTrackSpec(id: 2))
        fixture.close()
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        let files = Self.pdbFiles()
        tree.write(UsbLayout.exportPdb, files.export)
        tree.write(UsbLayout.exportExtPdb, files.exportExt)
        tree.write(UsbLayout.oneLibrary, try Data(contentsOf: fixture.url))
        let before = tree.tree()

        let (status, output) = try run(["usb-diff", "--device-library", tree.base.path, tree.base.path])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.last == "차이 0")
        #expect(lines.contains("content 2/2행 일치"))
        #expect(lines.contains("deadIDs 1/1행 일치"))
        #expect(!output.contains("시험"))

        let (bothStatus, both) = try run(["usb-diff", tree.base.path, tree.base.path])
        #expect(bothStatus == 0)
        let bothLines = both.split(separator: "\n").map(String.init)
        #expect(bothLines.last == "차이 0")
        #expect(bothLines.contains("content 2/2행 일치"))
        #expect(bothLines.contains { $0.hasPrefix("형식 불일치 A") })
        #expect(tree.tree() == before)

        // Device Library가 없는 쪽은 알려 준다
        let empty = UsbTreeFixture()
        defer { empty.remove() }
        empty.mkdir("PIONEER/rekordbox")
        let (_, missing) = try run(["usb-diff", "--device-library", empty.base.path, tree.base.path])
        #expect(missing.contains("export.pdb"))
    }

    @Test func usbDiffComparesFilesAndAnalysisTags() throws {
        let a = UsbTreeFixture()
        defer { a.remove() }
        try UsbLibraryFixture().write(to: a)
        let b = UsbTreeFixture()
        defer { b.remove() }
        try FileManager.default.removeItem(at: b.base)
        try FileManager.default.copyItem(at: a.base, to: b.base)
        let before = a.tree()

        let (status, same) = try run(["usb-diff", a.base.path, b.base.path, "--files", "--anlz"])
        #expect(status == 0)
        let lines = same.split(separator: "\n").map(String.init)
        #expect(lines.last == "차이 0")
        #expect(lines.contains("파일 27/27 같음, 한쪽에만 0/0, 내용 다름 0"))
        #expect(lines.contains("ANLZ 9/9 바이트 같음"))

        b.write(String(UsbLibraryFixture.analysisPath(2).dropFirst()), UsbLibraryFixture.dat(path: UsbLibraryFixture.trackPath(2), hotCueA: 9_000))
        let (_, changed) = try run(["usb-diff", a.base.path, b.base.path, "--anlz"])
        let changedLines = changed.split(separator: "\n").map(String.init)
        #expect(changedLines.contains("ANLZ 8/9 바이트 같음, 다른 태그: PCOB×1"))
        #expect(changedLines.contains("ANLZ 곡 2 DAT: PCOB"))
        #expect(changedLines.last == "차이 1")
        #expect(!changed.contains("test2") && !changed.contains("P000"))
        // --files·--anlz가 없으면 예전처럼 모델만
        let (_, model) = try run(["usb-diff", a.base.path, b.base.path])
        #expect(!model.contains("ANLZ") && model.split(separator: "\n").last == "차이 0")
        #expect(a.tree() == before)
    }

    @Test("--anlz에서 읽지 못한 파일이 있으면 차이 0을 보고하지 않는다")
    func usbDiffUnreadableAnalysisIsNotZero() throws {
        let a = UsbTreeFixture(), b = UsbTreeFixture()
        defer { a.remove(); b.remove() }
        try UsbLibraryFixture().write(to: a)
        try FileManager.default.removeItem(at: b.base)
        try FileManager.default.copyItem(at: a.base, to: b.base)
        b.write("PIONEER/USBANLZ/P123/0ABCDEF0/ANLZ0000.DAT", "broken ANLZ")
        let beforeA = a.tree(), beforeB = b.tree()

        let (status, output) = try run(["usb-diff", a.base.path, b.base.path, "--anlz"])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.contains("ANLZ 9/10 바이트 같음, PPTH 못 읽음 0/1"))
        #expect(lines.contains("ANLZ B: 비교 불가(PPTH 못 읽음)"))
        #expect(lines.last == "차이 1")
        #expect(!output.contains("0ABCDEF0") && !output.contains("broken ANLZ"))
        #expect(a.tree() == beforeA && b.tree() == beforeB)
    }

    @Test func anlzRelocateChangesCopyOnly() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try UsbLibraryFixture().write(to: tree)
        let (status, output) = try run(["usb-anlz-relocate", tree.base.path, "--track", "1", "--folder", "P123/0ABCDEF0", "--db-only"])
        #expect(status == 0)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.first == "모드 dbOnly")
        #expect(lines.contains("곡 1: export.pdb 분석 경로 → P123/0ABCDEF0/ANLZ0000.DAT"))
        #expect(lines.contains("곡 1: exportLibrary.db 분석 경로 → P123/0ABCDEF0/ANLZ0000.DAT"))
        #expect(FileManager.default.fileExists(atPath: tree.url("PIONEER/USBANLZ/P123/0ABCDEF0/ANLZ0000.EXT").path))

        let (decoyStatus, decoy) = try run(["usb-anlz-relocate", tree.base.path, "--track", "2", "--decoy-slot0"])
        #expect(decoyStatus == 0 && decoy.hasPrefix("모드 decoySlot0"))
        // 사용법·거부
        let (_, usage) = try run(["usb-anlz-relocate", tree.base.path, "--track", "3"])
        #expect(usage.contains("사용법"))
        let (_, twoModes) = try run(["usb-anlz-relocate", tree.base.path, "--track", "3", "--folder", "P123/0ABCDEF1", "--db-only", "--files-only"])
        #expect(twoModes.contains("사용법"))
        // 격리 HOME은 임시 폴더일 수 있어 고정 비임시 경로로 검사한다
        let (outsideStatus, outside) = try run(["usb-anlz-relocate", "/", "--track", "1", "--folder", "P123/0ABCDEF0"])
        #expect(outsideStatus != 0 && outside.contains("outsideScratch"))
    }
}
