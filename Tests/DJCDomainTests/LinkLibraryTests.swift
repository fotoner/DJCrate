import DJCDomain
import Foundation
import Testing

/// LINK로 내어 줄 라이브러리(#273): 내어 줄 곡 고르기, 번호 매기기, 형식 번호, 큐, 재생 목록 나무.
@Suite("LINK 라이브러리 만들기")
struct LinkLibraryTests {
    static func row(_ id: String, path: String = "/Users/dj/Music/Song.mp3", deleted: Bool = false, cues: [Cue] = [],
                    missing: Bool = false) -> TrackRow {
        let track = Track(id: id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: "아티스트", album: nil, albumArtist: nil, genre: "House",
                          composer: nil, releaseYear: nil, trackNumber: nil, key: "Am", bpm: 124.5, lengthSeconds: 200,
                          folderPath: path, comment: "메모", importedOn: nil,
                          analysisDataPath: "/PIONEER/USBANLZ/P01/0001/ANLZ0000.DAT", imagePath: nil, isDeleted: deleted,
                          bitrateKbps: 320, rating: 3)
        var row = TrackRow(track: track, cues: cues, playCount: 0)
        row.fileMissing = missing
        return row
    }

    static func cue(kind: Int, at ms: Int, out: Int = 0, color: Int? = nil) -> Cue {
        Cue(id: "c\(kind)-\(ms)", contentID: "1", kind: kind, inMsec: ms, name: "", colorTableIndex: color, outMsec: out)
    }

    @Test func 내어_줄_수_없는_곡은_빼고_번호는_1부터_차례로_매긴다() {
        let rows = [
            Self.row("10"),
            Self.row("djc-1"),
            Self.row("usb:VOL:5"),
            Self.row("11", deleted: true),
            Self.row("12", path: "spotify:track:x"),
            Self.row("13", missing: true),
            Self.row("14", path: "/Users/dj/Music/Song.ogg"),
            Self.row("15", path: "/Users/dj/Music/Song.wav"),
        ]
        let library = LinkLibrary.build(rows: rows, playlists: PlaylistLayout())
        #expect(library.tracks.map(\.contentID) == ["10", "15"])
        #expect(library.tracks.map(\.id) == [1, 2])
        #expect(library.linkID(of: "15") == 2)
        #expect(library.linkID(of: "djc-1") == nil)
        #expect(library.linkID(of: "13") == nil)
    }

    @Test func CDJ_번호로_곡_제목을_찾는다() {
        let library = LinkLibrary.build(rows: [Self.row("10"), Self.row("djc-1"), Self.row("15")], playlists: PlaylistLayout())
        #expect(library.title(ofLinkID: 1) == "곡 10")
        #expect(library.title(ofLinkID: 2) == "곡 15")
        #expect(library.title(ofLinkID: 0) == nil)
        #expect(library.title(ofLinkID: 3) == nil)
    }

    @Test func 음원_경로로_CDJ_번호를_찾는다() {
        // CDJ가 NFS로 읽으려 한 파일이 어느 곡인지 찾는다. 같은 음원을 가리키는 곡이 여럿이면 첫 곡이다
        let library = LinkLibrary.build(rows: [Self.row("10", path: "/Users/dj/Music/A.flac"), Self.row("11", path: "/Users/dj/Music/B.mp3"),
                                               Self.row("12", path: "/Users/dj/Music/A.flac")], playlists: PlaylistLayout())
        #expect(library.linkID(ofPath: "/Users/dj/Music/A.flac") == 1)
        #expect(library.linkID(ofPath: "/Users/dj/Music/B.mp3") == 2)
        #expect(library.linkID(ofPath: "/PIONEER/USBANLZ/P01/0001/ANLZ0000.DAT") == nil)
    }

    @Test func 곡_값을_옮긴다() throws {
        let track = try #require(LinkLibrary.build(rows: [Self.row("10")], playlists: PlaylistLayout()).tracks.first)
        #expect(track.title == "곡 10")
        #expect(track.key == "Am")
        #expect(track.bpmX100 == 12450)
        #expect(track.lengthSeconds == 200)
        #expect(track.path == "/Users/dj/Music/Song.mp3")
        #expect(track.analysisPath == "/PIONEER/USBANLZ/P01/0001/ANLZ0000.DAT")
        #expect(track.fileType == 1)
        #expect(track.bitrateKbps == 320)
        #expect(track.rating == 3)
    }

