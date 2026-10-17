import DJCLink
import Testing

/// CDJ로 갈 인터페이스 고르기(#273). 2026-10-16 실기: CDJ는 유선(169.254/16)에 있는데 경로표가 Wi‑Fi를 골라 알림이 닿지 않았다.
@Suite("LINK 인터페이스 고르기")
struct LinkSubnetTests {
    static let wifi = (address: [UInt8]([192, 168, 1, 31]), netmask: [UInt8]([255, 255, 255, 0]))
    static let wired = (address: [UInt8]([169, 254, 82, 66]), netmask: [UInt8]([255, 255, 0, 0]))

    @Test func CDJ와_같은_서브넷의_유선을_고른다() {
        #expect(LinkSubnet.pick(peer: [169, 254, 86, 193], among: [Self.wifi, Self.wired]) == 1)
    }

    @Test func 같은_서브넷이_없으면_고르지_않는다() {
        #expect(LinkSubnet.pick(peer: [10, 0, 0, 5], among: [Self.wifi, Self.wired]) == nil)
    }

    @Test func 여럿이_품으면_마스크가_좁은_쪽을_고른다() {
        let wide = (address: [UInt8]([10, 0, 0, 1]), netmask: [UInt8]([255, 0, 0, 0]))
        let narrow = (address: [UInt8]([10, 1, 2, 1]), netmask: [UInt8]([255, 255, 255, 0]))
        #expect(LinkSubnet.pick(peer: [10, 1, 2, 9], among: [wide, narrow]) == 1)
    }
}
