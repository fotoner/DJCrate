import DJCDomain
import AVFoundation
import CoreMedia
import DJCEnvironment
import Foundation
import MusicUnderstanding

/// Music Understanding(macOS 27+)으로 곡 하나를 분석한다.
public enum PartAnalyzer {
    /// `DJC_HOME`을 주면 그 아래(#195). 없으면 사용자 폴더의 `analysis`
    public static var cacheDirectory: URL { DJCCachePaths.current.analysis }

    /// 분석 결과는 트랙 UUID 단위로 캐시한다. 파일이 바뀌면(크기·수정 시각) 다시 분석한다.
    public static func analyze(fileAt url: URL, cacheKey: String? = nil) async throws -> PartAnalysis {
        let cacheURL = cacheKey.map { cacheDirectory.appending(path: "\($0)-\(fileStamp(url)).json") }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL) {
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            if let cached = try? decoder.decode(PartAnalysis.self, from: data) { return cached }
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        try Task.checkCancellation()
        let session = try await MusicUnderstandingSession(asset: asset)
        // 곡을 넘기면(작업 취소) 분석 세션도 멈춘다. 그렇지 않으면 5초짜리 분석이 쌓인다.
        let result = try await withTaskCancellationHandler {
            try await session.analyze()
        } onCancel: {
            Task { await session.cancel() }
        }
        try Task.checkCancellation()
        let analysis = convert(result, duration: duration)

        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            // 무음 구간의 -inf LUFS 같은 비유한 값은 JSON이 거부한다. convert에서 보정하지만 한 번 더 막는다.
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            if let data = try? encoder.encode(analysis) {
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        return analysis
    }

    static func fileStamp(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(modified))"
    }

    static func convert(_ result: MusicUnderstandingSession.SessionResult, duration: Double) -> PartAnalysis {
        func span(_ range: CMTimeRange) -> PartAnalysis.Span {
            .init(start: range.start.seconds, end: range.end.seconds)
        }
        // 무음 구간의 -inf LUFS 등 비유한 값은 -70으로 바꾼다(JSON 캐시 저장이 실패하던 원인).
        func finite(_ value: Double) -> Double { value.isFinite ? value : -70 }
        func samples<V: BinaryFloatingPoint>(_ values: [MusicUnderstandingSession.TimedValue<V>]) -> [PartAnalysis.Sample] {
            values.map { .init(time: $0.time.seconds, value: finite(Double($0.value))) }
        }

        let activity = result.instrumentActivity?.activity ?? [:]
        return PartAnalysis(
            duration: duration,
            bpm: result.rhythm?.beatsPerMinute.map(Double.init),
            beats: result.rhythm?.beats.map(\.seconds) ?? [],
            bars: result.rhythm?.bars.map(\.seconds) ?? [],
            sections: result.structure?.sections.map(span) ?? [],
            segments: result.structure?.segments.map(span) ?? [],
            phrases: result.structure?.phrases.map(span) ?? [],
            keys: result.key?.ranges.map {
                .init(span: span($0.range), tonic: $0.value.tonic.rawValue, mode: $0.value.mode.rawValue)
            } ?? [],
            pace: result.pace?.ranges.map { .init(time: $0.range.start.seconds, value: finite($0.value)) } ?? [],
            vocal: samples(activity[.vocal] ?? []),
            drum: samples(activity[.drum] ?? []),
            loudness: samples(result.loudness?.shortTerm ?? []),
            integratedLoudness: result.loudness.map { Double($0.integrated.value) }.flatMap { $0.isFinite ? $0 : nil }
        )
    }
}
