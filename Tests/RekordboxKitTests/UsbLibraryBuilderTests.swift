import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 로컬(합성 라이브러리) + 내보내기 계획 → 목표 USB 모델. 모든 값은 지어낸 것이다.
@Suite("USB 모델 빌더")
struct UsbLibraryBuilderTests {
    /// 지어낸 마스터 DB ID
    static let dbid = "424242"

    /// 음원·분석 파일 셋이 있는 곡(아트워크는 `artwork`면 작은·중간 그림)
    @discardableResult
    static func addTrack(_ fixture: RekordboxFixture, id: String, artist: String? = nil, album: String? = nil, composer: String? = nil,
                         fileName: String? = nil, artwork: Bool = true, bytes: Int = 300) throws -> TrackSpec {
        var track = TrackSpec(id: id)
        track.title = "시험 곡 \(id)"
        track.artistID = artist
        track.albumID = album
        track.composerID = composer
        // 음원 경로의 끝 성분 = FileNameL(USB 파일 이름은 경로 끝 성분으로 짓는다)
        track.folderPath = try fixture.writeAudio(named: "\(id)/" + (fileName ?? "\(id).mp3"), bytes: bytes).path
        try fixture.add(track)
        try fixture.setIdentity(track: track, masterSongID: "9\(id)", masterDBID: dbid, fileNameL: fileName ?? "\(id).mp3")
        try fixture.setFileSize(track: track, Int64(bytes))
        let path = "/PIONEER/USBANLZ/a\(id)/b\(id)/ANLZ0000.DAT"
        try fixture.setAnalysisPath(track: track, path)
        try fixture.writeLocalAnalysis(analysisPath: path, dat: Data(count: 10), ext: Data(count: 20), twoEx: Data(count: 30))
        if artwork {
            try fixture.writeArtwork(track: track, imagePath: "/PIONEER/Artwork/\(id)/artwork.jpg", small: Data(count: 11), medium: Data(count: 22))
        }
        return track
    }

    struct Built {
        var plan: UsbExportPlan
        var model: UsbExportModel
    }

    static func build(_ fixture: RekordboxFixture, ids: [String], playlists: [UsbPlaylistInput] = [],
                      formats: Set<UsbFormat> = UsbFormat.defaultSet, myTagMasterDBID: Int64 = 4_000_000_000) throws -> Built {
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let candidates = try UsbExportCandidates.load(database: db, share: fixture.shareRoot, contentIDs: ids)
        let plan = UsbExportPlanner.plan(UsbExportRequest(candidates: candidates, playlists: playlists, formats: formats,
                                                          snapshotTakenAt: .distantFuture))
        #expect(plan.blocked.isEmpty)
        let model = try UsbLibraryBuilder.build(plan: plan, formats: formats, local: UsbLocalSource(database: db), share: fixture.shareRoot,
                                                myTagMasterDBID: myTagMasterDBID, createdDate: "2026-09-01")
        return Built(plan: plan, model: model)
    }

    // MARK: - ID

