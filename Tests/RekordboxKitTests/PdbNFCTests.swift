import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// #233: CDJ-2000NXS는 풀어 쓴 한글(NFD 자모)을 "~"로 보여, Device Library의 사람이 읽는 문자열은 NFC로 쓴다.
/// 파일 경로 칸은 USB 파일의 실제 철자라 그대로 둔다. 모든 이름·경로는 지어낸 합성 값이다
@Suite("Device Library NFC 철자")
struct PdbNFCTests {
    /// 풀어 쓴 한글(NFD)
    static func nfd(_ text: String) -> String { text.decomposedStringWithCanonicalMapping }

    static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    static func isNFC(_ text: String) -> Bool { scalars(text) == scalars(text.precomposedStringWithCanonicalMapping) }

    /// 이름·제목·경로가 모두 NFD인 합성 모델
    static func nfdModel() -> UsbLibrary {
        var model = PdbWriterTests.model()
        model.playlists[0].name = nfd("합성 한글 목록")
        model.artists[0].name = nfd("합성 아티스트")
        model.albums[0].name = nfd("합성 앨범")
        model.genres[0].name = nfd("합성 장르")
        model.keys[0].name = nfd("합성 키")
        model.labels = [UsbNamedRow(id: 1, name: nfd("합성 레이블"))]
        model.menuItems[0].name = nfd("합성 메뉴")
        model.myTags = [UsbMyTag(id: 7, parentID: 0, sequenceNo: 0, name: nfd("합성 분류"), isCategory: true),
                        UsbMyTag(id: 8, parentID: 7, sequenceNo: 0, name: nfd("합성 태그"), isCategory: false)]
        for index in model.tracks.indices {
            model.tracks[index].labelID = 1
            model.tracks[index].title = nfd("합성 곡 \(index)")
            model.tracks[index].comment = nfd("합성 코멘트")
            model.tracks[index].subtitle = nfd("합성 믹스")
            model.tracks[index].lyricist = nfd("합성 작사")
            model.tracks[index].path = nfd("/Contents/합성 아티스트/합성 앨범/곡\(index).mp3")
            model.tracks[index].fileName = nfd("곡\(index).mp3")
            model.tracks[index].analysisDataPath = nfd("/PIONEER/USBANLZ/P000/한글\(index)/ANLZ0000.DAT")
        }
        model.images[0].pdbPath = nfd("/PIONEER/Artwork/00001/한글.jpg")
        return model
    }

    static func string(_ row: Data, _ offset: Int) throws -> String {
        try PdbStringDecoder.decode(row, at: offset).value
    }

    @Test("이름·제목은 NFC로, 파일 경로·파일 이름·분석 경로·아트워크 경로는 원래 철자로 쓴다")
    func writerNormalizesTextButNotPaths() throws {
        let model = Self.nfdModel()
        let (files, export, ext) = try PdbWriterTests.write(model)
        let track = try #require(try PdbWriterTests.rows(export, 0).first)
        let original = model.tracks[0]
        for (index, value) in [1: original.lyricist, 12: original.subtitle, 16: original.comment, 17: original.title] {
            let written = try Self.string(track, PdbWriterTests.u16(track, 0x5E + 2 * index))
            #expect(Self.isNFC(written) && Self.scalars(written) != Self.scalars(value), "문자열 \(index)")
            #expect(written == value, "문자열 \(index)")
        }
        for (index, value) in [14: original.analysisDataPath, 19: original.fileName, 20: original.path] {
            let written = try Self.string(track, PdbWriterTests.u16(track, 0x5E + 2 * index))
            #expect(Self.scalars(written) == Self.scalars(value), "문자열 \(index)")
        }
        let artwork = try PdbWriterTests.rows(export, 13)
        #expect(Self.scalars(try Self.string(artwork[0], 4)) == Self.scalars(model.images[0].pdbPath ?? ""))
        let playlist = try #require(try PdbWriterTests.rows(export, 7).first)
        #expect(Self.scalars(try Self.string(playlist, 0x14)) == Self.scalars("합성 한글 목록".precomposedStringWithCanonicalMapping))

        // 다시 읽은 모델: 사람이 읽는 문자열은 모두 NFC, 경로는 그대로
        let (reread, report) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        #expect(report.issues.isEmpty)
        let names = reread.artists.map(\.name) + reread.albums.map(\.name) + reread.genres.map(\.name) + reread.keys.map(\.name)
            + reread.labels.map(\.name) + reread.playlists.map(\.name) + reread.myTags.map(\.name) + reread.menuItems.map(\.name)
            + reread.tracks.flatMap { [$0.title, $0.comment, $0.subtitle, $0.lyricist] }
        #expect(names.allSatisfy(Self.isNFC))
        #expect(names.contains { $0.unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 } })
        #expect(zip(reread.tracks, model.tracks).allSatisfy { Self.scalars($0.path) == Self.scalars($1.path) })
        #expect(zip(reread.tracks, model.tracks).allSatisfy { Self.scalars($0.fileName) == Self.scalars($1.fileName) })
        #expect(zip(reread.tracks, model.tracks).allSatisfy { Self.scalars($0.analysisDataPath) == Self.scalars($1.analysisDataPath) })
        // written은 USB에 쓴 철자(NFC)이고, 다시 읽은 모델과 칸 단위로 같다
        #expect(Self.isNFC(files.written.playlists[0].name) && Self.isNFC(files.written.tracks[0].title))
        #expect(UsbLibraryDiff.compare(reread, files.written, options: .init(formats: [.deviceLibrary])).differences.isEmpty)
        #expect(reread == files.written)
        _ = ext
    }

