import DJCDomain
@testable import RekordboxKit
import Foundation
import Testing

@Suite("분석 파일 읽기")
struct AnlzReadTests {
    @Test func 박_개수가_터무니없는_분석_파일도_안전하다() throws {
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        // 박 개수 필드는 40억인데 실제 항목은 2개뿐인 PQTZ
        var tag = Array("PQTZ".utf8) + u32(24) + u32(24 + 16) + u32(0) + u32(0x80000) + u32(4_000_000_000)
        tag += [0, 1, 0x2E, 0xE0] + u32(100) + [0, 2, 0x2E, 0xE0] + u32(600)
        let data = Data(Array("PMAI".utf8) + u32(28) + u32(28 + tag.count) + [UInt8](repeating: 0, count: 16) + tag)
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-bad-\(UUID()).DAT")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try BeatGrid.load(anlz: url).beats.count == 2)
    }
}
