import Foundation

/// 앱 기본 초안·백업 폴더(`DJCPaths`)를 쓰는 시험은 `DJC_HOME`이 있을 때만 돈다(사용자 폴더를 건드리지 않게).
/// `scripts/check.sh`와 CI는 늘 준다. `DJC_HOME` 없이 `swift test`만 돌리면 건너뛴다.
enum LiveDraftHome {
    static let isIsolated = ProcessInfo.processInfo.environment["DJC_HOME"]?.isEmpty == false
}
