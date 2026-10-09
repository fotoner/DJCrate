import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 로컬 스냅샷 사본에서 USB 라이브러리를 만들 재료를 읽는다. 모든 값은 지어낸 것이다.
@Suite("USB 작성용 로컬 읽기")
struct UsbLocalSourceTests {
    func source(_ fixture: RekordboxFixture) throws -> UsbLocalSource {
        UsbLocalSource(database: try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive()))
    }

    @Test("곡 칸을 그대로 옮기고 이름을 조인한다(NULL → nil)")
    func trackRowColumnsAndJoins() throws {
        let fixture = try RekordboxFixture()
        try fixture.addArtist(id: "11", name: "시험 아티스트")
        try fixture.addArtist(id: "12", name: "시험 리믹서")
        try fixture.addArtist(id: "13", name: "시험 원곡자")
        try fixture.addArtist(id: "14", name: "시험 작곡가")
        try fixture.addArtist(id: "15", name: "시험 앨범 아티스트")
        try fixture.addAlbum(id: "21", name: "시험 앨범", albumArtistID: "15", compilation: 1)
        try fixture.addGenre(id: "31", name: "시험 장르")
        try fixture.addLabel(id: "41", name: "시험 레이블")
        try fixture.addKey(id: "51", scaleName: "8A")
        var track = TrackSpec(id: "101")
        track.title = "시험 제목"
        track.artistID = "11"
        track.albumID = "21"
        track.composerID = "14"
        track.bpm100 = 12850
        track.length = 245
        track.cueUpdated = "7"
        track.analysisUpdated = "2"
        track.trackInfoUpdated = ""
        track.analysisDataPath = "/PIONEER/USBANLZ/x/y/ANLZ0000.DAT"
        track.imagePath = "/PIONEER/Artwork/0/a/artwork.jpg"
        track.folderPath = "/tmp/djc-none/시험.mp3"
        try fixture.add(track)
        try fixture.setContent(track: track, [
            "Subtitle": .text("시험 믹스"), "TrackNo": .int(3), "DiscNo": .int(1), "RemixerID": .text("12"), "OrgArtistID": .text("13"),
            "Lyricist": .text("시험 작사"), "GenreID": .text("31"), "LabelID": .text("41"), "KeyID": .text("51"), "ColorID": .text("2"),
            "Commnt": .text("시험 코멘트"), "Rating": .int(4), "ReleaseYear": .int(2020), "ReleaseDate": .text("2020-05-06"),
            "DateCreated": .text("2026-01-01"), "StockDate": .text("2026-01-02"), "FileNameL": .text("시험.mp3"),
            "FileSize": .int(7_654_321), "BitDepth": .int(16), "SampleRate": .int(44100), "ISRC": .text("ZZ0000000001"),
            "DJPlayCount": .int(9), "HotCueAutoLoad": .text("on"), "DeliveryControl": .text("ON"), "DeliveryComment": .text("시험 전달"),
            "MasterDBID": .text("424242"), "MasterSongID": .text("777"), "ContentLink": .int(0x100003),
        ])

        let row = try source(fixture).track("101")
        #expect(row.id == "101")
        #expect(row.title == "시험 제목")
        #expect(row.subtitle == "시험 믹스")
        #expect(row.bpm == 12850)
        #expect(row.length == 245)
        #expect(row.trackNo == 3)
        #expect(row.discNo == 1)
        #expect(row.artistID == "11")
        #expect(row.artistName == "시험 아티스트")
        #expect(row.remixerID == "12")
        #expect(row.remixerName == "시험 리믹서")
        #expect(row.orgArtistID == "13")
        #expect(row.orgArtistName == "시험 원곡자")
        #expect(row.composerID == "14")
        #expect(row.composerName == "시험 작곡가")
        #expect(row.lyricist == "시험 작사")
        #expect(row.albumID == "21")
        #expect(row.albumName == "시험 앨범")
        #expect(row.albumArtistID == "15")
        #expect(row.albumArtistName == "시험 앨범 아티스트")
        #expect(row.albumCompilation == 1)
        #expect(row.genreID == "31")
        #expect(row.genreName == "시험 장르")
        #expect(row.labelID == "41")
        #expect(row.labelName == "시험 레이블")
        #expect(row.keyID == "51")
        #expect(row.keyName == "8A")
        #expect(row.colorID == "2")
        #expect(row.comment == "시험 코멘트")
        #expect(row.rating == 4)
        #expect(row.releaseYear == 2020)
        #expect(row.releaseDate == "2020-05-06")
        #expect(row.dateCreated == "2026-01-01")
        #expect(row.stockDate == "2026-01-02")
        #expect(row.folderPath == "/tmp/djc-none/시험.mp3")
        #expect(row.fileNameL == "시험.mp3")
        #expect(row.fileSize == 7_654_321)
        #expect(row.fileType == 1)
        #expect(row.bitRate == 320)
        #expect(row.bitDepth == 16)
        #expect(row.sampleRate == 44100)
        #expect(row.isrc == "ZZ0000000001")
        #expect(row.djPlayCount == 9)
        #expect(row.hotCueAutoLoad == "on")
        #expect(row.deliveryControl == "ON")
        #expect(row.deliveryComment == "시험 전달")
        #expect(row.masterDBID == "424242")
        #expect(row.masterSongID == "777")
        #expect(row.analysisDataPath == "/PIONEER/USBANLZ/x/y/ANLZ0000.DAT")
        #expect(row.imagePath == "/PIONEER/Artwork/0/a/artwork.jpg")
        #expect(row.analysed == 105)
        #expect(row.contentLink == 0x100003)
        #expect(row.cueUpdated == "7")
        #expect(row.analysisUpdated == "2")
        #expect(row.trackInfoUpdated == "")

        // 비어 있는 칸은 nil(조인할 행이 없으면 이름도 nil)
        var bare = TrackSpec(id: "102")
        bare.cueUpdated = nil
        try fixture.add(bare)
        try fixture.setContent(track: bare, ["Title": .null, "BPM": .null, "Rating": .null, "ArtistID": .text("999")])
        let empty = try source(fixture).track("102")
        #expect(empty.title == nil)
        #expect(empty.bpm == nil)
        #expect(empty.rating == nil)
        #expect(empty.subtitle == nil)
        #expect(empty.artistID == "999")
        #expect(empty.artistName == nil)
        #expect(empty.albumID == nil)
        #expect(empty.albumName == nil)
        #expect(empty.albumArtistID == nil)
        #expect(empty.cueUpdated == nil)
        #expect(empty.masterSongID == nil)
    }

    @Test("지운 곡·없는 곡은 던진다")
    func deletedTrackThrows() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec(id: "201"))
        try fixture.setContent(track: track, ["rb_local_deleted": .int(1)])
        let local = try source(fixture)
        // 스냅샷 문제라 USB를 다시 연결하라는 읽기 실패가 아니라 막힘으로 알린다
        #expect(usbRefusedCodes { _ = try local.track("201") } == ["localTrackMissing"])
        #expect(usbRefusedCodes { _ = try local.track("202") } == ["localTrackMissing"])
    }

    @Test("색은 지우지 않은 8개 전부, name = Commnt")
    func colorsAll8() throws {
        let fixture = try RekordboxFixture()
        try fixture.addColorDefaults()
        try fixture.insert("djmdColor", ["ID": .text("9"), "Commnt": .text("지운 색"), "rb_local_deleted": .int(1)])
        let colors = try source(fixture).colors()
        #expect(colors.count == 8)
        #expect(colors.map(\.id) == Array(1...8))
        #expect(colors.map(\.name) == RekordboxFixture.defaultColorNames)
        #expect(colors.allSatisfy { $0.nameForSearch == nil })
    }

    @Test("메뉴 kind = Class + 256, 이름 그대로")
    func menuKindClassPlus256() throws {
        let fixture = try RekordboxFixture()
        try fixture.addMenuDefaults()
        let items = try source(fixture).menuItems()
        #expect(items.count == RekordboxFixture.defaultMenuNames.count)
        #expect(items.first == UsbMenuItem(id: 1, kind: 257, name: "Genre"))
        #expect(items.map(\.kind) == items.map { $0.id + 256 })
        #expect(items.map(\.name) == RekordboxFixture.defaultMenuNames)
    }

    @Test("카테고리: 보임 = Disable ≠ 1, 순서 = Seq, 지운 행은 뺀다")
    func categoryVisibleDisableNot1_order() throws {
        let fixture = try RekordboxFixture()
        try fixture.addMenuDefaults()
        try fixture.addCategory(id: "3", menuItemID: "3", seq: 1, disable: 0, infoOrder: 2)
        try fixture.addCategory(id: "1", menuItemID: "1", seq: 3, disable: 1, infoOrder: 0)
        try fixture.addCategory(id: "2", menuItemID: "2", seq: 2, disable: nil)
        try fixture.addCategory(id: "4", menuItemID: "4", seq: 4, disable: 0, deleted: true)
        let categories = try source(fixture).categories()
        #expect(categories == [
            UsbCategory(id: 1, menuItemID: 1, sequenceNo: 3, isVisible: false, infoOrder: 0, disable: 1),
            UsbCategory(id: 2, menuItemID: 2, sequenceNo: 2, isVisible: true, infoOrder: nil, disable: nil),
            UsbCategory(id: 3, menuItemID: 3, sequenceNo: 1, isVisible: true, infoOrder: 2, disable: 0),
        ])
    }

    @Test("정렬: 지운 행은 빼고, 보조 칸 = Disable 2")
    func sortDropsDeleted_subColumnDisable2() throws {
        let fixture = try RekordboxFixture()
        try fixture.addMenuDefaults()
        try fixture.addSort(id: "0", menuItemID: "5", seq: 0, disable: 0)
        try fixture.addSort(id: "1", menuItemID: "1", seq: 1, disable: 1)
        try fixture.addSort(id: "2", menuItemID: "2", seq: 2, disable: 2)
        try fixture.addSort(id: "3", menuItemID: "3", seq: 3, disable: 0, deleted: true)
        let sorts = try source(fixture).sorts()
        #expect(sorts == [
            UsbSort(id: 0, menuItemID: 5, sequenceNo: 0, isVisible: true, isSelectedAsSubColumn: false, disable: 0),
            UsbSort(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: false, isSelectedAsSubColumn: false, disable: 1),
            UsbSort(id: 2, menuItemID: 2, sequenceNo: 2, isVisible: true, isSelectedAsSubColumn: true, disable: 2),
        ])
    }

    @Test("My Tag: 순서 = Seq − 1, 부모 root → 0, 지운 행은 뺀다, 64비트 ID")
    func myTagSeqMinusOneRootZero_deletedDropped() throws {
        let fixture = try RekordboxFixture()
        try fixture.addMyTag(id: "5000000001", name: "시험 분류", seq: 1, attribute: 1)
        try fixture.addMyTag(id: "5000000003", name: "시험 태그 2", seq: 2, attribute: 0, parentID: "5000000001")
        try fixture.addMyTag(id: "5000000002", name: "시험 태그 1", seq: 1, attribute: 0, parentID: "5000000001")
        try fixture.addMyTag(id: "5000000004", name: "지운 태그", seq: 3, attribute: 0, parentID: "5000000001", deleted: true)
        let tags = try source(fixture).myTags()
        #expect(tags == [
            UsbMyTag(id: 5_000_000_001, parentID: 0, sequenceNo: 0, name: "시험 분류", isCategory: true),
            UsbMyTag(id: 5_000_000_002, parentID: 5_000_000_001, sequenceNo: 0, name: "시험 태그 1", isCategory: false),
            UsbMyTag(id: 5_000_000_003, parentID: 5_000_000_001, sequenceNo: 1, name: "시험 태그 2", isCategory: false),
        ])
    }

    @Test("DBID는 64비트로 읽는다")
    func dbid64Bit() throws {
        let fixture = try RekordboxFixture()
        try fixture.setDBID("4000000123")
        #expect(try source(fixture).localDBID() == 4_000_000_123)
        try fixture.setDBID("abc")
        #expect(usbRefusedCodes { _ = try source(fixture).localDBID() } == ["localDBID"])
    }

    @Test("라이브 master.db면 읽지 않는다")
    func refusesLivePath() throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "301"))
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        // 공개 초기화는 라이브 경로를 바꿀 수 없다. 시험만 안쪽 초기화에 픽스처를 라이브 DB로 넘긴다
        let live = UsbLocalSource(database: db, liveDatabase: fixture.database)
        #expect(throws: UsbError.self) { try live.track("301") }
        #expect(throws: UsbError.self) { try live.colors() }
        #expect(throws: UsbError.self) { try live.menuItems() }
        #expect(throws: UsbError.self) { try live.categories() }
        #expect(throws: UsbError.self) { try live.sorts() }
        #expect(throws: UsbError.self) { try live.myTags() }
        #expect(throws: UsbError.self) { try live.localDBID() }
        #expect(try UsbLocalSource(database: db).track("301").id == "301")
    }
}

/// `UsbError.writeRefused`의 막힘 code들(다른 오류면 "other: …", 던지지 않으면 빈 배열)
func usbRefusedCodes(_ body: () throws -> Void) -> [String] {
    do {
        try body()
    } catch let UsbError.writeRefused(blocks) {
        return blocks.map(\.code)
    } catch {
        return ["other: \(error)"]
    }
    return []
}
