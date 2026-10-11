import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 쓴 뒤 검증기(OneLibrary·Device Library·불변식). 합성 로컬 곡을 합성 USB 폴더에 내보낸 뒤 하나씩 깨뜨려 잡는지 본다.
@Suite("USB 형식 검증기")
struct UsbFormatVerifierTests {
    final class Written {
        let usb = UsbChangeSetFixture()
        let staged: UsbExportAssemblyTests.Staged
        let scratch = FileManager.default.temporaryDirectory.appending(path: "djc-usbverify-\(UUID().uuidString)")

        /// before: 쓰기 전에 USB에 미리 둘 파일(상대 경로 → 바이트)
        init(before: [String: Data] = [:]) throws {
            for (path, data) in before { usb.write(path, data) }
            let fixture = try UsbExportFixture()
            try fixture.addTrack(id: "101", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
            try fixture.addTrack(id: "102", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
            try fixture.addTrack(id: "103", artist: ("2", "다른 아티스트"), artwork: false)
            try fixture.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "103"])
            try fixture.local.addMyTag(id: "5001", name: "합성 분류", seq: 1, attribute: 1)
            try fixture.local.addMyTag(id: "5002", name: "합성 태그", seq: 1, attribute: 0, parentID: "5001")
            staged = try UsbExportAssemblyTests.stage(fixture, ids: ["102"], playlists: ["900"])
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let report = try UsbWriter.write(staged.changes, root: usb.root, paths: usb.paths, guard: usb.writeGuard(),
                                             fileSystem: usb.fileSystem(), verifiers: [UsbFingerprintVerifier()],
                                             ppthReader: UsbExportAssembly.ppthReader)
            #expect(report.outcome == .written)
        }

        deinit {
            usb.remove()
            try? FileManager.default.removeItem(at: staged.staging)
            try? FileManager.default.removeItem(at: scratch)
        }

        var oneLibrary: OneLibraryVerifier { OneLibraryVerifier(expected: staged.assembled.library) }
        var pdb: PdbVerifier { PdbVerifier(expected: staged.assembled.pdbWritten!) }

        func problems(_ verifier: any UsbWriteVerifier) throws -> [String] {
            try verifier.verify(root: usb.root, changes: staged.changes, fileSystem: usb.fileSystem(), scratch: scratch)
        }

        func track(_ index: Int) -> UsbTrack { staged.assembled.library.tracks[index] }

        /// USB 상대 경로(앞 "/" 없음)
        func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }

        /// 모델로 DB 셋을 다시 만들어 USB의 것과 바꾼다(형식 작성기로)
        func replaceDatabases(with library: UsbLibrary) throws {
            let folder = scratch.appending(path: "replace-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let database = folder.appending(path: "exportLibrary.db")
            try OneLibraryWriter.create(library, at: database)
            usb.write(UsbLayout.oneLibrary, try Data(contentsOf: database))
            let files = try PdbWriter.files(library, mode: .fresh)
            usb.write(UsbLayout.exportPdb, files.export)
            usb.write(UsbLayout.exportExtPdb, files.exportExt)
        }
    }

    @Test("정상 합성 USB는 모든 검증기를 통과한다")
    func normalUsbPasses() throws {
        let written = try Written()
        #expect(try written.problems(UsbFingerprintVerifier()) == [])
        #expect(try written.problems(written.oneLibrary) == [])
        #expect(try written.problems(written.pdb) == [])
        #expect(try written.problems(UsbInvariantVerifier()) == [])
        #expect(UsbExportAssembly.verifiers(for: written.staged.assembled).count == 4)
    }

    /// rekordbox 7.2.x 경계 실험(2026-10-08): 긴 이름의 아티스트·앨범은 먼 모양으로 쓴다. My Tag 먼 모양은 쓰지 않으므로 잡는다
    @Test("작성기가 쓴 먼 모양 아티스트·앨범 행은 문제가 아니고, 그 밖의 표의 먼 모양 행만 잡는다")
    func farShapeRowsOnlyOutsideWrittenTables() throws {
        var model = PdbWriterTests.model()
        model.artists[0].name = String(repeating: "가", count: 116)
        model.albums[0].name = String(repeating: "A", count: 250)
        let files = try PdbWriter.files(model, mode: .fresh)
        let report = try PdbReader.inspect(files.export)
        #expect(report.farShapeRows == ["artists": 1, "albums": 1])
        #expect(!PdbVerifier.fileProblems("export", report, data: files.export).contains { $0.hasPrefix("far_shape_rows") })
        var tags = try PdbReader.inspect(files.exportExt)
        tags.farShapeRows = ["exportExt.tags": 1]
        #expect(PdbVerifier.fileProblems("exportExt", tags, data: files.exportExt).contains("far_shape_rows exportExt 1"))
    }

