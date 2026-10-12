import DJCDomain

/// 앱 업데이트(#59)의 설치·다시 켜기를 쓰기가 끝날 때까지 미룬다.
/// 업데이트 도구가 설치 직전에 `postpone`으로 묻는다. 미루면 이어 갈 블록을 맡아 두고,
/// 앱이 쓰기 상태가 바뀔 때마다 `activityChanged`를 부르면 쓰기가 모두 끝난 뒤 한 번만 부른다.
@MainActor
public final class UpdateDeferral {
    private let activity: @MainActor () -> AppWriteActivity
    private var pending: [@MainActor () -> Void] = []

    /// - Parameter activity: 지금 앱이 쓰는 중인 것(앱의 쓰기 잠금·USB 쓰기 세션에서 읽는다)
    public init(activity: @escaping @MainActor () -> AppWriteActivity) {
        self.activity = activity
    }

    /// 맡아 둔 블록이 있다(앱은 이때만 쓰기 상태를 지켜본다)
    public var isHolding: Bool { !pending.isEmpty }

    /// 지금 설치해도 되는지 본다. 쓰는 중이면 `resume`을 맡아 두고 미룬 이유를 돌려준다.
    public func postpone(resume: @escaping @MainActor () -> Void) -> UpdateInstallDecision {
        let decision = UpdateInstallPolicy.decision(for: activity())
        if decision != .proceed { pending.append(resume) }
        return decision
    }

    /// 쓰기 상태가 바뀌었다. 모두 끝났으면 맡아 둔 블록을 부른다.
    public func activityChanged() {
        guard isHolding, UpdateInstallPolicy.decision(for: activity()) == .proceed else { return }
        // 블록 안에서 다시 불려도 같은 블록을 두 번 부르지 않게 먼저 비운다
        let resumes = pending
        pending = []
        for resume in resumes { resume() }
    }
}
