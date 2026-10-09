import DJCApplication
import DJCDomain
import Foundation
import Synchronization

/// 추가 목록의 메모리 구현(`StagingStore`). 실제(`StagingStore.live`)와 같은 약속인지는 `stagingStoreContract`가 본다.
/// `saveError`를 주면 저장이 그것을 던지고 목록은 그대로다(실제의 저장 실패와 같다)
public final class MemoryStaging: Sendable {
    private let state: Mutex<(tracks: [StagedTrack], saveError: (any Error)?)>

    public init(_ tracks: [StagedTrack] = [], saveError: (any Error)? = nil) {
        state = Mutex((tracks, saveError))
    }

    public var tracks: [StagedTrack] { state.withLock { $0.tracks } }

    public var store: StagingStore {
        StagingStore(tracks: { self.state.withLock { $0.tracks } }, save: { tracks in
            try self.state.withLock { state in
                if let error = state.saveError { throw error }
                state.tracks = tracks
            }
        })
    }
}
