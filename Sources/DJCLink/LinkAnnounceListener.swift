internal import DJLinkKit
import Foundation

/// 장치 알림 포트(UDP 50000)를 열어 알림을 받기만 한다(#272). 아무 패킷도 보내지 않아 네트워크에 참여하지 않는다.
public enum LinkAnnounceListener {
    /// 장치 알림을 하나씩 흘린다. 스트림이 끝나거나(취소) 소비자가 떠나면 소켓을 닫는다. 포트를 열지 못하면 오류로 끝난다.
    /// 시험 프로세스에서는 DJLinkKit이 소켓을 만들지 않고 바로 실패한다(`LiveSocketFactory`).
    public static func devices() -> AsyncThrowingStream<LinkDevice, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let box = AnnounceSocket()
            continuation.onTermination = { _ in Task { @DJLinkActor in await box.close() } }
            Task { @DJLinkActor in
                do {
                    try await box.open(
                        onDevice: { continuation.yield($0) },
                        onError: { continuation.finish(throwing: $0) })
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// 소켓 하나와 닫힘 여부. 열기를 기다리는 사이에 스트림이 끝나면 연 뒤 바로 닫는다(포트를 붙잡아 두지 않게).
@DJLinkActor
private final class AnnounceSocket {
    private var socket: (any UDPSocket)?
    private var closed = false

    nonisolated init() {}

    func open(onDevice: @escaping @Sendable (LinkDevice) -> Void, onError: @escaping @Sendable (any Error) -> Void) async throws {
        guard !closed else { return }
        let socket = try LiveSocketFactory.shared.createUDPSocket(reuseAddr: true)
        self.socket = socket
        do {
            try await udpBind(socket, ANNOUNCE_PORT, "0.0.0.0")
        } catch {
            await close()
            throw error
        }
        if closed {
            await close()
            return
        }
        // 알림 포트에는 다른 앱의 방송도 온다. Pro DJ Link 알림이 아니면 버린다
        socket.onMessage { bytes, from in
            if let device = LinkDevice.fromAnnouncePacket(bytes) {
                RecentAnnouncements.remember(bytes, from: from.address)
                onDevice(device)
            }
        }
        socket.onError { onError($0) }
    }

    func close() async {
        closed = true
        guard let socket else { return }
        self.socket = nil
        socket.removeAllListeners()
        try? await udpClose(socket)
    }
}

/// 받기만 하는 장치 찾기가 들은 마지막 장치 알림(보낸 주소마다 하나). 서버를 띄울 때 넘겨,
/// CDJ의 다음 알림(약 2초 간격)을 기다리지 않고 바로 번호 받기를 시작한다(2026-10-16 캡처: 누른 뒤 1~2초를 알림 기다리기에 썼다)
@DJLinkActor
enum RecentAnnouncements {
    private static var last: [String: (packet: [UInt8], at: Date)] = [:]

    static func remember(_ packet: [UInt8], from address: String) {
        last[address] = (packet, Date())
    }

    /// 들은 지 `maxAge`초 안의 알림(오래된 알림은 그 장치가 아직 있다는 뜻이 아니다)
    static func recent(maxAge: TimeInterval = 3) -> [(packet: [UInt8], address: String)] {
        let now = Date()
        return last.filter { now.timeIntervalSince($0.value.at) <= maxAge }.map { (packet: $0.value.packet, address: $0.key) }
    }
}
