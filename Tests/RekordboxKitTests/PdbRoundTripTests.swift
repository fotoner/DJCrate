import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 읽기 → 모델 → 쓰기 → 다시 읽기. 편집 전에 이 왕복이 칸 단위로 같아야 Device Library를 다시 쓴다.
@Suite("Device Library 왕복")
struct PdbRoundTripTests {
    /// 읽기 시험의 합성 곡에서 file_type과 확장자를 맞춘 것(작성기는 다르면 막는다)
    static func sampleTracks() -> [PdbTrackSpec] {
        var tracks = PdbReadTests.sampleTracks()
        tracks[0][.fileName] = "test1.flac"
        tracks[0][.filePath] = "/Contents/시험 아티스트/시험 앨범/test1.flac"
        return tracks
    }

    /// 합성 export·exportExt(My Tag 연결은 v1이 옮기지 않아 뺀다)
    static func sample(configure: (inout PdbBuilder) -> Void = { _ in }) -> (export: Data, ext: Data) {
        let export = PdbReadTests.sampleExport(tracks: sampleTracks(), configure: configure).build().data
        let ext = PdbReadTests.sampleExt { $0.tables[PdbExtTableType.tagTracks.rawValue] = nil }.build().data
        return (export, ext)
    }

    static func differences(_ a: UsbLibrary, _ b: UsbLibrary) -> [UsbLibraryDiff.Difference] {
        UsbLibraryDiff.compare(a, b, options: .init(formats: [.deviceLibrary])).differences
    }

