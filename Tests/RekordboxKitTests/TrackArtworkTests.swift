import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing
import UniformTypeIdentifiers

/// 곡을 넣을 때 만드는 아트워크 파일 셋. 기대값은 rekordbox 7.2.18이 만든 라이브러리 아트워크(2026-09-26, 스냅샷 사본·share 읽기 전용 조사):
/// 경로는 아트워크 있는 곡 전부, 크기·JPEG 머리는 파일 19,914개 전부 같은 규칙이었다.
@Suite("곡 아트워크 파일")
struct TrackArtworkTests {
    @Test func 경로는_곡_UUID로_정한다() {
        #expect(TrackArtwork.imagePath(uuid: "0a1b2c3d-1111-4222-8333-944445555666")
                == "/PIONEER/Artwork/0a1/b2c3d-1111-4222-8333-944445555666/artwork.jpg")
    }

    @Test func 큰_그림은_긴_변을_800으로_줄이고_작은_그림은_그대로() {
        // 라이브러리에서 본 원본 → artwork.jpg 크기
        let seen: [((Int, Int), (Int, Int))] = [
            ((1000, 1000), (800, 800)), ((1500, 1500), (800, 800)), ((900, 784), (800, 697)), ((3311, 3001), (800, 725)),
            ((640, 640), (640, 640)), ((700, 625), (700, 625)), ((500, 442), (500, 442)), ((200, 199), (200, 199)),
        ]
        for (source, expected) in seen {
            let size = TrackArtwork.fullSize(width: source.0, height: source.1)
            #expect(size.width == expected.0 && size.height == expected.1, "\(source) → \(size)")
        }
        #expect(TrackArtwork.fullSize(width: 784, height: 900) == (697, 800), "세로가 긴 그림")
    }

    @Test func 세_파일은_rekordbox와_같은_JPEG_머리를_가진다() throws {
        let files = try #require(TrackArtwork.make(ImageFixture.image(width: 1000, height: 500)))
        for (data, size) in [(files.full, (800, 400)), (files.medium, (240, 240)), (files.small, (80, 80))] {
            let segments = ImageFixture.jpegSegments(data)
            #expect(segments.map(\.marker) == [0xE0, 0xDB, 0xDB, 0xC0, 0xC4, 0xC4, 0xC4, 0xC4, 0xDA])
            #expect(segments[0].body.hex == "4a46494600010100000100010000", "JFIF 1.01, 비율 1:1, 썸네일 없음")
            // libjpeg 품질 85 표(휘도·색차, 지그재그 순서)
            #expect(segments[1].body.hex == Self.luminance85 && segments[2].body.hex == Self.chrominance85)
            // 기준선 8비트, 높이·너비, Y 2x2(표 0)·Cb·Cr 1x1(표 1)
            let sof = segments[3].body
            #expect(sof.prefix(5).hex == String(format: "08%04x%04x", size.1, size.0) && sof.dropFirst(5).hex == "03012200021101031101")
            // 허프만 표는 DC0·AC0·DC1·AC1 순서로 하나씩(최적화라 내용은 그림마다 다르다)
            #expect(segments[4...7].map { $0.body.first } == [0x00, 0x10, 0x01, 0x11])
            #expect(segments[8].body.hex == "03010002110311003f00")
            #expect(data.suffix(2).hex == "ffd9")
            let decoded = try #require(ImageFixture.pixels(data))
            #expect(decoded.width == size.0 && decoded.height == size.1)
        }
    }

    @Test func 다시_인코딩한_그림은_원본과_거의_같다() throws {
        let source = ImageFixture.image(width: 600, height: 400)
        let files = try #require(TrackArtwork.make(source))
        let before = try #require(ImageFixture.pixels(source)), after = try #require(ImageFixture.pixels(files.full))
        #expect(after.width == 600 && after.height == 400)
        let diff = zip(before.rgb, after.rgb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        #expect(Double(diff) / Double(before.rgb.count) < 3, "평균 차이 \(Double(diff) / Double(before.rgb.count))")
    }

    @Test func 정사각이_아니면_검은_여백으로_가운데_맞춘다() throws {
        // 1000x500 → 240x120, 80x40이 가운데(위아래 여백 60·20줄)
        let files = try #require(TrackArtwork.make(ImageFixture.image(width: 1000, height: 500)))
        let medium = try #require(ImageFixture.pixels(files.medium)), small = try #require(ImageFixture.pixels(files.small))
        for row in [0, 30, 56, 184, 210, 239] { #expect(ImageFixture.rowBrightness(medium, row: row) < 8, "중간 \(row)줄") }
        for row in [64, 120, 176] { #expect(ImageFixture.rowBrightness(medium, row: row) > 60, "중간 \(row)줄") }
        for row in [0, 17, 62, 79] { #expect(ImageFixture.rowBrightness(small, row: row) < 8, "작은 \(row)줄") }
        for row in [22, 40, 57] { #expect(ImageFixture.rowBrightness(small, row: row) > 60, "작은 \(row)줄") }
    }

    @Test func 작은_그림은_중간_크기로_키운다() throws {
        // 200x200 → 240x240을 꽉 채운다(라이브러리의 200x200 원본과 같음)
        let files = try #require(TrackArtwork.make(ImageFixture.image(width: 200, height: 200)))
        let full = try #require(ImageFixture.pixels(files.full)), medium = try #require(ImageFixture.pixels(files.medium))
        #expect(full.width == 200 && full.height == 200)
        for row in [0, 1, 120, 238, 239] { #expect(ImageFixture.rowBrightness(medium, row: row) > 60, "\(row)줄") }
    }

    @Test func PNG도_JPEG로_만든다() throws {
        let files = try #require(TrackArtwork.make(ImageFixture.image(width: 300, height: 300, type: .png)))
        #expect(ImageFixture.jpegSegments(files.full).first?.marker == 0xE0)
        #expect(ImageFixture.pixels(files.full).map { ($0.width, $0.height) } ?? (0, 0) == (300, 300))
    }

    @Test func 풀_수_없는_그림은_만들지_않는다() {
        #expect(TrackArtwork.make(Data("그림 아님".utf8)) == nil)
        #expect(TrackArtwork.make(Data()) == nil)
    }

    // MARK: 태그

    @Test func 태그에서_내장_아트워크를_읽는다() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = ImageFixture.image(width: 64, height: 64)
        let mp3 = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"), artwork: image, in: folder)
        #expect(try await AudioTags.read(url: mp3).artwork == image)
        #expect(try await AudioTags.read(url: try TestResources.url("mp3-notag-cbr.mp3")).artwork == nil)
    }

    /// rekordbox 아트워크 DQT 두 개(표 번호 바이트 포함)
    static let luminance85 = "000503040404030504040405050506070c08070707070f0b0b090c110f1212110f111113161c1713141a1511111821181a1d1d1f1f1f13172224221e241c1e1f1e"
    static let chrominance85 = "010505050706070e08080e1e1411141e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e"
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
