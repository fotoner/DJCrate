import DJCDomain
import Foundation

/// DJCrate 캐시 폴더(피동 포트, #215): 종류별 용량 보기와 비우기. 지우는 규칙은 실제 구현(DJCStorage `DJCCache`) 한 곳이고,
/// 초안·추가 목록·백업·USB 저널·준비 폴더는 종류에 없다. 실제 구현은 DJCAdapters `CacheFiles.live`(조립 지점이 고른다).
public struct CacheFiles: Sendable {
    public var usage: @Sendable (DJCCachePaths) -> [DJCCacheUsage]
    /// 비우기 대상이 아닌 백업의 용량(데이터 폴더 아래)
    public var backupUsage: @Sendable (_ root: URL) -> [DJCBackupUsage]
    /// - Parameters:
    ///   - keepingSnapshots: 남길 라이브러리 읽기 사본(앱이 연 사본)
    ///   - dryRun: 지우지 않고 지울 것만 센다
    public var clear: @Sendable (_ kinds: [DJCCacheKind], DJCCachePaths, _ keepingSnapshots: [URL], _ dryRun: Bool) -> [DJCCacheOutcome]

    public init(usage: @escaping @Sendable (DJCCachePaths) -> [DJCCacheUsage], backupUsage: @escaping @Sendable (URL) -> [DJCBackupUsage],
                clear: @escaping @Sendable ([DJCCacheKind], DJCCachePaths, [URL], Bool) -> [DJCCacheOutcome]) {
        self.usage = usage
        self.backupUsage = backupUsage
        self.clear = clear
    }
}
