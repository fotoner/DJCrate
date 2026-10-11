import DJCDomain
import DJCEnvironment
import Foundation
@testable import DJCAdapters
import DJCApplication
import Testing

/// #218: 시험이 덱을 움직여 남기는 오디오 사건 기록은 이 프로세스의 로그 폴더(`DJC_HOME/logs` 또는 시험 임시 폴더)에만 쓴다.
@Suite("오디오 기록 위치")
struct AudioLogLocationTests {
    @Test func 오디오_기록은_실제_로그_폴더가_아니라_이_프로세스의_로그_폴더에_쓴다() {
        #expect(AudioEvents.url == DJCIdentity.logsDirectory.appending(path: "audio.log"))
        #expect(!AudioEvents.url.path.hasPrefix(DJCIdentity.userLogsDirectory.path + "/"))

        let marker = "시험 기록 \(UUID())"
        AudioEvents.record(marker)
        AudioEvents.flush()
        let written = (try? String(contentsOf: AudioEvents.url, encoding: .utf8)) ?? ""
        #expect(written.contains(marker))
    }
}
