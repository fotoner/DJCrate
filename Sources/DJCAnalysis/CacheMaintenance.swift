import DJCDomain
import DJCEnvironment
import Foundation

/// 파형·분석 캐시는 곡당 약 0.6MB다(전곡이면 4GB대). 합계가 상한을 넘으면 오래 안 쓴 파일부터 지운다.
public enum CacheMaintenance {
    public static func prune(maxBytes: Int = 1_500_000_000, paths: DJCCachePaths = .current) {
        let fm = FileManager.default
        var files = cacheFiles(in: [paths.waveforms, paths.analysis])
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        files.sort { $0.used < $1.used }
        for file in files {
            try? fm.removeItem(at: file.url)
            total -= file.size
            if total <= maxBytes * 8 / 10 { break }
        }
    }

    /// 하위 폴더(`analysis/grid-estimates/`·`chroma/`)까지 내려가 일반 파일만 모은다(#216).
    /// 폴더는 크기가 없어 한 단계만 읽으면 합계에서 빠지고, 순서에 걸리면 폴더째 지워졌다.
    static func cacheFiles(in directories: [URL]) -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        var files: [(url: URL, size: Int, used: Date)] = []
        for directory in directories {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files.append((url, values.fileSize ?? 0,
                              values.contentAccessDate ?? values.contentModificationDate ?? .distantPast))
            }
        }
        return files
    }
}
