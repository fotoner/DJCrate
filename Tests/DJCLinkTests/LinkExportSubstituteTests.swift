@testable import DJCLink
import Foundation
import Testing

/// FLAC·ALAC을 WAV로 바꿔 끼울 때(#277): 같은 음원을 가리키는 곡이 여럿이면 경로·형식·곡 정보를 모두 함께 바꾼다(PR #279 리뷰).
/// 경로만 모두 바꾸고 형식은 한 곡만 바꾸면 나머지 곡이 WAV 경로를 FLAC 형식으로 내보낸다.
@Suite("LINK WAV 바꿔 끼우기")
struct LinkExportSubstituteTests {
    @Test func 같은_원본을_가리키는_행과_곡_id를_모두_고른다() {
        let paths = ["/m/a.flac", "/m/b.mp3", "/m/a.flac", "/m/c.flac"]
        let ids: [UInt64] = [11, 12, 13, 14]
        let shared = LinkExportServer.substitutionTargets(paths: paths, ids: ids, of: 0)
        #expect(shared.map(\.row) == [0, 2])
        #expect(shared.map(\.id) == ["11", "13"])
        #expect(LinkExportServer.substitutionTargets(paths: paths, ids: ids, of: 3).map(\.id) == ["14"])
        #expect(LinkExportServer.substitutionTargets(paths: paths, ids: ids, of: 9).isEmpty)
    }

    @Test func NFS가_여는_폴더는_곡_경로의_앞_세_단계다() {
        // DJLinkKit `Files.exports`: 앞 세 단계 아래에 무엇이 더 있을 때만 폴더를 연다(얕은 경로는 그 파일 하나만)
        let roots = LinkExportServer.exportRoots(trackPaths: ["/Users/dj/Music/a.mp3", "/Users/dj/Music/sub/b.flac",
                                                              "/Volumes/Ext/Music/c.flac", "/Volumes/Ext/d.mp3"])
        #expect(roots == ["/Users/dj/Music", "/Volumes/Ext/Music"])
    }

