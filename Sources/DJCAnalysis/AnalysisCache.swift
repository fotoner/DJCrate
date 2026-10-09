import DJCDomain
import DJCEnvironment
import Foundation

/// 곡마다 한 번 계산하면 되는 분석 결과(그리드 추정·크로마) 캐시. 파일이 바뀌면(크기·수정 시각) 다시 계산한다.
/// 섹션 분석(`PartAnalyzer`)·파형(`WaveformCache`)과 같은 폴더를 쓴다.
public enum AnalysisCache {
    static func url(_ kind: String, key: String, file: URL, ext: String, paths: DJCCachePaths) -> URL {
        paths.analysis.appending(path: kind).appending(path: "\(key)-\(PartAnalyzer.fileStamp(file)).\(ext)")
    }

    // MARK: 그리드 추정

    public static func gridEstimate(key: String, file: URL, paths: DJCCachePaths = .current) -> GridEstimator.Estimate? {
        guard let data = try? Data(contentsOf: url("grid-estimates", key: key, file: file, ext: "json", paths: paths)) else { return nil }
        return try? JSONDecoder().decode(GridEstimator.Estimate.self, from: data)
    }

    public static func store(_ estimate: GridEstimator.Estimate, key: String, file: URL, paths: DJCCachePaths = .current) {
        let target = url("grid-estimates", key: key, file: file, ext: "json", paths: paths)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(estimate).write(to: target, options: .atomic)
    }

    // MARK: 크로마(프레임 × 12 Float, 이진)

    public static func chroma(key: String, file: URL, paths: DJCCachePaths = .current) -> KeyAnalyzer.Chroma? {
        guard let data = try? Data(contentsOf: url("chroma", key: key, file: file, ext: "bin", paths: paths)), data.count >= 8 else { return nil }
        return data.withUnsafeBytes { raw -> KeyAnalyzer.Chroma? in
            let hop = raw.loadUnaligned(fromByteOffset: 0, as: Double.self)
            let floats = raw.bindMemory(to: Float.self)
            let values = Array(floats.dropFirst(2))
            guard values.count % 12 == 0 else { return nil }
            let frames = stride(from: 0, to: values.count, by: 12).map { Array(values[$0..<$0 + 12]) }
            return KeyAnalyzer.Chroma(hop: hop, frames: frames)
        }
    }

    public static func store(_ chroma: KeyAnalyzer.Chroma, key: String, file: URL, paths: DJCCachePaths = .current) {
        let target = url("chroma", key: key, file: file, ext: "bin", paths: paths)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        withUnsafeBytes(of: chroma.hop) { data.append(contentsOf: $0) }
        for frame in chroma.frames { frame.withUnsafeBytes { data.append(contentsOf: $0) } }
        try? data.write(to: target, options: .atomic)
    }

    /// 재분석: 이 곡의 섹션 분석·그리드 추정·크로마 캐시를 지운다.
    public static func removeAll(key: String, paths: DJCCachePaths = .current) {
        let fm = FileManager.default
        let root = paths.analysis
        for folder in [root, root.appending(path: "grid-estimates"), root.appending(path: "chroma")] {
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix(key + "-") {
                try? fm.removeItem(at: file)
            }
        }
    }
}