    @Test func 앨범아트는_rekordbox_ImagePath를_옮기고_없으면_비운다() throws {
        // 2026-10-16 실기: 경로를 넘기지 않아 CDJ 목록·덱에 그림이 하나도 나오지 않았다
        let plain = Self.row("10")
        let withArt = TrackRow(track: Track(id: "11", uuid: "u11", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                            composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                            folderPath: "/Users/dj/Music/11.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                            imagePath: "/PIONEER/Artwork/00001/a1.jpg", isDeleted: false),
                               cues: [], playCount: 0)
        let tracks = LinkLibrary.build(rows: [plain, withArt], playlists: PlaylistLayout()).tracks
        #expect(tracks.map(\.artworkPath) == ["", "/PIONEER/Artwork/00001/a1.jpg"])
    }

    @Test func 형식_번호는_rekordbox_번호를_쓰고_모르는_형식은_뺀다() {
        #expect(LinkLibrary.fileType(ofExtension: "MP3") == 1)
        #expect(LinkLibrary.fileType(ofExtension: "wav") == 11)
        #expect(LinkLibrary.fileType(ofExtension: "aiff") == 12)
        #expect(LinkLibrary.fileType(ofExtension: "m4a") == 4)
        #expect(LinkLibrary.fileType(ofExtension: "flac") == 5)
        #expect(LinkLibrary.fileType(ofExtension: "ogg") == nil)
    }

    @Test func 메모리_큐와_A부터_H까지의_핫_큐만_옮긴다() throws {
        let cues = [Self.cue(kind: 0, at: 1000), Self.cue(kind: 1, at: 2000, color: 3), Self.cue(kind: 4, at: 3000),
                    Self.cue(kind: 9, at: 4000, out: 8000)]
        let track = try #require(LinkLibrary.build(rows: [Self.row("10", cues: cues)], playlists: PlaylistLayout()).tracks.first)
        #expect(track.cues == [
            LinkLibrary.Cue(positionMs: 1000, outMs: 0, hotCue: nil, colour: 0),
            LinkLibrary.Cue(positionMs: 2000, outMs: 0, hotCue: "A", colour: 3),
            LinkLibrary.Cue(positionMs: 4000, outMs: 8000, hotCue: "H", colour: 0),
        ])
    }

    @Test func 큐_초안이_있는_곡은_초안의_큐를_내어_준다() throws {
        // #280: CDJ에서 찍어 초안에 들어간 큐가 LINK를 다시 켜도 CDJ에 남는다
        let rekordbox = [Cue(id: "1", contentID: "10", kind: 0, inMsec: 1_000, name: "", colorTableIndex: nil)]
        let draft = [Cue(id: "1", contentID: "10", kind: 0, inMsec: 1_000, name: "", colorTableIndex: nil),
                     Cue(id: "n", contentID: "10", kind: 2, inMsec: 3_000, name: "", colorTableIndex: nil)]
        let library = LinkLibrary.build(rows: [Self.row("10", cues: rekordbox), Self.row("20", cues: rekordbox)], playlists: PlaylistLayout(),
                                        draftCues: ["10": draft])
        #expect(library.tracks.first { $0.contentID == "10" }?.cues.map(\.positionMs) == [1_000, 3_000])
        #expect(library.tracks.first { $0.contentID == "10" }?.cues.last?.hotCue == "B")
        #expect(library.tracks.first { $0.contentID == "20" }?.cues.map(\.positionMs) == [1_000])
    }

    @Test func 재생_목록은_폴더_나무와_곡_순서를_지키고_스마트_목록과_못_내어_주는_곡은_뺀다() {
        let layout = PlaylistLayout([
            (PlaylistLayout.Item(id: "f", name: "201X", isFolder: true), 0),
            (PlaylistLayout.Item(id: "p1", name: "Bass House", parentID: "f",
                                 entries: [PlaylistEntry(trackNo: 1, contentID: "11"), PlaylistEntry(trackNo: 2, contentID: "djc-1"),
                                           PlaylistEntry(trackNo: 3, contentID: "10"), PlaylistEntry(trackNo: 4, contentID: "11")]), 0),
            (PlaylistLayout.Item(id: "s", name: "Smart", isSmart: true), 1),
            (PlaylistLayout.Item(id: "p2", name: "Dance"), 2),
        ])
        let library = LinkLibrary.build(rows: [Self.row("10"), Self.row("11"), Self.row("djc-1")], playlists: layout)
        #expect(library.playlists == [
            LinkLibrary.Playlist(name: "201X", parent: nil, isFolder: true, trackIDs: []),
            LinkLibrary.Playlist(name: "Bass House", parent: 0, isFolder: false, trackIDs: [2, 1, 2]),
            LinkLibrary.Playlist(name: "Dance", parent: nil, isFolder: false, trackIDs: []),
        ])
    }

    @Test func iTunes_재생_목록은_맨_위_iTunes_폴더_아래_원래_나무대로_두고_컬렉션_곡만_넣는다() {
        let iTunes = SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: [
            .init(id: "F", name: "Club", isFolder: true),
            .init(id: "A1", name: "Warmup", parentID: "F", paths: ["/Users/dj/Music/Song.mp3", "/Users/dj/Music/없는곡.mp3"]),
            .init(id: "A2", name: "Peak", paths: ["/Users/dj/Music/Song.wav"]),
        ]), tracks: [Self.row("10").track, Self.row("15", path: "/Users/dj/Music/Song.wav").track])
        let layout = PlaylistLayout([(PlaylistLayout.Item(id: "r", name: "rekordbox 목록",
                                                          entries: [PlaylistEntry(trackNo: 1, contentID: "15")]), 0)])
        let library = LinkLibrary.build(rows: [Self.row("10"), Self.row("15", path: "/Users/dj/Music/Song.wav")], playlists: layout,
                                        iTunes: iTunes.tree)
        #expect(library.playlists == [
            LinkLibrary.Playlist(name: "iTunes", parent: nil, isFolder: true, trackIDs: []),
            LinkLibrary.Playlist(name: "Club", parent: 0, isFolder: true, trackIDs: []),
            LinkLibrary.Playlist(name: "Warmup", parent: 1, isFolder: false, trackIDs: [1]),
            LinkLibrary.Playlist(name: "Peak", parent: 0, isFolder: false, trackIDs: [2]),
            LinkLibrary.Playlist(name: "rekordbox 목록", parent: nil, isFolder: false, trackIDs: [2]),
        ])
    }

    @Test func iTunes_목록이_없으면_iTunes_폴더를_만들지_않고_나중에_넣을_수_있다() throws {
        var library = LinkLibrary.build(rows: [Self.row("10")], playlists: PlaylistLayout())
        #expect(library.playlists.isEmpty)
        let iTunes = SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: [
            .init(id: "B", name: "Later", paths: ["/Users/dj/Music/Song.mp3"]),
        ]), tracks: [Self.row("10").track])
        library.setPlaylists(layout: PlaylistLayout(), iTunes: iTunes.tree)
        #expect(library.playlists.map(\.name) == ["iTunes", "Later"])
        #expect(library.playlists.last?.trackIDs == [1])
        #expect(library.tracks.count == 1)
    }

    @Test func 바꿀지_볼_음원은_FLAC과_ALAC일_수_있는_m4a·mp4다() {
        #expect(LinkLibrary.mayNeedConversion(path: "/m/a.FLAC"))
        #expect(LinkLibrary.mayNeedConversion(path: "/m/a.m4a"))
        #expect(LinkLibrary.mayNeedConversion(path: "/m/a.mp4"))
        #expect(!LinkLibrary.mayNeedConversion(path: "/m/a.mp3"))
        #expect(!LinkLibrary.mayNeedConversion(path: "/m/a.wav"))
        #expect(!LinkLibrary.mayNeedConversion(path: "/m/a.aiff"))
    }

    @Test func FLAC·ALAC을_재생하는_기종은_NXS2·3000_세대와_새_올인원이다() {
        for model in ["CDJ-3000", "CDJ-3000X", "CDJ-2000NXS2", "XDJ-1000MK2", "XDJ-RX2", "XDJ-RX3", "XDJ-XZ", "XDJ-AZ", "OPUS-QUAD"] {
            #expect(LinkPlayerFormats.playsLossless(model: model), "\(model)")
        }
        // 앞 세대와 모르는 기종은 바꾼다. 이름 앞부분이 같아도(XDJ-RX와 XDJ-RX2) 따로 본다
        for model in ["CDJ-2000nexus", "CDJ-2000", "CDJ-900NXS", "XDJ-1000", "XDJ-700", "XDJ-RX", "XDJ-RX9", ""] {
            #expect(!LinkPlayerFormats.playsLossless(model: model), "\(model)")
        }
    }
}
