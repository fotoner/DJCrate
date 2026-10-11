import DJCAnalysis
import DJCDomain
import DJCEnvironment
import DJCTestKit
import Foundation
import DJCStorage
import Testing

/// #195: 음량 캐시(`loudness.json`)도 `DJC_HOME`을 따른다. 사용자 폴더 자리에 임시 폴더를 넣어 아무것도 쓰이지 않는지 본다.
@MainActor
@Suite("음량 캐시 위치")
struct LoudnessCacheLocationTests {
    @Test func DJC_HOME을_준_실행은_음량_캐시를_그_아래에만_쓴다() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-loudness-location-\(UUID())")
        let audio = root.appending(path: "audio"), support = root.appending(path: "support"), home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = try AudioFixture.wav(seconds: 1, in: audio)
        let paths = DJCCachePaths(root: DJCIdentity.dataDirectory(environment: ["DJC_HOME": home.path], support: support))

        let loudness = Loudness(integrated: -9.5, peak: -0.3, clippedRuns: 2)
        let cache = LoudnessCache(url: paths.loudness, saveDelay: .milliseconds(20))
        cache.store(loudness, for: wav)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: paths.loudness.path) {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(paths.loudness.path == home.path + "/loudness.json")
        #expect(FileManager.default.fileExists(atPath: paths.loudness.path))
        #expect(!FileManager.default.fileExists(atPath: support.path), "사용자 폴더 자리에는 폴더조차 생기지 않는다")
        #expect(LoudnessCache(url: paths.loudness).value(for: wav) == loudness, "다음 실행이 같은 파일에서 읽는다")
    }

    @Test func 공유_캐시는_이_프로세스의_현재_위치를_쓴다() {
        #expect(LoudnessCache.shared.url == DJCCachePaths.current.loudness)
    }
}
