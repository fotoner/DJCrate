import DJCDomain
@testable import RekordboxKit
import Foundation
import Testing

@Suite("rekordbox 비트 그리드")
struct BeatGridTests {
    /// PMAI 헤더 + PQTZ 태그를 가진 최소 ANLZ 파일을 만든다.
    func anlz(beats: [(Int, Int, Int)]) -> Data {
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        var tag = Array("PQTZ".utf8) + u32(24) + u32(24 + beats.count * 8) + u32(0) + u32(0x80000) + u32(beats.count)
        for (number, bpm100, ms) in beats { tag += u16(number) + u16(bpm100) + u32(ms) }
        let header = Array("PMAI".utf8) + u32(28) + u32(28 + tag.count) + [UInt8](repeating: 0, count: 16)
        return Data(header + tag)
    }

    @Test func PQTZ를_읽고_스냅_이동_마디를_계산한다() throws {
        // 120 BPM, 0.5초 간격, 첫 박은 4박째
        let beats = (0..<9).map { i in ((i + 3) % 4 + 1, 12000, 100 + i * 500) }
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-test-\(UUID()).DAT")
        try anlz(beats: beats).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let grid = try BeatGrid.load(anlz: url)
        #expect(grid.beats.count == 9)
        #expect(grid.beats[0].number == 4 && grid.beats[1].number == 1)
        #expect(grid.beats[0].bpm == 120)
        #expect(grid.snap(0.7) == 0.6)
        #expect(grid.snap(0.86) == 1.1)
        #expect(grid.nudge(1.1, beats: 2) == 2.1)
        #expect(grid.nudge(0.1, beats: -1) == 0.1)
        #expect(grid.bar(at: 0.3) == 0)
        #expect(grid.bar(at: 0.6) == 1)
        #expect(grid.bar(at: 2.6) == 2)
    }

    @Test func 아트워크_경로_크기_변형() {
        let url = RekordboxShare.artworkURL("/PIONEER/Artwork/031/abc/artwork.jpg", size: .small)
        #expect(url?.lastPathComponent == "artwork_s.jpg")
        #expect(RekordboxShare.artworkURL(nil, size: .full) == nil)
    }
}
