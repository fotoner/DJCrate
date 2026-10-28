import DJCApplication
import DJCDomain
import Observation

/// rekordbox·rekordboxAgent가 지금 켜져 있는지 앱이 늘 아는 값(#323). 조립 지점(`AppComposition.rekordboxRun`)이 하나 만들어
/// 앱이 켜져 있는 동안 돌리고, 상태 줄(#326)이 읽는다. 화면 표시용이다: 쓸지 말지는 이 값을 보지 않고 쓰기 관문이 그때그때 다시 확인한다.
@MainActor
@Observable
final class RekordboxRunModel {
    /// 마지막 판정. 처음 읽기 전에는 nil이다. `.unknown`(읽지 못함)은 켜진 것으로 다룬다
    private(set) var state: RekordboxRunState?
    @ObservationIgnored private let watch: RekordboxRunWatch
    @ObservationIgnored private var task: Task<Void, Never>?

    init(source: RekordboxProcessSource) {
        watch = RekordboxRunWatch(source: source)
    }

    /// 지켜보기를 시작한다. 이미 돌고 있으면 그대로 둔다
    func start() {
        guard task == nil else { return }
        let watch = watch
        let update: @Sendable (RekordboxRunState) async -> Void = { [weak self] state in await self?.apply(state) }
        task = Task { await watch.run(update: update) }
    }

    /// 지켜보기를 멈춘다(시험). 마지막 판정은 그대로 둔다
    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ state: RekordboxRunState) {
        self.state = state
    }
}
