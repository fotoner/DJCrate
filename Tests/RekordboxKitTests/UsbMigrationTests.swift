import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// Device Library만 있는 USB → 같은 USB에 OneLibrary 더하기(#46): 모델 변환과 계획(준비 폴더까지, USB에는 쓰지 않는다).
/// USB는 임시 폴더의 합성 트리다(곡 1·2·3, 목록 10, My Tag 분류·태그, 그림 1·2·3). 모든 값은 지어낸 것이다.
@Suite("Device Library → OneLibrary 옮기기")
struct UsbMigrationTests {
    final class Env {
        let usb = UsbChangeSetFixture()
        let fixture: UsbLibraryFixture
        var tree: UsbTreeFixture { UsbTreeFixture(base: usb.usbURL) }

        init(_ configure: (inout UsbLibraryFixture) -> Void = { _ in }) throws {
            var fixture = UsbLibraryFixture()
            fixture.formats = [.deviceLibrary]
            fixture.myTagLinks = []
            configure(&fixture)
            self.fixture = fixture
            try fixture.write(to: UsbTreeFixture(base: usb.usbURL))
        }

        deinit { usb.remove() }

        func snapshot() throws -> UsbSnapshot {
            try UsbSnapshot.take(root: usb.root, into: usb.folder.appending(path: "copy-\(UUID().uuidString)"))
        }

        /// pdb에서 읽은 모델
        func deviceLibrary() throws -> UsbLibrary {
            try #require(try PdbReader.read(snapshot: snapshot())).0
        }

        func plan(session: String = "mig1") throws -> UsbMigrationResult {
            try UsbMigration.plan(snapshot: snapshot(), root: usb.root, fileSystem: usb.fileSystem(),
                                  staging: usb.paths.staging.appending(path: session), session: session)
        }

        /// 곡의 USB `.2EX` 자리
        func twoEx(_ id: Int) -> String { String(fixture.analysisPath(id).dropFirst().dropLast(4)) + ".2EX" }
    }

    static func codes(_ result: UsbMigrationResult) -> [String] { result.blocks.map(\.code) }

    // MARK: - 모델 변환

    @Test("pdb 모델에 OneLibrary 몫을 더하면 Device Library 투영은 그대로이고 두 형식이 맞는다")
    func modelKeepsDeviceLibraryAndMatches() throws {
        let env = try Env { $0.playlists = [UsbLibraryFixture.Playlist(id: 10, name: "시험 목록", entries: [3, 1])] }
        let deviceLibrary = try env.deviceLibrary()
        let model = UsbMigration.model(from: deviceLibrary, vocal: [2])
        #expect(model.formats == UsbFormat.defaultSet)
        #expect(model.projected(to: .deviceLibrary) == deviceLibrary.projected(to: .deviceLibrary))
        let (_, mismatches) = UsbLibrary.merge(oneLibrary: model.projected(to: .oneLibrary), deviceLibrary: deviceLibrary)
        #expect(mismatches.isEmpty)
        #expect(model.tracks.allSatisfy { $0.presentIn == UsbFormat.defaultSet })
        #expect(model.playlists.map { $0.entries[.oneLibrary] } == [[3, 1]])
        #expect(model.playlists.map { $0.sortOrder[.oneLibrary] } == model.playlists.map { $0.sortOrder[.deviceLibrary] })
    }

