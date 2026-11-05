import Foundation

/// 지금 네트워크에 있는 장치 목록(#272). 장치는 알림을 1.5초마다 보내므로, 오래 알림이 없는 장치는 꺼졌거나 빠진 것으로 본다.
public struct LinkRoster: Equatable, Sendable {
    /// 알림이 이만큼 끊기면 목록에서 뺀다(DJLinkKit `DeviceManager` 기본값과 같다)
    public static let timeout: TimeInterval = 10

    private var seen: [Int: Entry] = [:]

    private struct Entry: Equatable, Sendable {
        var device: LinkDevice
        var at: Date
    }

    public init() {}

    /// 플레이어 먼저, 같은 종류는 번호순(rekordbox 아래 막대처럼 플레이어 번호대로 놓는다)
    public var devices: [LinkDevice] {
        seen.values.map(\.device).sorted { lhs, rhs in
            let left = Self.order(lhs.kind), right = Self.order(rhs.kind)
            return left != right ? left < right : lhs.number < rhs.number
        }
    }

    public var isEmpty: Bool { seen.isEmpty }

    /// 알림 하나를 넣는다. 보이는 목록이 바뀌었으면 true(같은 장치의 되풀이 알림은 시각만 고친다).
    @discardableResult
    public mutating func announce(_ device: LinkDevice, at time: Date) -> Bool {
        let changed = seen[device.number]?.device != device
        seen[device.number] = Entry(device: device, at: time)
        return changed
    }

    /// 알림이 `timeout` 넘게 끊긴 장치를 뺀다. 뺀 것이 있으면 true.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        let before = seen.count
        seen = seen.filter { now.timeIntervalSince($0.value.at) <= Self.timeout }
        return seen.count != before
    }

    private static func order(_ kind: LinkDevice.Kind) -> Int {
        switch kind {
        case .player: 0
        case .mixer: 1
        case .rekordbox: 2
        case .other: 3
        }
    }
}