    @Test("pdbStringNFC는 쓴 문자열이 NFC로 바뀔 때만 붙고, CDJ 확인 항목으로 알린다")
    func ruleOnlyWhenNormalizationChangesText() throws {
        // NFC 이름만이면 붙지 않는다
        #expect(!(try PdbWriter.files(PdbWriterTests.model(), mode: .fresh)).rules.contains(.pdbStringNFC))
        // 경로·파일 이름만 NFD면 붙지 않는다(경로는 바꾸지 않는다)
        var pathsOnly = PdbWriterTests.model()
        pathsOnly.tracks[0].path = Self.nfd("/Contents/합성/한글.mp3")
        pathsOnly.tracks[0].fileName = Self.nfd("한글.mp3")
        pathsOnly.tracks[0].analysisDataPath = Self.nfd("/PIONEER/USBANLZ/P000/한글/ANLZ0000.DAT")
        pathsOnly.images[0].pdbPath = Self.nfd("/PIONEER/Artwork/00001/한글.jpg")
        let paths = try PdbWriter.files(pathsOnly, mode: .fresh)
        #expect(!paths.rules.contains(.pdbStringNFC) && paths.rulesByTrack.isEmpty)
        // 목록 이름 하나만 NFD면 전체 규칙에만(곡 규칙은 없다)
        var playlistOnly = PdbWriterTests.model()
        playlistOnly.playlists[0].name = Self.nfd("합성 한글 목록")
        let playlist = try PdbWriter.files(playlistOnly, mode: .fresh)
        #expect(playlist.rules == [.pdbStringNFC] && playlist.rulesByTrack.isEmpty)
        // 곡 제목이 NFD면 그 곡에도
        var titleOnly = PdbWriterTests.model()
        titleOnly.tracks[1].title = Self.nfd("합성 제목")
        let title = try PdbWriter.files(titleOnly, mode: .fresh)
        #expect(title.rules == [.pdbStringNFC] && title.rulesByTrack == [2: [.pdbStringNFC]])
        // 막지 않고 알리는 규칙
        #expect(UsbProvisionalRule.pdbStringNFC.needsDeviceCheck && !UsbProvisionalRule.pdbStringNFC.alwaysBlocks)
        #expect(UsbProvisionalRule.deviceCheckRules([.pdbStringNFC, .pdbRegeneratedEdit]) == [.pdbStringNFC])
        #expect(UsbProvisionalRule(rawValue: "pdbStringNFC") == .pdbStringNFC)
        // NFD가 남았는지
        #expect(PdbWriter.needsNFC(playlistOnly) && PdbWriter.needsNFC(titleOnly))
        #expect(!PdbWriter.needsNFC(PdbWriterTests.model()) && !PdbWriter.needsNFC(pathsOnly))
    }

    @Test("NFC가 짧아 행 크기·아티스트 모양을 NFC 철자로 정한다")
    func rowSizeUsesNFC() {
        let name = Self.nfd(String(repeating: "가", count: 60))
        // NFD 120 단위(먼 모양) → NFC 60 단위(가까운 모양)
        #expect(PdbRowSize.artist(name: name) == PdbRowSize.artist(name: String(repeating: "가", count: 60)))
        #expect(PdbRowSize.tag(name: name) == PdbRowSize.tag(name: String(repeating: "가", count: 60)))
    }