    @Test func 읽기_전용_음원은_세션이_소유한_별도_파일로_제공하고_종료하면_정리한다() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "djc-approved-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let song = root.appending(path: "song.flac")
        try Data([3, 5, 7]).write(to: song)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: song.path)
        var track = LinkExportTrack(id: 2, title: "곡", artist: "", album: "", genre: "", key: "", bpmX100: 0, lengthSeconds: 0,
                                    path: song.path, analysisPath: "", fileType: 5, bitrate: 0, rating: 0, comment: "", cues: [])
        let alias: String, directory: String
        do {
            let files = try LinkExportFiles(tracks: [track], shareRoot: root.path, protected: [], allowsAudio: { _ in true })
            alias = try #require(files.tracks.first?.path)
            directory = files.directory
            let sourceID = try fm.attributesOfItem(atPath: song.path)[.systemFileNumber] as? NSNumber
            let servedID = try fm.attributesOfItem(atPath: alias)[.systemFileNumber] as? NSNumber
            #expect(sourceID != nil && servedID != nil && sourceID != servedID)
            #expect(try Data(contentsOf: URL(fileURLWithPath: alias)) == Data([3, 5, 7]))
            #expect(LinkExportServer.exportRoots(trackPaths: [alias]).isEmpty)
        }
        #expect(!fm.fileExists(atPath: alias) && !fm.fileExists(atPath: directory))
        var missing = track
        missing.id = 1
        missing.path = root.appending(path: "absent.flac").path
        track.id = 3
        let files = try LinkExportFiles(tracks: [missing, track], shareRoot: root.path, protected: [], allowsAudio: { _ in true })
        #expect(files.tracks.map(\.id) == [3])
    }

    @Test func 공개_API의_경로_검사도_민감한_폴더와_상위_폴더를_거부한다() {
        let protected = ["/fixture/librarydata", "/fixture/rekordbox"]
        for path in ["/Users/demo/Library/Pioneer/one.wav", "/fixture/rekordbox/share/two.mp3",
                     "/fixture/LibraryData/three.mp3", "/fixture/.private/four.wav", "/fixture", "/"] {
            #expect(!LinkExportFiles.allowsLocalAudio(path, protected: protected))
        }
        #expect(LinkExportFiles.allowsLocalAudio("/fixture/librarydata-other/one.wav", protected: protected))
    }

    @Test func 음원과_등록한_분석·그림만_세션에서_열_수_있다() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "djc-link-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let rootPath = LinkExportFiles.comparablePath(root.path)
        let analysis = "/PIONEER/USBANLZ/A/ANLZ0000.DAT", art = "/PIONEER/Artwork/A/cover.jpg"
        for path in ["/music/song.mp3", "/music/other.mp3", analysis, art,
                     "/PIONEER/USBANLZ/A/ANLZ0000.EXT", "/PIONEER/Artwork/A/cover_s.jpg"] {
            let url = URL(fileURLWithPath: rootPath + path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        let wave = rootPath + "/music/converted.wav"
        try Data([1, 2]).write(to: URL(fileURLWithPath: wave))
        let song = rootPath + "/music/song.mp3"
        var track = LinkExportTrack(id: 1, title: "곡", artist: "", album: "", genre: "", key: "", bpmX100: 0, lengthSeconds: 0,
                                    path: song, analysisPath: analysis, artworkPath: art, fileType: 1, bitrate: 0, rating: 0, comment: "", cues: [])
        let files = try LinkExportFiles(tracks: [track], shareRoot: rootPath, protected: [rootPath + "/data"], allowsAudio: { LinkExportFiles.comparablePath($0) == song })
        let converted = try #require(files.convertedWAV(wave, cache: rootPath + "/music"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: converted)) == Data([1, 2]))
        #expect(files.convertedWAV(wave, cache: rootPath) == nil)
        #expect(files.convertedWAV(rootPath + "/music/other.mp3", cache: rootPath + "/music") == nil)
        let input = try #require(files.audioPaths[1])
        #expect(input.hasSuffix(".mp3") && input.hasPrefix(files.directory + "/"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: input)) == Data("/music/song.mp3".utf8))
        let staged = try fm.attributesOfItem(atPath: input)
        #expect(staged[.posixPermissions] as? Int == 0o400)
        #expect(try fm.attributesOfItem(atPath: files.tracks[0].path)[.systemFileNumber] as? NSNumber == staged[.systemFileNumber] as? NSNumber)
        #expect(converted.hasPrefix(files.directory + "/"))
        let served = try #require(files.tracks.first)
        #expect(LinkExportServer.exportRoots(trackPaths: [served.path]).isEmpty)
        #expect(files.originalByAlias == [served.path: song])
        #expect(try Data(contentsOf: URL(fileURLWithPath: served.path)) == Data("/music/song.mp3".utf8))
        let catalog = URL(fileURLWithPath: files.directory)
        #expect(try Data(contentsOf: catalog.appending(path: served.analysisPath)) == Data(analysis.utf8))
        #expect(try Data(contentsOf: catalog.appending(path: served.artworkPath)) == Data(art.utf8))
        #expect(try fm.contentsOfDirectory(atPath: catalog.appending(path: served.analysisPath).deletingLastPathComponent().path).sorted()
                == ["analysis.DAT", "analysis.EXT", "art.jpg", "art_s.jpg"])
        let copied = try LinkExportFiles(tracks: [track], shareRoot: rootPath, protected: [], clone: { _, _ in EXDEV },
                                         allowsAudio: { _ in true })
        let asset = try #require(copied.tracks.first)
        for (path, bytes) in [(asset.path, "/music/song.mp3"), (copied.directory + asset.analysisPath, analysis),
                              (copied.directory + asset.artworkPath, art),
                              (copied.directory + "/assets/0/analysis.EXT", "/PIONEER/USBANLZ/A/ANLZ0000.EXT"),
                              (copied.directory + "/assets/0/art_s.jpg", "/PIONEER/Artwork/A/cover_s.jpg")] {
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(bytes.utf8))
        }
        track.analysisPath = "/PIONEER/Artwork/A/cover.jpg"
        track.artworkPath = "/PIONEER/CDP/other.jpg"
        let omitted = try LinkExportFiles(tracks: [track], shareRoot: rootPath, protected: [rootPath + "/data"], allowsAudio: { LinkExportFiles.comparablePath($0) == song })
        #expect(omitted.tracks[0].analysisPath.isEmpty && omitted.tracks[0].artworkPath.isEmpty)
        let sessions = root.appending(path: "sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: false)
        #expect(throws: LinkExportError.unsafeFile) {
            _ = try LinkExportFiles(tracks: [track], shareRoot: rootPath, protected: [], temporaryDirectory: sessions, allowsAudio: { _ in false })
        }
        #expect(try fm.contentsOfDirectory(atPath: sessions.path).isEmpty)
    }
}
