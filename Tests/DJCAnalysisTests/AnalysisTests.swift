import DJCDomain
import DJCTestKit
import Foundation
@testable import DJCAnalysis
import Testing

@Suite("조성")
struct KeyAnalyzerTests {
    @Test func Camelot_번호는_조표를_5도권으로() {
        // C장조 8B, G장조 9B, F장조 7B, E장조 12B, A단조 8A
        #expect(KeyAnalyzer.camelot(signature: 0, minor: false) == "8B")
        #expect(KeyAnalyzer.camelot(signature: 7, minor: false) == "9B")
        #expect(KeyAnalyzer.camelot(signature: 5, minor: false) == "7B")
        #expect(KeyAnalyzer.camelot(signature: 4, minor: false) == "12B")
        #expect(KeyAnalyzer.camelot(signature: 0, minor: true) == "8A")
        for s in 0..<12 {
            for minor in [false, true] {
                let text = KeyAnalyzer.camelot(signature: s, minor: minor)
                #expect(KeyAnalyzer.signature(camelot: text).map { $0.signature == s && $0.minor == minor } == true)
            }
        }
        #expect(KeyAnalyzer.signature(camelot: "13B") == nil && KeyAnalyzer.signature(camelot: "8C") == nil)
    }

    /// 장음계 크로마(으뜸화음을 세게). `tonic` 반음만큼 돌린다.
    func scaleFrame(tonic: Int) -> [Float] {
        let weights: [Int: Float] = [0: 1.0, 2: 0.4, 4: 0.75, 5: 0.45, 7: 0.85, 9: 0.4, 11: 0.35]
        return (0..<12).map { weights[($0 - tonic + 12) % 12] ?? 0.02 }
    }

    @Test func 전조를_구간으로_나눈다() {
        // 앞 40초 C장조, 뒤 40초 F#장조(공통음이 거의 없다, 0.2초 간격 크로마), 2초 창
        let frames = (0..<200).map { _ in scaleFrame(tonic: 0) } + (0..<200).map { _ in scaleFrame(tonic: 6) }
        let chroma = KeyAnalyzer.Chroma(hop: 0.2, frames: frames)
        let result = KeyAnalyzer.segments(chroma: chroma, windows: KeyAnalyzer.windows(grid: nil, duration: 80),
                                          switchPenalty: 1, minWindows: 4)
        #expect(result.segments.map(\.signature) == [0, 6])
        #expect(abs((result.segments.first?.end ?? 0) - 40) <= 2)
    }

    @Test func 짧은_흔들림은_옆_구간에_합친다() {
        let frames = (0..<150).map { _ in scaleFrame(tonic: 0) } + (0..<10).map { _ in scaleFrame(tonic: 2) }
            + (0..<150).map { _ in scaleFrame(tonic: 0) }
        let result = KeyAnalyzer.segments(chroma: KeyAnalyzer.Chroma(hop: 0.2, frames: frames),
                                          windows: KeyAnalyzer.windows(grid: nil, duration: 62), switchPenalty: 1, minWindows: 4)
        #expect(result.segments.map(\.signature) == [0] && result.main == 0)
    }

    @Test func 크로마는_실제_음높이를_잡는다() {
        // C4·E4·G4 사인파 → 음이름 0·4·7이 가장 세다
        let samples = AudioFixture.tones([(261.63, 0.3), (329.63, 0.3), (392.0, 0.3)], seconds: 3)
        let chroma = samples.withUnsafeBufferPointer { KeyAnalyzer.chroma(channels: [$0], sampleRate: 22_050) }
        #expect(!chroma.frames.isEmpty)
        var total = [Float](repeating: 0, count: 12)
        for frame in chroma.frames { for i in 0..<12 { total[i] += frame[i] } }
        let top = total.indices.sorted { total[$0] > total[$1] }.prefix(3)
        #expect(Set(top) == [0, 4, 7])
    }

