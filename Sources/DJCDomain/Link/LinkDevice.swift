import Foundation

/// Pro DJ Link 네트워크의 장치 하나(CDJ·DJM·rekordbox). 장치 알림에서 읽은 값이다(#272).
public struct LinkDevice: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: Equatable, Hashable, Sendable {
        case player
        case mixer
        case rekordbox
        /// 모르는 종류(예: stagehand)
        case other
    }

    /// 장치 번호(예: CDJ 1, DJM 33). 한 네트워크에서 겹치지 않는다
    public var number: Int
    public var name: String
    public var kind: Kind
    /// IPv4 주소(`a.b.c.d`)
    public var address: String

    public var id: Int { number }

    /// 덱이 있어 곡을 실을 수 있는 장치(플레이어)
    public var hasDeck: Bool { kind == .player }

    public init(number: Int, name: String, kind: Kind, address: String) {
        self.number = number
        self.name = name
        self.kind = kind
        self.address = address
    }
}
