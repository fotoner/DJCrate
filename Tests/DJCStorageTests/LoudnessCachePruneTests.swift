import DJCAnalysis
import DJCDomain
import DJCTestKit
import Foundation
@testable import DJCStorage
import Testing

/// #217: 지금 라이브러리에 없는 경로의 음량 항목을 정리한다. 캐시 파일은 임시 폴더로 주입한다(사용자 폴더를 열지 않는다).
@MainActor
@Suite("음량 캐시 정리")
struct LoudnessCachePruneTests {
    func scene() throws -> (root: URL, a: URL, b: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-loudness-prune-\(UUID())")
        for folder in ["a", "b"] { try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true) }
        return (root, try AudioFixture.wav(seconds: 1, in: root.appending(path: "a")), try AudioFixture.wav(seconds: 1, in: root.appending(path: "b")),
                root.appending(path: "loudness.json"))
    }

    @Test func 라이브러리에_없는_경로의_항목만_지운다() async throws {
        let (root, a, b, url) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Loudness(integrated: -9, peak: -1, clippedRuns: 0), second = Loudness(integrated: -12, peak: -2, clippedRuns: 1)
        let cache = LoudnessCache(url: url, saveDelay: .milliseconds(10))
        cache.store(first, for: a)
        cache.store(second, for: b)

        #expect(await cache.prune(keeping: [a.path]) == 1)

        #expect(cache.value(for: a) == first)
        #expect(cache.value(for: b) == nil)
        await cache.waitForSave()
        let reloaded = LoudnessCache(url: url)
        #expect(reloaded.value(for: a) == first)
        #expect(reloaded.value(for: b) == nil, "파일에서도 지워진다")
    }

    @Test func 같은_경로의_옛_크기_수정_시각_항목도_지운다() async throws {
        let (root, a, _, url) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LoudnessCache(url: url, saveDelay: .milliseconds(10))
        cache.store(Loudness(integrated: -9, peak: -1, clippedRuns: 0), for: a)
        let old = try Data(contentsOf: a)
        try (old + Data(count: 100)).write(to: a)
        let fresh = Loudness(integrated: -8, peak: -1, clippedRuns: 0)
        cache.store(fresh, for: a)

        #expect(await cache.prune(keeping: [a.path]) == 1, "지금 파일의 키(크기·수정 시각)와 다른 옛 항목")
        #expect(cache.value(for: a) == fresh)
    }

    @Test func 비어_있는_목록으로는_아무것도_지우지_않는다() async throws {
        let (root, a, _, url) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LoudnessCache(url: url, saveDelay: .milliseconds(10))
        cache.store(Loudness(integrated: -9, peak: -1, clippedRuns: 0), for: a)
        #expect(await cache.prune(keeping: []) == 0)
        #expect(cache.value(for: a) != nil)
    }

    @Test func 정리가_기다리던_저장보다_나중이라_지운_항목이_되살아나지_않는다() async throws {
        let (root, a, b, url) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LoudnessCache(url: url, saveDelay: .milliseconds(100))
        cache.store(Loudness(integrated: -9, peak: -1, clippedRuns: 0), for: a)
        cache.store(Loudness(integrated: -12, peak: -2, clippedRuns: 1), for: b)
        _ = await cache.prune(keeping: [a.path])
        await cache.waitForSave()
        #expect(LoudnessCache(url: url).value(for: b) == nil)
    }

    @Test func 파일_상태는_협력_풀_밖에서_읽는다() async throws {
        // 잠든 외장 볼륨이면 파일 상태 읽기가 오래 막힌다. 풀 스레드를 붙잡지 않아야 다른 비동기 일이 멈추지 않는다
        let (root, a, b, url) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LoudnessCache(url: url, saveDelay: .milliseconds(10)) { file in
            expectBlockingOffPool()
            return LoudnessCache.fileKey(file)
        }
        let loudness = Loudness(integrated: -9, peak: -1, clippedRuns: 0)
        cache.store(loudness, for: a)
        cache.store(loudness, for: b)
        #expect(await cache.prune(keeping: [a.path, b.path]) == 0)
    }

    @Test func 파일을_못_읽는_라이브러리_곡의_항목은_남긴다() async throws {
        let (root, a, b, url) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LoudnessCache(url: url, saveDelay: .milliseconds(10))
        let loudness = Loudness(integrated: -9, peak: -1, clippedRuns: 0)
        cache.store(loudness, for: a)
        cache.store(loudness, for: b)
        let offline = a.path
        try FileManager.default.removeItem(at: a)   // 꺼 둔 드라이브처럼 지금은 못 읽는 파일
        #expect(await cache.prune(keeping: [offline]) == 1, "라이브러리에 없는 b만 지운다")
        #expect(cache.value(for: b) == nil)
        await cache.waitForSave()
        let saved = try JSONDecoder().decode([String: Loudness].self, from: Data(contentsOf: url))
        #expect(saved.keys.contains { $0.hasPrefix(offline + "|") } && saved.count == 1)
    }
}
