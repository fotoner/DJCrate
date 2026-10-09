import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

@Suite("Apple Music XML 가져오기")
struct AppleMusicLibraryTests {
    func xml(tracks: [String: Any], playlists: [[String: Any]] = []) throws -> Data {
        try AppleMusicXMLFixture.xml(tracks: tracks, playlists: playlists)
    }

    func track(_ id: Int, _ extra: [String: Any] = [:]) -> [String: Any] { AppleMusicXMLFixture.track(id, extra) }

    @Test func XML_이스케이프와_파일_URL을_한_번만_푼다() throws {
        let data = try xml(tracks: ["1": track(1, ["Name": "가 & 나 <Live>",
            "Location": "file://localhost/fixtures/%ED%95%9C%EA%B8%80%20%2520.mp3"])])
        let library = try AppleMusicLibrary.parse(data, isReadableFile: { _ in true })
        let item = try #require(library.tracks.first)
        #expect(item.title == "가 & 나 <Live>")
        #expect(item.fileURL?.path == "/fixtures/한글 %20.mp3")
        #expect(item.exclusion == nil)
        #expect(library.id == "TEST-LIBRARY")
    }

    @Test func 로컬_파일만_허용하고_제외_이유를_구분한다() throws {
        let cases: [(Int, [String: Any], AppleMusicLibrary.Exclusion?)] = [
            (1, [:], nil),
            (2, ["Protected": true], .protectedContent),
            (3, ["Apple Music": true], .protectedContent),
            (4, ["Kind": "Protected AAC audio file"], .protectedContent),
            (5, ["Location": "file:///fixtures/song.m4p"], .protectedContent),
            (6, ["Track Type": "URL", "Location": "https://example.invalid/radio"], .streaming),
            (7, ["Location": ""], .cloudOnly),
            (8, ["Location": "file:///fixtures/missing.mp3"], .unavailableFile),
            (9, ["Location": "file://remote/fixtures/song.mp3"], .invalidLocation),
            (10, ["Location": "relative.mp3"], .invalidLocation),
            (11, ["Location": "file:///fixtures/song.txt"], .unsupportedFormat),
            (12, ["Has Video": true], .unsupportedFormat),
            (13, ["Location": "file:///fixtures/song.M4A", "Purchased": true], nil),
            (14, ["Location": "https://example.invalid/song.mp3"], .streaming)
        ]
        let data = try xml(tracks: Dictionary(uniqueKeysWithValues: cases.map { (String($0.0), track($0.0, $0.1)) }))
        let library = try AppleMusicLibrary.parse(data, isReadableFile: { !$0.path.contains("missing") })
        for (id, _, reason) in cases {
            #expect(library.tracks.first { $0.id == id }?.exclusion == reason)
        }
    }

    @Test func 재생_목록_선택과_순서·중복_소속을_기억한다() throws {
        let data = try xml(tracks: ["1": track(1), "2": track(2), "3": track(3, ["Protected": true])], playlists: [
            ["Name": "전체", "Master": true, "Playlist ID": 1],
            ["Name": "폴더", "Folder": true, "Playlist Persistent ID": "FOLDER"],
            ["Name": "목록", "Playlist Persistent ID": "A", "Parent Persistent ID": "FOLDER",
             "Playlist Items": [["Track ID": 2], ["Track ID": 999], ["Track ID": 1], ["Track ID": 2]]],
            ["Name": "목록", "Playlist Persistent ID": "B", "Playlist Items": [["Track ID": 1], ["Track ID": 3]]],
            ["Name": "빈 목록", "Playlist ID": 5]
        ])
        let library = try AppleMusicLibrary.parse(data, isReadableFile: { _ in true })
        #expect(library.playlists.map(\.id) == ["A", "B", "5"])
        #expect(library.selectedTracks(trackIDs: [3], playlistIDs: ["A"]).map(\.id) == [1, 2])
        let origin = library.origin(for: 2)
        #expect(origin.libraryID == "TEST-LIBRARY" && origin.trackID == 2)
        #expect(origin.playlists.map(\.position) == [0, 3])
        #expect(origin.playlists.first?.parentID == "FOLDER")
        #expect(library.origin(for: 1).playlists.map(\.id) == ["A", "B"])
    }

    @Test func 잘못된_XML과_다른_종류의_plist를_거부한다() throws {
        for data in [Data("<plist>broken".utf8), try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .xml, options: 0),
                     try xml(tracks: ["1": track(2)])] {
            #expect(throws: AppleMusicLibrary.ParseError.self) { try AppleMusicLibrary.parse(data) }
        }
        #expect(try AppleMusicLibrary.parse(xml(tracks: [:])).tracks.isEmpty)
    }

    @Test func 실제_파일_존재와_디렉터리를_구분한다() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-music-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let audio = try AudioFixture.wav(seconds: 0.1, in: home)
        let directory = home.appending(path: "directory.mp3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = try AppleMusicLibrary.parse(xml(tracks: [
            "1": track(1, ["Location": audio.absoluteString]), "2": track(2, ["Location": directory.absoluteString])
        ]))
        #expect(library.tracks[0].exclusion == nil)
        #expect(library.tracks[1].exclusion == .unavailableFile)
    }

    @Test func 출처를_저장하고_옛_추가_목록도_읽는다() throws {
        var staged = StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/fixtures/1.mp3", title: "합성 곡", duration: 1, addedOn: "2026-09-27")
        let old = try JSONEncoder().encode(staged)
        #expect(try JSONDecoder().decode(StagedTrack.self, from: old).appleMusicOrigins == nil)
        let library = try AppleMusicLibrary.parse(xml(tracks: ["1": track(1)]), isReadableFile: { _ in true })
        staged.appleMusicOrigins = [library.origin(for: 1)]
        let decoded = try JSONDecoder().decode(StagedTrack.self, from: JSONEncoder().encode(staged))
        #expect(decoded.appleMusicOrigins == staged.appleMusicOrigins)
    }

    @Test func 같은_파일을_다시_가져오면_출처를_갱신한다() {
        var staged = StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/fixtures/1.mp3", title: "합성 곡", duration: 1, addedOn: "2026-09-27")
        let first = AppleMusicOrigin(libraryID: "A", trackID: 1, playlists: [])
        let other = AppleMusicOrigin(libraryID: "B", trackID: 1, playlists: [])
        let updated = AppleMusicOrigin(libraryID: "A", trackID: 1, playlists: [.init(id: "P", name: "목록", parentID: nil, position: 3)])
        staged.rememberAppleMusicOrigins([first, other])
        staged.rememberAppleMusicOrigins([updated, updated])
        #expect(staged.appleMusicOrigins == [updated, other])
    }
}
