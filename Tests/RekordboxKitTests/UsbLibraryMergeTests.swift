import DJCDomain
import Foundation
import RekordboxKit
import Testing

/// 합성 단일 형식 모델(리더가 만드는 모양). 모든 값은 지어낸 것이다.
enum UsbModelSamples {
    static func track(_ id: Int, _ format: UsbFormat, path: String? = nil) -> UsbTrack {
        var track = UsbTrack(id: id)
        track.presentIn = [format]
        track.title = "시험 곡 \(id)"
        track.path = path ?? "/Contents/시험 아티스트/test\(id).mp3"
        track.fileName = "test\(id).mp3"
        track.bpmx100 = 12800
        track.lengthSeconds = 200
        track.artistID = 1
        track.albumID = 1
        track.analysisDataPath = String(format: "/PIONEER/USBANLZ/P000/%08X/ANLZ0000.DAT", id)
        track.cueUpdateCount = "3"
        track.deviceFields = [format: UsbTrackDeviceFields(rating: 0, playCount: 0, hasModified: format == .oneLibrary ? 0 : nil)]
        if format == .oneLibrary { track.lyricistArtistID = 0 }
        return track
    }

    static func playlist(_ id: Int, _ format: UsbFormat, name: String = "시험 목록", entries: [Int]) -> UsbPlaylist {
        UsbPlaylist(id: id, name: name, parentID: 0, attribute: 0, imageID: nil, presentIn: [format],
                    sortOrder: [format: id], entries: [format: entries])
    }

    /// 한 형식 리더가 만드는 모양의 모델
    static func library(_ format: UsbFormat, tracks: [Int], playlists: [UsbPlaylist] = []) -> UsbLibrary {
        var library = UsbLibrary.empty
        library.formats = [format]
        library.property = UsbProperty(deviceName: "", dbVersion: "1000", numberOfContents: tracks.count,
                                       createdDate: format == .oneLibrary ? "2026-01-02" : "", backgroundColorType: 0,
                                       myTagMasterDBID: 4_000_000_000, pdbDate: nil, pdbDeviceName: nil)
        library.tracks = tracks.map { track($0, format) }
        library.artists = [UsbNamedRow(id: 1, name: "시험 아티스트", nameForSearch: nil)]
        library.albums = [UsbAlbum(id: 1, name: "시험 앨범", artistID: 1, imageID: nil, isCompilation: 0, nameForSearch: nil)]
        library.genres = [UsbNamedRow(id: 1, name: "시험 장르", nameForSearch: nil)]
        library.keys = [UsbNamedRow(id: 1, name: "1A", nameForSearch: nil)]
        library.colors = [UsbNamedRow(id: 1, name: "Pink", nameForSearch: nil)]
        library.images = [UsbImage(id: 1, oneLibraryPath: format == .oneLibrary ? "/PIONEER/Artwork/00001/b1.jpg" : nil,
                                   pdbPath: format == .deviceLibrary ? "/PIONEER/Artwork/00001/a1.jpg" : nil)]
        library.playlists = playlists
        library.myTags = [UsbMyTag(id: 5_000_000_001, parentID: 0, sequenceNo: 0, name: "시험 분류", isCategory: true),
                          UsbMyTag(id: 5_000_000_002, parentID: 5_000_000_001, sequenceNo: 0, name: "시험 태그", isCategory: false)]
        library.myTagLinks = tracks.prefix(1).map { UsbMyTagLink(myTagID: 5_000_000_002, contentID: $0, presentIn: [format]) }
        library.menuItems = [UsbMenuItem(id: 1, kind: 257, name: "시험 메뉴")]
        library.categories = [UsbCategory(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, infoOrder: nil, disable: nil)]
        library.sorts = [UsbSort(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, isSelectedAsSubColumn: false, disable: nil)]
        library.histories = [UsbHistory(format: format, id: 1, name: "시험 기록", entries: Array(tracks.prefix(1)))]
        return library
    }

