import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("중복 후보 JSON")
struct DuplicateReadTests {
    private func fixture() throws -> RekordboxFixture { try duplicateLibraryFixture() }

    @Test func 후보_JSON은_원본_큐와_직접_소속과_재생수와_음질을_비교한다() throws {
        let fixture = try fixture()
        let before = try Data(contentsOf: fixture.database)
        let read = try LibraryReadTests().reader(fixture)
        let result = read.duplicates()
        #expect(result.lengthToleranceSeconds == 2)
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        #expect(group.tracks.map(\.id) == ["101", "102"])
        #expect(group.tracks.map(\.cueCount) == [2, 0])
        #expect(group.tracks.map(\.manualCueCount) == [1, 0])
        #expect(group.tracks.map(\.playlistCount) == [2, 1])
        #expect(group.tracks.map(\.playCount) == [2, 0])
        #expect(group.tracks.map(\.format) == ["MP3", "FLAC"])
        #expect(group.tracks.map(\.bitrateKbps) == [320, nil])
        let data = try LibraryReadTests().json("duplicates", result)
        #expect(Set(data.keys) == ["lengthToleranceSeconds", "groups"])
        let groups = try #require(data["groups"] as? [[String: Any]])
        let members = try #require(groups.first?["tracks"] as? [[String: Any]])
        #expect(Set(try #require(members.first).keys) == ["track", "cueCount", "manualCueCount", "playlistCount", "playCount", "format", "bitrateKbps"])
        #expect(members.last?["bitrateKbps"] == nil)
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "home").path))
    }

    @Test(arguments: ["0", "-1", "NULL"])
    func 비트레이트가_없거나_양수가_아니면_알수없음이다(value: String) throws {
        let fixture = try fixture()
        try fixture.execute("UPDATE djmdContent SET BitRate = \(value)")
        let members = try LibraryReadTests().reader(fixture).duplicates().groups.flatMap(\.tracks)
        #expect(members.count == 2 && members.allSatisfy { $0.bitrateKbps == nil })
    }

    /// 곡 목록과 같은 썸네일을 보이려고 후보마다 `ImagePath`를 넘긴다(#123). rekordbox는 그림이 없으면 빈 값이나 NULL을 둔다.
    @Test(arguments: ["''", "NULL"])
    func 후보는_곡의_아트워크_경로를_함께_준다(empty: String) throws {
        let fixture = try fixture()
        let path = TrackArtwork.imagePath(uuid: "track-101")
        try fixture.execute("UPDATE djmdContent SET ImagePath = '\(path)' WHERE ID = '101'")
        try fixture.execute("UPDATE djmdContent SET ImagePath = \(empty) WHERE ID = '102'")
        let result = try LibraryReadTests().reader(fixture).duplicates()
        let members = try #require(result.groups.first).tracks
        #expect(members.map(\.imagePath) == [path, nil])
        let data = try LibraryReadTests().json("duplicates", result)
        let encoded = try #require((data["groups"] as? [[String: Any]])?.first?["tracks"] as? [[String: Any]])
        #expect(encoded.first?["imagePath"] as? String == path)
        #expect(encoded.last?.keys.contains("imagePath") == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_DUPLICATES_FIXTURE"] != nil))
    func 화면확인용_합성_사본() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_DUPLICATES_FIXTURE"] else { return }
        let fixture = try fixture()
        try FileManager.default.copyItem(at: fixture.root, to: URL(filePath: path))
    }

    /// 앨범 아트 확인용(#123): 후보 400곡. 묶음마다 같은 그림 둘 · 한쪽만 그림 · 서로 다른 그림을 돌려 쓴다(합성 그러데이션).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_DUPLICATES_ARTWORK_FIXTURE"] != nil))
    func 화면확인용_아트워크_합성_사본() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_DUPLICATES_ARTWORK_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        try fixture.insert("djmdArtist", ["ID": .text("a1"), "Name": .text("합성 아티스트")])
        let palette = [40, 110, 180, 250].map { blue in
            [("artwork.jpg", 240), ("artwork_m.jpg", 240), ("artwork_s.jpg", 80)].map { name, side in
                (name, ImageFixture.image(width: side, height: side, blue: UInt8(blue)))
            }
        }
        for group in 0..<200 {
            for copy in 0..<2 {
                var track = TrackSpec(id: "\(1000 + group * 2 + copy)", uuid: String(format: "dup%05d", group * 2 + copy))
                track.title = String(format: "합성 중복 %03d", group + 1)
                track.artistID = "a1"
                track.length = 200 + copy
                track.folderPath = String(format: "/synthetic/%03d-%@.mp3", group + 1, copy == 0 ? "a" : "b")
                let art: Int? = switch group % 3 {
                case 0: group % 4
                case 1: copy == 0 ? group % 4 : nil
                default: (group + copy) % 4
                }
                if let art {
                    track.imagePath = TrackArtwork.imagePath(uuid: track.uuid)
                    let folder = fixture.shareRoot.appending(path: String(TrackArtwork.folder(uuid: track.uuid).dropFirst()))
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for (name, data) in palette[art] { try data.write(to: folder.appending(path: name)) }
                }
                try fixture.add(track)
            }
        }
        try FileManager.default.copyItem(at: fixture.root, to: URL(filePath: path))
    }
}
