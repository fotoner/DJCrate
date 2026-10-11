import DJCDomain
import Foundation
import RekordboxKit
import Testing

@Suite("USB 모델 비교")
struct UsbLibraryDiffTests {
    typealias Samples = UsbModelSamples

    static func merged() -> UsbLibrary {
        let (ol, dl) = Samples.pair()
        return UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl).0
    }

    @Test func identicalIsZero() {
        let library = Self.merged()
        let (summaries, differences) = UsbLibraryDiff.compare(library, library, options: .init())
        #expect(differences.isEmpty)
        #expect(summaries.allSatisfy { $0.matchedRows == $0.leftRows && $0.leftRows == $0.rightRows && $0.differingFields.isEmpty })
        #expect(summaries.first { $0.table == "content" }?.matchedRows == 2)
        #expect(summaries.first { $0.table == "property" }?.matchedRows == 1)
    }

    @Test func fieldDifferenceNamed() {
        let a = Self.merged()
        var b = a
        b.tracks[0].title = "비밀 제목 가나다"
        b.artists[0].name = "비밀 아티스트"
        let result = UsbLibraryDiff.compare(a, b, options: .init())
        #expect(result.differences == [UsbLibraryDiff.Difference(table: "content", key: "1", field: "title"),
                                       UsbLibraryDiff.Difference(table: "artist", key: "1", field: "name")])
        let content = result.summaries.first { $0.table == "content" }
        #expect(content?.matchedRows == 1)
        #expect(content?.differingFields == ["title": 1])
        // 글자 칸 값은 결과 어디에도 넣지 않는다
        let dump = String(describing: result)
        #expect(!dump.contains("비밀 제목") && !dump.contains("비밀 아티스트") && !dump.contains("시험 곡"))
    }

    @Test func rowsOnlyOnOneSideCounted() {
        let a = Self.merged()
        var b = a
        b.tracks.removeLast()
        b.genres.append(UsbNamedRow(id: 2, name: "새 장르", nameForSearch: nil))
        let result = UsbLibraryDiff.compare(a, b, options: .init())
        #expect(result.differences.count == 2)
        let content = result.summaries.first { $0.table == "content" }
        #expect(content?.leftRows == 2 && content?.rightRows == 1 && content?.matchedRows == 1)
        let genre = result.summaries.first { $0.table == "genre" }
        #expect(genre?.leftRows == 1 && genre?.rightRows == 2)
    }

    @Test func ignoreAnalysisFolderComparesFileNameOnly() {
        let a = Self.merged()
        var b = a
        b.tracks[0].analysisDataPath = "/PIONEER/USBANLZ/P123/0000ABCD/ANLZ0000.DAT"
        #expect(UsbLibraryDiff.compare(a, b, options: .init()).differences.map(\.field) == ["analysisDataPath"])
        #expect(UsbLibraryDiff.compare(a, b, options: .init(ignoreAnalysisFolder: true)).differences.isEmpty)
        b.tracks[0].analysisDataPath = "/PIONEER/USBANLZ/P123/0000ABCD/ANLZ0001.DAT"
        #expect(UsbLibraryDiff.compare(a, b, options: .init(ignoreAnalysisFolder: true)).differences.map(\.field) == ["analysisDataPath"])
    }

    @Test func ignoreIDsMatchesByPathAndName() {
        var a = Self.merged()
        a.playlists.append(UsbPlaylist(id: 20, name: "시험 폴더", parentID: 0, attribute: 1, imageID: nil, presentIn: UsbFormat.defaultSet,
                                       sortOrder: [.oneLibrary: 2, .deviceLibrary: 2], entries: [:]))
        a.playlists.append(UsbPlaylist(id: 21, name: "시험 하위", parentID: 20, attribute: 0, imageID: nil, presentIn: UsbFormat.defaultSet,
                                       sortOrder: [.oneLibrary: 1, .deviceLibrary: 1], entries: [.oneLibrary: [2, 1], .deviceLibrary: [2, 1]]))
        // 같은 내용을 다른 ID로: 곡·아티스트·앨범·목록 ID를 모두 옮기고 참조도 따라 옮긴다
        var b = a
        let shift = 100
        b.tracks = a.tracks.map { track in
            var track = track
            track.id += shift
            track.artistID = track.artistID.map { $0 + shift }
            track.albumID = track.albumID.map { $0 + shift }
            track.genreID = track.genreID.map { $0 + shift }
            return track
        }
        b.artists = a.artists.map { UsbNamedRow(id: $0.id + shift, name: $0.name, nameForSearch: $0.nameForSearch) }
        b.albums = a.albums.map { album in
            var album = album
            album.id += shift
            album.artistID = album.artistID.map { $0 + shift }
            return album
        }
        b.genres = a.genres.map { UsbNamedRow(id: $0.id + shift, name: $0.name, nameForSearch: $0.nameForSearch) }
        b.playlists = a.playlists.map { playlist in
            var playlist = playlist
            playlist.id += shift
            if playlist.parentID != 0 { playlist.parentID += shift }
            playlist.entries = playlist.entries.mapValues { $0.map { $0 + shift } }
            return playlist
        }
        b.myTagLinks = a.myTagLinks.map { UsbMyTagLink(myTagID: $0.myTagID, contentID: $0.contentID + shift, presentIn: $0.presentIn) }
        b.histories = a.histories.map { UsbHistory(format: $0.format, id: $0.id, name: $0.name, entries: $0.entries.map { $0 + shift }) }
        b.trackRowExtras = Dictionary(uniqueKeysWithValues: a.trackRowExtras.map { ($0.key + shift, $0.value) })

        #expect(!UsbLibraryDiff.compare(a, b, options: .init()).differences.isEmpty)
        let result = UsbLibraryDiff.compare(a, b, options: .init(ignoreIDs: true))
        #expect(result.differences.isEmpty)

        // 참조가 다른 곳을 가리키면 차이
        var c = b
        c.tracks[0].artistID = nil
        c.playlists[2].entries[.oneLibrary] = [1 + shift, 2 + shift]
        let changed = UsbLibraryDiff.compare(a, c, options: .init(ignoreIDs: true)).differences
        #expect(Set(changed.map(\.field)) == ["artistID", "entries.oneLibrary"])
        // 짝지은 키는 이름·경로를 드러내지 않는다
        #expect(!changed.contains { $0.key.contains("시험") || $0.key.contains("/") })
    }

    /// 이름이 같은 앨범·아티스트, 같은 부모 아래 같은 이름 폴더가 여럿이어도 나온 순서대로 짝지어 같은 라이브러리는 차이 0이다.
    @Test func ignoreIDsDuplicateNamesSameLibraryIsZero() {
        var a = Self.merged()
        a.artists.append(UsbNamedRow(id: 2, name: a.artists[0].name, nameForSearch: nil))
        a.albums = [UsbAlbum(id: 10, name: "같은 앨범", artistID: 1, imageID: nil, isCompilation: 0, nameForSearch: nil),
                    UsbAlbum(id: 11, name: "같은 앨범", artistID: 2, imageID: nil, isCompilation: 0, nameForSearch: nil)]
        a.tracks[0].artistID = 1
        a.tracks[0].albumID = 10
        a.tracks[1].artistID = 2
        a.tracks[1].albumID = 11
        for (id, name, parentID, attribute, entries) in [(20, "같은 폴더", 0, 1, [Int]()), (21, "같은 폴더", 0, 1, []),
                                                          (22, "하위", 20, 0, [1]), (23, "하위", 21, 0, [2])] {
            a.playlists.append(UsbPlaylist(id: id, name: name, parentID: parentID, attribute: attribute, imageID: nil,
                                           presentIn: UsbFormat.defaultSet, sortOrder: [.oneLibrary: 1, .deviceLibrary: 1],
                                           entries: entries.isEmpty ? [:] : [.oneLibrary: entries, .deviceLibrary: entries]))
        }
        #expect(UsbLibraryDiff.compare(a, a, options: .init()).differences.isEmpty)
        for formats in [UsbFormat.defaultSet, [.oneLibrary], [.deviceLibrary]] {
            #expect(UsbLibraryDiff.compare(a, a, options: .init(ignoreIDs: true, formats: formats)).differences.isEmpty)
        }

        // 같은 순서로 id만 옮긴 사본도 차이 0
        let shift = 100
        var b = a
        b.tracks = a.tracks.map { track in
            var track = track
            track.id += shift
            track.artistID = track.artistID.map { $0 + shift }
            track.albumID = track.albumID.map { $0 + shift }
            return track
        }
        b.artists = a.artists.map { UsbNamedRow(id: $0.id + shift, name: $0.name, nameForSearch: $0.nameForSearch) }
        b.albums = a.albums.map { album in
            var album = album
            album.id += shift
            album.artistID = album.artistID.map { $0 + shift }
            return album
        }
        b.playlists = a.playlists.map { playlist in
            var playlist = playlist
            playlist.id += shift
            if playlist.parentID != 0 { playlist.parentID += shift }
            playlist.entries = playlist.entries.mapValues { $0.map { $0 + shift } }
            return playlist
        }
        b.myTagLinks = a.myTagLinks.map { UsbMyTagLink(myTagID: $0.myTagID, contentID: $0.contentID + shift, presentIn: $0.presentIn) }
        b.histories = a.histories.map { UsbHistory(format: $0.format, id: $0.id, name: $0.name, entries: $0.entries.map { $0 + shift }) }
        b.trackRowExtras = Dictionary(uniqueKeysWithValues: a.trackRowExtras.map { ($0.key + shift, $0.value) })
        #expect(UsbLibraryDiff.compare(a, b, options: .init(ignoreIDs: true)).differences.isEmpty)

        // 둘째 폴더의 하위 목록 항목이 바뀌면 그 목록만 차이
        var c = b
        c.playlists[c.playlists.count - 1].entries[.oneLibrary] = [1 + shift]
        #expect(UsbLibraryDiff.compare(a, c, options: .init(ignoreIDs: true)).differences.map(\.field) == ["entries.oneLibrary"])
    }

    @Test func skipTables() {
        let a = Self.merged()
        var b = a
        b.artists[0].name = "다른 아티스트"
        b.tracks[0].title = "다른 제목"
        let result = UsbLibraryDiff.compare(a, b, options: .init(skipTables: ["artist"]))
        #expect(result.differences.map(\.table) == ["content"])
        #expect(!result.summaries.contains { $0.table == "artist" })
    }

    @Test func formatsOptionComparesOnlyThatFormatsFields() {
        let a = Self.merged()
        var b = a
        b.tracks[0].lyricist = "다른 작사"
        #expect(UsbLibraryDiff.compare(a, b, options: .init(formats: [.oneLibrary])).differences.isEmpty)
        #expect(UsbLibraryDiff.compare(a, b, options: .init(formats: [.deviceLibrary])).differences.map(\.field) == ["lyricist"])
        #expect(UsbLibraryDiff.compare(a, b, options: .init()).differences.map(\.field) == ["lyricist"])

        var c = a
        c.tracks[0].titleForSearch = "다른 검색"
        #expect(UsbLibraryDiff.compare(a, c, options: .init(formats: [.deviceLibrary])).differences.isEmpty)
        #expect(UsbLibraryDiff.compare(a, c, options: .init(formats: [.oneLibrary])).differences.map(\.field) == ["titleForSearch"])
        #expect(UsbLibraryDiff.compare(a, c, options: .init()).differences.map(\.field) == ["titleForSearch"])

        // 형식별로 나뉜 칸도 그 형식 것만 본다
        var d = a
        d.tracks[0].deviceFields[.deviceLibrary]?.rating = 5
        d.playlists[0].entries[.deviceLibrary] = [2, 1]
        #expect(UsbLibraryDiff.compare(a, d, options: .init(formats: [.oneLibrary])).differences.isEmpty)
        #expect(Set(UsbLibraryDiff.compare(a, d, options: .init(formats: [.deviceLibrary])).differences.map(\.field))
            == ["deviceFields.deviceLibrary", "entries.deviceLibrary"])
    }
}
