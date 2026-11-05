import DJCLink
import Testing

/// 장치 알림(keep-alive) 읽기. 바이트는 2026-10-16 실기 캡처(CDJ-2000nexus, DJM-900NXS2)의 UDP 내용 54바이트 그대로다.
/// MAC은 제조사 앞자리만 남기고 가렸다. DJLinkKit `Tests/DJLinkPassiveTests/PassiveCaptureTests.swift`의 같은 프레임에서
/// 앞 42바이트(Ethernet·IPv4·UDP 머리)를 뗀 것이다. 소켓을 열지 않는다.
@Suite("Pro DJ Link 장치 알림 읽기")
struct LinkDeviceTests {
    static let cdj1KeepAlive = bytes(
        "5173707431576d4a4f4c060043444a2d323030306e6578757300000000000000010200360101745e1c000001a9fe56c0040000000100"
    )
    static let djm33KeepAlive = bytes(
        "5173707431576d4a4f4c0600444a4d2d3930304e585332000000000000000000010200362101c83dfc000021a9fe62f2040000000331"
    )

    @Test func CDJ_알림은_번호_이름_플레이어_주소로_읽는다() {
        #expect(LinkDevice.fromAnnouncePacket(Self.cdj1KeepAlive)
            == LinkDevice(number: 1, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.192"))
    }

    @Test func DJM_알림은_믹서로_읽는다() {
        #expect(LinkDevice.fromAnnouncePacket(Self.djm33KeepAlive)
            == LinkDevice(number: 33, name: "DJM-900NXS2", kind: .mixer, address: "169.254.98.242"))
    }

    /// 알림 포트에는 다른 앱의 UDP 방송도 들어온다. 오류가 아니라 장치 없음이다.
    @Test func Pro_DJ_Link가_아닌_내용은_장치가_아니다() {
        #expect(LinkDevice.fromAnnouncePacket([0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x01, 0x02]) == nil)
        #expect(LinkDevice.fromAnnouncePacket([]) == nil)
    }

    /// 머리는 맞지만 주소 칸(0x2c) 앞에서 끊긴 알림. DJLinkKit은 던지고, 여기서는 장치 없음으로 본다.
    @Test func 주소_칸_앞에서_끊긴_알림은_장치가_아니다() {
        #expect(LinkDevice.fromAnnouncePacket(Array(Self.cdj1KeepAlive.prefix(0x2c))) == nil)
    }

    static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}
