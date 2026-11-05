import Foundation

/// 쓰는 동안 시스템이 앱을 예고 없이 끝내지 못하게 막는다(#300): 갑작스러운 종료를 끄고, 활동 하나를 시작한다(App Nap도 막는다).
/// 쓰기 활동이 시작될 때 걸고 모두 끝나면 푼다. 짝이 맞는지 시험한다(`WriteSystemGuardTests`).
@MainActor
final class WriteSystemGuard {
    struct Hooks {
        var disableSuddenTermination: @MainActor () -> Void
        var enableSuddenTermination: @MainActor () -> Void
        var beginActivity: @MainActor () -> NSObjectProtocol
        var endActivity: @MainActor (NSObjectProtocol) -> Void

        @MainActor static let live = Hooks(
            disableSuddenTermination: { ProcessInfo.processInfo.disableSuddenTermination() },
            enableSuddenTermination: { ProcessInfo.processInfo.enableSuddenTermination() },
            beginActivity: {
                ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled],
                                                      reason: "rekordbox·USB에 쓰는 중")
            },
            endActivity: { ProcessInfo.processInfo.endActivity($0) })
    }

    private let hooks: Hooks
    private var activity: NSObjectProtocol?

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    var isHolding: Bool { activity != nil }

    /// 쓰는 중인지 알린다. 같은 값을 거듭 알려도 한 번만 걸고 한 번만 푼다.
    func update(writing: Bool) {
        if writing, activity == nil {
            hooks.disableSuddenTermination()
            activity = hooks.beginActivity()
        } else if !writing, let held = activity {
            activity = nil
            hooks.endActivity(held)
            hooks.enableSuddenTermination()
        }
    }
}
