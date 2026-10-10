import Foundation
import Observation

/// 중복 후보 화면의 화면 모델(#244). 합치기 준비(확인 창·초안 만들기)를 시작하고, 준비하는 동안 합치기 단추를 막는다.
/// 준비는 화면이 사라져도 끝까지 간다(취소하지 않는다).
@MainActor @Observable
final class DuplicateTracksModel {
    private(set) var isPreparing = false
    /// 마지막으로 시작한 준비(시험이 기다린다)
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private let prepare: @MainActor (_ keeping: String, _ removing: [String]) async -> Void

    init(prepare: @escaping @MainActor (_ keeping: String, _ removing: [String]) async -> Void) {
        self.prepare = prepare
    }

    convenience init(store: LibraryStore) {
        self.init { [weak store] keeping, removing in await store?.prepareMerge(keeping: keeping, removing: removing) }
    }

    func startMerge(keeping: String, removing: [String]) {
        isPreparing = true
        task = Task {
            await prepare(keeping, removing)
            isPreparing = false
        }
    }
}
