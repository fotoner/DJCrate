import AVFoundation
@testable import DJCAdapters
import DJCApplication
import Foundation
import Testing

/// LINK로 끌어 놓은 FLAC·ALAC을 WAV로 바꾸기(#277). 임시 폴더에 합성 음원을 만들어 바꾼다(사용자 폴더에 쓰지 않는다).
@Suite("LINK 음원 변환")
struct LinkAudioConverterLiveTests {
    /// 1초 440Hz 사인파(스테레오 44.1kHz, 16비트)를 그 형식으로 쓴다
    static func tone(_ url: URL, format: AudioFormatID) throws {
        let settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVEncoderBitDepthHintKey: 16]
        // 16비트 정수로 넣어야 무손실 인코더가 원본을 16비트로 적는다(부동소수로 넣으면 24비트로 적는다)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        let frames: AVAudioFrameCount = 44_100
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = try #require(buffer.int16ChannelData?[channel])
            for frame in 0..<Int(frames) { samples[frame] = Int16(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 16_000) }
        }
        try file.write(from: buffer)
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-link-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func FLAC은_같은_길이의_WAV로_바꾸고_다시_놓으면_바꾼_파일을_다시_쓴다() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "tone.flac")
        try Self.tone(source, format: kAudioFormatFLAC)
        let before = try Data(contentsOf: source)
        let converter = LinkAudioConverter.live(cache: root.appending(path: "cache"))

        let path = try #require(try await converter.convert(source.path))
        #expect(path.hasSuffix(".wav"))
        let wav = try AVAudioFile(forReading: URL(filePath: path))
        #expect(wav.length == 44_100)
        #expect(wav.fileFormat.sampleRate == 44_100)
        // 압축 형식은 PCM 비트 수가 0으로 읽혀도 원본 비트 깊이(16)를 따른다. 24비트로 키우면 CDJ가 NFS로 1.5배를 읽는다
        #expect(wav.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        // 원본은 그대로, 반쯤 쓴 파일은 남지 않는다
        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "cache").path) == [URL(filePath: path).lastPathComponent])

        let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(try await converter.convert(source.path) == path)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == modified)
    }

    @Test func ALAC은_바꾸고_AAC와_MP3·WAV는_그대로_둔다() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let alac = root.appending(path: "lossless.m4a")
        let aac = root.appending(path: "lossy.m4a")
        try Self.tone(alac, format: kAudioFormatAppleLossless)
        try Self.tone(aac, format: kAudioFormatMPEG4AAC)
        let converter = LinkAudioConverter.live(cache: root.appending(path: "cache"))
        let alacWAV = try #require(try await converter.convert(alac.path))
        #expect(alacWAV.hasSuffix(".wav"))
        #expect(try AVAudioFile(forReading: URL(filePath: alacWAV)).fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(try await converter.convert(aac.path) == nil)
        #expect(try await converter.convert(root.appending(path: "song.mp3").path) == nil)
    }

    @Test func 읽지_못하는_원본은_까닭과_함께_실패한다() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appending(path: "broken.flac")
        try Data("not audio".utf8).write(to: broken)
        let converter = LinkAudioConverter.live(cache: root.appending(path: "cache"))
        await #expect {
            _ = try await converter.convert(broken.path)
        } throws: { error in
            if case .conversionFailed = error as? LinkProblem { true } else { false }
        }
    }
}