    /// OneLibrary·Device Library 모델 한 쌍. 한 형식 칸은 각 형식에만 값이 있다.
    static func pair(olTracks: [Int] = [1, 2], dlTracks: [Int] = [1, 2]) -> (UsbLibrary, UsbLibrary) {
        var ol = library(.oneLibrary, tracks: olTracks, playlists: [playlist(10, .oneLibrary, entries: [1, 2])])
        var dl = library(.deviceLibrary, tracks: dlTracks, playlists: [playlist(10, .deviceLibrary, entries: [1, 2])])
        ol.tracks[0].titleForSearch = "시험 검색"
        ol.artists[0].nameForSearch = "시험 검색"
        ol.albums[0].imageID = 3
        ol.albums[0].isCompilation = 1
        ol.playlists[0].imageID = 2
        dl.tracks[0].lyricist = "시험 작사"
        dl.categories[0].infoOrder = 2
        dl.categories[0].disable = 1
        dl.sorts[0].disable = 2
        dl.property.pdbDate = "2026-01-03"
        dl.property.pdbDeviceName = "x"
        dl.trackRowExtras = [1: UsbPdbTrackExtras()]
        dl.deadIDs = ["content": [7]]
        dl.unknownRows = [UsbUnknownRows(format: .deviceLibrary, file: "export.pdb", tableType: 99, liveRows: 1)]
        return (ol, dl)
    }
}

@Suite("USB 모델 합치기·투영")
struct UsbLibraryMergeTests {
    typealias Samples = UsbModelSamples

    @Test func sameTracksMergePresentIn() {
        let (ol, dl) = Samples.pair()
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(mismatches.isEmpty)
        #expect(merged.formats == UsbFormat.defaultSet)
        #expect(merged.tracks.map(\.id) == [1, 2])
        #expect(merged.tracks.allSatisfy { $0.presentIn == UsbFormat.defaultSet })
        #expect(merged.playlists.count == 1)
        #expect(merged.playlists[0].presentIn == UsbFormat.defaultSet)
        #expect(merged.myTagLinks == [UsbMyTagLink(myTagID: 5_000_000_002, contentID: 1, presentIn: UsbFormat.defaultSet)])
        #expect(merged.histories.map(\.format) == [.oneLibrary, .deviceLibrary])
    }

    @Test func mergeWithOneSideOnly() {
        let (ol, dl) = Samples.pair()
        #expect(UsbLibrary.merge(oneLibrary: ol, deviceLibrary: nil) == (ol, []))
        #expect(UsbLibrary.merge(oneLibrary: nil, deviceLibrary: dl) == (dl, []))
        #expect(UsbLibrary.merge(oneLibrary: nil, deviceLibrary: nil) == (UsbLibrary.empty, []))
    }

    @Test func pathDiffersBlocksEditing() {
        let (ol, original) = Samples.pair()
        var dl = original
        dl.tracks[1].path = "/Contents/다른 폴더/test2.mp3"
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(mismatches == [.trackPathDiffers(id: 2)])
        #expect(mismatches.contains { $0.blocksEditing })
        let track = merged.tracks.first { $0.id == 2 }
        #expect(track?.path == ol.tracks[1].path)
        #expect(track?.presentIn == [.oneLibrary])
        // NFC·NFD만 다른 경로는 같은 곡이다
        dl = Samples.pair().1
        dl.tracks[1].path = dl.tracks[1].path.decomposedStringWithCanonicalMapping
        #expect(UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl).1.isEmpty)
    }

    @Test func trackOnlyInOneFormat() {
        let (ol, dl) = Samples.pair(olTracks: [1, 2], dlTracks: [1, 3])
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(Set(mismatches) == [.trackOnlyIn(.oneLibrary, id: 2), .trackOnlyIn(.deviceLibrary, id: 3)])
        #expect(mismatches.allSatisfy { $0.blocksEditing })
        #expect(merged.tracks.map(\.id) == [1, 2, 3])
        #expect(merged.tracks.map(\.presentIn) == [UsbFormat.defaultSet, [.oneLibrary], [.deviceLibrary]])
    }

    @Test func playlistEntriesDifferKeptPerFormat() {
        var (ol, dl) = Samples.pair(olTracks: [1, 2, 3, 4], dlTracks: [1, 2, 3, 4])
        ol.playlists = [Samples.playlist(10, .oneLibrary, entries: [1, 2, 3])]
        dl.playlists = [Samples.playlist(10, .deviceLibrary, entries: [1, 2, 3, 4])]
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(mismatches == [.playlistEntriesDiffer(id: 10)])
        #expect(!mismatches.contains { $0.blocksEditing })
        #expect(merged.playlists.count == 1)
        #expect(merged.playlists[0].entries == [.oneLibrary: [1, 2, 3], .deviceLibrary: [1, 2, 3, 4]])
        #expect(merged.playlists[0].sortOrder == [.oneLibrary: 10, .deviceLibrary: 10])
    }

