import DJCDomain
import Foundation
import Testing

/// 파일이 없는 곡 모아 보기(#126): 로컬 곡만 보고, 연결되지 않은 외장 디스크는 볼륨째 묶는다.
@Suite("파일이 없는 곡")
struct MissingFilesTests {
    static func track(_ id: String, _ path: String) -> Track {
        Track(id: id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: path, comment: "",
              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    /// 가짜 파일 시스템: 있는 경로만 들고, 무엇을 물었는지 적어 둔다.
    final class FakeFiles: @unchecked Sendable {
        let existing: Set<String>
        private(set) var asked: [String] = []
        init(_ existing: Set<String>) { self.existing = existing }
        func exists(_ path: String) -> Bool {
            asked.append(path)
            return existing.contains(path)
        }
    }

    @Test func 없는_로컬_파일만_모으고_스트리밍_곡은_확인하지_않는다() {
        let files = FakeFiles(["/Users/dj/Music/a.mp3"])
        let result = MissingFiles.scan([Self.track("1", "/Users/dj/Music/a.mp3"), Self.track("2", "/Users/dj/Music/b.mp3"),
                                        Self.track("3", "apple-music:123"), Self.track("4", "spotify:track:abc")],
                                       exists: files.exists)
        #expect(result.trackIDs == ["2"])
        #expect(result.unmountedVolumes.isEmpty)
        #expect(!files.asked.contains { !$0.hasPrefix("/") })
    }

    @Test func 연결되지_않은_외장_디스크는_볼륨째_묶고_곡마다_확인하지_않는다() {
        let files = FakeFiles(["/Volumes/DJ SSD", "/Volumes/DJ SSD/a.mp3"])
        let result = MissingFiles.scan([
            Self.track("1", "/Volumes/DJ SSD/a.mp3"), Self.track("2", "/Volumes/DJ SSD/gone.mp3"),
            Self.track("3", "/Volumes/USB A/x/1.mp3"), Self.track("4", "/Volumes/USB A/x/2.mp3"),
            Self.track("5", "/Volumes/USB B/3.mp3"), Self.track("6", "/Volumes/USB A/x/3.mp3"),
        ], exists: files.exists)
        #expect(result.trackIDs == ["2", "3", "4", "5", "6"])
        // 곡이 많은 디스크부터. 연결된 디스크(DJ SSD)에서 없어진 곡은 디스크 문제로 묶지 않는다.
        #expect(result.unmountedVolumes == [.init(path: "/Volumes/USB A", trackCount: 3), .init(path: "/Volumes/USB B", trackCount: 1)])
        #expect(result.unmountedVolumes.first?.name == "USB A")
        // 볼륨 뿌리는 한 번만, 빠진 디스크의 곡은 하나씩 묻지 않는다.
        #expect(files.asked.filter { $0 == "/Volumes/USB A" }.count == 1)
        #expect(!files.asked.contains { $0.hasPrefix("/Volumes/USB A/") || $0.hasPrefix("/Volumes/USB B/") })
    }

    @Test func 볼륨_뿌리는_Volumes_아래_이름까지다() {
        #expect(MissingFiles.volumeRoot(of: "/Volumes/DJ USB/Music/a.mp3") == "/Volumes/DJ USB")
        #expect(MissingFiles.volumeRoot(of: "/Volumes/DJ USB/a.mp3") == "/Volumes/DJ USB")
        #expect(MissingFiles.volumeRoot(of: "/Users/dj/Music/a.mp3") == nil)
        #expect(MissingFiles.volumeRoot(of: "/Volumes/a.mp3") == nil)
        #expect(MissingFiles.volumeRoot(of: "/Volumes//a.mp3") == nil)
        #expect(MissingFiles.volumeRoot(of: "/VolumesX/a/b.mp3") == nil)
    }

    @Test func 필터는_파일이_없는_로컬_곡만_고른다() {
        let local = Self.track("1", "/Users/dj/Music/a.mp3"), streaming = Self.track("2", "apple-music:1")
        func includes(_ filter: LibraryFilter, _ track: Track, missing: Bool) -> Bool {
            filter.includes(track: track, comment: nil, hasCues: true, playCount: 0, tempoChanges: [], fileMissing: missing)
        }
        #expect(includes(.missingFile, local, missing: true))
        #expect(!includes(.missingFile, local, missing: false))
        #expect(!includes(.missingFile, streaming, missing: true))
        #expect(includes(.all, local, missing: true))
        #expect(!includes(.noCues, local, missing: true))
        #expect(LibraryFilter.missingFile.cliName == "missing-file")
        #expect(LibraryFilter.missingFile.title == String(ui: "파일 없음"))
        #expect(!LibraryFilter.missingFile.requiresCommentRule)
        #expect(LibraryFilter.visible(commentPreset: .none).contains(.missingFile))
    }
}
