import DJCDomain
import Testing

@Suite("읽기 실패 상태")
struct ReadFailureStateTests {
    @Test(arguments: [AudioSourceState.none, .preparing, .streaming, .missing, .readFailed, .decodeFailed, .unsupportedFormat])
    func 재생_불가_상태마다_할_일이_있다(_ state: AudioSourceState) {
        #expect(state.unavailableReason?.isEmpty == false)
        #expect(state != .ready)
        #expect(AudioSourceState.ready.unavailableReason == nil)
    }

    @Test(arguments: [LibraryReadFailure.Stage.snapshotCreation, .opening, .contents], [false, true])
    func 실패_단계와_최신성_범위를_보존한다(_ stage: LibraryReadFailure.Stage, _ previous: Bool) {
        let failure = LibraryReadFailure(stage: stage, keepsPreviousLibrary: previous)
        #expect(failure.stage == stage)
        #expect(failure.message.contains("이전 목록") == previous)
        #expect(failure.message.contains("확인"))
    }
}
