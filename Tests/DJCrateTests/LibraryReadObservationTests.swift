@testable import DJCrate
import DJCApplication
import Foundation
import Synchronization
import Testing

/// 읽기 순번은 유스케이스 `LibraryReadFlow`가 센다. 뷰는 쓰기 판정 단추에서 이 값을 읽는다
/// (USB 재시도 내보내기 시트의 미리 보기·쓰기 → `usbSyncSourceIsCurrent` → `snapshotReadEpoch`).
/// 그래서 순번이 바뀌면 저장소가 관찰자에게 알려야 단추가 다시 계산된다.
@MainActor
@Suite("라이브러리 읽기 순번 관찰")
struct LibraryReadObservationTests {
    final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// 다음 한 번의 순번 변화를 기다리는 관찰
    private func observeEpoch(_ store: LibraryStore) -> Flag {
        let changed = Flag()
        withObservationTracking { _ = store.snapshotReadEpoch } onChange: { changed.set() }
        return changed
    }

    @Test func 기다리던_읽기를_버리면_순번을_보는_화면에_알린다() {
        let store = LibraryStore.test(playlistImportURL: nil)
        let changed = observeEpoch(store)

        store.invalidatePendingLoads()

        #expect(changed.isSet)
    }

    @Test func 사본_읽기를_시작하면_결과를_넣기_전에_순번을_보는_화면에_알린다() async {
        let store = LibraryStore.test(playlistImportURL: nil)
        let changed = observeEpoch(store)
        let missing = FileManager.default.temporaryDirectory.appending(path: "djc-read-observation-\(UUID().uuidString)/master.db")

        await store.load(snapshot: missing)

        #expect(changed.isSet)
        #expect(store.snapshotURL == nil)
    }
}
