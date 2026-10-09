import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 로컬 합성 라이브러리 → 계획 → 빌더 → 준비 폴더(DB 셋·분석 파일·아트워크)와 변경 묶음. 모든 값은 지어낸 것이다.
@Suite("USB 내보내기 조립")
struct UsbExportAssemblyTests {
    struct Staged {
        var build: UsbExportBuild
        var assembled: UsbExportAssembled
        var staging: URL
        var changes: UsbChangeSet { assembled.changes }
    }

    static func stagingFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-usbexport-staging-\(UUID().uuidString)")
    }

    /// 계획 → 빌더 → 조립(준비 폴더는 부르는 쪽이 지운다)
    static func stage(_ fixture: UsbExportFixture, ids: [String], playlists: [String] = [], formats: Set<UsbFormat> = UsbFormat.defaultSet,
                      existing: UsbExistingState? = nil, sameContent: @escaping @Sendable (String, String) -> Bool = { _, _ in false },
                      settingsFolder: URL? = nil, staging: URL = stagingFolder()) throws -> Staged {
        let db = try fixture.open()
        defer { db.close() }
        let request = try fixture.request(db, ids: ids, playlists: playlists, formats: formats, existing: existing, sameContent: sameContent)
        let build = try fixture.build(db, request)
        #expect(build.volumeBlocks.isEmpty)
        let assembled = try UsbExportAssembly.assembled(model: build.model, plan: build.plan, localDatabase: db, share: fixture.share,
                                                        staging: staging, formats: formats, session: UsbLayout.newSessionID(),
                                                        settingsFolder: settingsFolder)
        return Staged(build: build, assembled: assembled, staging: staging)
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func ascii(_ count: Int, _ letter: Character = "a") -> String { String(repeating: letter, count: count) }

    static func threeTracks() throws -> UsbExportFixture {
        let fixture = try UsbExportFixture()
        try fixture.addTrack(id: "101", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
        try fixture.addTrack(id: "102", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
        try fixture.addTrack(id: "103", artist: ("2", "다른 아티스트"))
        return fixture
    }

    // MARK: - 준비 파일

    @Test("DB 셋·곡마다 분석 파일 셋·아트워크 a·b·_m·음원 복사 목록을 준비한다")
    func stagesAllFiles() throws {
        let fixture = try Self.threeTracks()
        let staged = try Self.stage(fixture, ids: ["101", "102", "103"])
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        let changes = staged.changes

        #expect(changes.databases.map(\.destination).sorted() == [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb].sorted())
        for database in changes.databases {
            #expect(database.staged.hasPrefix(staged.staging.path + "/"))
            #expect(try Self.sha256(URL(filePath: database.staged)) == database.sha256)
        }
        #expect(!FileManager.default.fileExists(atPath: staged.staging.appending(path: UsbLayout.oneLibrary + "-wal").path))
        #expect(!FileManager.default.fileExists(atPath: staged.staging.appending(path: UsbLayout.oneLibrary + "-shm").path))

        let plan = staged.build.plan
        #expect(plan.tracks.count == 3)
        var expectedWrites: Set<String> = []
        for track in plan.tracks {
            let base = String(track.analysisPath.dropFirst().dropLast(4))
            expectedWrites.formUnion([base + ".DAT", base + ".EXT", base + ".2EX"])
            let paths = UsbArtworkLayout.paths(imageID: try #require(track.imageID), folder: try #require(track.artworkFolder))
            expectedWrites.formUnion([paths.a, paths.aMedium, paths.b, paths.bMedium])
        }
        #expect(Set(changes.writes.map(\.destination)) == expectedWrites)
        #expect(changes.writes.allSatisfy { $0.disposition == .create })
        for write in changes.writes {
            #expect(try Self.sha256(URL(filePath: write.staged)) == write.sha256)
            #expect(Int64(try Data(contentsOf: URL(filePath: write.staged)).count) == write.size)
        }
        // 분석 파일 PPTH는 USB 곡 경로
        for track in plan.tracks {
            let write = try #require(changes.writes.first { $0.destination == String(track.analysisPath.dropFirst()) })
            let ppth = try #require(UsbExportAssembly.ppthReader(try Data(contentsOf: URL(filePath: write.staged))))
            #expect(ppth == track.contentsPath)
        }
        // 아트워크는 원본 시각을 남긴다
        for write in changes.writes where write.destination.hasPrefix(UsbLayout.artworkRoot) { #expect(write.modificationDate != nil) }

        #expect(changes.copies.count == 3)
        for (copy, track) in zip(changes.copies, plan.tracks) {
            #expect(copy.destination == String(track.contentsPath.dropFirst()))
            #expect(copy.disposition == .create)
            let attributes = try FileManager.default.attributesOfItem(atPath: copy.source)
            #expect(copy.size == (attributes[.size] as? Int64 ?? Int64(attributes[.size] as? Int ?? -1)))
            #expect(copy.modificationDate == attributes[.modificationDate] as? Date)
        }
        #expect(changes.purpose == .export && changes.base == nil && changes.removals.isEmpty)
        #expect(changes.stagingDirectory == staged.staging.path)
        #expect(changes.idHighWater["content"] == 3)
        #expect(staged.assembled.pdbWritten != nil)
    }

    @Test("목표 지문: 만든 모든 파일(DB·분석·아트워크는 크기·해시, 음원은 크기)")
    func targetFingerprintComplete() throws {
        let fixture = try Self.threeTracks()
        let staged = try Self.stage(fixture, ids: ["101", "102", "103"])
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        let changes = staged.changes
        let all = Set(changes.copies.map(\.destination) + changes.writes.map(\.destination) + changes.databases.map(\.destination))
        #expect(Set(changes.target.mustExist.keys) == all)
        #expect(changes.target.mustNotExist.isEmpty)
        for write in changes.writes { #expect(changes.target.mustExist[write.destination] == UsbTreeStamp(size: write.size, sha256: write.sha256)) }
        for database in changes.databases {
            #expect(changes.target.mustExist[database.destination] == UsbTreeStamp(size: database.size, sha256: database.sha256))
        }
        for copy in changes.copies { #expect(changes.target.mustExist[copy.destination] == UsbTreeStamp(size: copy.size, sha256: nil)) }
    }

    @Test("형식 하나만: OneLibrary만이면 DB 하나·b 그림, Device Library만이면 pdb 둘·a 그림")
    func formatsOneLibraryOnly_DeviceOnly() throws {
        let fixture = try Self.threeTracks()
        let oneLibrary = try Self.stage(fixture, ids: ["101", "102"], formats: [.oneLibrary])
        defer { try? FileManager.default.removeItem(at: oneLibrary.staging) }
        #expect(oneLibrary.changes.databases.map(\.destination) == [UsbLayout.oneLibrary])
        #expect(oneLibrary.changes.formats == [.oneLibrary])
        #expect(oneLibrary.assembled.pdbWritten == nil)
        let olArtwork = oneLibrary.changes.writes.map(\.destination).filter { $0.hasPrefix(UsbLayout.artworkRoot) }
        #expect(olArtwork.count == 4 && olArtwork.allSatisfy { ($0 as NSString).lastPathComponent.hasPrefix("b") })
        #expect(!FileManager.default.fileExists(atPath: oneLibrary.staging.appending(path: UsbLayout.exportPdb).path))

        let device = try Self.stage(fixture, ids: ["101", "102"], formats: [.deviceLibrary])
        defer { try? FileManager.default.removeItem(at: device.staging) }
        #expect(device.changes.databases.map(\.destination).sorted() == [UsbLayout.exportPdb, UsbLayout.exportExtPdb].sorted())
        #expect(device.assembled.pdbWritten != nil)
        let dlArtwork = device.changes.writes.map(\.destination).filter { $0.hasPrefix(UsbLayout.artworkRoot) }
        #expect(dlArtwork.count == 4 && dlArtwork.allSatisfy { ($0 as NSString).lastPathComponent.hasPrefix("a") })
        #expect(!FileManager.default.fileExists(atPath: device.staging.appending(path: UsbLayout.oneLibrary).path))
    }

    // MARK: - 확인 안 된 규칙

    @Test("requiredRules = 계획 규칙 ∪ 분석 파일 규칙 ∪ pdb 작성기 규칙 ∪ 설정 파일")
    func requiredRulesUnion() throws {
        // ① 경로가 순수 ASCII 127자여도 pdbLongAscii는 없다: 트랙 행 문자열의 긴 ASCII는 rekordbox 7.2.x 경계 실험(2026-10-08)으로 확인한 모양
        let long = try UsbExportFixture()
        try long.addTrack(id: "101", artist: ("1", Self.ascii(40, "b")), album: ("30", Self.ascii(40, "c")), fileName: Self.ascii(31, "d") + ".mp3")
        let longStaged = try Self.stage(long, ids: ["101"])
        defer { try? FileManager.default.removeItem(at: longStaged.staging) }
        #expect(longStaged.build.plan.tracks[0].contentsPath.count == 127)
        #expect(!longStaged.changes.requiredRules.contains(.pdbLongAscii))

        let short = try UsbExportFixture()
        try short.addTrack(id: "101", artist: ("1", Self.ascii(40, "b")), album: ("30", Self.ascii(40, "c")), fileName: Self.ascii(30, "d") + ".mp3")
        let shortStaged = try Self.stage(short, ids: ["101"])
        defer { try? FileManager.default.removeItem(at: shortStaged.staging) }
        #expect(shortStaged.build.plan.tracks[0].contentsPath.count == 126)
        #expect(!shortStaged.changes.requiredRules.contains(.pdbLongAscii))

        // ② 경로는 짧고 장르 이름만 127자: 계획기는 모르고 pdb 작성기 규칙으로 들어간다
        let genre = try UsbExportFixture()
        let track = try genre.addTrack(id: "101", artist: ("1", "합성"))
        try genre.local.addGenre(id: "40", name: Self.ascii(127, "g"))
        try genre.local.setContent(track: track, ["GenreID": .text("40")])
        let genreStaged = try Self.stage(genre, ids: ["101"])
        defer { try? FileManager.default.removeItem(at: genreStaged.staging) }
        #expect(!genreStaged.build.plan.requiredRules.contains(.pdbLongAscii))
        #expect(genreStaged.changes.requiredRules.contains(.pdbLongAscii))
        // ⑤ OneLibrary만 쓰면 pdb 작성기 규칙은 없다
        let genreOneLibrary = try Self.stage(genre, ids: ["101"], formats: [.oneLibrary])
        defer { try? FileManager.default.removeItem(at: genreOneLibrary.staging) }
        #expect(!genreOneLibrary.changes.requiredRules.contains(.pdbLongAscii))

        // ③ 목록 이름 127자
        let playlist = try UsbExportFixture()
        try playlist.addTrack(id: "101", artist: ("1", "합성"))
        try playlist.local.addPlaylist(id: "900", name: Self.ascii(127, "p"), seq: 1, contentIDs: ["101"])
        let playlistStaged = try Self.stage(playlist, ids: [], playlists: ["900"])
        defer { try? FileManager.default.removeItem(at: playlistStaged.staging) }
        #expect(playlistStaged.changes.requiredRules.contains(.pdbLongAscii))
        // ⑤ ③은 계획 규칙이라 OneLibrary만이어도 남는다
        let playlistOneLibrary = try Self.stage(playlist, ids: [], playlists: ["900"], formats: [.oneLibrary])
        defer { try? FileManager.default.removeItem(at: playlistOneLibrary.staging) }
        #expect(playlistOneLibrary.changes.requiredRules.contains(.pdbLongAscii))

        // ④ 분석 파일(큐 모양) 규칙과 설정 파일
        let cue = try UsbExportFixture()
        let cueTrack = try cue.addTrack(id: "101", artist: ("1", "합성"))
        try cue.local.addCue(track: cueTrack, kind: 1, inMsec: 1_000, colorTableIndex: 3)
        let settings = FileManager.default.temporaryDirectory.appending(path: "djc-usbexport-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: settings) }
        var body2 = DeviceSettingFixture.syntheticBody(count: 40)
        body2[5] = 0
        body2[6] = 0
        try DeviceSettingFixture.write(DeviceSettingFixture.make(.mySetting), as: .mySetting, in: settings)
        try DeviceSettingFixture.write(DeviceSettingFixture.make(.mySetting2, body: body2), as: .mySetting2, in: settings)
        try DeviceSettingFixture.write(DeviceSettingFixture.make(.djmMySetting), as: .djmMySetting, in: settings)
        let cueStaged = try Self.stage(cue, ids: ["101"], settingsFolder: settings)
        defer { try? FileManager.default.removeItem(at: cueStaged.staging) }
        let cueRules = UsbCueRules.rules(fileType: 1, cues: [UsbCueTraits(kind: 1, colorTableIndex: 3, color: nil, inMsec: 1_000, outMsec: -1,
                                                                          activeLoop: 0, beatLoopSize: 0, inMpegFrame: 0)])
        #expect(!cueRules.isEmpty)
        #expect(cueStaged.changes.requiredRules.isSuperset(of: cueRules))
        #expect(cueStaged.changes.requiredRules.contains(.settingFiles))
        let settingWrites = cueStaged.changes.writes.map(\.destination).filter { !$0.contains("/USBANLZ/") && !$0.contains("/Artwork/") }
        #expect(Set(settingWrites) == ["PIONEER/MYSETTING.DAT", "PIONEER/MYSETTING2.DAT", "PIONEER/DJMMYSETTING.DAT"])
        // 설정 파일을 켜지 않으면 규칙도 파일도 없다
        #expect(!longStaged.changes.requiredRules.contains(.settingFiles))
    }

    @Test("실물 관문: 긴 ASCII 장르 이름이 든 묶음은 동의 전에만 막히고, 긴 ASCII는 CDJ 확인 항목으로만 알린다")
    func physicalGateSeesLongAscii() throws {
        let fixture = try UsbExportFixture()
        let track = try fixture.addTrack(id: "101", artist: ("1", "합성"))
        try fixture.local.addGenre(id: "40", name: Self.ascii(127, "g"))
        try fixture.local.setContent(track: track, ["GenreID": .text("40")])
        let staged = try Self.stage(fixture, ids: ["101"])
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        let volume = FakeUsbVolume.physicalFAT32()
        let blocks = UsbRuleCheck.blocks(required: staged.changes.requiredRules, volume: volume, gate: FakeUsbVolume.gate(), confirmName: nil)
        #expect(blocks.map(\.code) == ["physicalDisabled"])
        #expect(UsbRuleCheck.blocks(required: staged.changes.requiredRules, volume: volume, gate: FakeUsbVolume.gate(consented: true),
                                    confirmName: volume.name).isEmpty)
        #expect(UsbProvisionalRule.deviceCheckRules(staged.changes.requiredRules).contains(.pdbLongAscii))
    }

    // MARK: - 이미 Contents/가 있는 USB

    @Test("Contents/의 사용자 파일: 같은 내용은 재사용, 다른 내용은 번호를 붙이고 쓰기·되돌리기 뒤에도 그대로")
    func contentsExistingFilesReusedOrNumbered() throws {
        let usb = UsbChangeSetFixture()
        defer { usb.remove() }
        let same = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) })
        let other = Data((0..<2_500).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) })
        usb.write("Contents/Artist A/Album B/x.mp3", same)
        usb.write("Contents/Artist A/Album B/y.mp3", other)
        let before = usb.tree()

        let fixture = try UsbExportFixture()
        try fixture.addTrack(id: "101", artist: ("1", "artist a"), album: ("30", "Album B"), fileName: "x.mp3", audioData: same)
        try fixture.addTrack(id: "102", artist: ("2", "Artist A"), album: ("31", "Album B"), fileName: "Y.mp3",
                             audioData: Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 17) }))
        let existing = try #require(try UsbExportAssembly.existingContents(root: usb.root))
        let db = try fixture.open()
        let candidates = try UsbExportCandidates.load(database: db, share: fixture.share, contentIDs: ["101", "102"])
        db.close()
        let sources = Dictionary(uniqueKeysWithValues: candidates.map { ($0.localContentID, $0.sourcePath ?? "") })
        let root = usb.usbURL
        let staged = try Self.stage(fixture, ids: ["101", "102"], existing: existing) { id, relative in
            UsbExportCandidates.sameContent(sourcePath: sources[id] ?? "", usbFile: root.appending(path: relative))
        }
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        let tracks = staged.build.plan.tracks
        #expect(tracks[0].contentsPath == "/Contents/Artist A/Album B/x.mp3")
        #expect(tracks[0].audioDisposition == .reuse)
        #expect(tracks[0].rules.contains(.pathCollision))
        #expect(tracks[1].contentsPath == "/Contents/Artist A/Album B/Y (2).mp3")
        #expect(tracks[1].audioDisposition == .create)
        let reused = try #require(staged.changes.copies.first { $0.destination == "Contents/Artist A/Album B/x.mp3" })
        #expect(reused.disposition == .reuse)
        #expect(staged.changes.copies.filter { $0.disposition == .create }.map(\.destination) == ["Contents/Artist A/Album B/Y (2).mp3"])

        let report = try UsbWriter.write(staged.changes, root: usb.root, paths: usb.paths, guard: usb.writeGuard(), fileSystem: usb.fileSystem(),
                                         verifiers: UsbExportAssembly.verifiers(for: staged.assembled),
                                         inspectors: [UsbEmptyVolumeInspector()], ppthReader: UsbExportAssembly.ppthReader)
        #expect(report.outcome == .written)
        #expect(report.filesReused == 1)
        let journal = try #require(usb.journal())
        #expect(journal.entries.contains { $0.destination == "Contents/Artist A/Album B/x.mp3" && $0.disposition == .reused })
        let written = usb.tree()
        for (path, hash) in before { #expect(written[path] == hash) }

        let restored = try usb.restore()
        #expect(restored.outcome == .restored)
        #expect(usb.tree() == before)
    }

    @Test("검사기: 계획 뒤 NFD만 다른 이름이 생기면 destinationExists로 막고 USB는 그대로")
    func emptyVolumeInspectorBlocksCollision() throws {
        let usb = UsbChangeSetFixture()
        defer { usb.remove() }
        let fixture = try UsbExportFixture()
        try fixture.addTrack(id: "101", artist: ("1", "Artist"), album: ("30", "Album"), fileName: "Caf\u{E9}.mp3")
        let staged = try Self.stage(fixture, ids: ["101"])
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        let copy = try #require(staged.changes.copies.first)
        #expect(copy.destination == "Contents/Artist/Album/Caf\u{E9}.mp3")
        #expect(try UsbEmptyVolumeInspector().blocks(root: usb.root, changes: staged.changes).isEmpty)

        usb.write("Contents/Artist/Album/Cafe\u{301}.mp3", Data("사용자 파일".utf8))
        let before = usb.tree()
        #expect(try UsbEmptyVolumeInspector().blocks(root: usb.root, changes: staged.changes).map(\.code) == ["destinationExists"])
        #expect(throws: UsbError.self) {
            try UsbWriter.write(staged.changes, root: usb.root, paths: usb.paths, guard: usb.writeGuard(), fileSystem: usb.fileSystem(),
                                verifiers: UsbExportAssembly.verifiers(for: staged.assembled), inspectors: [UsbEmptyVolumeInspector()])
        }
        do {
            _ = try UsbWriter.write(staged.changes, root: usb.root, paths: usb.paths, guard: usb.writeGuard(), fileSystem: usb.fileSystem(),
                                    verifiers: [], inspectors: [UsbEmptyVolumeInspector()])
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.contains { $0.code == "destinationExists" })
        }
        #expect(usb.tree() == before)
    }

    @Test("검사기: PIONEER/ 바로 아래 이름이 있으면 막는다(. 으로 시작하는 macOS 항목은 뺀다)")
    func emptyVolumeInspectorBlocksLeftoverPioneer() throws {
        let usb = UsbChangeSetFixture()
        defer { usb.remove() }
        let fixture = try UsbExportFixture()
        try fixture.addTrack(id: "101", artist: ("1", "Artist"))
        let staged = try Self.stage(fixture, ids: ["101"])
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        usb.write("PIONEER/.Spotlight-V100/x", Data([1]))
        #expect(try UsbEmptyVolumeInspector().blocks(root: usb.root, changes: staged.changes).isEmpty)
        // 만들 대상과 겹치지 않는 이름이어도 남은 것이 있으면 막는다
        usb.write("PIONEER/Artwork/00001/a9.jpg", Data([1, 2]))
        #expect(try UsbEmptyVolumeInspector().blocks(root: usb.root, changes: staged.changes).map(\.code) == ["leftoverPioneer"])
    }

    // MARK: - 행 크기 막힘

    @Test("곡 정보가 빈 쪽에도 안 들어가면 그 곡만 막는다(OneLibrary만이면 막지 않음)")
    func trackRowTooLargeBlocked() throws {
        let fixture = try Self.threeTracks()
        let db0 = try fixture.local.open()
        try db0.run("UPDATE djmdContent SET Commnt = ? WHERE ID = '102'", [.text(Self.ascii(3_900, "n"))])
        db0.close()
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: ["101", "102", "103"]))
        let block = try #require(build.blocks.first { $0.code == "trackRowTooLarge" })
        #expect(block.scope == .track("102"))
        #expect(build.volumeBlocks.isEmpty)
        #expect(build.plan.tracks.map(\.localContentID) == ["101", "103"])
        #expect(build.model.library.tracks.count == 2)

        let oneLibrary = try fixture.build(db, try fixture.request(db, ids: ["101", "102", "103"], formats: [.oneLibrary]))
        #expect(!oneLibrary.blocks.contains { $0.code == "trackRowTooLarge" })
        #expect(oneLibrary.plan.tracks.count == 3)
    }

    @Test("긴 아티스트 이름은 먼 모양으로 쓰고, 빈 쪽에도 안 들어가는 이름만 그 이름을 쓰는 곡을 막는다")
    func longArtistNameBlocked() throws {
        let fixture = try UsbExportFixture()
        try fixture.addTrack(id: "101", artist: ("1", Self.ascii(4_100, "z")))
        try fixture.addTrack(id: "102", artist: ("2", Self.ascii(250, "y")))
        try fixture.addTrack(id: "103", artist: ("3", "짧은 이름"))
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: ["101", "102", "103"]))
        let block = try #require(build.blocks.first { $0.code == "nameTooLongForDeviceLibrary" })
        #expect(block.scope == .track("101") && block.rule == nil)
        #expect(build.plan.tracks.map(\.localContentID) == ["102", "103"])
        // rekordbox 7.2.x 경계 실험(2026-10-08): 'A' × 250은 먼 모양 아티스트 행이다
        let staging = Self.stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let (changes, _) = try UsbExportAssembly.assemble(model: build.model, plan: build.plan, localDatabase: db, share: fixture.share,
                                                     staging: staging, formats: UsbFormat.defaultSet, session: UsbLayout.newSessionID())
        #expect(!changes.requiredRules.contains(.pdbFarOffsetRows) && !changes.requiredRules.contains(.pdbLongAscii))
        let export = try Data(contentsOf: staging.appending(path: UsbLayout.exportPdb))
        let ext = try Data(contentsOf: staging.appending(path: UsbLayout.exportExtPdb))
        let (library, report) = try PdbReader.read(export: export, exportExt: ext)
        #expect(report.farShapeRows == ["artists": 1] && report.issues.isEmpty)
        #expect(Set(library.artists.map(\.name)) == [Self.ascii(250, "y"), "짧은 이름"])
    }

    @Test("My Tag 이름이 길면 볼륨 막힘(곡을 빼서 풀 수 없음)이고 작성기를 부르지 않는다")
    func longMyTagNameBlocked() throws {
        let fixture = try Self.threeTracks()
        try fixture.local.addMyTag(id: "5001", name: "합성 분류", seq: 1, attribute: 1)
        try fixture.local.addMyTag(id: "5002", name: Self.ascii(220, "t"), seq: 1, attribute: 0, parentID: "5001")
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: ["101", "102"]))
        let block = try #require(build.volumeBlocks.first)
        #expect(block.code == "myTagNameTooLongForDeviceLibrary" && block.rule == .pdbFarOffsetRows && block.scope == .volume)
        // 조립도 같은 막힘으로 멈춘다(작성기의 일반 문구 대신)
        let staging = Self.stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            _ = try UsbExportAssembly.assemble(model: build.model, plan: build.plan, localDatabase: db, share: fixture.share, staging: staging,
                                               formats: UsbFormat.defaultSet, session: UsbLayout.newSessionID())
            Issue.record("막히지 않음")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["myTagNameTooLongForDeviceLibrary"])
        }
        #expect(!FileManager.default.fileExists(atPath: staging.appending(path: UsbLayout.exportPdb).path))
        #expect(!FileManager.default.fileExists(atPath: staging.appending(path: UsbLayout.oneLibrary).path))

        let oneLibrary = try fixture.build(db, try fixture.request(db, ids: ["101", "102"], formats: [.oneLibrary]))
        #expect(oneLibrary.volumeBlocks.isEmpty)
    }

    /// Device Library 작성기가 곡 하나 때문에 내보내기 전체를 거부하는 경우
    enum WriterRefusal: String, CaseIterable, Sendable {
        case isrcNotASCII, fileTypeMismatch, discNoOutOfRange, releaseYearOutOfRange

        var code: String {
            switch self {
            case .isrcNotASCII: "isrcNotASCIIForDeviceLibrary"
            case .fileTypeMismatch: "fileTypeMismatchForDeviceLibrary"
            case .discNoOutOfRange, .releaseYearOutOfRange: "valueOutOfRangeForDeviceLibrary"
            }
        }

        /// 곡 102를 이 경우로 만든 합성 라이브러리(101·103은 정상)
        func fixture() throws -> UsbExportFixture {
            let fixture = try UsbExportFixture()
            try fixture.addTrack(id: "101", artist: ("1", "합성 아티스트"))
            try fixture.addTrack(id: "102", artist: ("1", "합성 아티스트"), fileName: self == .fileTypeMismatch ? "track102.mp4" : nil)
            try fixture.addTrack(id: "103", artist: ("2", "다른 아티스트"))
            let (column, value): (String, CipherDatabase.Value) = switch self {
            case .isrcNotASCII: ("ISRC", .text("ＪＰ－ＡＢＣ"))
            case .fileTypeMismatch: ("FileType", .int(4))
            case .discNoOutOfRange: ("DiscNo", .int(70_000))
            case .releaseYearOutOfRange: ("ReleaseYear", .int(-1))
            }
            let db = try fixture.local.open()
            defer { db.close() }
            try db.run("UPDATE djmdContent SET \(column) = ? WHERE ID = '102'", [value])
            return fixture
        }
    }

    @Test("Device Library 작성기가 거부할 곡(ISRC·확장자·칸 범위)은 계획 단계에서 그 곡만 로컬 ID로 막고 나머지는 내보낸다",
          arguments: WriterRefusal.allCases)
    func deviceLibraryWriterRefusalBlocksTrack(_ refusal: WriterRefusal) throws {
        let fixture = try refusal.fixture()
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: ["101", "102", "103"]))
        let blocks = build.blocks.filter { $0.code == refusal.code }
        #expect(blocks.map(\.scope) == [.track("102")])
        #expect(!(blocks.first?.message.isEmpty ?? true))
        #expect(build.volumeBlocks.isEmpty)
        #expect(build.plan.tracks.map(\.localContentID) == ["101", "103"])
        // 나머지 두 곡은 작성기까지 막힘 없이 간다
        let staging = Self.stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let assembled = try UsbExportAssembly.assembled(model: build.model, plan: build.plan, localDatabase: db, share: fixture.share,
                                                        staging: staging, formats: UsbFormat.defaultSet, session: UsbLayout.newSessionID())
        #expect(assembled.pdbWritten?.tracks.count == 2)

        // OneLibrary만 쓰면 막지 않는다
        let oneLibrary = try fixture.build(db, try fixture.request(db, ids: ["101", "102", "103"], formats: [.oneLibrary]))
        #expect(!oneLibrary.blocks.contains { $0.code == refusal.code })
        #expect(oneLibrary.plan.tracks.count == 3)
    }

    @Test("칸 범위 막힘 문구는 칸 이름을 적는다")
    func valueOutOfRangeNamesField() throws {
        let fixture = try WriterRefusal.discNoOutOfRange.fixture()
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: ["101", "102", "103"]))
        let block = try #require(build.blocks.first { $0.code == "valueOutOfRangeForDeviceLibrary" })
        #expect(block.message.contains("discNo"))
    }

    @Test("막힌 곡을 빼고 다시 계획하면 content·image ID가 빈틈없이 다시 매겨진다")
    func blockedTrackRemovedAndIDsRenumbered() throws {
        let fixture = try Self.threeTracks()
        try fixture.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102", "103"])
        let db0 = try fixture.local.open()
        try db0.run("UPDATE djmdContent SET Commnt = ? WHERE ID = '102'", [.text(Self.ascii(3_900, "n"))])
        db0.close()
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: [], playlists: ["900"]))
        #expect(build.plan.tracks.map(\.contentID) == [1, 2])
        #expect(build.plan.tracks.map(\.imageID) == [1, 2])
        #expect(build.model.library.tracks.map(\.id) == [1, 2])
        #expect(build.model.library.playlists.first?.entries[.deviceLibrary] == [1, 2])
        #expect(build.blocks.map(\.code) == ["trackRowTooLarge"])
    }

    // MARK: - 경고

    @Test("로컬 PSSI가 이미 마스크된 모양이면 경고 analysisPSSIMasked")
    func pssiMaskedWarning() throws {
        let fixture = try UsbExportFixture()
        try fixture.addTrack(id: "101", artist: ("1", "합성"), pssiMood: 9)
        try fixture.addTrack(id: "102", artist: ("1", "합성"))
        let staged = try Self.stage(fixture, ids: ["101", "102"])
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        let warnings = staged.assembled.warnings.filter { $0.code == "analysisPSSIMasked" }
        #expect(warnings.map(\.scope) == [.track("101")])
        #expect(!(warnings.first?.message.isEmpty ?? true))
    }

    @Test("Kind 4 큐는 빼고 경고 kind4CueDropped를 곡마다 한 번만 낸다")
    func kind4Warning() throws {
        let fixture = try UsbExportFixture()
        let track = try fixture.addTrack(id: "101", artist: ("1", "합성"))
        try fixture.local.addCue(track: track, kind: 4, inMsec: 2_000)
        try fixture.local.addCue(track: track, kind: 1, inMsec: 1_000)
        let staged = try Self.stage(fixture, ids: ["101"])
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        #expect(staged.assembled.warnings.filter { $0.code == "kind4CueDropped" }.map(\.scope) == [.track("101")])
        #expect(!staged.assembled.warnings.contains { $0.code == "cueKindDropped" })
    }

    // MARK: - 그 밖

    @Test("취소하면 준비를 멈춘다")
    func cancelledDuringStaging() throws {
        let fixture = try Self.threeTracks()
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: ["101", "102", "103"]))
        let staging = Self.stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        #expect(throws: UsbError.self) {
            _ = try UsbExportAssembly.assembled(model: build.model, plan: build.plan, localDatabase: db, share: fixture.share, staging: staging,
                                                formats: UsbFormat.defaultSet, session: UsbLayout.newSessionID(), isCancelled: { true })
        }
    }

    /// 준비 중 사라지는 로컬 파일
    enum VanishingFile: String, CaseIterable, Sendable { case audio, artwork, analysis }

    @Test("준비 중 로컬 파일이 사라지면 오류에 파일 이름·경로 대신 로컬 ID만 적는다", arguments: VanishingFile.allCases)
    func vanishedLocalFileErrorNamesOnlyContentID(_ vanishing: VanishingFile) throws {
        let fixture = try UsbExportFixture()
        try fixture.addTrack(id: "101", artist: ("1", "합성"), fileName: "숨길 아티스트 - 숨길 제목.mp3")
        let db = try fixture.open()
        defer { db.close() }
        let build = try fixture.build(db, try fixture.request(db, ids: ["101"]))
        let source = try #require(build.model.files.compactMap { file -> String? in
            switch (vanishing, file.kind) {
            case let (.audio, .audio(source)), let (.artwork, .artwork(source)): source
            case let (.analysis, .analysis(localDAT, _, _, _)): localDAT
            default: nil
            }
        }.first)
        try FileManager.default.removeItem(atPath: source)
        let staging = Self.stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            _ = try UsbExportAssembly.assembled(model: build.model, plan: build.plan, localDatabase: db, share: fixture.share,
                                                staging: staging, formats: UsbFormat.defaultSet, session: UsbLayout.newSessionID())
            Issue.record("던지지 않음")
        } catch let UsbError.readFailed(detail) {
            #expect(detail.contains("content 101"))
            #expect(!detail.contains("숨길") && !detail.contains((source as NSString).lastPathComponent) && !detail.contains("/"))
        } catch {
            Issue.record("readFailed가 아님: \(type(of: error))")
        }
    }

    @Test("재사용 음원 해시: 열지 못하면 로컬 ID만 적는다")
    func reusedAudioHashErrorNamesOnlyContentID() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "djc-missing-\(UUID().uuidString)/숨길 제목.mp3").path
        do {
            _ = try UsbExportAssembly.fileHashes(missing, content: "101")
            Issue.record("던지지 않음")
        } catch let UsbError.readFailed(detail) {
            #expect(detail == "open audio content 101")
        }
    }

    @Test("Contents/가 없으면 기존 상태 없음, 있으면 폴더·파일 철자와 충돌 키")
    func existingContentsState() throws {
        let usb = UsbTreeFixture()
        defer { usb.remove() }
        #expect(try UsbExportAssembly.existingContents(root: usb.root) == nil)
        usb.write("CONTENTS/Artist/Song.MP3", Data([1]))
        let state = try #require(try UsbExportAssembly.existingContents(root: usb.root))
        #expect(!state.hasLibrary)
        #expect(state.folderSpelling["contents"] == "CONTENTS")
        #expect(state.folderSpelling["contents/artist/song.mp3"] == "CONTENTS/Artist/Song.MP3")
        #expect(state.usedCollisionKeys["contents/artist"] == ["song.mp3"])
        #expect(state.usedCollisionKeys[""] == ["contents"])
    }
}