    @Test("OneLibrary에만 있는 칸은 골든에서 본 값으로 채운다")
    func oneLibraryOnlyFields() throws {
        let env = try Env()
        let model = UsbMigration.model(from: try env.deviceLibrary(), vocal: [2])
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기): 보컬 PVDI가 있는 곡 0x1C0700, 없는 곡 0x0C0700, analysedBits 105
        #expect(model.tracks.map(\.contentLink) == [0x0C_0700, 0x1C_0700, 0x0C_0700])
        #expect(model.tracks.allSatisfy { $0.analysedBits == 105 && $0.lyricistArtistID == 0 && $0.hasModified == 0 })
        #expect(model.tracks.allSatisfy { $0.titleForSearch == nil && $0.kuvoDeliveryComment.isEmpty })
        #expect(model.tracks.allSatisfy { $0.deviceFields[.oneLibrary] == UsbTrackDeviceFields(rating: $0.rating, playCount: $0.djPlayCount, hasModified: 0) })
        #expect(model.images.map(\.oneLibraryPath) == (1...3).map { "/PIONEER/Artwork/00001/b\($0).jpg" })
        // pdb 표 19 날짜(내보낸 날) = OneLibrary createdDate
        #expect(model.property.createdDate == "2026-01-03")
        #expect(model.property.dbVersion == "1000" && model.property.deviceName.isEmpty && model.property.backgroundColorType == 0)
        #expect(model.property.numberOfContents == 3 && model.property.myTagMasterDBID == 123_456)
    }

    @Test("새로 만든 exportLibrary.db를 다시 읽으면 변환 모델의 OneLibrary 투영과 같고 pdb와 맞는다")
    func createdDatabaseReadsBack() throws {
        let env = try Env()
        let deviceLibrary = try env.deviceLibrary()
        let model = UsbMigration.model(from: deviceLibrary, vocal: [])
        let target = env.usb.folder.appending(path: "out/exportLibrary.db")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OneLibraryWriter.create(model, at: target)
        let reread = try OneLibraryReader.read(copyAt: target)
        #expect(UsbLibraryDiff.compare(reread, model.projected(to: .oneLibrary), options: .init(formats: [.oneLibrary])).differences.isEmpty)
        #expect(UsbLibrary.merge(oneLibrary: reread, deviceLibrary: deviceLibrary).1.isEmpty)
    }

    // MARK: - 계획

    @Test("계획은 exportLibrary.db와 b 아트워크만 만들고 원래 pdb는 그대로여야 한다고 적는다")
    func planStagesDatabaseAndArtwork() throws {
        let env = try Env()
        let before = env.usb.tree()
        let result = try env.plan()
        #expect(result.blocks.isEmpty)
        let changes = try #require(result.changes)
        #expect(changes.purpose == .edit && changes.label == "migrate" && changes.formats == [.oneLibrary])
        #expect(changes.databases.map(\.destination) == [UsbLayout.oneLibrary] && changes.databases.map(\.format) == [.oneLibrary])
        #expect(changes.copies.isEmpty && changes.removals.isEmpty)
        let names = (1...3).flatMap { ["PIONEER/Artwork/00001/b\($0).jpg", "PIONEER/Artwork/00001/b\($0)_m.jpg"] }
        #expect(Set(changes.writes.map(\.destination)) == Set(names))
        #expect(changes.writes.allSatisfy { $0.disposition == .create })
        // b 그림은 같은 폴더 a 그림의 바이트 사본이다
        for write in changes.writes {
            let a = write.destination.replacingOccurrences(of: "/b", with: "/a")
            #expect(try Data(contentsOf: URL(filePath: write.staged)) == env.usb.data(a))
        }
        // 원래 pdb 두 파일은 지금 해시 그대로여야 한다(G 단계가 확인)
        for path in [UsbLayout.exportPdb, UsbLayout.exportExtPdb] {
            #expect(changes.target.mustExist[path]?.sha256 == before[path])
        }
        #expect(try #require(changes.base).sameContent(as: try UsbWriter.databaseFingerprint(root: env.usb.root, fileSystem: env.usb.fileSystem())))
        #expect(changes.requiredRules.contains(.deviceLibraryMigration) && changes.requiredRules.contains(.playlistSiblingBase))
        // 준비한 DB는 변환 모델 그대로다
        let staged = URL(filePath: try #require(changes.databases.first).staged)
        #expect(try OneLibraryWriter.verify(staged, expected: try #require(result.library)).isEmpty)
        #expect(env.usb.tree() == before)
    }

    @Test("USB .2EX의 PVDI에 본문이 있는 곡만 보컬 비트를 받는다")
    func vocalBitFromUsbTwoEx() throws {
        let env = try Env()
        let path = UsbLibraryFixture.trackPath(2)
        env.tree.write(env.twoEx(2), AnlzBuilder.local2EX(path: path, pvdi: true))
        // 빈 PVDI(24바이트)는 보컬이 아니다
        var empty = try AnlzFile(data: AnlzBuilder.local2EX(path: UsbLibraryFixture.trackPath(3), pvdi: true))
        let replaced = empty.replace("PVDI", with: AnlzMasks.emptyPVDI)
        #expect(replaced)
        env.tree.write(env.twoEx(3), empty.serialized())
        let library = try #require(try env.plan().library)
        #expect(library.tracks.map(\.contentLink) == [0x0C_0700, 0x1C_0700, 0x0C_0700])
    }

    @Test("곡 정보·목록·My Tag 연결·그림 없는 곡이 있으면 그 확인 안 된 규칙을 싣는다")
    func rulesFollowContent() throws {
        let plain = try #require(try Env { $0.playlists = [] }.plan().changes)
        #expect(plain.requiredRules == [.deviceLibraryMigration])
        let env = try Env {
            $0.myTagLinks = [(8, 1)]
            $0.writeArtwork = false
        }
        let rules = try #require(try env.plan().changes).requiredRules
        #expect(rules.isSuperset(of: [.deviceLibraryMigration, .myTagLinks, .artworkMissing, .playlistSiblingBase]))
    }

    // MARK: - 막힘

    @Test("OneLibrary가 이미 있거나 사이드카만 남아 있으면 옮기지 않는다")
    func oneLibraryPresentBlocks() throws {
        let both = try Env { $0.formats = UsbFormat.defaultSet }
        #expect(Self.codes(try both.plan()) == ["oneLibraryExists"])
        let orphan = try Env()
        orphan.tree.write(UsbLayout.oneLibrary + "-wal", Data([1, 2, 3]))
        let result = try orphan.plan()
        #expect(Self.codes(result) == ["oneLibraryExists"] && result.changes == nil)
    }

    @Test("Device Library가 없거나 곡이 없으면 옮기지 않는다")
    func nothingToMigrate() throws {
        let empty = try Env { $0.formats = [] }
        #expect(Self.codes(try empty.plan()) == ["noDeviceLibrary"])
        let noTracks = try Env {
            $0.trackIDs = []
            $0.playlists = []
        }
        #expect(Self.codes(try noTracks.plan()) == ["noTracks"])
    }

    @Test("정상으로 닫지 않은 pdb·기기 기록·모르는 표 행은 옮기지 않는다")
    func deviceLibraryStateBlocks() throws {
        #expect(Self.codes(try Env { $0.pdbFlag10 = 4 }.plan()) == ["pdbNotClosed"])
        let history = try Env { $0.pdbHistoryEntries = [1] }.plan()
        #expect(Self.codes(history) == ["carriedDeviceRows"] && history.blocks.first?.rule == .carriedDeviceRows)
        #expect(Self.codes(try Env { $0.pdbUnknownRows = 1 }.plan()) == ["carriedDeviceRows"])
    }

    @Test("a 그림이 없거나 b 자리에 다른 파일이 있으면 옮기지 않고, 같은 b 그림은 다시 쓰지 않는다")
    func artworkChecks() throws {
        let missing = try Env()
        try FileManager.default.removeItem(at: missing.usb.usb("PIONEER/Artwork/00001/a2.jpg"))
        #expect(Self.codes(try missing.plan()) == ["artworkMissingOnUsb"])

        let conflict = try Env()
        conflict.tree.write("PIONEER/Artwork/00001/b2.jpg", Data([9, 9, 9]))
        #expect(Self.codes(try conflict.plan()) == ["artworkExists"])

        let same = try Env()
        same.tree.write("PIONEER/Artwork/00001/b2.jpg", UsbLibraryFixture.artwork(2, medium: false))
        let changes = try #require(try same.plan().changes)
        #expect(changes.writes.first { $0.destination == "PIONEER/Artwork/00001/b2.jpg" }?.disposition == .reuse)
    }

    @Test("USB 파일이 pdb와 맞지 않아 OneLibrary에 새 문제가 생기면 옮기지 않는다")
    func newInvariantProblemBlocks() throws {
        let env = try Env()
        // 분석 파일의 PPTH가 곡 경로와 다르다(pdb에는 이미 있던 문제, OneLibrary에는 새 문제)
        env.tree.write(String(env.fixture.analysisPath(2).dropFirst()), UsbLibraryFixture.dat(path: "/Contents/합성 다른 곡.mp3", hotCueA: nil))
        let result = try env.plan()
        #expect(Self.codes(result) == ["libraryFilesMismatch"] && result.changes == nil)
        // 음원 크기가 파일 크기 칸과 다른 것은 rekordbox가 만든 USB에도 흔하다(분석 뒤 바뀐 음원, 2026-10-08 빈 USB 실험 §5).
        // OneLibrary는 pdb 칸을 그대로 옮기므로 같은 문제로 보고 막지 않는다
        let resized = try Env()
        resized.tree.write(String(UsbLibraryFixture.trackPath(2).dropFirst()), Data(repeating: 1, count: 3))
        let kept = try resized.plan()
        #expect(kept.blocks.isEmpty && kept.preexistingProblems.contains("audioSize content 2"))
        // 음원이 아예 없는 것은 두 형식에 같은 문제라 막지 않는다
        let missing = try Env()
        try FileManager.default.removeItem(at: missing.usb.usb(String(UsbLibraryFixture.trackPath(3).dropFirst())))
        let planned = try missing.plan()
        #expect(planned.blocks.isEmpty && planned.preexistingProblems.contains("missing audio content 3"))
    }

    /// 곡 1 하나뿐인 합성 export.pdb(설정을 바꿔 막힘을 만든다)
    static func export(configure: (inout PdbBuilder) -> Void) -> Data {
        var export = PdbBuilder(kind: .export)
        var track = PdbTrackSpec(id: 1)
        track[.analyzePath] = UsbLibraryFixture.analysisPath(1)
        export.add(.tracks, PdbBuilder.trackRow(track))
        configure(&export)
        return export.build().data
    }

    @Test("읽지 못하는 pdb·읽지 못한 행·모르는 버전은 옮기지 않는다")
    func unreadableDeviceLibraryBlocks() throws {
        let corrupt = try Env()
        corrupt.tree.write(UsbLayout.exportPdb, Data(repeating: 0, count: 4096))
        #expect(Self.codes(try corrupt.plan()) == ["libraryCorrupt"])

        // 없는 목록을 가리키는 산 항목(구조 문제): 읽기는 그 행을 버리므로 그대로 옮기면 행이 조용히 빠진다
        let orphan = try Env()
        orphan.tree.write(UsbLayout.exportPdb, Self.export {
            $0.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: 1, trackID: 1, playlistID: 99))
            $0.add(.history19, PdbBuilder.propertyRow(count: 1, date: "2026-01-03"))
        })
        #expect(Self.codes(try orphan.plan()) == ["pdbUnreadableRows"])

        // 아티스트·앨범 먼 모양 행은 칸을 모두 읽으므로 막지 않는다(rekordbox 7.2.x 경계 실험, 2026-10-08)
        let far = try Env()
        far.tree.write(UsbLayout.exportPdb, Self.export {
            $0.add(.artists, PdbBuilder.artistRow(5, String(repeating: "가", count: 116), far: true))
            $0.add(.albums, PdbBuilder.albumRow(6, String(repeating: "가", count: 116), artistID: 5, far: true))
            $0.add(.history19, PdbBuilder.propertyRow(count: 1, date: "2026-01-03"))
        })
        #expect(!Self.codes(try far.plan()).contains("pdbUnreadableRows"))

        let version = try Env()
        version.tree.write(UsbLayout.exportPdb, Self.export { $0.add(.history19, PdbBuilder.propertyRow(count: 1, date: "2026-01-03", version: "2000")) })
        #expect(Self.codes(try version.plan()) == ["pdbVersionUnsupported"])
    }

    @Test("exportExt.pdb가 없으면 My Tag 마스터 DB ID를 모르는 규칙을 싣고, 분석 파일이 없는 곡은 보컬이 아니다")
    func missingExportExtAndAnalysis() throws {
        let env = try Env { $0.writeAnalysis = false }
        try FileManager.default.removeItem(at: env.usb.usb(UsbLayout.exportExtPdb))
        let result = try env.plan()
        let changes = try #require(result.changes)
        #expect(changes.requiredRules.contains(.myTagMasterDBID))
        #expect(result.library?.tracks.allSatisfy { $0.contentLink == 0x0C_0700 } == true)
        #expect(result.preexistingProblems.contains("missing DAT content 1"))
    }

    @Test("쓰기 직전 확인: OneLibrary가 생겼거나 pdb가 열린 채이거나 있던 파일을 바꾸는 묶음은 막는다")
    func inspectorBlocks() throws {
        let env = try Env()
        let changes = try #require(try env.plan().changes)
        let inspector = UsbMigrationInspector()
        #expect(try inspector.blocks(root: env.usb.root, changes: changes).isEmpty)

        var overwriting = changes
        overwriting.writes[0].disposition = .overwrite
        #expect(try inspector.blocks(root: env.usb.root, changes: overwriting).map(\.code) == ["migrateChangesFiles"])
        var pdb = changes
        pdb.databases[0].format = .deviceLibrary
        #expect(try inspector.blocks(root: env.usb.root, changes: pdb).map(\.code) == ["oneLibraryExists"])

        env.tree.write(UsbLayout.oneLibrary + "-journal", Data([1]))
        #expect(try inspector.blocks(root: env.usb.root, changes: changes).map(\.code) == ["oneLibraryExists"])

        let open = try Env { $0.pdbFlag10 = 4 }
        #expect(try inspector.blocks(root: open.usb.root, changes: changes).map(\.code) == ["pdbNotClosed"])
    }

    @Test("a 경로 모양: 아트워크 폴더·다섯 자리 번호·a{id}.jpg만 b 경로가 된다")
    func artworkPathShape() {
        #expect(UsbMigration.oneLibraryArtworkPath("/PIONEER/Artwork/00002/a7.jpg", imageID: 7) == "/PIONEER/Artwork/00002/b7.jpg")
        #expect(UsbMigration.oneLibraryArtworkPath("/pioneer/artwork/00002/A7.JPG", imageID: 7) == "/pioneer/artwork/00002/b7.jpg")
        for path in ["/PIONEER/Artwork/00002/a8.jpg", "/PIONEER/Artwork/2/a7.jpg", "/PIONEER/Other/00002/a7.jpg", "PIONEER/Artwork/00002/a7.jpg",
                     "/PIONEER/Artwork/00002/../a7.jpg", "/PIONEER/Artwork/0000x/a7.jpg"] {
            #expect(UsbMigration.oneLibraryArtworkPath(path, imageID: 7) == nil, "\(path)")
        }
    }
}
