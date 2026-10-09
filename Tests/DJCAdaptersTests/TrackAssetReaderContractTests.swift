import CoreGraphics
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import RekordboxFixtures
import RekordboxKit
import Testing

/// 덱 읽기 포트의 실제 구현(`TrackAssetReader.live`): 주입한 share 뿌리에서 분석 파일·그림을 찾는다(DB 없이 임시 폴더에 합성 파일).
/// 계약: 메모리 구현(`MemoryTrackAssets`, 덱 시험이 쓰는 가짜)에 DJCApplicationTests가 돌리는 같은 계약 함수(PortTestKit)를 돌린다(adv4 T7).
@Suite("덱 읽기 — 실제 파일과 계약")
struct TrackAssetReaderContractTests {
    static let gridPath = "/PIONEER/USBANLZ/grid/ANLZ0000.DAT"
    static let halfPath = "/PIONEER/USBANLZ/half/ANLZ0000.DAT"
    static let beats = AnlzBuilder.beats(bpm: 120, first: 500, count: 8)

    static func put(_ data: Data, at path: String, in share: URL) throws {
        let url = share.appending(path: String(path.dropFirst()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// 합성 share: 그리드·파형 파일이 다 있는 곡, `.DAT`만 있는 반쪽 곡. 음원 WAV 하나
    struct Fixture {
        let folder: TemporaryFolder
        let share: URL
        let audio: URL

        init() throws {
            folder = try TemporaryFolder(prefix: "djc-asset-reader")
            share = folder.url.appending(path: "share")
            try put(AnlzBuilder.dat(beats: beats), at: gridPath, in: share)
            try put(AnlzBuilder.ext(beats: beats), at: gridPath.replacingOccurrences(of: ".DAT", with: ".EXT"), in: share)
            try put(AnlzBuilder.dat(beats: beats), at: halfPath, in: share)
            audio = try AudioFixture.wav(seconds: 1, in: folder.url)
        }
    }

    @Test func 실제_구현() throws {
        let fixture = try Fixture()
        trackAssetReaderContract(.live(drafts: MemoryDrafts().store),
                                 TrackAssetContractFiles(share: fixture.share, gridPath: Self.gridPath, halfPath: Self.halfPath,
                                                         beatTimes: Self.beats.map { $0.time / 1000 }, audio: fixture.audio,
                                                         missingAudio: fixture.folder.url.appending(path: "없음.wav")))
    }

    @Test(arguments: ["missing", "unreadable", "empty"])
    func 분석_파일의_부재와_읽기_실패와_박_없음을_구분한다(kind: String) throws {
        let folder = try TemporaryFolder(prefix: "djc-deck-reader")
        let share = folder.url.appending(path: "share")
        switch kind {
        case "unreadable": try Self.put(Data("broken".utf8), at: Self.gridPath, in: share)
        case "empty": try Self.put(AnlzBuilder.dat(beats: []), at: Self.gridPath, in: share)
        default: break
        }
        let read = TrackAssetReader.readGrid(Self.gridPath, shareRoot: share)
        switch kind {
        case "missing": #expect(read == .missing)
        case "unreadable": #expect(read == .unreadable)
        default: #expect(read == .noBeats)
        }
    }

    @Test func 그림은_주입한_share에서_줄여_읽는다() async throws {
        let folder = try TemporaryFolder(prefix: "djc-deck-reader")
        let share = folder.url.appending(path: "share")
        try Self.put(ImageFixture.image(width: 800, height: 400), at: "/PIONEER/Artwork/00001/a.jpg", in: share)
        let reader = TrackAssetReader.live(drafts: MemoryDrafts().store)
        let artwork = try #require(reader.artwork("/PIONEER/Artwork/00001/a.jpg", share, 360))
        #expect(max(artwork.image.width, artwork.image.height) == 360)
        #expect(reader.artwork("/PIONEER/Artwork/00001/none.jpg", share, 360) == nil)
        // 음원에 든 그림이 없으면 nil
        #expect(await reader.embeddedArtwork(try AudioFixture.wav(seconds: 1, in: folder.url)) == nil)
    }

    @Test func 색_파형은_분석_파일의_EXT에서_rekordbox_시간축으로_읽는다() throws {
        let folder = try TemporaryFolder(prefix: "djc-deck-reader")
        let share = folder.url.appending(path: "share")
        try Self.put(AnlzBuilder.file([AnlzBuilder.waveform("PWV3", entryBytes: 1, samples: Array(repeating: 31, count: 300))]),
                     at: Self.gridPath.replacingOccurrences(of: ".DAT", with: ".EXT"), in: share)
        let reader = TrackAssetReader.live(drafts: MemoryDrafts().store)
        let source = try #require(reader.colorWaveform(Self.gridPath, share, .blue))
        #expect(source.columns.count == 300 && source.rate == 150)
        #expect(reader.colorWaveform(Self.gridPath, share, .threeBand) == nil, "3밴드는 자체 파형으로 그린다")
        #expect(reader.colorWaveform(nil, share, .blue) == nil)
    }
}
