import DJCApplication
import DJCDomain
import DJCLink
import Foundation
import RekordboxKit

extension LinkDiscoverySource {
    /// 실제 알림 포트(`LinkAnnounceListener`, 받기만 한다)와 rekordbox 실행 확인(`LibrarySnapshot.isRekordboxRunning`)
    public static let live = LinkDiscoverySource(
        announcements: {
            let devices = LinkAnnounceListener.devices()
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await device in devices { continuation.yield(DJCDomain.LinkDevice(device)) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        },
        isRekordboxRunning: { LibrarySnapshot.isRekordboxRunning() },
        now: { Date() })
}

extension DJCDomain.LinkDevice {
    init(_ device: DJCLink.LinkDevice) {
        let kind: Kind = switch device.kind {
        case .player: .player
        case .mixer: .mixer
        case .rekordbox: .rekordbox
        case .other: .other
        }
        self.init(number: device.number, name: device.name, kind: kind, address: device.address)
    }
}
