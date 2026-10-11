import AVFoundation
import Foundation

/// 화음 진행 합성 음원. 조성 추정 시험용(실제 곡은 쓰지 않는다).
public enum ChordFixture {
    /// 화음 하나: 위 음들(MIDI 번호)과 베이스(MIDI 번호)
    public struct Chord: Sendable {
        public var notes: [Int]
        public var bass: Int
        public init(_ notes: [Int], bass: Int) { self.notes = notes; self.bass = bass }
    }

    /// i–iv–V–i(A단조, 8A). V는 화성 단음계의 E장조(G#)다.
    public static let aMinor = [Chord([57, 60, 64], bass: 45), Chord([62, 65, 69], bass: 50),
                                Chord([64, 68, 71], bass: 40), Chord([57, 60, 64], bass: 45)]
    /// I–IV–V–I(C장조, 8B). A단조와 조표가 같아 장·단만 다르다.
    public static let cMajor = [Chord([60, 64, 67], bass: 48), Chord([65, 69, 72], bass: 53),
                                Chord([67, 71, 74], bass: 43), Chord([60, 64, 67], bass: 48)]
    /// I–IV–V–I(D장조, 10B)
    public static let dMajor = [Chord([62, 66, 69], bass: 50), Chord([67, 71, 74], bass: 43),
                                Chord([69, 73, 76], bass: 45), Chord([62, 66, 69], bass: 50)]
    /// i–iv–V–i(E단조, 9A)
    public static let eMinor = [Chord([64, 67, 71], bass: 40), Chord([57, 60, 64], bass: 45),
                                Chord([59, 63, 66], bass: 47), Chord([64, 67, 71], bass: 40)]

    static func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    /// 화음마다 `beatsPerChord`박씩 되풀이한 모노 신호. 배음(1/2·1/3)과 매 박 킥을 넣어 실제 곡에 가깝게 한다.
    public static func samples(_ chords: [Chord], bpm: Double = 120, beatsPerChord: Int = 4, seconds: Double,
                               sampleRate: Double = 44_100) -> [Float] {
        let beat = 60 / bpm
        let chordLength = beat * Double(beatsPerChord)
        return (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            let chord = chords[Int(t / chordLength) % chords.count]
            let inBeat = t.truncatingRemainder(dividingBy: beat)
            var value = 0.0
            for note in chord.notes {
                let f = frequency(note)
                value += 0.12 * (sin(2 * .pi * f * t) + 0.5 * sin(4 * .pi * f * t) + 0.33 * sin(6 * .pi * f * t))
            }
            let bass = frequency(chord.bass)
            value += 0.2 * (sin(2 * .pi * bass * t) + 0.4 * sin(4 * .pi * bass * t))
            value += 0.5 * sin(2 * .pi * (55 + 90 * exp(-inBeat * 30)) * inBeat) * exp(-inBeat * 9)
            return Float(max(-0.95, min(0.95, value * 0.8)))
        }
    }

    /// 스테레오 16비트 WAV로 쓴다(두 채널 같음).
    public static func wav(_ chords: [Chord], bpm: Double = 120, seconds: Double, sampleRate: Double = 44_100,
                           in directory: URL, name: String) throws -> URL {
        let mono = samples(chords, bpm: bpm, seconds: seconds, sampleRate: sampleRate)
        let url = directory.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count))!
        buffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { samples in
            buffer.floatChannelData![0].update(from: samples.baseAddress!, count: mono.count)
            buffer.floatChannelData![1].update(from: samples.baseAddress!, count: mono.count)
        }
        try file.write(from: buffer)
        return url
    }
}

public extension AudioFixture {
    /// 음원 앞에 ID3v2.3 글자 태그(TIT2·TKEY 등)를 붙인 사본. 원본에 ID3 태그가 없어야 한다.
    static func mp3(_ source: URL, textFrames: [(id: String, value: String)], in directory: URL, name: String) throws -> URL {
        func bigEndian(_ value: Int) -> Data { Data([24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }) }
        func syncsafe(_ value: Int) -> Data { Data([21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) }) }
        var frames = Data()
        for frame in textFrames {
            // 글자 인코딩 1(UTF-16, BOM 포함)
            let body = Data([1]) + frame.value.data(using: .utf16)!
            frames += Data(frame.id.utf8) + bigEndian(body.count) + Data([0, 0]) + body
        }
        let tag = Data("ID3".utf8) + Data([3, 0, 0]) + syncsafe(frames.count) + frames
        let url = directory.appending(path: name)
        try (tag + Data(contentsOf: source)).write(to: url)
        return url
    }
}
