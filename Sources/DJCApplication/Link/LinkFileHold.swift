import DJCDomain
import Synchronization

/// CDJ가 못 읽는 원본(FLAC·ALAC)을 WAV로 바꾸는 동안 그 파일 요청에 답하지 않게 한다(#277).
/// 플레이어는 답이 없으면 1초쯤 뒤 같은 요청을 다시 보내므로, 다 바꾼 뒤의 요청에 WAV로 답하면 첫 싣기부터 WAV가 실린다.
/// 원본으로 답해 E-8305로 실패한 뒤 같은 덱에 다시 실으면 CDJ가 몇 분씩 느려졌다(2026-10-17 CDJ-2000nexus 실기).
/// NFS가 답하는 도중에 바로 묻으므로 세션 액터 밖에서 잠금으로 지킨다
public final class LinkFileHold: Sendable {
    /// 이보다 오래 바꾸면 원본으로 답한다(그 싣기는 실패하고 다 바꾼 뒤 다시 실으면 실린다)
    public static let limit: Duration = .seconds(15)

    private struct State {
        /// 바꿔야 할 수 있는 원본 경로(연결할 때 정한다)
        var candidates: Set<String> = []
        /// 처음 보류한 때
        var since: [String: ContinuousClock.Instant] = [:]
        /// 더 보류하지 않는 원본(바꿔 끼웠거나 바꿀 필요가 없거나 실패했거나 오래 걸렸다)
        var released: Set<String> = []
        /// 오래 걸려 원본으로 답한 원본(그 싣기는 실패했다)
        var expired: Set<String> = []
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// 새로 연결할 때 후보를 정하고 앞 연결의 기록을 비운다
    func reset(candidates: Set<String>) {
        state.withLock { $0 = State(candidates: candidates) }
    }

    /// 그 플레이어의 그 파일 요청에 답하지 않고 기다리게 할지. FLAC·ALAC을 읽는 기종이거나 후보가 아니면 바로 답한다
    public func shouldHold(path: String, playerModel: String) -> Bool {
        guard !LinkPlayerFormats.playsLossless(model: playerModel) else { return false }
        let now = now()
        return state.withLock { state in
            guard state.candidates.contains(path), !state.released.contains(path) else { return false }
            let since = state.since[path] ?? now
            state.since[path] = since
            guard now - since <= Self.limit else {
                state.released.insert(path)
                state.expired.insert(path)
                return false
            }
            return true
        }
    }

    /// 그 원본을 더 보류하지 않는다(다음 요청에 바로 답한다)
    /// - Returns: 오래 걸려 원본으로 답한 적이 없는지. false면 그 싣기는 실패해 다시 실어야 한다
    @discardableResult
    func release(_ path: String) -> Bool {
        state.withLock { state in
            state.released.insert(path)
            return !state.expired.contains(path)
        }
    }
}
