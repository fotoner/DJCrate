import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension CacheFiles {
    /// 실제 캐시 폴더(DJCStorage `DJCCache`의 규칙)
    public static let live = CacheFiles(
        usage: { DJCCache.usage(paths: $0) },
        backupUsage: { DJCCache.backupUsage(root: $0) },
        clear: { kinds, paths, keeping, dryRun in DJCCache.clear(kinds, paths: paths, keepingSnapshots: keeping, dryRun: dryRun) })
}
