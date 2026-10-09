import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 외부 파서(rekordcrate·pyrekordbox) 대조용 합성 USB를 폴더에 쓴다(#189). `DJC_USB_PARSER_FIXTURE=<임시 폴더>`일 때만 돈다.
/// - basic: 기본 `UsbLibraryFixture`
/// - hard: 리더가 견뎌야 할 모양(284행 쪽·멀쩡한 복제인 죽은 행·먼 모양·긴 ASCII·ISRC 특수형·七로 시작하는 UTF-16·NULL 칸·2³¹ 넘는 ID 등)
/// - fartag: rekordbox로 확인하지 못한 먼 모양 My Tag 행 하나(Deep Symmetry 문서의 자리)
/// - written: basic을 DJCrate 작성기(`PdbWriter`·`OneLibraryWriter`)로 다시 쓴 것
/// 모든 값은 지어낸 것이다.
@Suite struct UsbParserFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_USB_PARSER_FIXTURE"] != nil))
    func capture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_USB_PARSER_FIXTURE"] else { return }
        let base = URL(filePath: path)
        try UsbLibraryFixture().write(to: UsbTreeFixture(base: base.appending(path: "basic")))

        let hard = UsbTreeFixture(base: base.appending(path: "hard"))
        hard.write(UsbLayout.exportPdb, Self.hardExport())
        hard.write(UsbLayout.exportExtPdb, Self.hardExportExt(farTag: false))
        hard.write(UsbLayout.oneLibrary, try Self.hardOneLibrary())

        let farTag = UsbTreeFixture(base: base.appending(path: "fartag"))
        var export = PdbBuilder(kind: .export)
        export.add(.tracks, PdbBuilder.trackRow(PdbTrackSpec(id: 1)))
        export.add(.history19, PdbBuilder.propertyRow(count: 1, date: "2026-01-03"))
        farTag.write(UsbLayout.exportPdb, export.build().data)
        farTag.write(UsbLayout.exportExtPdb, Self.hardExportExt(farTag: true))

        var plain = UsbLibraryFixture()
        plain.myTagLinks = []
        let source = UsbTreeFixture(), copy = UsbTreeFixture()
        defer {
            source.remove()
            copy.remove()
        }
        try plain.write(to: source)
        let snapshot = try UsbSnapshot.take(root: source.root, into: copy.base.appending(path: "copy"))
        let oneLibrary = try OneLibraryReader.read(copyAt: try #require(snapshot.oneLibrary))
        let deviceLibrary = try #require(try PdbReader.read(snapshot: snapshot)).0
        let model = UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary).0
        let written = UsbTreeFixture(base: base.appending(path: "written"))
        let files = try PdbWriter.files(model, mode: .fresh)
        written.write(UsbLayout.exportPdb, files.export)
        written.write(UsbLayout.exportExtPdb, files.exportExt)
        try OneLibraryWriter.create(model, at: written.url(UsbLayout.oneLibrary))
    }

    /// 284행(12바이트 행) 쪽, 죽은 복제, 먼 모양 아티스트·앨범, 긴 ASCII(0x40), ISRC 특수형, 七(U+4E03)로 시작하는 UTF-16,
    /// 모르는 file_type, 숨김·보조 칸 메뉴, 기록 표, 모르는 표 행
    static func hardExport() -> Data {
        var builder = PdbBuilder(kind: .export)
        var first = PdbTrackSpec(id: 1)
        (first.artistID, first.albumID, first.genreID, first.keyID, first.labelID, first.artworkID) = (1, 1, 1, 1, 1, 1)
        (first.composerID, first.remixerID, first.originalArtistID) = (2, 3, 4)
        (first.colorID, first.rating, first.playCount, first.year, first.discNo, first.trackNo) = (1, 3, 2, 2025, 1, 4)
        var second = PdbTrackSpec(id: 2)
        second[.title] = "七つの海"
        second[.comment] = "コメント"
        second[.lyricist] = "작사가"
        second[.mixName] = "Extended Mix"
        second[.isrc] = "JPXX02600001"
        second.isrcSpecial = true
        second[.kuvoPublic] = "ON"
        second[.autoloadHotcues] = ""
        (second[.message], second[.unknown8], second[.unknown9], second[.unknown13], second[.unknown18]) = ("m", "x", "y", "z", "w")
        (second.fileType, second.colorID, second.rating, second.artistID, second.albumID, second.artworkID) = (5, 8, 5, 3, 2, 2)
        second.masterDbId = 3_000_000_000
        var third = PdbTrackSpec(id: 3)
        third[.title] = "ascii title"
        third.fileType = 0x0B
        var thirdRow = PdbBuilder.trackRow(third)
        // 코멘트를 긴 ASCII(0x40)로: 행 끝에 붙이고 문자열 16번 오프셋을 옮긴다
        let longComment = Data(String(repeating: "long ascii comment ", count: 8).utf8)
        let offset = thirdRow.bytes.count
        thirdRow.bytes.append(contentsOf: [0x40, UInt8((longComment.count + 4) & 0xFF), UInt8((longComment.count + 4) >> 8), 0])
        thirdRow.bytes.append(longComment)
        thirdRow.bytes[0x5E + 2 * 16] = UInt8(offset & 0xFF)
        thirdRow.bytes[0x5E + 2 * 16 + 1] = UInt8(offset >> 8)
        var fifth = PdbTrackSpec(id: 5)
        fifth[.title] = "🎵 곡"
        fifth[.filePath] = "/Contents/e\u{301}/test5.mp3"
        fifth.fileType = 2
        var sixth = PdbTrackSpec(id: 6)
        sixth[.autoloadHotcues] = ""
        sixth[.dateCreated] = ""
        sixth[.dateAdded] = ""
        var dead = PdbBuilder.trackRow(first)
        dead.live = false
        for row in [PdbBuilder.trackRow(first), dead, PdbBuilder.trackRow(second), thirdRow, PdbBuilder.trackRow(fifth), PdbBuilder.trackRow(sixth)] {
            builder.add(.tracks, row)
        }
        builder.add(.genres, PdbBuilder.idNameRow(1, "House"))
        var deadGenre = PdbBuilder.idNameRow(9, "지운 장르")
        deadGenre.live = false
        builder.add(.genres, deadGenre)
        builder.add(.genres, PdbBuilder.idNameRow(2, "하우스"))
        builder.add(.labels, PdbBuilder.idNameRow(1, "Label A"))
        builder.add(.artists, PdbBuilder.artistRow(1, "Artist"))
        builder.add(.artists, PdbBuilder.artistRow(2, "먼 아티스트", far: true))
        builder.add(.artists, PdbBuilder.artistRow(3, "七 아티스트"))
        builder.add(.artists, PdbBuilder.artistRow(4, "A4"))
        builder.add(.albums, PdbBuilder.albumRow(1, "Album", artistID: 1))
        builder.add(.albums, PdbBuilder.albumRow(2, "먼 앨범", artistID: 2, far: true))
        builder.add(.keys, PdbBuilder.keyRow(1, "Am"))
        builder.add(.keys, PdbBuilder.keyRow(2, "8A"))
        for (index, name) in ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"].enumerated() {
            builder.add(.colors, PdbBuilder.colorRow(index + 1, name))
        }
        builder.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 10, name: "목록 A", sortOrder: 0))
        builder.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 11, name: "폴더", sortOrder: 1, isFolder: true))
        builder.add(.playlistTree, PdbBuilder.playlistTreeRow(id: 12, name: "七 목록", parentID: 11, sortOrder: 0))
        let cycle = [1, 2, 3, 5, 6]
        for index in 0..<300 {
            builder.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: index + 1, trackID: cycle[index % cycle.count], playlistID: 10))
        }
        builder.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: 2, trackID: 1, playlistID: 12))
        builder.add(.playlistEntries, PdbBuilder.playlistEntryRow(index: 1, trackID: 2, playlistID: 12))
        builder.add(.historyPlaylists, PdbBuilder.idNameRow(1, "HISTORY 001"))
        builder.add(.historyEntries, PdbBuilder.historyEntryRow(trackID: 2, playlistID: 1, index: 1))
        builder.add(.historyEntries, PdbBuilder.historyEntryRow(trackID: 1, playlistID: 1, index: 2))
        builder.add(.artwork, PdbBuilder.idNameRow(1, "/PIONEER/Artwork/00001/a1.jpg"))
        builder.add(.artwork, PdbBuilder.idNameRow(2, "/PIONEER/Artwork/00001/a2.jpg"))
        builder.add(.columns, PdbBuilder.columnRow(id: 1, code: 0x80, name: "GENRE"))
        builder.add(.columns, PdbBuilder.columnRow(id: 2, code: 0x81, name: "ARTIST"))
        builder.add(.columns, PdbBuilder.columnRow(id: 3, code: 0x8E, name: "七"))
        builder.add(.category, PdbBuilder.categoryRow(id: 1, menuItemID: 1, infoOrder: 1, disable: 0, sequence: 1))
        builder.add(.category, PdbBuilder.categoryRow(id: 2, menuItemID: 2, infoOrder: 2, disable: 1, sequence: 2))
        builder.add(.category, PdbBuilder.categoryRow(id: 3, menuItemID: 3, infoOrder: 0, disable: 2, sequence: 3))
        builder.add(.sort, PdbBuilder.sortRow(id: 1, menuItemID: 1, disable: 0, sequence: 1))
        builder.add(.sort, PdbBuilder.sortRow(id: 2, menuItemID: 2, disable: 2, sequence: 2))
        builder.add(.sort, PdbBuilder.sortRow(id: 3, menuItemID: 3, disable: 1, sequence: 3))
        builder.add(PdbTableType.unknown9.rawValue, PdbBuilder.opaqueRow())
        builder.add(.history19, PdbBuilder.propertyRow(count: 5, date: "2026-01-03", name: "USB"))
        return builder.build().data
    }

    /// 분류·태그·2³¹ 넘는 태그 id·태그 연결·myTagMasterDBID. `farTag`면 확인 안 된 먼 모양 태그 행만 더한다
    static func hardExportExt(farTag: Bool) -> Data {
        var builder = PdbBuilder(kind: .exportExt)
        builder.add(.tags, PdbBuilder.tagRow(id: 7, name: "분류", position: 0, isCategory: true))
        if farTag {
            builder.add(.tags, PdbBuilder.tagRow(id: 9, name: "먼 태그", parentID: 7, position: 0, isCategory: false, far: true))
        } else {
            builder.add(.tags, PdbBuilder.tagRow(id: 8, name: "태그", parentID: 7, position: 0, isCategory: false))
            builder.add(.tags, PdbBuilder.tagRow(id: 3_000_000_000, name: "七 태그", parentID: 7, position: 1, isCategory: false))
            builder.add(.tagTracks, PdbBuilder.tagTrackRow(trackID: 1, tagID: 8))
            builder.add(.tagTracks, PdbBuilder.tagTrackRow(trackID: 2, tagID: 3_000_000_000))
        }
        builder.add(.myTagProperty, PdbBuilder.myTagPropertyRow(masterDBID: 3_500_000_000))
        return builder.build().data
    }

    /// NULL 칸, TEXT ''·NULL·INTEGER 갱신 횟수, 2³¹ 넘는 ID, 감싼·감싸지 않은 메뉴 이름, 순서가 뒤바뀌고 같은 곡이 두 번 든 목록 항목, 기록,
    /// 모델에 담지 않는 표 행
    static func hardOneLibrary() throws -> Data {
        let fixture = try OneLibraryFixture(journalMode: .delete)
        var first = OneLibraryTrackSpec(id: 1)
        (first.artistID, first.albumID, first.genreID, first.labelID, first.keyID, first.colorID, first.imageID) = (1, 1, 1, 1, 1, 1, 1)
        (first.rating, first.djPlayCount, first.trackNo, first.discNo, first.releaseYear) = (3, 2, 4, 1, 2025)
        try fixture.add(track: first)
        var second = OneLibraryTrackSpec(id: 2)
        second.title = "七つの海"
        second.titleForSearch = "ナナツノウミ"
        (second.subtitle, second.djComment, second.releaseDate, second.isrc, second.kuvoDeliveryComment) = (nil, nil, nil, nil, nil)
        (second.lyricistArtistID, second.colorID) = (nil, nil)
        second.cueUpdateCount = .text("")
        second.analysisDataUpdateCount = .null
        second.informationUpdateCount = .int(5)
        second.masterDbId = 3_000_000_000
        (second.isKuvoDeliverStatusOn, second.isHotCueAutoLoadOn, second.hasModified) = (1, 0, 1)
        (second.contentLink, second.analysedBits, second.fileType) = (0x1C0700, 105, 5)
        try fixture.add(track: second)
        var third = OneLibraryTrackSpec(id: 3)
        third.title = nil
        third.path = "/Contents/e\u{301}/test3.mp3"
        third.releaseDate = "2026-02-03"
        third.dateCreated = nil
        try fixture.add(track: third)
        try fixture.insert("artist", ["artist_id": .int(1), "name": .text("Artist"), "nameForSearch": .text("artist")])
        try fixture.insert("artist", ["artist_id": .int(2), "name": .text("먼 아티스트"), "nameForSearch": .null])
        try fixture.insert("album", ["album_id": .int(1), "name": .text("Album"), "artist_id": .int(1), "image_id": .int(1),
                                     "isComplation": .int(1), "nameForSearch": .text("album")])
        try fixture.insert("album", ["album_id": .int(2), "name": .null, "artist_id": .null, "image_id": .null,
                                     "isComplation": .null, "nameForSearch": .null])
        try fixture.insert("genre", ["genre_id": .int(1), "name": .text("House")])
        try fixture.insert("key", ["key_id": .int(1), "name": .text("Am")])
        try fixture.insert("label", ["label_id": .int(1), "name": .text("Label A")])
        try fixture.insert("color", ["color_id": .int(1), "name": .text("Pink")])
        try fixture.insert("image", ["image_id": .int(1), "path": .text("/PIONEER/Artwork/00001/b1.jpg")])
        try fixture.add(playlist: 10, name: "목록 A", sequenceNo: 1)
        // 넣은 순서와 sequenceNo 순서가 다르고, 같은 곡이 두 번 든다
        for (content, sequence) in [(3, 2), (1, 1), (2, 3), (1, 4)] {
            try fixture.insert("playlist_content", ["playlist_id": .int(10), "content_id": .int(content), "sequenceNo": .int(sequence)])
        }
        try fixture.add(playlist: 11, name: "폴더", attribute: 1, sequenceNo: 2)
        try fixture.add(playlist: 12, name: "七 목록", parentID: 11, sequenceNo: 1, imageID: 1, entries: [2])
        try fixture.add(myTag: 7, name: "분류", isCategory: true)
        try fixture.add(myTag: 8, name: "태그", parentID: 7)
        try fixture.add(myTag: 3_000_000_000, name: "七 태그", parentID: 7, sequenceNo: 1)
        try fixture.link(myTag: 8, content: 1)
        try fixture.link(myTag: 3_000_000_000, content: 2)
        try fixture.add(menuItem: 1, kind: 0x80, name: "\u{FFFA}GENRE\u{FFFB}")
        try fixture.add(menuItem: 2, kind: 0x81, name: "ARTIST")
        try fixture.add(category: 1, menuItemID: 1, sequenceNo: 1)
        try fixture.add(category: 2, menuItemID: 2, sequenceNo: 2, isVisible: false)
        try fixture.add(sort: 1, menuItemID: 1, sequenceNo: 1)
        try fixture.add(sort: 2, menuItemID: 2, sequenceNo: 2, isVisible: true, isSelectedAsSubColumn: true)
        try fixture.insert("history", ["history_id": .int(1), "sequenceNo": .int(1), "name": .text("HISTORY 001"), "attribute": .int(0),
                                       "history_id_parent": .int(0)])
        for (content, sequence) in [(1, 2), (2, 1)] {
            try fixture.insert("history_content", ["history_id": .int(1), "content_id": .int(content), "sequenceNo": .int(sequence)])
        }
        try fixture.insert("cue", ["cue_id": .int(1), "content_id": .int(1), "kind": .int(1)])
        try fixture.insert("recommendedLike", ["content_id_1": .int(1), "content_id_2": .int(2), "rating": .int(1)])
        try fixture.setProperty(deviceName: "USB", numberOfContents: 3, createdDate: "2026-01-02", backgroundColorType: 2,
                                myTagMasterDBID: 3_500_000_000)
        fixture.close()
        return try Data(contentsOf: fixture.url)
    }
}
