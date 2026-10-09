import DJCDomain
import DJCEnvironment
import DJCTestKit
import Foundation
@testable import DJCAnalysis
import Testing

/// #195: `DJC_HOME`을 준 실행은 파형·분석(크로마·그리드 추정) 캐시를 그 아래에만 쓰고 사용자 폴더에는 아무것도 쓰지 않는다.
/// 실제 폴더는 열지 않는다. 사용자 폴더 자리에 임시 폴더를 넣어 그 폴더가 비어 있는지 본다.
@Suite("분석 캐시 위치")
struct CacheLocationTests {
    struct Scene {
        let root: URL, support: URL, home: URL, audio: URL
        var paths: DJCCachePaths {
            DJCCachePaths(root: DJCIdentity.dataDirectory(environment: ["DJC_HOME": home.path], support: support))
        }
    }

    func scene() throws -> Scene {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-cache-location-\(UUID())")
        let audio = root.appending(path: "audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        return Scene(root: root, support: root.appending(path: "support"), home: root.appending(path: "home"), audio: audio)
    }

    func files(under directory: URL) -> [String] {
        let base = directory.standardizedFileURL.path
        let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(base.count + 1)) }.sorted()
    }

    @Test func DJC_HOME을_준_실행은_파형_캐시를_그_아래에만_쓴다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let wav = try AudioFixture.wav(seconds: 2, in: scene.audio)
        _ = try WaveformCache.load(fileAt: wav, key: "synthetic-uuid", paths: scene.paths)
        #expect(files(under: scene.home).map { $0.hasPrefix("waveforms/synthetic-uuid-") && $0.hasSuffix(".json") } == [true])
        #expect(!FileManager.default.fileExists(atPath: scene.support.path), "사용자 폴더 자리에는 폴더조차 생기지 않는다")
        // 같은 곳에서 다시 읽는다
        let cached = try WaveformCache.load(fileAt: wav, key: "synthetic-uuid", paths: scene.paths)
        #expect(cached.count > 0)
    }

    @Test func DJC_HOME을_준_실행은_크로마와_그리드_추정_캐시를_analysis_아래에만_쓴다() throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let wav = try AudioFixture.wav(seconds: 1, in: scene.audio)
        let chroma = KeyAnalyzer.Chroma(hop: 0.2, frames: [[Float]](repeating: [Float](repeating: 0.5, count: 12), count: 3))
        AnalysisCache.store(chroma, key: "synthetic-uuid", file: wav, paths: scene.paths)
        let stored = files(under: scene.home)
        #expect(stored.count == 1 && stored[0].hasPrefix("analysis/chroma/synthetic-uuid-") && stored[0].hasSuffix(".bin"), "\(stored)")
        #expect(AnalysisCache.chroma(key: "synthetic-uuid", file: wav, paths: scene.paths)?.frames.count == 3)
        #expect(!FileManager.default.fileExists(atPath: scene.support.path))

        AnalysisCache.removeAll(key: "synthetic-uuid", paths: scene.paths)
        #expect(files(under: scene.home).isEmpty, "재분석은 같은 뿌리의 캐시를 지운다")
    }

    /// 기본 인자는 이 프로세스의 현재 위치다(옛 호출부가 그대로 같은 폴더를 쓴다).
    @Test func 기본_캐시_폴더는_현재_위치에서_나온다() {
        #expect(WaveformCache.directory == DJCCachePaths.current.waveforms)
        #expect(PartAnalyzer.cacheDirectory == DJCCachePaths.current.analysis)
    }
}
