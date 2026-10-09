import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Synchronization
import Testing

/// 분석 캐시 포트의 계약(실제 구현, 캐시 폴더): 가짜(`MemoryAnalysisStore`)에 DJCApplicationTests가 돌리는 같은 계약 함수를 돌린다.
@MainActor
@Suite("분석 캐시 계약(실제)")
struct AnalysisStoreContractTests {
    @Test func 실제_구현() throws {
        let folder = try TemporaryFolder(prefix: "djc-analysis-store")
        let paths = DJCCachePaths(root: folder.url.appending(path: "cache"))
        // 음량 캐시는 앱이 목록과 함께 쓰는 하나를 넘긴다(여기서는 시험용 사전)
        let loudness = Mutex<[String: Loudness]>([:])
        let store = AnalysisStore.live(paths: paths, loudness: { url in loudness.withLock { $0[url.path] } },
                                       storeLoudness: { value, url in loudness.withLock { $0[url.path] = value } })
        analysisStoreContract(store, first: try AudioFixture.wav(seconds: 1, in: folder.url, name: "a.wav"),
                              second: try AudioFixture.wav(seconds: 2, in: folder.url, name: "b.wav"))
        // 캐시는 주입한 폴더에만 쓴다
        #expect(FileManager.default.fileExists(atPath: paths.analysis.appending(path: "chroma").path))
    }
}
