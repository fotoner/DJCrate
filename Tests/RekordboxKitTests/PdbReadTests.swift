import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("Device Library 읽기")
struct PdbReadTests {
    typealias Field = PdbTrackSpec.Field

    /// 합성 곡 3·아티스트 3·앨범 2·장르 2·키 2·색 8·목록 1(항목 3)·아트워크 3·메뉴 3·카테고리 2·정렬 2·property,
    /// exportExt 분류 1 + 태그 2·표 7. 모든 값은 지어낸 것이다.
    static func sampleTracks() -> [PdbTrackSpec] {
        var first = PdbTrackSpec(id: 1)
        first.sampleRate = 48000
        first.composerID = 14
        first.fileSize = 7_654_321
        first.artworkID = 61
        first.keyID = 51
        first.originalArtistID = 13
        first.labelID = 41
        first.remixerID = 12
        first.bitrate = 1411
        first.trackNo = 3
        first.bpmx100 = 12850
        first.genreID = 31
        first.albumID = 21
        first.artistID = 11
        first.discNo = 1
        first.playCount = 7
        first.year = 2020
        first.bitDepth = 24
        first.duration = 245
        first.colorID = 2
        first.rating = 4
        first.fileType = 5
        first.isrcSpecial = true
        first[.isrc] = "ZZ0000000001"
        first[.lyricist] = "시험 작사"
        first[.informationUpdateCount] = "9"
        first[.analysisDataUpdateCount] = "2"
        first[.cueUpdateCount] = "15"
        first[.kuvoPublic] = "ON"
        first[.autoloadHotcues] = "ON"
        first[.releaseDate] = "2020-05-06"
        first[.mixName] = "시험 믹스"
        first[.comment] = "시험 코멘트"
        var second = PdbTrackSpec(id: 2)
        second[.autoloadHotcues] = ""
        second[.title] = String(repeating: "t", count: 130)
        var third = PdbTrackSpec(id: 3)
        third.artistID = 11
        return [first, second, third]
    }