    @Test("분석 파일 PPTH가 DB 경로와 다르면 불변식 검증이 잡는다")
    func ppthMismatchCaught() throws {
        let written = try Written()
        let dat = written.relative(written.track(0).analysisDataPath)
        var file = try AnlzFile(data: try #require(written.usb.data(dat)))
        let replaced = file.replace("PPTH", with: AnlzPathTag.encode("/Contents/다른/곡.mp3"))
        #expect(replaced)
        written.usb.write(dat, file.serialized())
        #expect(try written.problems(UsbInvariantVerifier()).contains { $0.hasPrefix("ppth") })
    }

    @Test("DB가 가리키는 파일이 없으면 잡는다")
    func missingFileCaught() throws {
        let written = try Written()
        let image = try #require(written.staged.assembled.library.images.first)
        try FileManager.default.removeItem(at: written.usb.usb(written.relative(try #require(image.oneLibraryPath))))
        #expect(try written.problems(UsbInvariantVerifier()).contains { $0.hasPrefix("missing") })
        let ext = written.relative(String(written.track(1).analysisDataPath.dropLast(4)) + ".EXT")
        try FileManager.default.removeItem(at: written.usb.usb(ext))
        #expect(try written.problems(UsbInvariantVerifier()).filter { $0.hasPrefix("missing") }.count == 2)
    }

    @Test("음원 크기가 fileSize와 다르면 잡는다")
    func audioSizeCaught() throws {
        let written = try Written()
        let audio = written.relative(written.track(0).path)
        written.usb.write(audio, try #require(written.usb.data(audio)) + Data([0]))
        // 두 형식에 같은 곡이 있어도 한 번만 센다(한 형식만 있던 USB에 다른 형식을 더해도 새 문제가 아니게)
        #expect(try written.problems(UsbInvariantVerifier()).filter { $0.hasPrefix("audioSize") } == ["audioSize content \(written.track(0).id)"])
        // 이 쓰기가 로컬 FileSize로 적은 곡(분석 뒤 바뀐 음원, rekordbox와 같게)은 크기 비교를 뺀다
        let exempt = UsbInvariantVerifier(audioSizeFromDatabase: [written.track(0).id])
        #expect(try written.problems(exempt).allSatisfy { !$0.hasPrefix("audioSize") })
    }

    @Test("곡 수 칸이 어긋나면 OneLibrary·불변식 검증이 잡는다")
    func trackCountCaught() throws {
        let written = try Written()
        var library = written.staged.assembled.library
        library.property.numberOfContents += 1
        try written.replaceDatabases(with: library)
        #expect(try written.problems(UsbInvariantVerifier()).contains { $0.hasPrefix("trackCount") })
        #expect(try !written.problems(written.oneLibrary).isEmpty)
    }

    @Test("OneLibrary 사이드카가 남으면 열지 않고 잡는다")
    func sidecarCaught() throws {
        let written = try Written()
        written.usb.write(UsbLayout.oneLibrary + "-wal", Data(count: 32))
        let before = written.usb.data(UsbLayout.oneLibrary)
        #expect(try written.problems(written.oneLibrary).contains { $0.hasPrefix("sidecar") })
        #expect(written.usb.data(UsbLayout.oneLibrary) == before)
        #expect(written.usb.exists(UsbLayout.oneLibrary + "-wal"))
    }

    @Test("pdb 머리 0x10이 5가 아니면 잡는다")
    func pdbFlagCaught() throws {
        let written = try Written()
        var bytes = try #require(written.usb.data(UsbLayout.exportPdb))
        bytes[0x10] = 4
        written.usb.write(UsbLayout.exportPdb, bytes)
        #expect(try written.problems(written.pdb).contains { $0.hasPrefix("flag10") })
    }

    @Test("pdb 칸이 기대와 다르면 잡는다")
    func pdbFieldCaught() throws {
        let written = try Written()
        var library = written.staged.assembled.library
        library.tracks[0].bpmx100 += 100
        let files = try PdbWriter.files(library, mode: .fresh)
        written.usb.write(UsbLayout.exportPdb, files.export)
        #expect(try written.problems(written.pdb).contains { $0.contains("bpmx100") })
    }

    @Test("._ 파일·.djc-part 임시 파일이 남으면 잡는다")
    func leftoversCaught() throws {
        let written = try Written()
        written.usb.write("PIONEER/rekordbox/._export.pdb", Data(count: 4096))
        #expect(try written.problems(UsbInvariantVerifier()).contains { $0.hasPrefix("appledouble") })
        let other = try Written()
        other.usb.write("Contents/.djc-part-abc-1", Data([1]))
        #expect(try other.problems(UsbInvariantVerifier()).contains { $0.hasPrefix("temp") })
    }

    @Test("쓰기 전부터 있던 ._ 파일(루트 ._.Trashes, 사용자 음원 옆)은 잡지 않는다")
    func preexistingAppleDoublePasses() throws {
        let before = ["._.Trashes": Data(count: 4096), "Contents/User/Album/x.mp3": Data([7, 7, 7]),
                      "Contents/User/Album/._x.mp3": Data(count: 4096)]
        let written = try Written(before: before)
        let preexisting = try UsbInvariantVerifier.appleDoubles(on: written.usb.root)
        #expect(preexisting == ["._.Trashes", "Contents/User/Album/._x.mp3"])
        #expect(try written.problems(UsbInvariantVerifier(preexistingAppleDoubles: preexisting)) == [])
        // 미리 있던 것을 모르면 전부 센다
        #expect(try written.problems(UsbInvariantVerifier()).contains("appledouble 2"))
        #expect(UsbExportAssembly.verifiers(for: written.staged.assembled, preexistingAppleDoubles: preexisting).count == 4)
    }

    @Test("쓰기 뒤 새로 생긴 ._ 파일(쓴 파일 옆, PIONEER 아래)은 미리 있던 것과 따로 잡는다")
    func newAppleDoubleCaughtBesidePreexisting() throws {
        let written = try Written(before: ["._.Trashes": Data(count: 4096)])
        let preexisting: Set<String> = ["._.Trashes"]
        let audio = written.relative(written.track(0).path)
        let parent = (audio as NSString).deletingLastPathComponent, name = (audio as NSString).lastPathComponent
        written.usb.write(parent + "/._" + name, Data(count: 4096))
        #expect(try written.problems(UsbInvariantVerifier(preexistingAppleDoubles: preexisting)).contains("appledouble 1"))
        written.usb.write("PIONEER/._rekordbox", Data(count: 4096))
        #expect(try written.problems(UsbInvariantVerifier(preexistingAppleDoubles: preexisting)).contains("appledouble 2"))
    }

    @Test("fileName이 경로 끝 성분과 다르면 잡는다")
    func fileNameCaught() throws {
        let written = try Written()
        var library = written.staged.assembled.library
        library.tracks[0].fileName = "다른 이름.mp3"
        try written.replaceDatabases(with: library)
        #expect(try written.problems(UsbInvariantVerifier()).contains { $0.hasPrefix("fileName") })
    }

    @Test("두 DB의 분석 경로가 다르면 잡는다")
    func analysisPathMismatchCaught() throws {
        let written = try Written()
        var library = written.staged.assembled.library
        library.tracks[0].analysisDataPath = written.track(1).analysisDataPath
        let files = try PdbWriter.files(library, mode: .fresh)
        written.usb.write(UsbLayout.exportPdb, files.export)
        written.usb.write(UsbLayout.exportExtPdb, files.exportExt)
        let problems = try written.problems(UsbInvariantVerifier())
        #expect(problems.contains { $0.hasPrefix("analysisPath") })
        #expect(problems.contains { $0.hasPrefix("slotDuplicate") })
    }
}
