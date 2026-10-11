import DJCApplication
import DJCDomain
import Foundation
import Synchronization

/// 반영 XML 계획 묶음 저장의 메모리 구현. 실제 구현(`ReflectionBatchStore.live`)과 같은 계약인지는 DJCAdaptersTests가 같은 시험 함수로 본다.
public final class MemoryReflectionBatches: Sendable {
    private let batch = Mutex<ReflectionXMLBatch?>(nil)
    public init() {}
    public var port: ReflectionBatchStore {
        ReflectionBatchStore(load: { self.batch.withLock { $0 } }, save: { new in self.batch.withLock { $0 = new } })
    }
}