    @Test func 창은_마디_단위() {
        let grid = BeatGrid(beats: (0..<40).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 1.0 + Double($0) * 0.5) })
        let windows = KeyAnalyzer.windows(grid: grid, duration: 30)
        #expect(windows.first! == (0, 1.0) && windows[1] == (1.0, 3.0))
        #expect(windows.last!.1 == 30)
    }
}

@Suite("메모리 큐 제안")
struct MemoryCueSuggesterTests {
    /// 120 BPM(마디 2초), 박 0.5초마다, 섹션 [0,8) [8,9) [9,40) [40,80) [80,120)
    func analysis() -> PartAnalysis {
        let beats = stride(from: 0.0, to: 120, by: 0.5).map { $0 }
        let bars = stride(from: 0.0, to: 120, by: 2.0).map { $0 }
        func span(_ a: Double, _ b: Double) -> PartAnalysis.Span { .init(start: a, end: b) }
        return PartAnalysis(duration: 120, bpm: 120, beats: beats, bars: bars,
                            sections: [span(0, 8), span(8, 9), span(9, 40), span(40, 80), span(80, 120)],
                            segments: [], phrases: [], keys: [], pace: [], vocal: [], drum: [], loudness: [], integratedLoudness: nil)
    }

    @Test func 섹션_시작을_박에_맞추고_짧은_섹션은_뺀다() {
        // 8~9초는 반 마디라 빠지고, 0초는 곡 첫머리라 빠진다. 9초는 마디(8·10)에서 반 박보다 멀어 박 그대로.
        #expect(MemoryCueSuggester.candidates(analysis()) == [9, 40, 80])
    }

    @Test func 기존_큐와_한_마디_안이면_만들지_않는다() {
        #expect(MemoryCueSuggester.suggestions(analysis(), existing: [41.5, 100]) == [9, 80])
    }

    @Test func 재현율과_정밀도() {
        let evaluation = CueEvaluation(truth: [10, 40, 80], predicted: [10.2, 40, 60, 90], tolerance: 0.5)
        #expect(evaluation.truthMatched == 2 && evaluation.predictedMatched == 2)
        #expect(abs(evaluation.recall - 2.0 / 3) < 1e-9 && abs(evaluation.precision - 0.5) < 1e-9)
        let sum = evaluation + evaluation
        #expect(sum.truth == 6 && abs(sum.recall - evaluation.recall) < 1e-9)
    }

    @Test func 마디_번호와_스냅() {
        let a = analysis()
        #expect(a.barNumber(at: 4.1) == 3 && a.snap(39.8) == 40 && a.snap(9.1) == 9)
    }
}

@Suite("파형·어택")
struct WaveformOnsetTests {
    @Test func 파형은_초당_150칸_3밴드() throws {
        let folder = try TemporaryFolder()
        let url = try AudioFixture.flac(seconds: 2, in: folder.url)
        let waveform = try WaveformAnalyzer.analyze(fileAt: url)
        #expect(abs(Double(waveform.count) - 300) <= 2)
        #expect(waveform.low.count == waveform.count && waveform.high.count == waveform.count)
        #expect(waveform.mid.max() ?? 0 > 0, "440Hz 사인은 중역에 잡힌다")
        #expect(waveform.downsampled(to: 30).count == 30)
        #expect(abs(Double(waveform.slice(from: 0.5, to: 1.5).count) - 150) <= 2)
    }

    @Test func 어택_곡선은_클릭_자리에서_솟는다() throws {
        let folder = try TemporaryFolder()
        let times = [0.5, 1.0, 1.5, 2.0, 2.5]
        let envelope = try OnsetEnvelope.compute(url: try AudioFixture.clicks(at: times, seconds: 3, in: folder.url))
        #expect(abs(envelope.duration - 3) < 0.01)
        for t in times {
            #expect(envelope.value(at: t + 0.001) > envelope.value(at: t + 0.25) * 3, "\(t)초")
        }
        // 박 목록이 4ms 이르면, `t - lag`가 클릭에 오게 하는 lag는 −4ms다
        let best = envelope.bestLag(for: times.map { $0 - 0.004 }, range: -0.02...0.02)
        #expect(abs(best.lag + 0.004) <= 0.001)
    }
}
