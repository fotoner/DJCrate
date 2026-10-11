import Foundation

/// 시험 프로세스(`swift test`·Xcode 시험)인지와 그 프로세스의 기본 폴더.
/// 시험은 실제 rekordbox 라이브러리와 사용자 DJCrate 데이터를 쓰지 않는다. 기본 경로는 이 프로세스만의 임시 폴더로 바꾸고,
/// 실제 rekordbox 폴더 쓰기·복원은 쓰기 관문이 거부한다(#182: 시험이 실제 라이브러리로 복원해 라이브러리를 덮었다).
public enum TestProcess {
    public static let isRunning: Bool = {
        let info = ProcessInfo.processInfo
        if ["xctest", "swiftpm-testing-helper"].contains(info.processName) { return true }
        if info.environment["XCTestConfigurationFilePath"] != nil || info.environment["XCTestBundlePath"] != nil { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    /// 시험 프로세스의 기본 폴더 뿌리. 프로세스마다 따로 두어 동시에 도는 시험끼리도 섞이지 않는다.
    public static let sandbox: URL = FileManager.default.temporaryDirectory
        .appending(path: "djc-test-sandbox-\(ProcessInfo.processInfo.processIdentifier)")
}
