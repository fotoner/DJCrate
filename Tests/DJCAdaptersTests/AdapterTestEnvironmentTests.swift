import DJCDomain
import DJCEnvironment
import Foundation
import Testing

/// 어댑터(.live)는 실제 폴더를 기본값으로 읽고 쓴다. 이 타깃의 시험이 실제 DJCrate 폴더를 보지 않는지 먼저 확인한다(#182).
@Suite("어댑터 시험 환경")
struct AdapterTestEnvironmentTests {
    @Test func 시험_프로세스는_실제_DJCrate_폴더_대신_임시_폴더를_쓴다() {
        #expect(TestProcess.isRunning)
        #expect(DJCIdentity.supportDirectory != DJCIdentity.userSupportDirectory)
        #expect(DJCIdentity.logsDirectory != DJCIdentity.userLogsDirectory)
        #expect(DJCIdentity.dataDirectory.path.hasPrefix(DJCIdentity.userSupportDirectory.path) == false)
    }
}
