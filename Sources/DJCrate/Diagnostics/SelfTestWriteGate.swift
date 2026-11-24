#if DEBUG
import DJCAdapters
import DJCApplication
import Foundation
import Synchronization

/// 자동 저장 자가 테스트 실행(`--auto-reflect-selftest`)의 쓰기 관문: 실제 관문을 감싸고, 자가 테스트가 정한 동안 미리 보기를 붙잡는다.
/// ⌘Q 저장 자가 테스트(`--quit-wait-selftest`, R17)가 "자동 저장이 미리 보기 중일 때 ⌘Q"를 만든다. 붙잡는 동안은 아직 아무것도 쓰지 않았다.
/// 조립 지점이 이 실행에서만 고른다(디버그 빌드). 붙잡는 시간을 정하지 않으면 실제 관문과 같다
enum SelfTestWriteGate {
    private static let previewHold = Mutex<Duration?>(nil)

    /// 다음 미리 보기부터 붙잡는 시간(nil이면 붙잡지 않는다)
    static func holdPreviews(for duration: Duration?) { previewHold.withLock { $0 = duration } }

    static func live() -> RekordboxWriteGate {
        var gate = RekordboxWriteGate.live()
        let preview = gate.preview
        gate.preview = { batch, inputs, target, progress in
            // 미리 보기 포트는 async라 취소(미리 보기 [취소]·Esc)를 그대로 받는다
            if let hold = previewHold.withLock({ $0 }) { try await Task.sleep(for: hold) }
            return try await preview(batch, inputs, target, progress)
        }
        return gate
    }
}
#endif
