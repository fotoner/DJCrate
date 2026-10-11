import AVFoundation
import DJCDomain
import DJCTestKit
import Foundation
@testable import DJCAnalysis
import Testing

@Suite("곡 전체 조성 추정(#124)")
struct KeyEstimateTests {
    static let progressions: [(name: String, chords: [ChordFixture.Chord], camelot: String)] = [
        ("A단조", ChordFixture.aMinor, "8A"), ("C장조", ChordFixture.cMajor, "8B"),
        ("D장조", ChordFixture.dMajor, "10B"), ("E단조", ChordFixture.eMinor, "9A"),
    ]

    func chroma(_ chords: [ChordFixture.Chord], seconds: Double = 40) -> KeyAnalyzer.Chroma {
        let samples = ChordFixture.samples(chords, seconds: seconds, sampleRate: 22_050)
        return samples.withUnsafeBufferPointer { KeyAnalyzer.chroma(channels: [$0], sampleRate: 22_050) }
    }

    @Test(arguments: progressions.indices)
    func 합성_화음_진행의_조성과_장단(index: Int) {
        let (name, chords, camelot) = Self.progressions[index]
        let key = KeyAnalyzer.mainKey(chroma: chroma(chords), windows: KeyAnalyzer.windows(grid: nil, duration: 40))
        #expect(key?.camelot == camelot, "\(name)")
    }

    @Test func 조표가_같은_장조와_나란한_단조를_가른다() {
        // C장조·A단조는 조표가 같아(8) 조표 흐름만으로는 못 가른다. 장·단은 으뜸화음 쪽 크로마로 본다.
        for (chords, minor) in [(ChordFixture.cMajor, false), (ChordFixture.aMinor, true)] {
            let c = chroma(chords)
            let segments = [KeyAnalyzer.Segment(start: 0, end: 40, signature: 0)]
            #expect(KeyAnalyzer.isMinor(chroma: c, signature: 0, segments: segments) == minor)
        }
    }

    @Test func 파일에서_덱과_같은_크로마로_추정한다() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-key-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ChordFixture.wav(ChordFixture.aMinor, seconds: 30, in: directory, name: "a-minor.wav")
        let fromFile = try KeyAnalyzer.chroma(fileAt: url)
        // 덱은 디코딩한 채널을 모두 넘긴다(DecodedAudio.chroma). 파일에서 읽어도 같은 값이어야 한다.
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = (0..<Int(buffer.format.channelCount)).map {
            UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))
        }
        let fromBuffer = KeyAnalyzer.chroma(channels: channels, sampleRate: buffer.format.sampleRate)
        #expect(fromFile.frames.count == fromBuffer.frames.count && fromFile.hop == fromBuffer.hop)
        let diff = zip(fromFile.frames, fromBuffer.frames).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
        #expect(diff < 1e-4)
        let key = KeyAnalyzer.mainKey(chroma: fromFile, windows: KeyAnalyzer.windows(grid: nil, duration: 30))
        #expect(key?.camelot == "8A")
    }

    @Test func 무음이면_조성이_없다() {
        let chroma = KeyAnalyzer.Chroma(hop: 0.2, frames: [[Float]](repeating: [Float](repeating: 0, count: 12), count: 100))
        #expect(KeyAnalyzer.mainKey(chroma: chroma, windows: KeyAnalyzer.windows(grid: nil, duration: 20)) == nil)
        #expect(KeyAnalyzer.mainKey(chroma: KeyAnalyzer.Chroma(hop: 0.2, frames: []), windows: [(0, 2)]) == nil)
    }
}
