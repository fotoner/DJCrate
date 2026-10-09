import Foundation

/// 앱 이름과 데이터 위치. 이름이 박히는 곳은 여기 한 곳에서 가져간다.
public enum DJCIdentity {
    public static let name = "DJCrate"
    public static let shortName = "DJC"
    /// 2026-09-26 이전 이름(데이터 폴더·설정을 옮길 때 찾는다)
    public static let legacyName = "anicue"
    public static let legacyBundleID = "com.fotone.anicue"

    // 이 프로세스의 실제 위치(환경 변수·시험 여부·사용자 폴더를 읽는 것)는 `DJCEnvironment`의 확장에 있다.
    // 여기에는 환경을 인자로 받는 순수 규칙만 둔다.

    public static func logsDirectory(environment: [String: String], fallback: URL) -> URL {
        if let override = environment["DJC_HOME"], !override.isEmpty {
            return URL(filePath: override).appending(path: "logs")
        }
        return fallback
    }

    public static func snapshotsDirectory(environment: [String: String], support: URL) -> URL {
        if let override = environment["DJC_REKORDBOX_DIR"], !override.isEmpty {
            return URL(filePath: override).appending(path: "djc-snapshots")
        }
        return support.appending(path: "snapshots")
    }

    public static func dataDirectory(environment: [String: String], support: URL) -> URL {
        if let override = environment["DJC_HOME"], !override.isEmpty {
            return URL(filePath: override)
        }
        return support
    }
}
