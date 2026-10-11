import DJCDomain
import Foundation
@testable import DJCAnalysis
import Testing

/// #216: 파형·분석 캐시 정리가 `analysis/` 아래 하위 폴더(`grid-estimates/`·`chroma/`)의 파일까지 하나씩 세고,
/// 폴더째 지우지 않는다. 캐시 뿌리는 임시 폴더로 주입한다(사용자 폴더를 열지 않는다).
@Suite("캐시 정리")
struct CacheMaintenanceTests {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-cache-prune-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `bytes` 크기 파일을 쓰고 접근·수정 시각을 `daysAgo`일 전으로 맞춘다(정리 순서를 시험이 정한다).
    @discardableResult
    func write(_ url: URL, bytes: Int, daysAgo: Double) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        try age(url, daysAgo: daysAgo)
        return url
    }

    func age(_ url: URL, daysAgo: Double) throws {
        let date = Date(timeIntervalSinceNow: -daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.contentAccessDate = date
        var target = url
        try target.setResourceValues(values)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func 하위_폴더의_파일도_상한_합계에_들어가_오래된_것부터_지운다() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DJCCachePaths(root: root)
        let chroma = paths.analysis.appending(path: "chroma")
        let old = try write(chroma.appending(path: "a-1.bin"), bytes: 4_000, daysAgo: 30)
        let newer = try write(chroma.appending(path: "b-1.bin"), bytes: 4_000, daysAgo: 1)

        CacheMaintenance.prune(maxBytes: 6_000, paths: paths)

        #expect(!exists(old), "크로마 합계(8000)가 상한(6000)을 넘으므로 오래된 파일을 지운다")
        #expect(exists(newer))
        #expect(exists(chroma), "폴더는 남긴다")
    }

    @Test func 하위_폴더가_가장_오래돼도_폴더째_지우지_않고_파일만_지운다() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DJCCachePaths(root: root)
        let grid = paths.analysis.appending(path: "grid-estimates")
        let oldGrid = try write(grid.appending(path: "a-1.json"), bytes: 1_000, daysAgo: 2)
        let freshGrid = try write(grid.appending(path: "b-1.json"), bytes: 1_000, daysAgo: 0)
        let waveform = try write(paths.waveforms.appending(path: "c-1.json"), bytes: 8_000, daysAgo: 10)
        let section = try write(paths.analysis.appending(path: "d-1.json"), bytes: 1_000, daysAgo: 0)
        try age(grid, daysAgo: 100)

        CacheMaintenance.prune(maxBytes: 8_500, paths: paths)

        #expect(!exists(waveform), "가장 오래 안 쓴 파일부터 지운다")
        #expect(exists(grid), "폴더는 접근 시각과 상관없이 지우지 않는다")
        #expect(exists(oldGrid) && exists(freshGrid) && exists(section), "상한의 80% 아래로 내려가면 멈춘다")
    }

    @Test func 상한_아래면_아무것도_지우지_않는다() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DJCCachePaths(root: root)
        let file = try write(paths.analysis.appending(path: "chroma/a-1.bin"), bytes: 1_000, daysAgo: 30)
        CacheMaintenance.prune(maxBytes: 2_000, paths: paths)
        #expect(exists(file))
    }

    @Test func 캐시_폴더_밖은_세지도_지우지도_않는다() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DJCCachePaths(root: root)
        let draft = try write(root.appending(path: "cue-drafts/x.json"), bytes: 50_000, daysAgo: 400)
        let cache = try write(paths.waveforms.appending(path: "a-1.json"), bytes: 1_000, daysAgo: 1)
        CacheMaintenance.prune(maxBytes: 2_000, paths: paths)
        #expect(exists(draft) && exists(cache))
    }
}
