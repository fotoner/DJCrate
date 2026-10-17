import DJCDomain
import Foundation
import Testing

/// LINK 장치 목록 규칙(#272): 알림으로 넣고, 알림이 끊긴 장치를 빼고, 플레이어부터 번호순으로 놓는다.
@Suite("LINK 장치 목록")
struct LinkRosterTests {
    static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    static let cdj1 = LinkDevice(number: 1, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.192")
    static let cdj2 = LinkDevice(number: 2, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.193")
    static let djm = LinkDevice(number: 33, name: "DJM-900NXS2", kind: .mixer, address: "169.254.98.242")
    static let rekordbox = LinkDevice(number: 17, name: "rekordbox", kind: .rekordbox, address: "169.254.1.2")

    @Test func 플레이어_먼저_같은_종류는_번호순으로_놓는다() {
        var roster = LinkRoster()
        for device in [Self.rekordbox, Self.djm, Self.cdj2, Self.cdj1] { roster.announce(device, at: Self.start) }
        #expect(roster.devices == [Self.cdj1, Self.cdj2, Self.djm, Self.rekordbox])
    }

    @Test func 같은_알림이_되풀이되면_바뀌지_않았다고_한다() {
        var roster = LinkRoster()
        let changed1 = roster.announce(Self.cdj1, at: Self.start)
        #expect(changed1)
        let changed2 = roster.announce(Self.cdj1, at: Self.start.addingTimeInterval(1.5))
        #expect(!changed2)
    }

    @Test func 같은_번호의_이름이나_주소가_바뀌면_바꾼다() {
        var roster = LinkRoster()
        roster.announce(Self.cdj1, at: Self.start)
        var moved = Self.cdj1
        moved.address = "169.254.86.200"
        let changed3 = roster.announce(moved, at: Self.start.addingTimeInterval(1))
        #expect(changed3)
        #expect(roster.devices == [moved])
    }

    @Test func 알림이_10초_넘게_끊긴_장치만_뺀다() {
        var roster = LinkRoster()
        roster.announce(Self.cdj1, at: Self.start)
        roster.announce(Self.djm, at: Self.start.addingTimeInterval(5))
        let changed4 = roster.expire(now: Self.start.addingTimeInterval(10))
        #expect(!changed4)
        let changed5 = roster.expire(now: Self.start.addingTimeInterval(10.5))
        #expect(changed5)
        #expect(roster.devices == [Self.djm])
    }

    @Test func 되풀이_알림은_만료_시각을_늦춘다() {
        var roster = LinkRoster()
        roster.announce(Self.cdj1, at: Self.start)
        roster.announce(Self.cdj1, at: Self.start.addingTimeInterval(9))
        let changed6 = roster.expire(now: Self.start.addingTimeInterval(15))
        #expect(!changed6)
        #expect(roster.devices == [Self.cdj1])
    }

    @Test func 덱은_플레이어에만_있다() {
        #expect(Self.cdj1.hasDeck)
        #expect(!Self.djm.hasDeck)
        #expect(!Self.rekordbox.hasDeck)
    }
}
