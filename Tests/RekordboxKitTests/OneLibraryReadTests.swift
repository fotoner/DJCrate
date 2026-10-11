import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("OneLibrary 읽기")
struct OneLibraryReadTests {
    /// 합성 곡 3·목록 1(항목 3)·My Tag 분류 1 + 태그 2·메뉴 3·카테고리 2·정렬 2
    static func sample() throws -> OneLibraryFixture {
        let fixture = try OneLibraryFixture()
        var first = OneLibraryTrackSpec(id: 1)
        first.titleForSearch = "시험 검색"
        first.subtitle = "시험 믹스"
        first.bpmx100 = 12850
        first.length = 245
        first.trackNo = 3
        first.discNo = 1
        first.artistID = 11
        first.remixerID = 12
        first.originalArtistID = 13
        first.composerID = 14
        first.lyricistArtistID = 0
        first.albumID = 21
        first.genreID = 31
        first.labelID = 41
        first.keyID = 51
        first.colorID = 2
        first.imageID = 61
        first.djComment = "시험 코멘트"
        first.rating = 4
        first.releaseYear = 2020
        first.releaseDate = "2020-05-06"
        first.dateCreated = "2026-01-01"
        first.dateAdded = "2026-01-02"
        first.fileSize = 7_654_321
        first.fileType = 5
        first.bitrate = 1411
        first.bitDepth = 24
        first.samplingRate = 48000
        first.isrc = "ZZ0000000001"
        first.djPlayCount = 7
        first.isHotCueAutoLoadOn = 1
        first.isKuvoDeliverStatusOn = 1
        first.kuvoDeliveryComment = "시험 전달"
        first.analysedBits = 3
        first.contentLink = 5
        first.hasModified = 1
        first.cueUpdateCount = .int(15)
        first.analysisDataUpdateCount = .int(2)
        first.informationUpdateCount = .int(9)
        try fixture.add(track: first)
        var second = OneLibraryTrackSpec(id: 2)
        second.title = nil
        second.subtitle = nil
        second.djComment = nil
        second.colorID = nil
        second.lyricistArtistID = nil
        try fixture.add(track: second)
        try fixture.add(track: OneLibraryTrackSpec(id: 3))

        try fixture.insert("artist", ["artist_id": .int(11), "name": .text("시험 아티스트"), "nameForSearch": .text("시험 검색")])
        try fixture.insert("artist", ["artist_id": .int(12), "name": .text("시험 리믹서"), "nameForSearch": .null])
        try fixture.insert("album", ["album_id": .int(21), "name": .text("시험 앨범"), "artist_id": .int(11), "image_id": .int(61),
                                     "isComplation": .int(1), "nameForSearch": .null])
        try fixture.insert("genre", ["genre_id": .int(31), "name": .text("시험 장르")])
        try fixture.insert("label", ["label_id": .int(41), "name": .text("시험 레이블")])
        try fixture.insert("key", ["key_id": .int(51), "name": .text("8A")])
        try fixture.insert("color", ["color_id": .int(2), "name": .text("Pink")])
        try fixture.insert("image", ["image_id": .int(61), "path": .text("/PIONEER/Artwork/00001/b61.jpg")])
        try fixture.add(playlist: 71, name: "시험 목록", sequenceNo: 2, imageID: 61, entries: [3, 1, 2])
        try fixture.add(playlist: 70, name: "시험 폴더", attribute: 1, sequenceNo: 1)
        try fixture.add(myTag: 5_000_000_001, name: "시험 분류", sequenceNo: 0, isCategory: true)
        try fixture.add(myTag: 5_000_000_003, name: "시험 태그 2", parentID: 5_000_000_001, sequenceNo: 1)
        try fixture.add(myTag: 5_000_000_002, name: "시험 태그 1", parentID: 5_000_000_001, sequenceNo: 0)
        try fixture.link(myTag: 5_000_000_002, content: 2)
        try fixture.link(myTag: 5_000_000_002, content: 1)
        try fixture.add(menuItem: 1, kind: 257, name: "\u{FFFA}시험 메뉴 1\u{FFFB}")
        try fixture.add(menuItem: 2, kind: 258, name: "시험 메뉴 2")
        try fixture.add(menuItem: 3, kind: 259, name: "\u{FFFA}시험 메뉴 3\u{FFFB}")
        try fixture.add(category: 1, menuItemID: 1, sequenceNo: 1)
        try fixture.add(category: 2, menuItemID: 2, sequenceNo: 2, isVisible: false)
        try fixture.add(sort: 1, menuItemID: 1, sequenceNo: 1, isSelectedAsSubColumn: true)
        try fixture.add(sort: 2, menuItemID: 3, sequenceNo: 2, isVisible: false)
        try fixture.setProperty(deviceName: "", numberOfContents: 3, createdDate: "2026-01-02", myTagMasterDBID: 123_456)
        return fixture
    }

