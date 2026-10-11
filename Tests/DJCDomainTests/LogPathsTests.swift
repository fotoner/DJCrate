import DJCDomain
import DJCEnvironment
import Foundation
import Testing

/// #218: 오디오 사건 기록(`audio.log`)도 `DJC_HOME`을 따른다. 시험·자가 테스트가 `~/Library/Logs/DJCrate`에 쓰지 않게.
/// 폴더는 열지 않고 경로 글자만 비교한다.
@Suite("로그 위치")
struct LogPathsTests {
    let userLogs = NSHomeDirectory() + "/Library/Logs/DJCrate"

    @Test func 설치한_앱의_로그_폴더는_옛_경로_그대로다() {
        #expect(DJCIdentity.userLogsDirectory.path == userLogs)
        for environment in [[:], ["DJC_HOME": ""]] as [[String: String]] {
            #expect(DJCIdentity.logsDirectory(environment: environment, fallback: DJCIdentity.userLogsDirectory).path == userLogs)
        }
    }

    @Test func DJC_HOME이_있으면_그_아래_logs에_쓴다() {
        let home = "/private/tmp/djc-home-\(UUID())"
        let logs = DJCIdentity.logsDirectory(environment: ["DJC_HOME": home], fallback: DJCIdentity.userLogsDirectory)
        #expect(logs.path == home + "/logs")
    }

    @Test func 시험_프로세스의_로그는_실제_로그_폴더_밖이다() {
        let current = DJCIdentity.logsDirectory
        #expect(!current.path.hasPrefix(userLogs), "\(current.path)")
        if ProcessInfo.processInfo.environment["DJC_HOME"]?.isEmpty != false {
            #expect(current == TestProcess.sandbox.appending(path: "logs"))
        }
    }
}
