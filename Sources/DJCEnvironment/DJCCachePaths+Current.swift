import DJCDomain

extension DJCCachePaths {
    /// 이 프로세스의 캐시 위치(`DJC_HOME`이 있으면 그 아래)
    public static var current: DJCCachePaths {
        DJCCachePaths(root: DJCIdentity.dataDirectory, snapshots: DJCIdentity.snapshotsDirectory)
    }
}
