import DJCApplication
import Foundation
import Testing

/// 동기 입출력은 협력 스레드 풀 밖(GCD)에서 돈다. 풀에서 막으면 코어가 적은 기계에서 다른 비동기 일이 모두 멈춘다.
@Suite("협력 풀 밖 동기 작업")
struct BlockingWorkTests {
    /// 지금 스레드의 디스패치 큐 이름(협력 풀은 `….cooperative`)
    static func queueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }

    struct Failure: Error, Equatable {}

    @Test func 협력_풀이_아닌_스레드에서_돌린다() async {
        let label = await BlockingWork.run { Self.queueLabel() }
        #expect(!label.hasSuffix(".cooperative"), "\(label)")
        let utility = await BlockingWork.run(qos: .utility) { Self.queueLabel() }
        #expect(!utility.hasSuffix(".cooperative"), "\(utility)")
    }

    @Test func 던진_오류를_그대로_돌려준다() async throws {
        await #expect(throws: Failure.self) { try await BlockingWork.run { () throws -> Int in throw Failure() } }
        #expect(try await BlockingWork.run { () throws -> Int in 7 } == 7)
    }
}
