import DJCDomain
import Foundation

/// 내보낸 반영 XML의 계획 묶음 저장(포트): XML을 만들 때 남기고, rekordbox에서 가져온 뒤 새 스냅샷과 견줄 때 읽는다.
/// 실제 구현(`ReflectionBatchStore.live(url:)`, 데이터 폴더의 `reflection.json`)은 DJCAdapters가 주고 조립 지점이 고른다.
public struct ReflectionBatchStore: Sendable {
    /// 남긴 묶음(없거나 읽지 못하면 nil)
    public var load: @Sendable () -> ReflectionXMLBatch?
    /// 묶음을 남긴다. nil이면 지운다(모두 확인했다)
    public var save: @Sendable (ReflectionXMLBatch?) throws -> Void

    public init(load: @escaping @Sendable () -> ReflectionXMLBatch?, save: @escaping @Sendable (ReflectionXMLBatch?) throws -> Void) {
        self.load = load
        self.save = save
    }
}