    @Test("아티스트 번호: 곡 순서대로 곡 아티스트 → 앨범 아티스트 → 작곡가")
    func artistOrderTrackThenAlbumArtistThenComposer() throws {
        let fixture = try RekordboxFixture()
        for (id, name) in [("1", "A"), ("2", "B"), ("3", "C"), ("4", "D")] { try fixture.addArtist(id: id, name: "시험 \(name)") }
        try fixture.addAlbum(id: "30", name: "시험 앨범", albumArtistID: "3")
        try Self.addTrack(fixture, id: "101", artist: "1", album: "30", composer: "4")
        try Self.addTrack(fixture, id: "102", artist: "2")
        try Self.addTrack(fixture, id: "103", artist: "1", album: "30")
        let library = try Self.build(fixture, ids: ["101", "102", "103"]).model.library

        // 첫 곡: 곡 아티스트 A, 앨범 아티스트 C, 작곡가 D. 둘째 곡: B. 셋째 곡은 모두 이미 번호가 있다
        let order = ["시험 A", "시험 C", "시험 D", "시험 B"]
        #expect(library.artists == order.enumerated().map { UsbNamedRow(id: $0.offset + 1, name: $0.element, nameForSearch: nil) })
        let byName = Dictionary(uniqueKeysWithValues: library.artists.map { ($0.name, $0.id) })
        #expect(library.tracks.map(\.artistID) == [byName["시험 A"], byName["시험 B"], byName["시험 A"]])
        #expect(library.tracks[0].composerID == byName["시험 D"])
        #expect(library.albums == [UsbAlbum(id: 1, name: "시험 앨범", artistID: byName["시험 C"], imageID: nil, isCompilation: 0,
                                             nameForSearch: nil)])
        #expect(library.tracks.map(\.albumID) == [1, nil, 1])
    }

    @Test("앨범 아티스트가 NULL이나 빈 글자면 NULL")
    func albumArtistEmptyIsNull() throws {
        let fixture = try RekordboxFixture()
        try fixture.addArtist(id: "1", name: "시험 아티스트")
        try fixture.addAlbum(id: "30", name: "시험 앨범 1", albumArtistID: nil)
        try fixture.addAlbum(id: "31", name: "시험 앨범 2", albumArtistID: "", compilation: 1)
        try Self.addTrack(fixture, id: "101", artist: "1", album: "30")
        try Self.addTrack(fixture, id: "102", artist: "1", album: "31")
        let library = try Self.build(fixture, ids: ["101", "102"]).model.library
        #expect(library.albums.map(\.artistID) == [nil, nil])
        #expect(library.albums.map(\.isCompilation) == [0, 1])
        #expect(library.artists.count == 1)
    }

    @Test("쓰이지 않는 행은 넣지 않고 색은 8개 모두 넣는다")
    func unusedRowsDropped_colorsKept8() throws {
        let fixture = try RekordboxFixture()
        try fixture.addColorDefaults()
        try fixture.addArtist(id: "1", name: "시험 아티스트")
        try fixture.addArtist(id: "2", name: "안 쓰는 아티스트")
        try fixture.addAlbum(id: "30", name: "안 쓰는 앨범")
        try fixture.addGenre(id: "40", name: "시험 장르")
        try fixture.addGenre(id: "41", name: "안 쓰는 장르")
        try fixture.addKey(id: "50", scaleName: "1A")
        try fixture.addKey(id: "51", scaleName: "2A")
        try fixture.addLabel(id: "60", name: "안 쓰는 레이블")
        let track = try Self.addTrack(fixture, id: "101", artist: "1")
        try fixture.setContent(track: track, ["GenreID": .text("40"), "KeyID": .text("51")])
        let library = try Self.build(fixture, ids: ["101"]).model.library
        #expect(library.artists == [UsbNamedRow(id: 1, name: "시험 아티스트")])
        #expect(library.albums.isEmpty)
        #expect(library.genres == [UsbNamedRow(id: 1, name: "시험 장르")])
        #expect(library.keys == [UsbNamedRow(id: 1, name: "2A")])
        #expect(library.labels.isEmpty)
        #expect(library.colors.count == 8)
        #expect(library.colors.map(\.name) == RekordboxFixture.defaultColorNames)
    }

    @Test("레이블은 장르처럼 곡 순서대로 번호를 준다")
    func labelLikeGenre() throws {
        let fixture = try RekordboxFixture()
        try fixture.addLabel(id: "60", name: "시험 레이블 1")
        try fixture.addLabel(id: "61", name: "시험 레이블 2")
        try fixture.addGenre(id: "40", name: "시험 장르 1")
        try fixture.addGenre(id: "41", name: "시험 장르 2")
        let first = try Self.addTrack(fixture, id: "101")
        let second = try Self.addTrack(fixture, id: "102")
        let third = try Self.addTrack(fixture, id: "103")
        try fixture.setContent(track: first, ["LabelID": .text("61"), "GenreID": .text("41")])
        try fixture.setContent(track: second, ["LabelID": .text("60"), "GenreID": .text("40")])
        try fixture.setContent(track: third, ["LabelID": .text("61"), "GenreID": .text("41")])
        let built = try Self.build(fixture, ids: ["101", "102", "103"])
        let library = built.model.library
        #expect(library.labels == [UsbNamedRow(id: 1, name: "시험 레이블 2"), UsbNamedRow(id: 2, name: "시험 레이블 1")])
        #expect(library.genres == [UsbNamedRow(id: 1, name: "시험 장르 2"), UsbNamedRow(id: 2, name: "시험 장르 1")])
        #expect(library.tracks.map(\.labelID) == [1, 2, 1])
        #expect(library.tracks.map(\.genreID) == [1, 2, 1])
        // 레이블이 있는 곡은 계획이 확인 안 된 규칙으로 표시한다
        #expect(built.plan.requiredRules.contains(.metadataSeenEmptyOnly))
    }

    // MARK: - content 칸

    @Test("content 칸: 로컬 값·계획 값을 정해진 대로 옮긴다")
    func contentFields46() throws {
        let fixture = try RekordboxFixture()
        try fixture.addColorDefaults()
        try fixture.addArtist(id: "1", name: "시험 아티스트")
        try fixture.addArtist(id: "2", name: "시험 리믹서")
        try fixture.addArtist(id: "3", name: "시험 원곡자")
        try fixture.addArtist(id: "4", name: "시험 작곡가")
        try fixture.addAlbum(id: "30", name: "시험 앨범", albumArtistID: "1")
        try fixture.addGenre(id: "40", name: "시험 장르")
        try fixture.addKey(id: "50", scaleName: "8A")
        try fixture.addLabel(id: "60", name: "시험 레이블")
        let track = try Self.addTrack(fixture, id: "101", artist: "1", album: "30", composer: "4", bytes: 4_321)
        try fixture.setContent(track: track, [
            "Subtitle": .text("시험 믹스"), "BPM": .int(12850), "Length": .int(245), "TrackNo": .int(3), "DiscNo": .int(2),
            "RemixerID": .text("2"), "OrgArtistID": .text("3"), "Lyricist": .text(""), "GenreID": .text("40"), "LabelID": .text("60"),
            "KeyID": .text("50"), "ColorID": .text("3"), "Commnt": .text("시험 코멘트"), "Rating": .int(4), "ReleaseYear": .int(2020),
            "ReleaseDate": .text("2020-05-06"), "DateCreated": .text("2026-01-01"), "StockDate": .text("2026-01-02"),
            "FileType": .int(1), "BitRate": .int(320), "BitDepth": .int(16), "SampleRate": .int(44100), "ISRC": .text("ZZ0000000001"),
            "DJPlayCount": .int(9), "HotCueAutoLoad": .text("On"), "DeliveryControl": .text("ON"), "DeliveryComment": .text("시험 전달"),
            "MasterDBID": .text(Self.dbid), "MasterSongID": .text("9101"), "Analysed": .int(105), "ContentLink": .int(0),
            "CueUpdated": .text("7"), "AnalysisUpdated": .text("2"), "TrackInfoUpdated": .text("5"),
        ])
        let built = try Self.build(fixture, ids: ["101"])
        let plan = try #require(built.plan.tracks.first)
        let usb = try #require(built.model.library.tracks.first)
        let artist = Dictionary(uniqueKeysWithValues: built.model.library.artists.map { ($0.name, $0.id) })
        #expect(usb.id == plan.contentID)
        #expect(usb.presentIn == UsbFormat.defaultSet)
        #expect(usb.title == "시험 곡 101")
        #expect(usb.titleForSearch == nil)
        #expect(usb.subtitle == "시험 믹스")
        #expect(usb.bpmx100 == 12850)
        #expect(usb.lengthSeconds == 245)
        #expect(usb.trackNo == 3)
        #expect(usb.discNo == 2)
        #expect(usb.artistID == artist["시험 아티스트"])
        #expect(usb.remixerID == artist["시험 리믹서"])
        #expect(usb.originalArtistID == artist["시험 원곡자"])
        #expect(usb.composerID == artist["시험 작곡가"])
        #expect(usb.lyricistArtistID == 0)
        #expect(usb.lyricist == "")
        #expect(usb.albumID == 1)
        #expect(usb.genreID == 1)
        #expect(usb.labelID == 1)
        #expect(usb.keyID == 1)
        #expect(usb.colorID == 3)
        #expect(usb.imageID == plan.imageID)
        #expect(usb.imageID != nil)
        #expect(usb.comment == "시험 코멘트")
        #expect(usb.rating == 4)
        #expect(usb.releaseYear == 2020)
        #expect(usb.releaseDate == "2020-05-06")
        #expect(usb.dateCreated == "2026-01-01")
        #expect(usb.dateAdded == "2026-01-02")
        #expect(usb.path == plan.contentsPath)
        #expect(usb.fileName == plan.fileName)
        #expect(usb.fileSize == 4_321)
        #expect(usb.fileType == 1)
        #expect(usb.bitrate == 320)
        #expect(usb.bitDepth == 16)
        #expect(usb.sampleRate == 44100)
        #expect(usb.isrc == "ZZ0000000001")
        #expect(usb.djPlayCount == 9)
        #expect(usb.hotCueAutoLoad)
        #expect(usb.kuvoDeliver)
        #expect(usb.kuvoDeliveryComment == "시험 전달")
        #expect(usb.masterDbId == 424_242)
        #expect(usb.masterContentId == 9101)
        #expect(usb.analysisDataPath == plan.analysisPath)
        #expect(usb.analysedBits == 105)
        #expect(usb.contentLink == 0x0C0700)
        #expect(usb.hasModified == 0)
        #expect(usb.cueUpdateCount == "7")
        #expect(usb.analysisDataUpdateCount == "2")
        #expect(usb.informationUpdateCount == "5")
        #expect(usb.deviceFields == [.oneLibrary: UsbTrackDeviceFields(rating: 4, playCount: 9, hasModified: 0),
                                     .deviceLibrary: UsbTrackDeviceFields(rating: 4, playCount: 9, hasModified: nil)])

        let library = built.model.library
        #expect(library.formats == UsbFormat.defaultSet)
        #expect(library.property == UsbProperty(deviceName: "", dbVersion: "1000", numberOfContents: 1, createdDate: "2026-09-01",
                                                backgroundColorType: 0, myTagMasterDBID: 4_000_000_000))
        #expect(library.myTagLinks.isEmpty)
        #expect(library.histories.isEmpty)
    }

    @Test("갱신 횟수는 로컬 글자 그대로, NULL은 빈 글자(TEXT로 남는다)")
    func updateCountTextBinding() throws {
        let fixture = try RekordboxFixture()
        let first = try Self.addTrack(fixture, id: "101")
        let second = try Self.addTrack(fixture, id: "102")
        try fixture.setContent(track: first, ["CueUpdated": .text("12"), "AnalysisUpdated": .text(""), "TrackInfoUpdated": .null])
        try fixture.setContent(track: second, ["CueUpdated": .null, "AnalysisUpdated": .text("3"), "TrackInfoUpdated": .text("4")])
        let library = try Self.build(fixture, ids: ["101", "102"], formats: [.oneLibrary]).model.library
        #expect(library.tracks.map(\.cueUpdateCount) == ["12", ""])
        #expect(library.tracks.map(\.analysisDataUpdateCount) == ["", "3"])
        #expect(library.tracks.map(\.informationUpdateCount) == ["", "4"])

        // 숫자 글자는 INTEGER, 빈 글자는 TEXT ''로 저장된다
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-builder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "exportLibrary.db")
        try OneLibraryWriter.create(library, at: url)
        let db = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readOnly)
        defer { db.close() }
        var types: [[String]] = []
        try db.query("""
            SELECT typeof(cueUpdateCount), quote(cueUpdateCount), typeof(analysisDataUpdateCount), typeof(informationUpdateCount)
            FROM content ORDER BY content_id
            """) { row in types.append((0..<4).map { row.string(Int32($0)) ?? "" }) }
        #expect(types == [["integer", "12", "text", "text"], ["text", "''", "integer", "integer"]])
    }

    @Test("핫큐 자동 불러오기·KUVO 전달: on(대소문자 무시) → 켬, 그 밖 → 끔")
    func onOffFlags() throws {
        let fixture = try RekordboxFixture()
        let values: [(String?, String?)] = [("on", "on"), ("ON", "ON"), ("", ""), (nil, nil), ("off", "OFF")]
        for (index, value) in values.enumerated() {
            let track = try Self.addTrack(fixture, id: "10\(index)")
            try fixture.setContent(track: track, ["HotCueAutoLoad": value.0.map { .text($0) } ?? .null,
                                                  "DeliveryControl": value.1.map { .text($0) } ?? .null])
        }
        let library = try Self.build(fixture, ids: values.indices.map { "10\($0)" }).model.library
        #expect(library.tracks.map(\.hotCueAutoLoad) == [true, true, false, false, false])
        #expect(library.tracks.map(\.kuvoDeliver) == [true, true, false, false, false])
    }

    @Test("contentLink = 0x0C0700 | (로컬 ContentLink & 0x100000)")
    func contentLinkBits() throws {
        let fixture = try RekordboxFixture()
        let with = try Self.addTrack(fixture, id: "101")
        let without = try Self.addTrack(fixture, id: "102")
        let empty = try Self.addTrack(fixture, id: "103")
        try fixture.setContent(track: with, ["ContentLink": .int(0x100000 | 0x3)])
        try fixture.setContent(track: without, ["ContentLink": .int(0x3)])
        try fixture.setContent(track: empty, ["ContentLink": .null])
        let library = try Self.build(fixture, ids: ["101", "102", "103"]).model.library
        #expect(library.tracks.map(\.contentLink) == [0x1C0700, 0x0C0700, 0x0C0700])
    }

    @Test("작사가 글자가 있어도 artist_id_lyricist는 0(계획이 규칙으로 표시)")
    func lyricistEmptyZero() throws {
        let fixture = try RekordboxFixture()
        let empty = try Self.addTrack(fixture, id: "101")
        let named = try Self.addTrack(fixture, id: "102")
        try fixture.setContent(track: empty, ["Lyricist": .text("")])
        try fixture.setContent(track: named, ["Lyricist": .text("시험 작사")])
        let built = try Self.build(fixture, ids: ["101", "102"])
        #expect(built.model.library.tracks.map(\.lyricistArtistID) == [0, 0])
        #expect(built.model.library.tracks.map(\.lyricist) == ["", "시험 작사"])
        #expect(built.plan.tracks.map { $0.rules.contains(.metadataSeenEmptyOnly) } == [false, true])
    }

    @Test("파일 이름은 계획 경로의 끝 성분(자르거나 바꾼 이름)")
    func fileNameIsLastPathComponent() throws {
        let fixture = try RekordboxFixture()
        let long = String(repeating: "가", count: 60) + ".mp3"
        try Self.addTrack(fixture, id: "101", fileName: long)
        try Self.addTrack(fixture, id: "102", fileName: "시험:곡.mp3")
        let built = try Self.build(fixture, ids: ["101", "102"])
        let tracks = built.model.library.tracks
        #expect(tracks.map(\.fileName) == built.plan.tracks.map(\.fileName))
        #expect(tracks.map(\.fileName) == tracks.map { String($0.path.split(separator: "/").last ?? "") })
        #expect(tracks[0].fileName != long)
        #expect(tracks[1].fileName == "시험_곡.mp3")
    }

    @Test("그림 없는 곡은 image_id NULL, image 행도 없다")
    func noArtworkImageNull() throws {
        let fixture = try RekordboxFixture()
        try Self.addTrack(fixture, id: "101", artwork: false)
        try Self.addTrack(fixture, id: "102")
        let built = try Self.build(fixture, ids: ["101", "102"])
        let library = built.model.library
        #expect(library.tracks.map(\.imageID) == [nil, 1])
        #expect(library.images == [UsbImage(id: 1, oneLibraryPath: UsbArtworkLayout.oneLibraryPath(imageID: 1, folder: 1),
                                            pdbPath: UsbArtworkLayout.pdbPath(imageID: 1, folder: 1))])
        #expect(built.plan.requiredRules.contains(.artworkMissing))
    }

    // MARK: - 목록·My Tag·메뉴

    @Test("목록: 계획 ID·순번·폴더·항목, 형식마다 같은 값")
    func playlistsFromPlan() throws {
        let fixture = try RekordboxFixture()
        try Self.addTrack(fixture, id: "101")
        try Self.addTrack(fixture, id: "102")
        let playlists = [
            UsbPlaylistInput(localID: "p1", name: "시험 폴더", parentLocalID: nil, attribute: 1, trackLocalIDs: []),
            UsbPlaylistInput(localID: "p2", name: "시험 목록", parentLocalID: "p1", attribute: 0, trackLocalIDs: ["102", "101", "102"]),
        ]
        let built = try Self.build(fixture, ids: ["101", "102"], playlists: playlists)
        let formats = UsbFormat.defaultSet
        #expect(built.model.library.playlists == [
            UsbPlaylist(id: 1, name: "시험 폴더", parentID: 0, attribute: 1, imageID: nil, presentIn: formats,
                        sortOrder: [.oneLibrary: 0, .deviceLibrary: 0], entries: [.oneLibrary: [], .deviceLibrary: []]),
            UsbPlaylist(id: 2, name: "시험 목록", parentID: 1, attribute: 0, imageID: nil, presentIn: formats,
                        sortOrder: [.oneLibrary: 0, .deviceLibrary: 0], entries: [.oneLibrary: [2, 1, 2], .deviceLibrary: [2, 1, 2]]),
        ])
    }

    @Test("My Tag·메뉴·카테고리·정렬은 로컬 값, My Tag 연결은 쓰지 않는다")
    func menusAndMyTagsFromLocal() throws {
        let fixture = try RekordboxFixture()
        try fixture.addMenuDefaults()
        try fixture.addCategory(id: "1", menuItemID: "1", seq: 1, disable: 0, infoOrder: 1)
        try fixture.addSort(id: "0", menuItemID: "2", seq: 0, disable: 2)
        try fixture.addMyTag(id: "5000000001", name: "시험 분류", seq: 1, attribute: 1)
        try fixture.addMyTag(id: "5000000002", name: "시험 태그", seq: 1, attribute: 0, parentID: "5000000001")
        let track = try Self.addTrack(fixture, id: "101")
        try fixture.insert("djmdSongMyTag", ["ID": .text("m1"), "MyTagID": .text("5000000002"), "ContentID": .text(track.id),
                                             "rb_local_deleted": .int(0)])
        let library = try Self.build(fixture, ids: ["101"]).model.library
        #expect(library.menuItems.count == RekordboxFixture.defaultMenuNames.count)
        #expect(library.categories == [UsbCategory(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, infoOrder: 1, disable: 0)])
        #expect(library.sorts == [UsbSort(id: 0, menuItemID: 2, sequenceNo: 0, isVisible: true, isSelectedAsSubColumn: true, disable: 2)])
        #expect(library.myTags.map(\.id) == [5_000_000_001, 5_000_000_002])
        #expect(library.myTagLinks.isEmpty)
    }

    // MARK: - 파일 작업

    @Test("파일 작업: 음원·아트워크 a/b/_m·분석 원본 → USB 경로")
    func plannedFilesListed() throws {
        let fixture = try RekordboxFixture()
        let first = try Self.addTrack(fixture, id: "101")
        try Self.addTrack(fixture, id: "102", artwork: false)
        let built = try Self.build(fixture, ids: ["101", "102"])
        let plan = built.plan.tracks
        let files = built.model.files
        let share = fixture.shareRoot.path
        let artworkFolder = share + "/PIONEER/Artwork/101"
        let paths = UsbArtworkLayout.paths(imageID: 1, folder: 1)
        let expected: [UsbPlannedFile] = [
            UsbPlannedFile(kind: .audio(source: first.folderPath), destination: String(plan[0].contentsPath.dropFirst()), contentID: 1),
            UsbPlannedFile(kind: .artwork(source: artworkFolder + "/artwork_s.jpg"), destination: paths.a, contentID: 1),
            UsbPlannedFile(kind: .artwork(source: artworkFolder + "/artwork_m.jpg"), destination: paths.aMedium, contentID: 1),
            UsbPlannedFile(kind: .artwork(source: artworkFolder + "/artwork_s.jpg"), destination: paths.b, contentID: 1),
            UsbPlannedFile(kind: .artwork(source: artworkFolder + "/artwork_m.jpg"), destination: paths.bMedium, contentID: 1),
            UsbPlannedFile(kind: .analysis(localDAT: share + "/PIONEER/USBANLZ/a101/b101/ANLZ0000.DAT",
                                           localEXT: share + "/PIONEER/USBANLZ/a101/b101/ANLZ0000.EXT",
                                           local2EX: share + "/PIONEER/USBANLZ/a101/b101/ANLZ0000.2EX", localContentID: "101"),
                           destination: String(plan[0].analysisPath.dropFirst()), contentID: 1),
        ]
        #expect(Array(files.filter { $0.contentID == 1 }) == expected)
        #expect(files.filter { $0.contentID == 2 }.count == 2)
        #expect(files.allSatisfy { !$0.destination.hasPrefix("/") })

        // OneLibrary만 쓰면 Device Library 그림(a)은 옮기지 않는다
        let oneLibraryOnly = try Self.build(fixture, ids: ["101"], formats: [.oneLibrary]).model
        let artwork = oneLibraryOnly.files.filter { if case .artwork = $0.kind { true } else { false } }.map(\.destination)
        #expect(artwork == [paths.b, paths.bMedium])
        #expect(oneLibraryOnly.library.images == [UsbImage(id: 1, oneLibraryPath: "/" + paths.b, pdbPath: nil)])
    }

    @Test("같은 음원을 함께 쓰는 곡은 음원을 한 번만 옮긴다")
    func sharedAudioCopiedOnce() throws {
        let fixture = try RekordboxFixture()
        let first = try Self.addTrack(fixture, id: "101")
        var second = TrackSpec(id: "102")
        second.folderPath = first.folderPath
        try fixture.add(second)
        try fixture.setIdentity(track: second, masterSongID: "9102", masterDBID: Self.dbid, fileNameL: "101.mp3")
        try fixture.setFileSize(track: second, 300)
        try fixture.setAnalysisPath(track: second, "/PIONEER/USBANLZ/a102/b102/ANLZ0000.DAT")
        try fixture.writeLocalAnalysis(analysisPath: "/PIONEER/USBANLZ/a102/b102/ANLZ0000.DAT", dat: Data(count: 1), ext: Data(count: 1),
                                       twoEx: Data(count: 1))
        let built = try Self.build(fixture, ids: ["101", "102"])
        let audio = built.model.files.filter { if case .audio = $0.kind { true } else { false } }
        #expect(audio.count == 1)
        #expect(built.model.library.tracks.map(\.path) == [built.plan.tracks[0].contentsPath, built.plan.tracks[0].contentsPath])
    }

    // MARK: - 그 밖

    @Test("myTagMasterDBID 기본값은 1 … 2³¹−1")
    func myTagMasterDBIDRange() {
        for _ in 0..<1000 {
            let value = UsbLibraryBuilder.randomMyTagMasterDBID()
            #expect((1...Int64(Int32.max)).contains(value))
        }
    }

    @Test("기존 USB에 더하기: 기존 ID·행은 그대로, 새 ID는 가장 큰 값 다음, 같은 이름(NFC) 아티스트는 다시 쓴다")
    func addKeepsExistingIDsAndRows() throws {
        let fixture = try RekordboxFixture()
        try fixture.addArtist(id: "1", name: "Cafe\u{301}")
        try fixture.addArtist(id: "2", name: "시험 새 아티스트")
        try fixture.addGenre(id: "40", name: "시험 새 장르")
        let track = try Self.addTrack(fixture, id: "201", artist: "1", composer: "2")
        try fixture.setContent(track: track, ["GenreID": .text("40")])

        var existing = UsbModelSamples.library(.oneLibrary, tracks: [1, 2])
        existing.artists = [UsbNamedRow(id: 1, name: "시험 아티스트"), UsbNamedRow(id: 7, name: "Caf\u{E9}")]
        existing.deadIDs = ["artist": [9]]
        existing.canonicalize()

        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let candidates = try UsbExportCandidates.load(database: db, share: fixture.shareRoot, contentIDs: ["201"])
        var ids = UsbIDAllocator()
        for track in existing.tracks { ids.observe(.content, track.id) }
        for image in existing.images { ids.observe(.image, image.id) }
        let plan = UsbExportPlanner.plan(UsbExportRequest(candidates: candidates, existing: UsbExistingState(hasLibrary: true, ids: ids),
                                                          formats: [.oneLibrary], snapshotTakenAt: .distantFuture))
        #expect(plan.blocked.isEmpty)
        let model = try UsbLibraryBuilder.add(plan: plan, into: existing, local: UsbLocalSource(database: db), share: fixture.shareRoot)
        let library = model.library

        // 기존 행은 그대로
        #expect(Array(library.tracks.prefix(2)) == existing.tracks)
        #expect(library.albums == existing.albums)
        #expect(library.colors == existing.colors)
        #expect(library.myTags == existing.myTags)
        #expect(library.menuItems == existing.menuItems)
        #expect(library.histories == existing.histories)
        #expect(library.playlists == existing.playlists)
        // 새 곡: ID = 가장 큰 값 다음, 같은 이름 아티스트(NFC)는 기존 ID, 새 아티스트는 죽은 ID까지 넘어선 번호
        let added = try #require(library.tracks.last)
        #expect(added.id == 3)
        #expect(added.presentIn == [.oneLibrary])
        #expect(added.artistID == 7)
        #expect(added.composerID == 10)
        #expect(library.artists.map(\.id) == [1, 7, 10])
        #expect(added.genreID == 2)
        #expect(library.genres.map(\.id) == [1, 2])
        #expect(added.imageID == 2)
        #expect(library.images.map(\.id) == [1, 2])
        #expect(library.property.numberOfContents == 3)
        #expect(library.property.myTagMasterDBID == existing.property.myTagMasterDBID)
        #expect(library.property.createdDate == existing.property.createdDate)
        #expect(model.files.contains { $0.contentID == 3 })
    }

    @Test("로컬 곡이 없으면 던진다")
    func missingLocalTrackThrows() throws {
        let fixture = try RekordboxFixture()
        try Self.addTrack(fixture, id: "101")
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let candidates = try UsbExportCandidates.load(database: db, share: fixture.shareRoot, contentIDs: ["101"])
        let plan = UsbExportPlanner.plan(UsbExportRequest(candidates: candidates, snapshotTakenAt: .distantFuture))
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '101'")
        #expect(usbRefusedCodes {
            _ = try UsbLibraryBuilder.build(plan: plan, formats: UsbFormat.defaultSet, local: UsbLocalSource(database: db),
                                            share: fixture.shareRoot, myTagMasterDBID: 1, createdDate: "2026-09-01")
        } == ["localTrackMissing"])
    }

    /// 기존 USB 모델에 로컬 곡 201을 더하는 계획(`existing`의 곡·그림 ID를 계획이 알고 있다)
    static func addPlan(_ fixture: RekordboxFixture, _ db: CipherDatabase, existing: UsbLibrary, formats: Set<UsbFormat>) throws -> UsbExportPlan {
        let candidates = try UsbExportCandidates.load(database: db, share: fixture.shareRoot, contentIDs: ["201"])
        var ids = UsbIDAllocator()
        for track in existing.tracks { ids.observe(.content, track.id) }
        for image in existing.images { ids.observe(.image, image.id) }
        let plan = UsbExportPlanner.plan(UsbExportRequest(candidates: candidates, existing: UsbExistingState(hasLibrary: true, ids: ids),
                                                          formats: formats, snapshotTakenAt: .distantFuture))
        #expect(plan.blocked.isEmpty)
        return plan
    }

    @Test("기존 USB에 더하기: numberOfContents는 OneLibrary에 있는 곡 수(Device Library에만 있는 곡은 세지 않는다)")
    func addCountsOneLibraryTracks() throws {
        let fixture = try RekordboxFixture()
        try Self.addTrack(fixture, id: "201")
        var existing = UsbModelSamples.library(.oneLibrary, tracks: [1, 2])
        existing.formats = UsbFormat.defaultSet
        existing.tracks.append(UsbModelSamples.track(3, .deviceLibrary))
        existing.canonicalize()
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let plan = try Self.addPlan(fixture, db, existing: existing, formats: UsbFormat.defaultSet)
        let library = try UsbLibraryBuilder.add(plan: plan, into: existing, local: UsbLocalSource(database: db), share: fixture.shareRoot).library
        #expect(library.tracks.count == 4)
        #expect(library.tracks.filter { $0.presentIn.contains(.oneLibrary) }.count == 3)
        #expect(library.property.numberOfContents == 3)
    }

    @Test("기존 USB에 있는 곡 번호로 더하려 하면 막는다")
    func addRefusesContentIDOnUsb() throws {
        let fixture = try RekordboxFixture()
        try Self.addTrack(fixture, id: "201")
        let existing = UsbModelSamples.library(.oneLibrary, tracks: [1, 2])
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        var plan = try Self.addPlan(fixture, db, existing: existing, formats: [.oneLibrary])
        plan.tracks[0].contentID = 2
        #expect(usbRefusedCodes {
            _ = try UsbLibraryBuilder.add(plan: plan, into: existing, local: UsbLocalSource(database: db), share: fixture.shareRoot)
        } == ["contentIDInUse"])
    }
}

extension UsbLibrary {
    mutating func canonicalize() { self = canonicalized() }
}
