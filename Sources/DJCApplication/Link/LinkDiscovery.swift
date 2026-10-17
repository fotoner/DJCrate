import DJCDomain
import Foundation

/// Pro DJ Link 장치 알림을 받는 포트(#272). 받기만 하고 네트워크에 아무것도 보내지 않는다.
public struct LinkDiscoverySource: Sendable {
    /// 알림 포트를 열어 장치 알림을 흘린다. 스트림을 버리면 포트를 닫는다. 포트를 열지 못하면 오류로 끝난다
    public var announcements: @Sendable () -> AsyncThrowingStream<LinkDevice, any Error>
    /// rekordbox·rekordboxAgent가 켜져 있는지(같은 포트를 쓴다). 프로세스를 띄워 보므로 메인 밖에서 부른다
    public var isRekordboxRunning: @Sendable () -> Bool
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(announcements: @escaping @Sendable () -> AsyncThrowingStream<LinkDevice, any Error>,
                isRekordboxRunning: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Date,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.announcements = announcements
        self.isRekordboxRunning = isRekordboxRunning
        self.now = now
        self.sleep = sleep
    }

    /// 아무 장치도 보지 않는다(화면 시험·자가 테스트 실행). 포트를 열지 않는다
    public static let none = LinkDiscoverySource(announcements: { AsyncThrowingStream { _ in } }, isRekordboxRunning: { false },
                                                 now: { .distantPast })
}

/// 장치 찾기의 지금 상태
public enum LinkDiscoveryState: Equatable, Sendable {
    /// 아직 시작하지 않음
    case idle
    /// 알림을 받는 중. 보이는 장치(없으면 빈 목록)
    case listening([LinkDevice])
    /// rekordbox가 같은 포트를 쓰고 있어 멈춤
    case blockedByRekordbox
    /// 알림 포트를 열지 못함(다른 앱이 쓰는 중 등). 잠시 뒤 다시 연다
    case unavailable

    public var devices: [LinkDevice] {
        if case let .listening(devices) = self { devices } else { [] }
    }
}

/// 앱이 켜져 있는 동안 장치 알림을 받아 장치 목록을 만든다(#272).
/// rekordbox가 켜지면 포트를 닫고 멈췄다가, 꺼지면 다시 연다. 포트를 열지 못하면 잠시 뒤 다시 해 본다.
public struct LinkDiscovery: Sendable {
    /// 목록 만료·rekordbox 확인 간격
    public static let tick: Duration = .seconds(1)
    /// 듣는 중에 rekordbox가 켜졌는지 볼 간격. rekordbox가 같은 포트를 열기 전에 비켜 주도록 짧게 두되,
    /// 프로세스를 띄워 보므로 매 틱마다 보지는 않는다
    public static let rekordboxCheck: Duration = .seconds(2)
    /// 멈춘 동안(rekordbox 켜짐·포트 실패) 다시 볼 간격
    public static let retry: Duration = .seconds(5)

    public let source: LinkDiscoverySource
    /// 포트 실패를 남길 곳(사용자에게는 `unavailable`만 보인다)
    public var log: @Sendable (String) -> Void

    public init(source: LinkDiscoverySource, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.source = source
        self.log = log
    }

    /// 취소될 때까지 상태가 바뀔 때마다 알린다.
    public func run(update: @escaping @Sendable (LinkDiscoveryState) async -> Void) async {
        var last: LinkDiscoveryState = .idle
        let emit: (LinkDiscoveryState) async -> Void = { state in
            guard state != last else { return }
            last = state
            await update(state)
        }
        while !Task.isCancelled {
            if await rekordboxRunning() {
                await emit(.blockedByRekordbox)
            } else {
                switch await listen(emit: emit) {
                case .cancelled: return
                case .rekordboxStarted: continue
                case let .failed(error):
                    log("[LINK] 장치 알림 포트를 열지 못했습니다: \(error.map { "\($0)" } ?? "스트림이 끝남")")
                    await emit(.unavailable)
                }
            }
            do { try await source.sleep(Self.retry) } catch { return }
        }
    }

    private enum Outcome {
        case cancelled
        case rekordboxStarted
        case failed((any Error)?)
    }

    private enum Event: Sendable {
        case device(LinkDevice)
        case tick
        case ended((any Error)?)
    }

    /// 포트를 열어 듣는다. 취소·rekordbox 켜짐·포트 실패로 끝난다(끝나면 포트를 닫는다).
    private func listen(emit: (LinkDiscoveryState) async -> Void) async -> Outcome {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let source = source
        let feeder = Task {
            do {
                for try await device in source.announcements() { continuation.yield(.device(device)) }
                continuation.yield(.ended(nil))
            } catch {
                continuation.yield(.ended(error))
            }
        }
        let ticker = Task {
            while !Task.isCancelled {
                do { try await source.sleep(Self.tick) } catch { return }
                continuation.yield(.tick)
            }
        }
        defer {
            feeder.cancel()
            ticker.cancel()
            continuation.finish()
        }
        var roster = LinkRoster()
        var nextCheck = source.now().addingTimeInterval(Self.rekordboxCheck.seconds)
        await emit(.listening([]))
        for await event in events {
            switch event {
            case let .device(device):
                if roster.announce(device, at: source.now()) { await emit(.listening(roster.devices)) }
            case .tick:
                let now = source.now()
                if roster.expire(now: now) { await emit(.listening(roster.devices)) }
                if now >= nextCheck {
                    nextCheck = now.addingTimeInterval(Self.rekordboxCheck.seconds)
                    if await rekordboxRunning() { return .rekordboxStarted }
                }
            case let .ended(error):
                return .failed(error)
            }
        }
        return .cancelled
    }

    private func rekordboxRunning() async -> Bool {
        await BlockingWork.run(qos: .utility) { [source] in source.isRekordboxRunning() }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