    @Test("rekordbox가 NFD로 쓴 pdb도 왕복 검사를 통과한다(먼 모양이 가까운 모양이 되는 아티스트·모양이 바뀌는 글자 포함)")
    func roundTripAcceptsNFDFile() throws {
        let farNFD = Self.nfd(String(repeating: "가", count: 60))   // NFD 이름 끝 256(먼 모양), NFC 136(가까운 모양)
        var tracks = PdbRoundTripTests.sampleTracks()
        tracks[1][.title] = Self.nfd("합성 한글 제목")
        tracks[2][.title] = "\u{212A}"   // KELVIN SIGN: NFC는 ASCII "K"(UTF-16 → 짧은 ASCII)
        let (export, ext) = PdbRoundTripTests.sample { builder in
            builder.tables[PdbTableType.tracks.rawValue] = tracks.map(PdbBuilder.trackRow)
            builder.add(.artists, PdbBuilder.artistRow(19, farNFD, far: true))
            builder.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 72, name: Self.nfd("합성 한글 목록"), sortOrder: 3))
            builder.add(.genres, PdbBuilder.idNameRow(33, Self.nfd("합성 장르")))
        }
        let (model, report) = try PdbReader.read(export: export, exportExt: ext)
        #expect(report.issues.isEmpty && report.farShapeRows["artists"] == 1)
        #expect(model.trackRowExtras[3]?.stringKinds[17] == .utf16LE)
        #expect(PdbWriter.needsNFC(model))
        #expect(try PdbRoundTrip.check(export: export, exportExt: ext) == [])
        // 다시 쓴 파일은 NFC이고 먼 모양 아티스트 행이 없다
        let files = try PdbWriter.files(model, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                           previousExtSequence: report.extHeader?.sequence ?? 0))
        let (reread, rereadReport) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        #expect(rereadReport.farShapeRows["artists"] == nil)
        #expect(!PdbWriter.needsNFC(reread))
        #expect(reread.trackRowExtras[3]?.stringKinds[17] == .shortASCII)
        #expect(files.rules.contains(.pdbStringNFC))
        // 다시 쓴 파일(NFC)의 왕복은 바이트까지 그대로다
        #expect(try PdbRoundTrip.check(export: files.export, exportExt: files.exportExt) == [])
    }

    @Test("원래 철자로도 작성기와 다른 문자열 모양은 NFC로 옮기지 않고 문제로 남긴다")
    func roundTripStillDetectsShapeMismatch() throws {
        var tracks = PdbRoundTripTests.sampleTracks()
        // NFD 한글 제목을 rekordbox가 쓰지 않는 모양(0x40)으로 가리킬 수는 없으니, ASCII 제목을 0x40로 쓴 행으로 본다(기존 검사 유지)
        tracks[2][.title] = "Title Three"
        var row = PdbBuilder.trackRow(tracks[2])
        let title = Array(tracks[2][.title].utf8)
        let offset = row.bytes.count, length = 4 + title.count
        row.bytes.append(contentsOf: [0x40, UInt8(length & 0xFF), UInt8(length >> 8), 0x00] + title)
        row.bytes[0x5E + 2 * 17] = UInt8(offset & 0xFF)
        row.bytes[0x5E + 2 * 17 + 1] = UInt8(offset >> 8)
        let (export, ext) = PdbRoundTripTests.sample { builder in
            builder.tables[PdbTableType.tracks.rawValue] = [PdbBuilder.trackRow(tracks[0]), PdbBuilder.trackRow(tracks[1]), row]
            builder.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 72, name: Self.nfd("합성 한글 목록"), sortOrder: 3))
        }
        #expect(try PdbRoundTrip.check(export: export, exportExt: ext).contains { $0.contains("trackRowExtras") })
    }

    @Test("pdb-verify는 NFC로 바꿔 쓰는 문자열이 든 데이터 쪽을 이유와 함께 뺀다")
    func pageCheckExcludesNFCPages() throws {
        let nfc = PdbReadTests.sampleExport(tracks: PdbRoundTripTests.sampleTracks())
        var nfd = nfc
        nfd.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 72, name: Self.nfd("합성 한글 목록"), sortOrder: 3))
        let before = try PdbPageCheck.check(PdbPageCheckTests.writerShaped(nfc).build().data)
        #expect(!before.excluded.contains { $0.reason == "nfcStrings" })
        let report = try PdbPageCheck.check(PdbPageCheckTests.writerShaped(nfd).build().data)
        #expect(report.excluded.filter { $0.reason == "nfcStrings" }.map(\.table) == ["playlist_tree"])
        #expect(!report.compared.contains { $0.table == "playlist_tree" && $0.category == .data })
    }
}