    @Test func readsTracksPlaylistsTagsMenus() throws {
        let fixture = try Self.sample()
        let library = try OneLibraryReader.read(copyAt: fixture.url)
        #expect(library.formats == [.oneLibrary])
        #expect(library.tracks.map(\.id) == [1, 2, 3])

        let expected = UsbTrack(
            id: 1, presentIn: [.oneLibrary], title: "시험 곡 1", titleForSearch: "시험 검색", subtitle: "시험 믹스",
            bpmx100: 12850, lengthSeconds: 245, trackNo: 3, discNo: 1,
            artistID: 11, remixerID: 12, originalArtistID: 13, composerID: 14, lyricistArtistID: 0, lyricist: "",
            albumID: 21, genreID: 31, labelID: 41, keyID: 51, colorID: 2, imageID: 61,
            comment: "시험 코멘트", rating: 4, releaseYear: 2020, releaseDate: "2020-05-06", dateCreated: "2026-01-01", dateAdded: "2026-01-02",
            path: "/Contents/시험 아티스트/시험 앨범/test1.mp3", fileName: "test1.mp3", fileSize: 7_654_321, fileType: 5,
            bitrate: 1411, bitDepth: 24, sampleRate: 48000, isrc: "ZZ0000000001", djPlayCount: 7,
            hotCueAutoLoad: true, kuvoDeliver: true, kuvoDeliveryComment: "시험 전달",
            masterDbId: 1_000_001, masterContentId: 900_001, analysisDataPath: "/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT",
            analysedBits: 3, contentLink: 5, hasModified: 1,
            cueUpdateCount: "15", analysisDataUpdateCount: "2", informationUpdateCount: "9",
            deviceFields: [.oneLibrary: UsbTrackDeviceFields(rating: 4, playCount: 7, hasModified: 1)])
        #expect(library.tracks[0] == expected)

        // NULL 글자 칸은 "", 색 NULL은 0, 참조 NULL은 nil
        let second = library.tracks[1]
        #expect(second.title == "" && second.subtitle == "" && second.comment == "")
        #expect(second.colorID == 0)
        #expect(second.artistID == nil && second.lyricistArtistID == nil && second.imageID == nil)
        #expect(second.titleForSearch == nil)

        #expect(library.artists == [UsbNamedRow(id: 11, name: "시험 아티스트", nameForSearch: "시험 검색"),
                                    UsbNamedRow(id: 12, name: "시험 리믹서", nameForSearch: nil)])
        #expect(library.albums == [UsbAlbum(id: 21, name: "시험 앨범", artistID: 11, imageID: 61, isCompilation: 1, nameForSearch: nil)])
        #expect(library.genres == [UsbNamedRow(id: 31, name: "시험 장르")])
        #expect(library.labels == [UsbNamedRow(id: 41, name: "시험 레이블")])
        #expect(library.keys == [UsbNamedRow(id: 51, name: "8A")])
        #expect(library.colors == [UsbNamedRow(id: 2, name: "Pink")])
        #expect(library.images == [UsbImage(id: 61, oneLibraryPath: "/PIONEER/Artwork/00001/b61.jpg", pdbPath: nil)])

        #expect(library.playlists == [
            UsbPlaylist(id: 70, name: "시험 폴더", parentID: 0, attribute: 1, imageID: nil, presentIn: [.oneLibrary],
                        sortOrder: [.oneLibrary: 1], entries: [.oneLibrary: []]),
            UsbPlaylist(id: 71, name: "시험 목록", parentID: 0, attribute: 0, imageID: 61, presentIn: [.oneLibrary],
                        sortOrder: [.oneLibrary: 2], entries: [.oneLibrary: [3, 1, 2]]),
        ])
        #expect(library.myTags == [
            UsbMyTag(id: 5_000_000_001, parentID: 0, sequenceNo: 0, name: "시험 분류", isCategory: true),
            UsbMyTag(id: 5_000_000_002, parentID: 5_000_000_001, sequenceNo: 0, name: "시험 태그 1", isCategory: false),
            UsbMyTag(id: 5_000_000_003, parentID: 5_000_000_001, sequenceNo: 1, name: "시험 태그 2", isCategory: false),
        ])
        #expect(library.myTagLinks == [UsbMyTagLink(myTagID: 5_000_000_002, contentID: 1, presentIn: [.oneLibrary]),
                                       UsbMyTagLink(myTagID: 5_000_000_002, contentID: 2, presentIn: [.oneLibrary])])
        #expect(library.menuItems.map(\.kind) == [257, 258, 259])
        #expect(library.categories == [UsbCategory(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, infoOrder: nil, disable: nil),
                                       UsbCategory(id: 2, menuItemID: 2, sequenceNo: 2, isVisible: false, infoOrder: nil, disable: nil)])
        #expect(library.sorts == [UsbSort(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, isSelectedAsSubColumn: true, disable: nil),
                                  UsbSort(id: 2, menuItemID: 3, sequenceNo: 2, isVisible: false, isSelectedAsSubColumn: false, disable: nil)])
        #expect(library.property == UsbProperty(deviceName: "", dbVersion: "1000", numberOfContents: 3, createdDate: "2026-01-02",
                                                backgroundColorType: 0, myTagMasterDBID: 123_456, pdbDate: nil, pdbDeviceName: nil))
        #expect(library.histories.isEmpty && library.unknownRows.isEmpty)
        #expect(library.deadIDs.isEmpty && library.trackRowExtras.isEmpty)

        // 한 형식 리더의 모델은 그 형식 투영과 같다
        #expect(library.projected(to: .oneLibrary) == library)
        // 두 번 읽어도 같다
        #expect(try OneLibraryReader.read(copyAt: fixture.url) == library)
    }

    @Test func reads64BitIDs() throws {
        let fixture = try OneLibraryFixture()
        var track = OneLibraryTrackSpec(id: 1)
        track.masterDbId = 3_000_000_000
        track.masterContentId = 3_000_000_001
        try fixture.add(track: track)
        try fixture.add(myTag: 5_000_000_001, name: "시험 분류", isCategory: true)
        try fixture.add(myTag: 5_000_000_002, name: "시험 태그", parentID: 5_000_000_001)
        try fixture.link(myTag: 5_000_000_002, content: 1)
        try fixture.setProperty(numberOfContents: 1, myTagMasterDBID: 4_000_000_000)
        let library = try OneLibraryReader.read(copyAt: fixture.url)
        #expect(library.tracks[0].masterDbId == 3_000_000_000)
        #expect(library.tracks[0].masterContentId == 3_000_000_001)
        #expect(library.myTags.map(\.id) == [5_000_000_001, 5_000_000_002])
        #expect(library.myTags[1].parentID == 5_000_000_001)
        #expect(library.myTagLinks.first?.myTagID == 5_000_000_002)
        #expect(library.property.myTagMasterDBID == 4_000_000_000)
    }

    @Test func updateCountTypes() throws {
        let fixture = try OneLibraryFixture()
        var track = OneLibraryTrackSpec(id: 1)
        track.cueUpdateCount = .int(15)
        track.analysisDataUpdateCount = .text("")
        track.informationUpdateCount = .null
        try fixture.add(track: track)
        // integer 칸에 TEXT ''가 그대로 남는지(칸 자료형 친화성)
        #expect(try fixture.rows("SELECT typeof(cueUpdateCount) AS c, typeof(analysisDataUpdateCount) AS a FROM content")
            == [["c": "integer", "a": "text"]])
        let library = try OneLibraryReader.read(copyAt: fixture.url)
        #expect(library.tracks[0].cueUpdateCount == "15")
        #expect(library.tracks[0].analysisDataUpdateCount == "")
        #expect(library.tracks[0].informationUpdateCount == "")
    }

    @Test func menuNameUnwrapsFFFA() throws {
        let fixture = try OneLibraryFixture()
        try fixture.add(menuItem: 1, kind: 257, name: "\u{FFFA}시험 메뉴\u{FFFB}")
        try fixture.add(menuItem: 2, kind: 258, name: "평범한 메뉴")
        let library = try OneLibraryReader.read(copyAt: fixture.url)
        #expect(library.menuItems == [UsbMenuItem(id: 1, kind: 257, name: "시험 메뉴"), UsbMenuItem(id: 2, kind: 258, name: "평범한 메뉴")])
    }

    @Test func rollbackHeaderFileReads() throws {
        let fixture = try OneLibraryFixture(journalMode: .delete)
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        #expect(try fixture.rows("PRAGMA journal_mode") == [["journal_mode": "delete"]])
        let library = try OneLibraryReader.read(copyAt: fixture.url)
        #expect(library.tracks.map(\.id) == [1])
    }

    @Test func historiesAndUnmodeledRows() throws {
        let fixture = try OneLibraryFixture()
        try fixture.add(track: OneLibraryTrackSpec(id: 1))
        try fixture.add(track: OneLibraryTrackSpec(id: 2))
        try fixture.insert("history", ["history_id": .int(1), "sequenceNo": .int(1), "name": .text("시험 기록"), "attribute": .int(0),
                                       "history_id_parent": .int(0)])
        try fixture.insert("history_content", ["history_id": .int(1), "content_id": .int(2), "sequenceNo": .int(2)])
        try fixture.insert("history_content", ["history_id": .int(1), "content_id": .int(1), "sequenceNo": .int(1)])
        // 모델에 담지 않는 표에 행이 있으면 수만 남긴다(쓸 때 조용히 지우지 않게)
        try fixture.insert("cue", ["cue_id": .int(1), "content_id": .int(1), "kind": .int(0)])
        try fixture.insert("recommendedLike", ["content_id_1": .int(1), "content_id_2": .int(2), "rating": .int(1), "createdDate": .int(0)])
        try fixture.insert("recommendedLike", ["content_id_1": .int(2), "content_id_2": .int(1), "rating": .int(1), "createdDate": .int(0)])
        let library = try OneLibraryReader.read(copyAt: fixture.url)
        #expect(library.histories == [UsbHistory(format: .oneLibrary, id: 1, name: "시험 기록", entries: [1, 2])])
        let tables = OneLibrarySchema.tables.map(\.name)
        #expect(library.unknownRows == [
            UsbUnknownRows(format: .oneLibrary, file: "exportLibrary.db", tableType: tables.firstIndex(of: "cue")!, liveRows: 1),
            UsbUnknownRows(format: .oneLibrary, file: "exportLibrary.db", tableType: tables.firstIndex(of: "recommendedLike")!, liveRows: 2),
        ])
    }

    @Test func unsupportedSchemaIsRefused() throws {
        let fixture = try OneLibraryFixture()
        try fixture.setProperty(dbVersion: "1001")
        let error = #expect(throws: UsbError.self) { try OneLibraryReader.read(copyAt: fixture.url) }
        if let error, case .formatUnsupported = error {} else { Issue.record("formatUnsupported가 아님") }
    }
}