    @Test func writeReadEqualsModel() throws {
        let (export, ext) = Self.sample()
        let (model, report) = try PdbReader.read(export: export, exportExt: ext)
        #expect(report.issues.isEmpty)
        let files = try PdbWriter.files(model, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                           previousExtSequence: report.extHeader?.sequence ?? 0))
        let (reread, rereadReport) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        #expect(rereadReport.issues.isEmpty)
        #expect(Self.differences(reread, model.projected(to: .deviceLibrary)).isEmpty)
        #expect(reread == model.projected(to: .deviceLibrary))
        #expect(reread == files.written)
        // 합성 모델(PdbWriterTests)도 같다
        let synthetic = PdbWriterTests.model()
        let written = try PdbWriter.files(synthetic, mode: .fresh)
        let again = try PdbReader.read(export: written.export, exportExt: written.exportExt).0
        #expect(Self.differences(again, written.written).isEmpty)
    }

    /// 두 형식을 합친 모델: OneLibrary에만 있는 칸·곡·목록은 투영에서 빠지므로 차이가 아니다. pdb 칸은 입력 값 그대로 다시 읽힌다
    @Test func writeReadIgnoresOneLibraryOnlyFields() throws {
        let (export, ext) = Self.sample()
        var model = try PdbReader.read(export: export, exportExt: ext).0
        model.formats = [.oneLibrary, .deviceLibrary]
        model.property.createdDate = "2026-01-01"
        model.property.deviceName = "시험 기기"
        for index in model.tracks.indices {
            model.tracks[index].presentIn = [.oneLibrary, .deviceLibrary]
            model.tracks[index].titleForSearch = "검색 \(index)"
            model.tracks[index].kuvoDeliveryComment = "시험"
            model.tracks[index].deviceFields[.oneLibrary] = UsbTrackDeviceFields(rating: 1, playCount: 2, hasModified: 1)
        }
        model.tracks[0].lyricist = "시험 작사 2"
        model.artists[0].nameForSearch = "검색"
        model.albums[0].imageID = 61
        model.albums[0].isCompilation = 1
        model.images[0].oneLibraryPath = "/PIONEER/Artwork/00001/b61.jpg"
        model.playlists[0].imageID = 62
        model.playlists[0].presentIn = [.oneLibrary, .deviceLibrary]
        model.playlists[0].sortOrder[.oneLibrary] = 5
        model.playlists.append(UsbPlaylist(id: 99, name: "시험 OneLibrary 목록", presentIn: [.oneLibrary], sortOrder: [.oneLibrary: 1],
                                           entries: [.oneLibrary: [1]]))
        model.tracks.append(UsbTrack(id: 50, presentIn: [.oneLibrary], title: "OneLibrary 곡", fileName: "x.mp3", fileType: 1))
        model.categories[0].infoOrder = 3
        model.categories[1].disable = 1
        model.sorts[0].disable = 2
        model.property.pdbDate = "2025-12-31"
        model = model.canonicalized()

        let files = try PdbWriter.files(model, mode: .fresh)
        let reread = try PdbReader.read(export: files.export, exportExt: files.exportExt).0
        #expect(Self.differences(reread, model.projected(to: .deviceLibrary)).isEmpty)
        #expect(reread.tracks.map(\.id) == [1, 2, 3])
        #expect(reread.tracks[0].lyricist == "시험 작사 2")
        #expect(reread.categories[0].infoOrder == 3 && reread.categories[1].disable == 1 && reread.sorts[0].disable == 2)
        #expect(reread.property.pdbDate == "2025-12-31")
        #expect(reread.playlists.map(\.id) == [71])
    }

    /// DJCrate가 쓴 파일을 읽어 다시 쓰면 바이트가 같다
    @Test func djcrateFileRewriteIsByteIdentical() throws {
        let first = try PdbWriter.files(PdbWriterTests.model(), mode: .fresh)
        let model = try PdbReader.read(export: first.export, exportExt: first.exportExt).0
        let second = try PdbWriter.files(model, mode: .fresh)
        #expect(second.export == first.export)
        #expect(second.exportExt == first.exportExt)
        #expect(try PdbRoundTrip.check(export: first.export, exportExt: first.exportExt).isEmpty)
    }

    @Test func roundTripPassesOnSample() throws {
        let (export, ext) = Self.sample()
        #expect(try PdbRoundTrip.check(export: export, exportExt: ext).isEmpty)
        #expect(try PdbRoundTrip.check(export: export, exportExt: nil).isEmpty)
    }

    /// rekordbox 7.2.x 경계 실험(2026-10-08): 긴 이름의 먼 모양 아티스트·앨범 행과 긴 ASCII 이름은 다시 써도 같은 모양·같은 칸이다
    @Test func roundTripPassesWithFarRowsAndLongASCII() throws {
        let (export, ext) = Self.sample { builder in
            builder.add(.artists, PdbBuilder.artistRow(19, String(repeating: "가", count: 116), far: true))
            builder.add(.artists, PdbBuilder.artistRow(20, String(repeating: "A", count: 127)))
            builder.add(.artists, PdbBuilder.artistRow(21, String(repeating: "A", count: 250), far: true))
            builder.add(.albums, PdbBuilder.albumRow(29, String(repeating: "가", count: 120), artistID: 19, far: true))
        }
        let report = try PdbReader.read(export: export, exportExt: ext).1
        let base = try PdbReader.read(export: Self.sample().export, exportExt: ext).1
        #expect(report.farShapeRows == ["artists": 2, "albums": 1])
        #expect(report.stringKinds["longASCII", default: 0] == base.stringKinds["longASCII", default: 0] + 2)
        #expect(try PdbRoundTrip.check(export: export, exportExt: ext) == [])
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func roundTripDetectsUnknownTrackConstant() throws {
        var tracks = Self.sampleTracks()
        tracks[1].bitmask = 0x000C_0701
        let (export, ext) = Self.sample { builder in
            builder.tables[PdbTableType.tracks.rawValue] = tracks.map(PdbBuilder.trackRow)
        }
        let problems = try PdbRoundTrip.check(export: export, exportExt: ext)
        #expect(!problems.isEmpty)
        #expect(problems.contains { $0.contains("bitmask") && $0.contains("2") })
        for field in ["u5", "u7"] {
            var changed = Self.sampleTracks()
            if field == "u5" { changed[0].u5 = 0x002A } else { changed[0].u7 = 4 }
            let (export, ext) = Self.sample { $0.tables[PdbTableType.tracks.rawValue] = changed.map(PdbBuilder.trackRow) }
            #expect(try PdbRoundTrip.check(export: export, exportExt: ext).contains { $0.contains(field) })
        }
    }

    @Test func roundTripDetectsNonEmptyUnknownString() throws {
        var tracks = Self.sampleTracks()
        tracks[2][.unknown13] = "x"
        let (export, ext) = Self.sample { $0.tables[PdbTableType.tracks.rawValue] = tracks.map(PdbBuilder.trackRow) }
        let problems = try PdbRoundTrip.check(export: export, exportExt: ext)
        #expect(problems.contains { $0.contains("13") })
    }

    /// 문자열 6·7은 "ON"만 참으로 읽고 작성기는 참을 "ON", 거짓을 ''로 쓴다.
    /// 다른 값("OFF"·"1")이 든 파일은 모델이 같아도 다시 쓰면 바뀌므로 문제로 남긴다(글자 값은 문제에 넣지 않는다)
    @Test func roundTripDetectsFlagStringOtherThanOnOrEmpty() throws {
        var tracks = Self.sampleTracks()
        tracks[1][.kuvoPublic] = "OFF"
        tracks[2][.autoloadHotcues] = "1"
        let (export, ext) = Self.sample { $0.tables[PdbTableType.tracks.rawValue] = tracks.map(PdbBuilder.trackRow) }
        // 읽기는 원래 값을 남긴다(모델 칸은 거짓)
        let model = try PdbReader.read(export: export, exportExt: ext).0
        #expect(model.trackRowExtras[1]?.flagStrings == [6: "ON", 7: "ON"])
        #expect(model.trackRowExtras[2]?.flagStrings[6] == "OFF" && model.tracks[1].kuvoDeliver == false)
        let problems = try PdbRoundTrip.check(export: export, exportExt: ext)
        #expect(problems.contains("content 2 string6 not ON or empty"))
        #expect(problems.contains("content 3 string7 not ON or empty"))
        #expect(!problems.contains { $0.hasPrefix("content 1 ") })
        #expect(!problems.contains { $0.contains("OFF") })
    }

    /// 0x40 긴 ASCII는 쓰지 않는 모양이라 다시 쓰면 모양이 바뀐다
    @Test func roundTripDetectsStringKindDifference() throws {
        var tracks = Self.sampleTracks()
        tracks[2][.title] = "Title Three"
        var row = PdbBuilder.trackRow(tracks[2])
        // 제목(문자열 17)을 끝에 붙인 0x40 긴 ASCII로 가리킨다(값은 같게)
        let title = Array(tracks[2][.title].utf8)
        let offset = row.bytes.count
        let length = 4 + title.count
        row.bytes.append(contentsOf: [0x40, UInt8(length & 0xFF), UInt8(length >> 8), 0x00] + title)
        row.bytes[0x5E + 2 * 17] = UInt8(offset & 0xFF)
        row.bytes[0x5E + 2 * 17 + 1] = UInt8(offset >> 8)
        let (export, ext) = Self.sample { builder in
            builder.tables[PdbTableType.tracks.rawValue] = [PdbBuilder.trackRow(tracks[0]), PdbBuilder.trackRow(tracks[1]), row]
        }
        let (model, _) = try PdbReader.read(export: export, exportExt: ext)
        #expect(model.trackRowExtras[3]?.stringKinds[17] == .longASCII)
        let problems = try PdbRoundTrip.check(export: export, exportExt: ext)
        #expect(problems.contains { $0.contains("trackRowExtras") })
    }

    /// 구조 문제·먼 모양·작성기가 옮기지 못하는 행은 왕복 실패로 남긴다
    @Test func roundTripReportsUnwritableInput() throws {
        // My Tag 연결
        let export = PdbReadTests.sampleExport(tracks: Self.sampleTracks()).build().data
        let withLinks = PdbReadTests.sampleExt().build().data
        #expect(try PdbRoundTrip.check(export: export, exportExt: withLinks).contains { $0.contains("myTagLinks") })
        // 작성기가 고르지 않는 모양의 아티스트 행(짧은 이름을 먼 모양으로): 다시 쓰면 모양이 바뀐다
        let far = PdbReadTests.sampleExport(tracks: Self.sampleTracks()) { $0.add(.artists, PdbBuilder.artistRow(19, "Far", far: true)) }
            .build().data
        #expect(try PdbRoundTrip.check(export: far, exportExt: nil).contains("far_shape_rows artists 1 -> 0"))
        // 모르는 표의 행
        let unknown = PdbReadTests.sampleExport(tracks: Self.sampleTracks()) { $0.add(9, PdbBuilder.opaqueRow()) }.build().data
        #expect(!(try PdbRoundTrip.check(export: unknown, exportExt: nil)).isEmpty)
        // 속성 행의 두 번째 문자열이 비어 있지 않다
        let named = PdbReadTests.sampleExport(tracks: Self.sampleTracks()) { builder in
            builder.tables[PdbTableType.history19.rawValue] = [PdbBuilder.propertyRow(count: 3, date: "2026-01-03", name: "x")]
        }.build().data
        #expect(try PdbRoundTrip.check(export: named, exportExt: nil).contains { $0.contains("pdbDeviceName") })
        // 파일 머리를 읽지 못하면 던진다
        #expect(throws: UsbError.self) { try PdbRoundTrip.check(export: Data(count: 10), exportExt: nil) }
    }

    /// 머리 순번이 u32 끝인 파일(망가진 파일 등): 죽지 않고 막힘을 문제로 돌려준다
    @Test func roundTripReportsSequenceOverflow() throws {
        let files = try PdbWriter.files(PdbWriterTests.model(), mode: .fresh)
        func maxed(_ data: Data) -> Data {
            var data = data
            data.replaceSubrange(0x14..<0x18, with: [0xFF, 0xFF, 0xFF, 0xFF])
            return data
        }
        for (export, ext) in [(maxed(files.export), files.exportExt), (files.export, maxed(files.exportExt))] {
            let problems = try PdbRoundTrip.check(export: export, exportExt: ext)
            #expect(problems.contains("refused pdbSequenceOverflow"))
        }
    }

    /// 지운 행 ID는 다시 쓰면 사라진다(왕복 비교에서 뺀다)
    @Test func roundTripIgnoresDeadRows() throws {
        let (export, ext) = Self.sample { builder in
            var dead = PdbTrackSpec(id: 9)
            dead[.title] = "시험 지운 곡"
            builder.add(.tracks, PdbBuilder.Row(PdbBuilder.trackRow(dead).bytes, live: false, hasIndexShift: true))
        }
        #expect(try PdbReader.read(export: export, exportExt: ext).0.deadIDs == ["content": [9]])
        #expect(try PdbRoundTrip.check(export: export, exportExt: ext).isEmpty)
    }
}