    static func sampleExport(tracks: [PdbTrackSpec] = sampleTracks(), configure: (inout PdbBuilder) -> Void = { _ in }) -> PdbBuilder {
        var builder = PdbBuilder(kind: .export)
        for track in tracks { builder.add(.tracks, PdbBuilder.trackRow(track)) }
        builder.add(.genres, PdbBuilder.idNameRow(31, "시험 장르"))
        builder.add(.genres, PdbBuilder.idNameRow(32, "Genre"))
        builder.add(.artists, PdbBuilder.artistRow(11, "시험 아티스트"))
        builder.add(.artists, PdbBuilder.artistRow(12, "Remixer"))
        builder.add(.artists, PdbBuilder.artistRow(13, "시험 원곡"))
        builder.add(.albums, PdbBuilder.albumRow(21, "시험 앨범", artistID: 11))
        builder.add(.albums, PdbBuilder.albumRow(22, "Album"))
        builder.add(.labels, PdbBuilder.idNameRow(41, "시험 레이블"))
        builder.add(.keys, PdbBuilder.keyRow(51, "8A"))
        builder.add(.keys, PdbBuilder.keyRow(52, "9B"))
        for (id, name) in ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"].enumerated() {
            builder.add(.colors, PdbBuilder.colorRow(id + 1, name))
        }
        builder.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 71, name: "시험 목록", sortOrder: 2))
        for (index, track) in [3, 1, 2].enumerated() {
            builder.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: index + 1, trackID: track, playlistID: 71))
        }
        for id in [61, 62, 63] {
            builder.add(.artwork, PdbBuilder.idNameRow(id, String(format: "/PIONEER/Artwork/00001/a%d.jpg", id)))
        }
        builder.add(.columns, PdbBuilder.columnRow(id: 1, code: 257, name: "시험 메뉴 1"))
        builder.add(.columns, PdbBuilder.columnRow(id: 2, code: 258, name: "MENU2"))
        builder.add(.columns, PdbBuilder.columnRow(id: 3, code: 259, name: "시험 메뉴 3"))
        builder.add(.category, PdbBuilder.categoryRow(id: 1, menuItemID: 1, infoOrder: 2, disable: 0, sequence: 1))
        builder.add(.category, PdbBuilder.categoryRow(id: 2, menuItemID: 2, infoOrder: 0, disable: 1, sequence: 2))
        builder.add(.sort, PdbBuilder.sortRow(id: 1, menuItemID: 1, disable: 2, sequence: 1))
        builder.add(.sort, PdbBuilder.sortRow(id: 2, menuItemID: 3, disable: 1, sequence: 2))
        builder.add(.history19, PdbBuilder.propertyRow(count: 3, date: "2026-01-03"))
        configure(&builder)
        return builder
    }

    static func sampleExt(configure: (inout PdbBuilder) -> Void = { _ in }) -> PdbBuilder {
        var builder = PdbBuilder(kind: .exportExt)
        builder.add(.tags, PdbBuilder.tagRow(id: 4_000_000_001, name: "시험 분류", position: 0, isCategory: true))
        builder.add(.tags, PdbBuilder.tagRow(id: 4_000_000_003, name: "Tag 2", parentID: 4_000_000_001, position: 1, isCategory: false))
        builder.add(.tags, PdbBuilder.tagRow(id: 4_000_000_002, name: "시험 태그 1", parentID: 4_000_000_001, position: 0, isCategory: false))
        builder.add(.tagTracks, PdbBuilder.tagTrackRow(trackID: 2, tagID: 4_000_000_002))
        builder.add(.tagTracks, PdbBuilder.tagTrackRow(trackID: 1, tagID: 4_000_000_002))
        builder.add(.myTagProperty, PdbBuilder.myTagPropertyRow(masterDBID: 123_456))
        configure(&builder)
        return builder
    }

    static func read(_ export: PdbBuilder = sampleExport(), _ ext: PdbBuilder? = sampleExt()) throws -> (UsbLibrary, PdbReadReport) {
        try PdbReader.read(export: export.build().data, exportExt: ext?.build().data)
    }

    @Test func readsAllKnownTables() throws {
        let (library, report) = try Self.read()
        #expect(report.issues.isEmpty)
        #expect(library.formats == [.deviceLibrary])
        #expect(library.tracks.map(\.id) == [1, 2, 3])

        let expected = UsbTrack(
            id: 1, presentIn: [.deviceLibrary], title: "시험 곡 1", titleForSearch: nil, subtitle: "시험 믹스",
            bpmx100: 12850, lengthSeconds: 245, trackNo: 3, discNo: 1,
            artistID: 11, remixerID: 12, originalArtistID: 13, composerID: 14, lyricistArtistID: nil, lyricist: "시험 작사",
            albumID: 21, genreID: 31, labelID: 41, keyID: 51, colorID: 2, imageID: 61,
            comment: "시험 코멘트", rating: 4, releaseYear: 2020, releaseDate: "2020-05-06", dateCreated: "2026-01-01", dateAdded: "2026-01-02",
            path: "/Contents/시험 아티스트/시험 앨범/test1.mp3", fileName: "test1.mp3", fileSize: 7_654_321, fileType: 5,
            bitrate: 1411, bitDepth: 24, sampleRate: 48000, isrc: "ZZ0000000001", djPlayCount: 7,
            hotCueAutoLoad: true, kuvoDeliver: true, kuvoDeliveryComment: "",
            masterDbId: 1_000_001, masterContentId: 900_001, analysisDataPath: "/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT",
            analysedBits: 0, contentLink: 0, hasModified: 0,
            cueUpdateCount: "15", analysisDataUpdateCount: "2", informationUpdateCount: "9",
            deviceFields: [.deviceLibrary: UsbTrackDeviceFields(rating: 4, playCount: 7, hasModified: nil)])
        #expect(library.tracks[0] == expected)
        // id 칸 0은 없음, "ON"이 아니면 false, 126자 넘는 ASCII 제목
        let second = library.tracks[1]
        #expect(second.artistID == nil && second.albumID == nil && second.imageID == nil && second.composerID == nil)
        #expect(second.hotCueAutoLoad == false && second.kuvoDeliver == false)
        #expect(second.title == String(repeating: "t", count: 130))
        #expect(second.isrc == "" && second.colorID == 0)

        // 상수 칸 관찰값
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
        let extras = try #require(library.trackRowExtras[1])
        #expect(extras.subtype == 0x0024 && extras.bitmask == 0x000C_0700 && extras.u5 == 0x0029 && extras.u7 == 3)
        #expect(extras.unknownStrings == [5: "", 8: "", 9: "", 13: "", 18: ""])
        #expect(extras.stringKinds.count == 21)
        #expect(extras.stringKinds[0] == .isrc && extras.stringKinds[1] == .utf16LE && extras.stringKinds[2] == .shortASCII)
        // 130자 순수 ASCII 제목은 긴 ASCII(0x40)
        #expect(library.trackRowExtras[2]?.stringKinds[17] == .longASCII)
        #expect(library.trackRowExtras.keys.sorted() == [1, 2, 3])

        #expect(library.artists == [UsbNamedRow(id: 11, name: "시험 아티스트"), UsbNamedRow(id: 12, name: "Remixer"),
                                    UsbNamedRow(id: 13, name: "시험 원곡")])
        #expect(library.albums == [UsbAlbum(id: 21, name: "시험 앨범", artistID: 11), UsbAlbum(id: 22, name: "Album", artistID: nil)])
        #expect(library.genres == [UsbNamedRow(id: 31, name: "시험 장르"), UsbNamedRow(id: 32, name: "Genre")])
        #expect(library.labels == [UsbNamedRow(id: 41, name: "시험 레이블")])
        #expect(library.keys == [UsbNamedRow(id: 51, name: "8A"), UsbNamedRow(id: 52, name: "9B")])
        #expect(library.colors.count == 8 && library.colors[0] == UsbNamedRow(id: 1, name: "Pink"))
        #expect(library.colors.map(\.id) == Array(1...8))
        #expect(library.images == [61, 62, 63].map { UsbImage(id: $0, oneLibraryPath: nil, pdbPath: "/PIONEER/Artwork/00001/a\($0).jpg") })
        #expect(library.playlists == [UsbPlaylist(id: 71, name: "시험 목록", parentID: 0, attribute: 0, imageID: nil, presentIn: [.deviceLibrary],
                                                  sortOrder: [.deviceLibrary: 2], entries: [.deviceLibrary: [3, 1, 2]])])
        #expect(library.menuItems == [UsbMenuItem(id: 1, kind: 257, name: "시험 메뉴 1"), UsbMenuItem(id: 2, kind: 258, name: "MENU2"),
                                      UsbMenuItem(id: 3, kind: 259, name: "시험 메뉴 3")])
        #expect(library.categories == [UsbCategory(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, infoOrder: 2, disable: 0),
                                       UsbCategory(id: 2, menuItemID: 2, sequenceNo: 2, isVisible: false, infoOrder: 0, disable: 1)])
        #expect(library.sorts == [UsbSort(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, isSelectedAsSubColumn: true, disable: 2),
                                  UsbSort(id: 2, menuItemID: 3, sequenceNo: 2, isVisible: false, isSelectedAsSubColumn: false, disable: 1)])
        #expect(library.property == UsbProperty(deviceName: "", dbVersion: "1000", numberOfContents: 3, createdDate: "",
                                                backgroundColorType: 0, myTagMasterDBID: 123_456, pdbDate: "2026-01-03", pdbDeviceName: ""))
        #expect(library.myTags == [
            UsbMyTag(id: 4_000_000_001, parentID: 0, sequenceNo: 0, name: "시험 분류", isCategory: true),
            UsbMyTag(id: 4_000_000_002, parentID: 4_000_000_001, sequenceNo: 0, name: "시험 태그 1", isCategory: false),
            UsbMyTag(id: 4_000_000_003, parentID: 4_000_000_001, sequenceNo: 1, name: "Tag 2", isCategory: false),
        ])
        #expect(library.myTagLinks.map(\.contentID) == [1, 2])
        #expect(library.myTagLinks.allSatisfy { $0.presentIn == [.deviceLibrary] })
        #expect(library.histories.isEmpty && library.unknownRows.isEmpty && library.deadIDs.isEmpty)

        // 보고서
        #expect(report.tableCounts["tracks"]?.live == 3 && report.tableCounts["tracks"]?.slots == 3)
        #expect(report.tableCounts["colors"]?.live == 8)
        #expect(report.tableCounts["exportExt.tags"]?.live == 3)
        #expect(report.tableCounts["exportExt.my_tag_property"]?.live == 1)
        #expect(report.stringKinds["isrc"] == 1)
        #expect((report.stringKinds["utf16LE"] ?? 0) > 0 && (report.stringKinds["shortASCII"] ?? 0) > 0)
        #expect(report.misalignedUTF16 == 0)
        #expect(report.exportHeader.flag10 == 5 && report.extHeader?.numTables == 9)
        // 한 형식 리더의 모델은 그 형식 투영과 같고, 두 번 읽어도 같다
        #expect(library.projected(to: .deviceLibrary) == library)
        #expect(try Self.read().0 == library)
    }

    @Test func withoutExportExt() throws {
        let (library, report) = try Self.read(Self.sampleExport(), nil)
        #expect(library.myTags.isEmpty && library.myTagLinks.isEmpty)
        #expect(library.property.myTagMasterDBID == 0)
        #expect(report.extHeader == nil)
        #expect(report.issues.isEmpty)
    }

    @Test func deadRowsIgnoredDuplicatesIgnored() throws {
        let export = Self.sampleExport { builder in
            // 산 곡 1의 죽은 복제(다른 제목), 죽은 곡 5, 죽은 아티스트 9, 죽은 목록 항목
            var copy = PdbTrackSpec(id: 1)
            copy[.title] = "시험 옛 제목"
            builder.tables[PdbTableType.tracks.rawValue]!.insert(PdbBuilder.Row(PdbBuilder.trackRow(copy).bytes, live: false, hasIndexShift: true),
                                                                 at: 0)
            var dead = PdbBuilder.trackRow(PdbTrackSpec(id: 5))
            dead.live = false
            builder.add(.tracks, dead)
            var artist = PdbBuilder.artistRow(9, "시험 지운 아티스트")
            artist.live = false
            builder.add(.artists, artist)
            var entry = PdbBuilder.playlistEntryRow(index: 4, trackID: 5, playlistID: 71)
            entry.live = false
            builder.add(.playlistEntries, entry)
            var playlist = PdbBuilder.playlistTreeRow(id: 72, name: "시험 지운 목록")
            playlist.live = false
            builder.add(.playlistTree, playlist)
        }
        let (library, report) = try Self.read(export)
        let (clean, _) = try Self.read()
        #expect(report.issues.isEmpty)
        #expect(library.tracks == clean.tracks)
        #expect(library.artists == clean.artists)
        #expect(library.playlists == clean.playlists)
        #expect(library.deadIDs == ["content": [1, 5], "artist": [9], "playlist": [72]])
        #expect(report.tableCounts["tracks"]?.live == 3 && report.tableCounts["tracks"]?.slots == 5)
        #expect(report.tableCounts["playlist_entries"]?.live == 3 && report.tableCounts["playlist_entries"]?.slots == 4)
    }

    @Test func indexShiftNotUsed() throws {
        var export = Self.sampleExport()
        export.indexShift = { UInt16(truncatingIfNeeded: 0x1234 &* ($0 + 7)) }
        var ext = Self.sampleExt()
        ext.indexShift = { _ in 0xFFFF }
        let (library, report) = try Self.read(export, ext)
        #expect(report.issues.isEmpty)
        #expect(library == (try Self.read()).0)
    }

    @Test func paddingGarbageIgnored() throws {
        var export = Self.sampleExport { builder in
            for table in builder.tables.keys {
                builder.tables[table] = builder.tables[table]!.map { row in var row = row; row.extraPadding = 8; return row }
            }
        }
        export.paddingFill = 0xEE
        var ext = Self.sampleExt()
        ext.paddingFill = 0x90
        let (library, report) = try Self.read(export, ext)
        #expect(report.issues.isEmpty)
        #expect(library == (try Self.read()).0)
    }

    @Test func pageWith284Rows() throws {
        let export = Self.sampleExport { builder in
            builder.tables[PdbTableType.playlistEntries.rawValue] = (1...285).map {
                PdbBuilder.playlistEntryRow(index: $0, trackID: [1, 2, 3][$0 % 3], playlistID: 71)
            }
        }
        let built = export.build()
        #expect(built.dataPages[PdbTableType.playlistEntries.rawValue]?.count == 2)
        let (library, report) = try PdbReader.read(export: built.data, exportExt: nil)
        #expect(report.issues.isEmpty)
        #expect(library.playlists[0].entries[.deviceLibrary] == (1...285).map { [1, 2, 3][$0 % 3] })
        #expect(report.tableCounts["playlist_entries"]?.live == 285)
        #expect(report.pageCounts["playlist_entries"] == 3)
    }

    @Test func entriesFollowEntryIndexNotRowOrder() throws {
        let export = Self.sampleExport { builder in
            builder.tables[PdbTableType.playlistEntries.rawValue] = [
                PdbBuilder.playlistEntryRow(index: 3, trackID: 2, playlistID: 71),
                PdbBuilder.playlistEntryRow(index: 1, trackID: 3, playlistID: 71),
                PdbBuilder.playlistEntryRow(index: 2, trackID: 1, playlistID: 71),
            ]
            builder.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 70, name: "시험 폴더", sortOrder: 1, isFolder: true))
            builder.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 73, name: "시험 하위", parentID: 70, sortOrder: 0))
        }
        let (library, _) = try Self.read(export)
        #expect(library.playlists.map(\.id) == [70, 71, 73])
        #expect(library.playlists[0].attribute == 1 && library.playlists[0].entries[.deviceLibrary] == [])
        #expect(library.playlists[1].entries[.deviceLibrary] == [3, 1, 2])
        #expect(library.playlists[2].parentID == 70)
    }

    @Test func farOffsetArtistAlbumTagRead() throws {
        let export = Self.sampleExport { builder in
            builder.tables[PdbTableType.artists.rawValue] = [PdbBuilder.artistRow(11, "시험 아티스트", far: true),
                                                             PdbBuilder.artistRow(12, "Remixer", far: true),
                                                             PdbBuilder.artistRow(13, "시험 원곡")]
            builder.tables[PdbTableType.albums.rawValue] = [PdbBuilder.albumRow(21, "시험 앨범", artistID: 11, far: true),
                                                            PdbBuilder.albumRow(22, "Album", far: true)]
        }
        let ext = Self.sampleExt { builder in
            builder.tables[PdbExtTableType.tags.rawValue] = [
                PdbBuilder.tagRow(id: 4_000_000_001, name: "시험 분류", position: 0, isCategory: true, far: true),
                PdbBuilder.tagRow(id: 4_000_000_003, name: "Tag 2", parentID: 4_000_000_001, position: 1, isCategory: false, far: true),
                PdbBuilder.tagRow(id: 4_000_000_002, name: "시험 태그 1", parentID: 4_000_000_001, position: 0, isCategory: false),
            ]
        }
        let (library, report) = try Self.read(export, ext)
        // 아티스트·앨범 먼 모양은 칸 자리가 알려져 문제가 아니다. 먼 모양 태그 행은 칸 자리를 확인하지 못해
        // 모델에 넣되 구조 문제로 남긴다(편집·다시 쓰기가 막히게)
        #expect(report.issueDetails.map(\.kind) == [.unconfirmedRowShape, .unconfirmedRowShape])
        #expect(report.issueDetails.allSatisfy { $0.table == "exportExt.tags" && $0.page != nil && $0.slot != nil })
        #expect(report.farShapeRows == ["artists": 2, "albums": 2, "exportExt.tags": 2])
        #expect(library == (try Self.read()).0)
        #expect(try Self.read().1.farShapeRows.isEmpty)
        let inspected = try PdbReader.inspect(export.build().data)
        #expect(inspected.farShapeRows == ["artists": 2, "albums": 2])
    }

    /// 먼 모양 태그 행은 아티스트·앨범 먼 모양과 같은 규칙이다: 가까운 모양의 u8 표시 0x03·u8 오프셋 자리에 u16 표시 0x0003·u16 오프셋.
    /// 근거: Deep Symmetry rekordbox export 분석 문서의 tag rows("For subtype 0684, each is stored in two bytes")와
    /// rekordcrate(`TagOrCategory`, 오프셋 배열 @0x1C)가 같은 자리를 적는다(#189). rekordbox 실험으로는 아직 확인 못 함.
    @Test func farTagRowFollowsDocumentedLayout() throws {
        var row = PdbBuilder.RowBytes(count: 0x22)
        row.u16(0x0684, at: 0)
        row.u32(4_000_000_001, at: 0x0C)
        row.u32(1, at: 0x10)
        row.u32(4_000_000_003, at: 0x14)
        row.u16(0x0003, at: 0x1C)
        let name = row.append("먼 태그")
        let second = row.append("")
        row.u16(name, at: 0x1E)
        row.u16(second, at: 0x20)
        let ext = Self.sampleExt { builder in
            builder.tables[PdbExtTableType.tags.rawValue] = [
                PdbBuilder.tagRow(id: 4_000_000_001, name: "시험 분류", position: 0, isCategory: true),
                PdbBuilder.Row(row.bytes, hasIndexShift: true),
            ]
        }
        let (library, report) = try Self.read(Self.sampleExport(), ext)
        #expect(library.myTags.map(\.id) == [4_000_000_001, 4_000_000_003])
        #expect(library.myTags.last?.name == "먼 태그")
        #expect(library.myTags.last?.parentID == 4_000_000_001 && library.myTags.last?.sequenceNo == 1)
        // 칸 자리는 rekordbox로 확인하지 못했으니 편집이 막히게 구조 문제로 남긴다
        #expect(report.issueDetails.map(\.kind) == [.unconfirmedRowShape])
        #expect(report.farShapeRows == ["exportExt.tags": 1])
    }

    @Test func farTagRowWithInconsistentOffsetsIsUnreadable() throws {
        // 먼 모양 태그 행의 두 오프셋이 거꾸로면(이름 ≥ 두 번째) 조용히 틀린 이름을 읽지 않고 행을 버린다
        var swapped = PdbBuilder.tagRow(id: 4_000_000_003, name: "Tag 2", parentID: 4_000_000_001, position: 1, isCategory: false, far: true)
        let name = Int(swapped.bytes[0x1E]) | Int(swapped.bytes[0x1F]) << 8
        let second = Int(swapped.bytes[0x20]) | Int(swapped.bytes[0x21]) << 8
        swapped.bytes[0x1E] = UInt8(second & 0xFF)
        swapped.bytes[0x1F] = UInt8(second >> 8)
        swapped.bytes[0x20] = UInt8(name & 0xFF)
        swapped.bytes[0x21] = UInt8(name >> 8)
        let ext = Self.sampleExt { builder in
            builder.tables[PdbExtTableType.tags.rawValue] = [
                PdbBuilder.tagRow(id: 4_000_000_001, name: "시험 분류", position: 0, isCategory: true),
                swapped,
            ]
        }
        let (library, report) = try Self.read(Self.sampleExport(), ext)
        #expect(report.issueDetails.map(\.kind) == [.rowUnreadable])
        #expect(library.myTags.map(\.id) == [4_000_000_001])
        #expect(report.farShapeRows.isEmpty)
    }

    @Test func orphanPlaylistEntryReported() throws {
        // 산 목록 항목이 없는 목록을 가리키면 모델에는 담을 곳이 없어 빠지므로 구조 문제로 남긴다
        let export = Self.sampleExport { builder in
            builder.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: 1, trackID: 1, playlistID: 99))
        }
        let (library, report) = try Self.read(export)
        #expect(report.issueDetails.map(\.kind) == [.orphanEntry])
        let issue = try #require(report.issueDetails.first)
        #expect(issue.table == "playlist_entries" && issue.page != nil && issue.slot == 3)
        #expect(library.playlists == (try Self.read()).0.playlists)
        #expect(report.tableCounts["playlist_entries"]?.live == 4)

        // 죽은 항목은 문제가 아니다(rekordbox는 지운 목록의 항목을 함께 죽인다)
        let dead = Self.sampleExport { builder in
            var entry = PdbBuilder.playlistEntryRow(index: 1, trackID: 1, playlistID: 99)
            entry.live = false
            builder.add(.playlistEntries, entry)
        }
        #expect(try Self.read(dead).1.issues.isEmpty)
    }

    @Test func unknownTablesCounted() throws {
        let export = Self.sampleExport { builder in
            builder.add(9, PdbBuilder.opaqueRow())
            builder.add(9, PdbBuilder.opaqueRow())
            var dead = PdbBuilder.opaqueRow()
            dead.live = false
            builder.add(9, dead)
            builder.add(14, PdbBuilder.opaqueRow(20))
        }
        let ext = Self.sampleExt { builder in
            builder.add(0, PdbBuilder.opaqueRow())
            builder.add(8, PdbBuilder.opaqueRow(4))
            builder.add(8, PdbBuilder.opaqueRow(4))
        }
        let (library, report) = try Self.read(export, ext)
        #expect(report.issues.isEmpty)
        #expect(library.unknownRows == [
            UsbUnknownRows(format: .deviceLibrary, file: "export.pdb", tableType: 9, liveRows: 2),
            UsbUnknownRows(format: .deviceLibrary, file: "export.pdb", tableType: 14, liveRows: 1),
            UsbUnknownRows(format: .deviceLibrary, file: "exportExt.pdb", tableType: 0, liveRows: 1),
            UsbUnknownRows(format: .deviceLibrary, file: "exportExt.pdb", tableType: 8, liveRows: 2),
        ])
        #expect(report.unknownRows == library.unknownRows)
    }

    @Test func historyTablesTyped() throws {
        let export = Self.sampleExport { builder in
            builder.add(.historyPlaylists, PdbBuilder.idNameRow(2, "HISTORY 002"))
            builder.add(.historyPlaylists, PdbBuilder.idNameRow(1, "시험 기록"))
            builder.add(.historyEntries, PdbBuilder.historyEntryRow(trackID: 2, playlistID: 1, index: 2))
            builder.add(.historyEntries, PdbBuilder.historyEntryRow(trackID: 1, playlistID: 1, index: 1))
            builder.add(.historyEntries, PdbBuilder.historyEntryRow(trackID: 3, playlistID: 2, index: 1))
        }
        let (library, report) = try Self.read(export)
        #expect(report.issues.isEmpty)
        #expect(library.histories == [UsbHistory(format: .deviceLibrary, id: 1, name: "시험 기록", entries: [1, 2]),
                                      UsbHistory(format: .deviceLibrary, id: 2, name: "HISTORY 002", entries: [3])])
        #expect(library.unknownRows.isEmpty)

        // 해석이 안 되면(짧은 행) 두 표 모두 행 수만 남긴다
        let broken = Self.sampleExport { builder in
            builder.add(.historyPlaylists, PdbBuilder.idNameRow(1, "시험 기록"))
            builder.add(.historyEntries, PdbBuilder.Row(Data([1, 0, 0, 0])))
        }
        let (partial, _) = try Self.read(broken)
        #expect(partial.histories.isEmpty)
        #expect(partial.unknownRows == [
            UsbUnknownRows(format: .deviceLibrary, file: "export.pdb", tableType: 11, liveRows: 1),
            UsbUnknownRows(format: .deviceLibrary, file: "export.pdb", tableType: 12, liveRows: 1),
        ])
    }

    @Test func brokenChainsReported() throws {
        let tracks = PdbTableType.tracks.rawValue, genres = PdbTableType.genres.rawValue, keys = PdbTableType.keys.rawValue
        var built = Self.sampleExport().build()
        // 곡 데이터 쪽의 쪽 번호 ≠ 위치
        built.setU32(page: built.dataPages[tracks]![0], offset: 0x04, 77)
        // 장르 인덱스 쪽 → 파일 밖
        built.setU32(page: built.indexPages[genres]!, offset: 0x0C, 50_000)
        // 키 데이터 쪽 → 인덱스 쪽으로 되돌아감
        built.setU32(page: built.dataPages[keys]![0], offset: 0x0C, UInt32(built.indexPages[keys]!))
        let (library, report) = try PdbReader.read(export: built.data, exportExt: nil)
        let kinds = Set(report.issueDetails.map(\.kind))
        #expect(kinds == [.pageIndexMismatch, .pageOutsideFile, .cycle])
        #expect(report.issues.count == 3)
        #expect(report.issues.contains { $0.contains("tracks") && $0.contains("pageIndexMismatch") })
        // 부분 결과: 망가진 표는 비고, 나머지는 그대로
        #expect(library.tracks.isEmpty && library.genres.isEmpty)
        #expect(library.keys.count == 2)
        #expect(library.artists.count == 3)
        // 문제 문자열에는 값이 들어가지 않는다
        #expect(!report.issues.joined().contains("시험"))
    }

    @Test func rowProblemsReported() throws {
        let export = Self.sampleExport { builder in
            // 알 수 없는 문자열 첫 바이트
            var bad = PdbBuilder.idNameRow(33, "x")
            bad.bytes[4] = 0x02
            builder.add(.genres, bad)
            // 같은 id 산 행 둘
            builder.add(.keys, PdbBuilder.keyRow(51, "8A"))
        }
        let (library, report) = try Self.read(export)
        #expect(Set(report.issueDetails.map(\.kind)) == [.rowUnreadable, .duplicateID])
        #expect(library.genres.map(\.id) == [31, 32])

        // 행 오프셋이 힙 밖, 산 행 수와 presence 비트 수가 다름
        var built = Self.sampleExport().build()
        let page = built.dataPages[PdbTableType.genres.rawValue]![0]
        let at = page * PdbPage.size + PdbPage.size - 6 - 2
        built.data[at] = 0xF0
        built.data[at + 1] = 0x0F
        built.data[page * PdbPage.size + 0x18 ..< page * PdbPage.size + 0x1B] = PdbPage.packRowCounts(slots: 2, live: 1)
        let (_, broken) = try PdbReader.read(export: built.data, exportExt: nil)
        #expect(Set(broken.issueDetails.map(\.kind)) == [.rowOutsideHeap, .liveCountMismatch])
    }

    @Test func u32AboveInt32() throws {
        var track = PdbTrackSpec(id: 1)
        track.masterDbId = 3_000_000_000
        track.masterContentId = 3_000_000_001
        let export = Self.sampleExport(tracks: [track])
        var ext = PdbBuilder(kind: .exportExt)
        ext.add(.tags, PdbBuilder.tagRow(id: 4_000_000_001, name: "시험 분류", position: 0, isCategory: true))
        ext.add(.tags, PdbBuilder.tagRow(id: 4_100_000_000, name: "시험 태그", parentID: 4_000_000_001, position: 0, isCategory: false))
        ext.add(.tagTracks, PdbBuilder.tagTrackRow(trackID: 1, tagID: 4_100_000_000))
        ext.add(.myTagProperty, PdbBuilder.myTagPropertyRow(masterDBID: 4_000_000_000))
        let (library, _) = try Self.read(export, ext)
        #expect(library.tracks[0].masterDbId == 3_000_000_000 && library.tracks[0].masterContentId == 3_000_000_001)
        #expect(library.property.myTagMasterDBID == 4_000_000_000)
        #expect(library.myTags.map(\.id) == [4_000_000_001, 4_100_000_000])
        #expect(library.myTags[1].parentID == 4_000_000_001)
        #expect(library.myTagLinks == [UsbMyTagLink(myTagID: 4_100_000_000, contentID: 1, presentIn: [.deviceLibrary])])
    }

    /// pdb 트랙 0x14(로컬 MasterSongID)·0x18(MasterDBID)과 경로 끝 성분으로 로컬 곡과 짝짓는다(OneLibrary와 같은 열쇠)
    @Test func matchesLocalTrackFromDeviceLibrary() throws {
        var track = PdbTrackSpec(id: 1)
        track.masterDbId = 3_000_000_000
        track.masterContentId = 3_000_000_001
        track[.fileName] = "시험 곡 (2).mp3"
        track[.filePath] = "/Contents/시험 아티스트/시험 앨범/시험 곡 (2).mp3"
        let (library, _) = try Self.read(Self.sampleExport(tracks: [track]))
        let usb = try #require(library.tracks.first)
        let key = UsbTrackKey(masterDbId: usb.masterDbId, masterContentId: usb.masterContentId, fileName: usb.fileName)
        let local = [UsbLocalTrackKey(contentID: "71", masterSongID: "3000000001", fileNameL: "시험 곡.mp3"),
                     UsbLocalTrackKey(contentID: "72", masterSongID: "3000000002", fileNameL: "시험 곡.mp3")]
        #expect(UsbTrackMatch.match(key, localDBID: 3_000_000_000, local: local) == "71")
        // 다른 라이브러리에서 내보낸 곡
        #expect(UsbTrackMatch.match(key, localDBID: 1_000_001, local: local) == nil)
    }

    @Test func flag10NotFiveReported() throws {
        var export = Self.sampleExport()
        export.flag10 = 4
        var ext = Self.sampleExt()
        ext.flag10 = 1
        let (library, report) = try Self.read(export, ext)
        #expect(report.exportHeader.flag10 == 4 && report.extHeader?.flag10 == 1)
        // 막는 것은 쓰기 쪽 몫이라 읽기는 멈추지 않는다
        #expect(report.issues.isEmpty)
        #expect(library.tracks.count == 3)
    }

    @Test func headerTableCountChecked() throws {
        // export 자리에 exportExt를 넣으면 멈춘다
        #expect(throws: UsbError.self) { try PdbReader.read(export: Self.sampleExt().build().data, exportExt: nil) }
        #expect(throws: UsbError.self) {
            try PdbReader.read(export: Self.sampleExport().build().data, exportExt: Self.sampleExport().build().data)
        }
    }

    @Test func inspectSingleFile() throws {
        let export = try PdbReader.inspect(Self.sampleExport().build().data)
        #expect(export.kind == .export && export.issues.isEmpty)
        #expect(export.tables.count == 20)
        #expect(export.tables.first { $0.name == "tracks" }?.liveRows == 3)
        #expect(export.maxPageSequence < export.header.sequence)
        let ext = try PdbReader.inspect(Self.sampleExt().build().data)
        #expect(ext.kind == .exportExt && ext.tables.count == 9)
        #expect(ext.tables.first { $0.name == "exportExt.tags" }?.liveRows == 3)
    }

    @Test func readsSnapshotCopies() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        tree.write(UsbLayout.exportPdb, Self.sampleExport().build().data)
        tree.write(UsbLayout.exportExtPdb, Self.sampleExt().build().data)
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-pdb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = try UsbSnapshot.take(root: tree.root, into: work)
        let (library, _) = try #require(try PdbReader.read(snapshot: snapshot))
        #expect(library == (try Self.read()).0)
    }

    /// 같은 합성 라이브러리를 OneLibrary·Device Library로 만들어 합치면 불일치가 없고, pdb에만 있는 칸은 합친 모델에 남는다
    @Test func mergeWithOneLibraryFixture() throws {
        let fixture = try OneLibraryFixture()
        var olFirst = OneLibraryTrackSpec(id: 1)
        olFirst.subtitle = "시험 믹스"
        olFirst.bpmx100 = 12850
        olFirst.length = 245
        olFirst.trackNo = 3
        olFirst.discNo = 1
        olFirst.artistID = 11
        olFirst.remixerID = 12
        olFirst.originalArtistID = 13
        olFirst.composerID = 14
        olFirst.albumID = 21
        olFirst.genreID = 31
        olFirst.labelID = 41
        olFirst.keyID = 51
        olFirst.colorID = 2
        olFirst.imageID = 61
        olFirst.djComment = "시험 코멘트"
        olFirst.rating = 4
        olFirst.releaseYear = 2020
        olFirst.releaseDate = "2020-05-06"
        olFirst.fileSize = 7_654_321
        olFirst.fileType = 5
        olFirst.bitrate = 1411
        olFirst.bitDepth = 24
        olFirst.samplingRate = 48000
        olFirst.isrc = "ZZ0000000001"
        olFirst.djPlayCount = 7
        olFirst.isKuvoDeliverStatusOn = 1
        olFirst.kuvoDeliveryComment = "시험 전달"
        olFirst.cueUpdateCount = .int(15)
        olFirst.analysisDataUpdateCount = .int(2)
        olFirst.informationUpdateCount = .int(9)
        olFirst.titleForSearch = "시험 검색"
        try fixture.add(track: olFirst)
        var olSecond = OneLibraryTrackSpec(id: 2)
        olSecond.title = String(repeating: "t", count: 130)
        olSecond.isHotCueAutoLoadOn = 0
        try fixture.add(track: olSecond)
        var olThird = OneLibraryTrackSpec(id: 3)
        olThird.artistID = 11
        try fixture.add(track: olThird)
        try fixture.insert("artist", ["artist_id": .int(11), "name": .text("시험 아티스트"), "nameForSearch": .text("시험 검색")])
        try fixture.insert("artist", ["artist_id": .int(12), "name": .text("Remixer"), "nameForSearch": .null])
        try fixture.insert("artist", ["artist_id": .int(13), "name": .text("시험 원곡"), "nameForSearch": .null])
        try fixture.insert("album", ["album_id": .int(21), "name": .text("시험 앨범"), "artist_id": .int(11), "image_id": .int(61),
                                     "isComplation": .int(0), "nameForSearch": .null])
        try fixture.insert("album", ["album_id": .int(22), "name": .text("Album"), "artist_id": .null, "image_id": .null,
                                     "isComplation": .int(0), "nameForSearch": .null])
        try fixture.insert("genre", ["genre_id": .int(31), "name": .text("시험 장르")])
        try fixture.insert("genre", ["genre_id": .int(32), "name": .text("Genre")])
        try fixture.insert("label", ["label_id": .int(41), "name": .text("시험 레이블")])
        try fixture.insert("key", ["key_id": .int(51), "name": .text("8A")])
        try fixture.insert("key", ["key_id": .int(52), "name": .text("9B")])
        for (id, name) in ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"].enumerated() {
            try fixture.insert("color", ["color_id": .int(id + 1), "name": .text(name)])
        }
        for id in [61, 62, 63] {
            try fixture.insert("image", ["image_id": .int(id), "path": .text(String(format: "/PIONEER/Artwork/00001/b%d.jpg", id))])
        }
        try fixture.add(playlist: 71, name: "시험 목록", sequenceNo: 5, imageID: 61, entries: [3, 1, 2])
        try fixture.add(myTag: 4_000_000_001, name: "시험 분류", sequenceNo: 0, isCategory: true)
        try fixture.add(myTag: 4_000_000_003, name: "Tag 2", parentID: 4_000_000_001, sequenceNo: 1)
        try fixture.add(myTag: 4_000_000_002, name: "시험 태그 1", parentID: 4_000_000_001, sequenceNo: 0)
        try fixture.link(myTag: 4_000_000_002, content: 2)
        try fixture.link(myTag: 4_000_000_002, content: 1)
        try fixture.add(menuItem: 1, kind: 257, name: "\u{FFFA}시험 메뉴 1\u{FFFB}")
        try fixture.add(menuItem: 2, kind: 258, name: "\u{FFFA}MENU2\u{FFFB}")
        try fixture.add(menuItem: 3, kind: 259, name: "\u{FFFA}시험 메뉴 3\u{FFFB}")
        try fixture.add(category: 1, menuItemID: 1, sequenceNo: 1)
        try fixture.add(category: 2, menuItemID: 2, sequenceNo: 2, isVisible: false)
        try fixture.add(sort: 1, menuItemID: 1, sequenceNo: 1, isSelectedAsSubColumn: true)
        try fixture.add(sort: 2, menuItemID: 3, sequenceNo: 2, isVisible: false)
        try fixture.setProperty(deviceName: "", numberOfContents: 3, createdDate: "2026-01-02", myTagMasterDBID: 123_456)
        let oneLibrary = try OneLibraryReader.read(copyAt: fixture.url)

        let (deviceLibrary, report) = try Self.read()
        #expect(report.issues.isEmpty)

        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        #expect(mismatches.isEmpty)
        // pdb에만 있는 칸은 합친 모델에 그대로
        let first = try #require(merged.tracks.first { $0.id == 1 })
        #expect(first.lyricist == "시험 작사")
        #expect(first.titleForSearch == "시험 검색" && first.kuvoDeliveryComment == "시험 전달")
        #expect(merged.categories.first { $0.id == 1 }?.infoOrder == 2)
        #expect(merged.categories.first { $0.id == 2 }?.disable == 1)
        #expect(merged.sorts.first { $0.id == 1 }?.disable == 2)
        #expect(merged.property.pdbDate == "2026-01-03")
        #expect(merged.property.createdDate == "2026-01-02")
        #expect(merged.images.first { $0.id == 61 } == UsbImage(id: 61, oneLibraryPath: "/PIONEER/Artwork/00001/b61.jpg",
                                                                pdbPath: "/PIONEER/Artwork/00001/a61.jpg"))
        #expect(merged.trackRowExtras == deviceLibrary.trackRowExtras)
        #expect(merged.playlists.first?.sortOrder == [.oneLibrary: 5, .deviceLibrary: 2])

        // 투영은 pdb 단독 읽기와 같다
        let diff = UsbLibraryDiff.compare(merged.projected(to: .deviceLibrary), deviceLibrary,
                                          options: UsbLibraryDiff.Options(formats: [.deviceLibrary]))
        #expect(diff.differences.isEmpty)
        #expect(merged.projected(to: .deviceLibrary) == deviceLibrary)
    }
}
