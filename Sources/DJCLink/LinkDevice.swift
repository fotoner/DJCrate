// internal: DJLinkKit 타입이 이 모듈의 공개 API에 나가면 컴파일러가 막는다.
internal import DJLinkKit

/// Pro DJ Link 네트워크의 장치 하나(CDJ·DJM·rekordbox). DJLinkKit 타입을 밖에 내지 않으려고 쓰는 값만 옮긴다.
public struct LinkDevice: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case player
        case mixer
        case rekordbox
        /// 모르는 종류(예: stagehand)
        case other
    }

    /// 장치 번호(예: CDJ 1, DJM 33)
    public var number: Int
    public var name: String
    public var kind: Kind
    /// IPv4 주소(`a.b.c.d`)
    public var address: String

    public init(number: Int, name: String, kind: Kind, address: String) {
        self.number = number
        self.name = name
        self.kind = kind
        self.address = address
    }

    /// 장치 알림(keep-alive) UDP 내용을 읽는다. Pro DJ Link 알림이 아니면 nil이다.
    /// 알림 포트에는 다른 앱의 방송도 들어온다. 그래서 DJLinkKit이 던지는 짧은 알림도 오류가 아니라 장치 없음으로 본다.
    public static func fromAnnouncePacket(_ bytes: [UInt8]) -> LinkDevice? {
        guard let device = try? deviceFromPacket(bytes) else { return nil }
        let kind: Kind = switch device.type {
        case .cdj: .player
        case .mixer: .mixer
        case .rekordbox: .rekordbox
        default: .other
        }
        return LinkDevice(number: device.id, name: device.name, kind: kind, address: device.ip.address)
    }
}
