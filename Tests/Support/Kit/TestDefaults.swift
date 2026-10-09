import Foundation

/// 시험용 UserDefaults. 영역 이름을 임시 폴더 안의 절대 경로로 주어, plist가 사용자 환경설정 폴더(`~/Library/Preferences`)가 아니라
/// 임시 폴더에 생긴다(adv4 T6: 시험이 `djc-test-*.plist`를 10만 개 넘게 남겼다. `removePersistentDomain`은 빈 plist를 남긴다).
/// 시험은 `UserDefaults(suiteName:)`을 직접 만들지 않는다(`scripts/check-imports.py`의 test-defaults 규칙).
public enum TestDefaults {
    /// 실행별 접두사. `scripts/check.sh`가 `DJC_TEST_DEFAULTS_PREFIX`로 주고, 끝나면 이 접두사의 plist가
    /// 사용자 환경설정 폴더에 생겼는지 본다(생기면 종료 코드 4).
    public static let prefix = ProcessInfo.processInfo.environment["DJC_TEST_DEFAULTS_PREFIX"] ?? "djc-test-"

    /// 이 프로세스의 영역 plist를 두는 임시 폴더
    public static let folder = FileManager.default.temporaryDirectory
        .appending(path: "\(prefix)defaults-\(ProcessInfo.processInfo.processIdentifier)")

    /// 새 영역 이름(임시 폴더 안의 절대 경로). 같은 영역을 다시 열 때는 이 이름을 `open`에 준다.
    public static func suiteName(_ label: String) -> String {
        folder.appending(path: "\(prefix)\(label).\(UUID().uuidString)").path
    }

    /// 새 빈 영역
    public static func make(_ label: String) -> UserDefaults { open(suiteName(label)) }

    /// `suiteName`으로 만든 영역을 (다시) 연다
    public static func open(_ suiteName: String) -> UserDefaults {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suiteName) else { preconditionFailure("시험 설정 영역을 열지 못했습니다: \(suiteName)") }
        return defaults
    }
}