    /// 형식 하나의 목록(부모·종류까지)
    static func list(_ id: Int, _ format: UsbFormat, _ name: String, parent: Int = 0, folder: Bool = false, order: Int = 0,
                     entries: [Int] = []) -> UsbPlaylist {
        UsbPlaylist(id: id, name: name, parentID: parent, attribute: folder ? 1 : 0, imageID: nil, presentIn: [format],
                    sortOrder: [format: order], entries: [format: folder ? [] : entries])
    }

    /// 두 형식 투영이 각 형식 리더 모델과 같다(쓰기가 건드리지 않은 목록은 그대로 다시 쓴다)
    static func expectRoundTrip(_ merged: UsbLibrary, _ ol: UsbLibrary, _ dl: UsbLibrary) {
        #expect(merged.projected(to: .oneLibrary).playlists == ol.playlists.sorted { $0.id < $1.id })
        #expect(merged.projected(to: .deviceLibrary).playlists == dl.playlists.sorted { $0.id < $1.id })
        for format in UsbFormat.allCases {
            let single = format == .oneLibrary ? ol : dl
            #expect(UsbLibraryDiff.compare(merged.projected(to: format), single, options: .init(formats: [format])).differences.isEmpty)
        }
    }

    @Test("#233: 같은 목록이 형식마다 다른 번호여도 자리·이름·종류로 짝짓고 형식 번호를 지킨다")
    func samePlaylistDifferentIDsPaired() {
        var (ol, dl) = Samples.pair()
        ol.playlists = [Self.list(5, .oneLibrary, "합성 폴더", folder: true), Self.list(6, .oneLibrary, "합성 목록 A", parent: 5, entries: [1]),
                        Self.list(10, .oneLibrary, "합성 목록 B", order: 1, entries: [2])]
        dl.playlists = [Self.list(3, .deviceLibrary, "합성 폴더", folder: true), Self.list(9, .deviceLibrary, "합성 목록 A", parent: 3, entries: [1]),
                        Self.list(10, .deviceLibrary, "합성 목록 B", order: 1, entries: [2])]
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(mismatches.isEmpty)
        #expect(merged.playlists.map(\.id) == [5, 6, 10])
        #expect(merged.playlists.allSatisfy { $0.presentIn == UsbFormat.defaultSet })
        #expect(merged.playlists.map(\.formatIDs) == [[.deviceLibrary: 3], [.deviceLibrary: 9], [:]])
        #expect(merged.playlists[1].parentID == 5)
        #expect(merged.playlists[1].id(in: .deviceLibrary) == 9 && merged.playlists[1].id(in: .oneLibrary) == 6)
        Self.expectRoundTrip(merged, ol, dl)
        // 합친 모델을 다시 합쳐도 같다
        #expect(UsbLibrary.merge(oneLibrary: merged, deviceLibrary: merged).0 == merged)
    }

    @Test("#233: Device Library는 빈 번호를 다시 쓰고 OneLibrary는 가장 큰 값+1을 써 같은 번호가 다른 목록이어도 짝짓는다")
    func sameIDDifferentPlaylistsPaired() {
        // 둘 다 30(지운 목록) 뒤에 X·Y를 만든 모양: Device Library X 30·Y 31, OneLibrary X 31·Y 32
        var (ol, dl) = Samples.pair()
        ol.playlists = [Self.list(10, .oneLibrary, "합성 폴더", folder: true), Self.list(31, .oneLibrary, "합성 X", parent: 10, entries: [1]),
                        Self.list(32, .oneLibrary, "합성 Y", parent: 10, order: 1, entries: [2])]
        dl.playlists = [Self.list(10, .deviceLibrary, "합성 폴더", folder: true), Self.list(30, .deviceLibrary, "합성 X", parent: 10, entries: [1]),
                        Self.list(31, .deviceLibrary, "합성 Y", parent: 10, order: 1, entries: [2])]
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(mismatches.isEmpty)
        #expect(!mismatches.contains { $0.blocksEditing })
        #expect(merged.playlists.map(\.id) == [10, 31, 32])
        #expect(merged.playlists.map { $0.id(in: .deviceLibrary) } == [10, 30, 31])
        #expect(merged.playlists.first { $0.id == 31 }?.name == "합성 X")
        Self.expectRoundTrip(merged, ol, dl)
    }

