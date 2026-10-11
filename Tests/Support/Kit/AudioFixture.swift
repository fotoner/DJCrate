import AVFoundation
import Foundation

/// 합성 음원 파일(무음·램프·사인). 곡 길이·탐색 위치 계산 시험용.
public enum AudioFixture {
    /// 무손실 WAV(인코더 지연 없음)
    public static func wav(seconds: Double, sampleRate: Double = 44_100, in directory: URL, name: String = "silence.wav") throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    /// FLAC(macOS 인코더). 블록 크기는 인코더가 정한다.
    public static func flac(seconds: Double, sampleRate: Double = 44_100, in directory: URL, name: String = "tone.flac") throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // 압축이 되도록 소리를 조금 넣는다(440Hz)
        for ch in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = Float(sin(2 * .pi * 440 * Double(i) / sampleRate) * 0.3) }
        }
        try file.write(from: buffer)
        return url
    }

    /// ALAC(M4A). 비트 깊이·샘플레이트별 음원 칸 시험용.
    public static func alac(seconds: Double, sampleRate: Double = 44_100, bitDepth: Int = 16, in directory: URL, name: String = "lossless.m4a") throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: bitDepth,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    /// AAC(M4A). macOS 인코더는 앞에 프라이밍 2112샘플을 넣는다.
    public static func aac(seconds: Double, sampleRate: Double = 44_100, in directory: URL, name: String = "tone.m4a") throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }
}

public extension AudioFixture {
    /// 짧은 클릭(1ms 사각파 + 감쇠)을 `times`(초)에 넣은 모노 WAV. 어택 곡선 시험용.
    static func clicks(at times: [Double], seconds: Double, sampleRate: Double = 44_100, in directory: URL,
                       name: String = "clicks.wav") throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for t in times {
            let start = Int(t * sampleRate)
            for i in 0..<Int(0.03 * sampleRate) where start + i < Int(frames) {
                let noise = Float((i * 7919) % 200) / 100 - 1
                data[start + i] = noise * 0.9 * Float(exp(-Double(i) / (0.004 * sampleRate)))
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// 사인파 합(주파수·세기) 채널 버퍼. 크로마 시험용.
    static func tones(_ partials: [(frequency: Double, amplitude: Double)], seconds: Double, sampleRate: Double = 22_050) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            return Float(partials.reduce(0) { $0 + $1.amplitude * sin(2 * .pi * $1.frequency * t) })
        }
    }
}
