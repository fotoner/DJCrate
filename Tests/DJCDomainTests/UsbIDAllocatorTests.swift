import DJCDomain
import Foundation
import Testing

@Suite("USB ID 배정")
struct UsbIDAllocatorTests {
    @Test("새 USB는 1부터")
    func newStartsAt1() {
        var ids = UsbIDAllocator()
        #expect(ids.next(.content) == 1)
        #expect(ids.next(.content) == 2)
        #expect(ids.next(.playlist) == 1)
    }

    @Test("산 행·죽은 행·저널 highWater 중 가장 큰 값 다음")
    func existingMaxPlusOne() {
        var ids = UsbIDAllocator(highWater: [.content: 7])
        ids.observe(.content, 5)
        ids.observe(.content, 9)
        #expect(ids.next(.content) == 10)
    }

    @Test("지운 ID를 다시 쓰지 않는다")
    func neverReuses() {
        var ids = UsbIDAllocator()
        let first = ids.next(.image)
        let second = ids.next(.image)
        // 지운 뒤에 다시 관찰해도(작은 값) 앞으로만 간다
        ids.observe(.image, first)
        #expect(ids.next(.image) == second + 1)
        #expect(ids.highWater[.image] == second + 1)
    }

    @Test("종류마다 따로 센다")
    func kindsIndependent() {
        var ids = UsbIDAllocator()
        ids.observe(.artist, 40)
        #expect(ids.next(.artist) == 41)
        #expect(ids.next(.album) == 1)
        #expect(ids.next(.genre) == 1)
        #expect(ids.next(.content) == 1)
    }

    @Test("저널에 적고 다시 읽는다")
    func codableRoundTrip() throws {
        var ids = UsbIDAllocator(highWater: [.content: 3, .label: 8])
        ids.observe(.key, 12)
        _ = ids.next(.playlist)
        let data = try JSONEncoder().encode(ids)
        let decoded = try JSONDecoder().decode(UsbIDAllocator.self, from: data)
        #expect(decoded.highWater == ids.highWater)
        // 종류 이름을 키로 쓰는 객체(저널을 사람이 읽을 수 있게)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let highWater = object?["highWater"] as? [String: Int]
        #expect(highWater?["content"] == 3)
        #expect(highWater?["key"] == 12)
        #expect(highWater?["playlist"] == 1)
    }
}
