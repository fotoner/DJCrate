import Foundation
import Synchronization

/// rekordbox 실행 경계(R23, #405 컨실 S7): 이 앱 실행 안에서 rekordbox·Agent가 꺼졌다 켜진 것을 본 횟수. 게인 초안 base에 적어 두고,
/// 지금과 다르면(만든 뒤 rekordbox가 한 번 켜졌다·앱을 다시 켜 알 수 없다) base 없는 초안으로 본다(자동으로 쓰지 않는다).
/// 켜진 동안 만든 초안은 만든 뒤 켜짐이 없어 꺼진 뒤에도 base를 쓴다(그사이 바뀐 게인은 쓰기 입구가 base와 견줘 막는다).
/// 자동 저장 엔진이 실행 상태를 지켜볼 때마다 넘긴다(`observe`). 실행마다 새 이름(`session`)을 받는다
public final class RekordboxRunEpoch: Sendable {
    private let state: Mutex<(starts: Int, running: Bool?)>
    private let session: String

    /// - Parameter session: 이 앱 실행의 이름(조립 지점이 준다. 핵심부는 UUID를 스스로 만들지 않는다)
    public init(session: String) {
        self.session = session
        state = Mutex((0, nil))
    }

    /// 지금 경계
    public var current: String { "\(session)#\(state.withLock { $0.starts })" }

    /// rekordbox·Agent 실행 여부를 넘긴다(모름은 켜짐으로 본다). 꺼짐에서 켜짐으로 바뀌면 경계를 넘긴다
    public func observe(running: Bool) {
        state.withLock { state in
            if state.running == false, running { state.starts += 1 }
            state.running = running
        }
    }
}