    @Test("이름이 다른 같은 번호 목록은 짝짓지 않고 두 한 형식 목록으로 둔다(Device Library 목록을 잃지 않는다)")
    func sameIDDifferentNameKeptApart() {
        let (ol, original) = Samples.pair()
        var dl = original
        dl.playlists[0].name = "다른 이름"
        dl.playlists.append(Samples.playlist(11, .deviceLibrary, name: "또 다른 목록", entries: [2]))
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(Set(mismatches) == [.playlistOnlyIn(.oneLibrary, id: 10), .playlistOnlyIn(.deviceLibrary, id: -10),
                                    .playlistOnlyIn(.deviceLibrary, id: 11)])
        #expect(!mismatches.contains { $0.blocksEditing })
        #expect(merged.playlists.map(\.id) == [-10, 10, 11])
        let deviceOnly = merged.playlists.first { $0.id == -10 }
        #expect(deviceOnly?.name == "다른 이름" && deviceOnly?.presentIn == [.deviceLibrary] && deviceOnly?.id(in: .deviceLibrary) == 10)
        #expect(merged.playlists.first { $0.id == 10 }?.presentIn == [.oneLibrary])
        Self.expectRoundTrip(merged, ol, dl)
    }

    @Test("같은 부모 아래 같은 이름·종류가 여럿이면 번호까지 같은 것만 짝짓는다")
    func ambiguousNamesPairOnlySameID() {
        var (ol, dl) = Samples.pair()
        ol.playlists = [Self.list(10, .oneLibrary, "합성 같은 이름", entries: [1]), Self.list(12, .oneLibrary, "합성 같은 이름", order: 1, entries: [2])]
        dl.playlists = [Self.list(10, .deviceLibrary, "합성 같은 이름", entries: [1]), Self.list(11, .deviceLibrary, "합성 같은 이름", order: 1, entries: [2])]
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(Set(mismatches) == [.playlistOnlyIn(.oneLibrary, id: 12), .playlistOnlyIn(.deviceLibrary, id: 11)])
        #expect(merged.playlists.map(\.id) == [10, 11, 12])
        #expect(merged.playlists.map(\.presentIn) == [UsbFormat.defaultSet, [.deviceLibrary], [.oneLibrary]])
        Self.expectRoundTrip(merged, ol, dl)

        // 번호도 모두 다르면 하나도 짝짓지 않는다
        dl.playlists = [Self.list(20, .deviceLibrary, "합성 같은 이름", entries: [1]), Self.list(21, .deviceLibrary, "합성 같은 이름", order: 1, entries: [2])]
        let (apart, apartMismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(apart.playlists.allSatisfy { $0.presentIn.count == 1 } && apart.playlists.count == 4)
        #expect(!apartMismatches.contains { $0.blocksEditing })
        Self.expectRoundTrip(apart, ol, dl)
    }

    @Test("짝을 찾지 못한 폴더 아래 목록은 이름이 같아도 짝짓지 않고, 한 형식 목록의 부모는 대표 번호로 적는다")
    func childrenFollowParentPairing() {
        var (ol, dl) = Samples.pair()
        ol.playlists = [Self.list(5, .oneLibrary, "합성 폴더", folder: true), Self.list(6, .oneLibrary, "합성 목록", parent: 5, entries: [1]),
                        Self.list(7, .oneLibrary, "합성 이름 바꾼 폴더", folder: true, order: 1),
                        Self.list(8, .oneLibrary, "합성 안 목록", parent: 7, entries: [2])]
        // Device Library: 짝 폴더(3) 아래 Device Library에만 있는 목록(5, OneLibrary 번호와 겹침), 이름이 다른 폴더(4) 아래 같은 이름 목록
        dl.playlists = [Self.list(3, .deviceLibrary, "합성 폴더", folder: true), Self.list(5, .deviceLibrary, "합성 장치 목록", parent: 3, entries: [2]),
                        Self.list(9, .deviceLibrary, "합성 목록", parent: 3, order: 1, entries: [1]),
                        Self.list(4, .deviceLibrary, "합성 옛 폴더", folder: true, order: 1),
                        Self.list(6, .deviceLibrary, "합성 안 목록", parent: 4, entries: [2])]
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(!mismatches.contains { $0.blocksEditing })
        let deviceOnly = merged.playlists.first { $0.name == "합성 장치 목록" }
        #expect(deviceOnly?.id == -5 && deviceOnly?.parentID == 5)
        #expect(merged.playlists.first { $0.id == 6 }?.formatIDs == [.deviceLibrary: 9])
        // 이름이 다른 폴더(7·4)는 짝이 없고, 그 아래 같은 이름 목록(8·6)도 짝짓지 않는다
        let inner = merged.playlists.filter { $0.name == "합성 안 목록" }
        #expect(inner.count == 2 && inner.allSatisfy { $0.presentIn.count == 1 })
        let innerDevice = inner.first { $0.presentIn == [.deviceLibrary] }
        #expect(innerDevice?.id == -6 && innerDevice?.parentID == 4)
        Self.expectRoundTrip(merged, ol, dl)
    }

    @Test("맨 위에서 닿지 않는 목록(없는 부모)은 대표 번호를 정할 수 없어 편집을 막는다")
    func orphanPlaylistBlocks() {
        let (ol, original) = Samples.pair()
        var dl = original
        dl.playlists.append(Self.list(11, .deviceLibrary, "합성 고아 목록", parent: 99, entries: [1]))
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(mismatches == [.playlistConflict(id: 11)])
        #expect(mismatches[0].blocksEditing)
        #expect(merged.projected(to: .deviceLibrary).playlists == dl.playlists)
        // 맨 위에서 닿는 목록은 그대로 짝짓는다
        #expect(merged.playlists.first { $0.id == 10 }?.presentIn == UsbFormat.defaultSet)
        #expect(merged.projected(to: .oneLibrary).playlists == ol.playlists)
    }

    @Test func sharedFieldDifferencesReported() {
        let (ol, original) = Samples.pair()
        var dl = original
        dl.tracks[0].title = "다른 제목"
        dl.artists[0].name = "다른 아티스트"
        dl.property.numberOfContents = 99
        dl.menuItems.append(UsbMenuItem(id: 2, kind: 258, name: "시험 메뉴 2"))
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(Set(mismatches) == [.trackFieldDiffers(id: 1, field: "title"), .sharedRowDiffers(table: "artist", id: 1),
                                    .propertyDiffers(field: "numberOfContents"), .sharedRowDiffers(table: "menuItem", id: 2)])
        #expect(!mismatches.contains { $0.blocksEditing })
        // 두 형식 모두의 칸은 OneLibrary 값, 한쪽에만 있는 행은 합집합(보고도 한다)
        #expect(merged.tracks[0].title == ol.tracks[0].title)
        #expect(merged.artists[0].name == ol.artists[0].name)
        #expect(merged.property.numberOfContents == ol.property.numberOfContents)
        #expect(merged.menuItems.map(\.id) == [1, 2])
    }

    @Test func projectedKeepsOnlyFormatEntities() {
        var (ol, dl) = Samples.pair(olTracks: [1, 2], dlTracks: [1, 3])
        ol.playlists.append(Samples.playlist(11, .oneLibrary, entries: [2]))
        dl.myTagLinks.append(UsbMyTagLink(myTagID: 5_000_000_002, contentID: 3, presentIn: [.deviceLibrary]))
        let (merged, _) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        let olView = merged.projected(to: .oneLibrary), dlView = merged.projected(to: .deviceLibrary)
        #expect(olView.formats == [.oneLibrary])
        #expect(olView.tracks.map(\.id) == [1, 2])
        #expect(dlView.tracks.map(\.id) == [1, 3])
        #expect(olView.tracks.allSatisfy { $0.presentIn == [.oneLibrary] && Set($0.deviceFields.keys) == [.oneLibrary] })
        #expect(olView.playlists.map(\.id) == [10, 11])
        #expect(dlView.playlists.map(\.id) == [10])
        #expect(dlView.playlists[0].entries.keys.sorted { $0.rawValue < $1.rawValue } == [.deviceLibrary])
        #expect(olView.histories.map(\.format) == [.oneLibrary])
        #expect(olView.unknownRows.isEmpty && dlView.unknownRows.count == 1)
        #expect(olView.myTagLinks.map(\.contentID) == [1])
        #expect(dlView.myTagLinks.map(\.contentID) == [1, 3])
        #expect(olView.deadIDs.isEmpty && olView.trackRowExtras.isEmpty)
        #expect(dlView.deadIDs == ["content": [7]])
    }

    @Test func deviceFieldsKeptPerFormat() {
        var (ol, dl) = Samples.pair()
        ol.tracks[0].deviceFields = [.oneLibrary: UsbTrackDeviceFields(rating: 3, playCount: 4, hasModified: 1)]
        dl.tracks[0].deviceFields = [.deviceLibrary: UsbTrackDeviceFields(rating: 5, playCount: 6, hasModified: nil)]
        let (merged, _) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(merged.tracks[0].deviceFields == [.oneLibrary: UsbTrackDeviceFields(rating: 3, playCount: 4, hasModified: 1),
                                                  .deviceLibrary: UsbTrackDeviceFields(rating: 5, playCount: 6, hasModified: nil)])
    }

    @Test func mergeKeepsFormatOnlyFields() {
        let (ol, dl) = Samples.pair()
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(mismatches.isEmpty)
        let track = merged.tracks[0]
        #expect(track.titleForSearch == "시험 검색")
        #expect(track.lyricist == "시험 작사")
        #expect(track.lyricistArtistID == 0)
        #expect(merged.artists[0].nameForSearch == "시험 검색")
        #expect(merged.albums[0].imageID == 3)
        #expect(merged.albums[0].isCompilation == 1)
        #expect(merged.playlists[0].imageID == 2)
        #expect(merged.property.createdDate == "2026-01-02")
        #expect(merged.property.backgroundColorType == 0)
        #expect(merged.property.pdbDate == "2026-01-03")
        #expect(merged.property.pdbDeviceName == "x")
        #expect(merged.categories[0].infoOrder == 2)
        #expect(merged.categories[0].disable == 1)
        #expect(merged.sorts[0].disable == 2)
        #expect(merged.trackRowExtras == [1: UsbPdbTrackExtras()])
        #expect(merged.images[0].oneLibraryPath == "/PIONEER/Artwork/00001/b1.jpg")
        #expect(merged.images[0].pdbPath == "/PIONEER/Artwork/00001/a1.jpg")
        // 합친 모델을 자기 자신과 다시 합쳐도 같다
        let (again, againMismatches) = UsbLibrary.merge(oneLibrary: merged, deviceLibrary: merged)
        #expect(again == merged)
        #expect(againMismatches.isEmpty)
    }

    @Test func projectedMatchesSingleFormatRead() {
        let (ol, dl) = Samples.pair()
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
        #expect(mismatches.isEmpty)
        #expect(merged.projected(to: .oneLibrary) == ol)
        #expect(merged.projected(to: .deviceLibrary) == dl)
        for format in UsbFormat.allCases {
            let single = format == .oneLibrary ? ol : dl
            #expect(UsbLibraryDiff.compare(merged.projected(to: format), single, options: .init(formats: [format])).differences.isEmpty)
            #expect(UsbLibraryDiff.compare(merged, single, options: .init(formats: [format])).differences.isEmpty)
        }

        // 한 형식에만 있는 곡·목록은 그 형식 투영에만 있다
        var (ol2, dl2) = Samples.pair(olTracks: [1, 2], dlTracks: [1, 2, 3])
        dl2.property.numberOfContents = ol2.property.numberOfContents
        ol2.playlists.append(Samples.playlist(12, .oneLibrary, entries: [2]))
        let (merged2, _) = UsbLibrary.merge(oneLibrary: ol2, deviceLibrary: dl2)
        #expect(merged2.projected(to: .oneLibrary) == ol2)
        #expect(merged2.projected(to: .deviceLibrary) == dl2)
        #expect(!merged2.projected(to: .oneLibrary).tracks.contains { $0.id == 3 })
        #expect(!merged2.projected(to: .deviceLibrary).playlists.contains { $0.id == 12 })

        // 공유 표(artist 등) 행이 한 형식에만 있으면 불일치로 보고하고(불일치 없는 USB가 아니다), 투영은 그 행을 읽은 형식에만 둔다(#234)
        var dl3 = dl
        dl3.artists.append(UsbNamedRow(id: 2, name: "다른 아티스트", nameForSearch: nil))
        let (merged3, mismatches3) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl3)
        #expect(mismatches3 == [.sharedRowDiffers(table: "artist", id: 2)])
        #expect(!mismatches3.contains { $0.blocksEditing })
        #expect(merged3.artists.map(\.id) == [1, 2])
        #expect(merged3.projected(to: .deviceLibrary) == dl3)
        #expect(merged3.projected(to: .oneLibrary) == ol)
        var ol3 = ol
        ol3.menuItems.append(UsbMenuItem(id: 2, kind: 258, name: "시험 메뉴 2"))
        #expect(UsbLibrary.merge(oneLibrary: ol3, deviceLibrary: dl).1 == [.sharedRowDiffers(table: "menuItem", id: 2)])
    }
}
