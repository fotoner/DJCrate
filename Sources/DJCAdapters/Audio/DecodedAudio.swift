import DJCAnalysis
import DJCDomain
import AVFoundation
import Foundation

/// 곡 전체를 메모리에 풀어 둔 PCM. 재생을 다시 시작할 때 파일을 읽지 않고 바로 소리를 낸다.
///
/// 큐 점프·CUE 미리 듣기가 외장 드라이브에서도 바로 반응하도록 곡을 불러올 때 한 번 디코딩해 두고,
/// 재생은 이 버퍼를 복사 없이 잘라 예약한다.
/// (처음 겪은 "재시작마다 1~1.7초 무음"의 실제 원인은 파일 읽기가 아니라 엔진 pause→start 뒤의
/// 시작 시각 어긋남이었다. 그건 `stop()`에서 engine.stop()을 쓰는 것으로 고쳤다.)
final class DecodedAudio: @unchecked Sendable {
    /// 디코딩이 끝난 뒤에는 바뀌지 않는다(읽기 전용 공유).
    let buffer: AVAudioPCMBuffer

    private init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// 긴 믹스 파일은 메모리를 너무 많이 쓰므로 파일 스트리밍으로 둔다.
    static let maxDuration: Double = 20 * 60

    var frameCount: AVAudioFramePosition { AVAudioFramePosition(buffer.frameLength) }

    static func decode(url: URL) -> DecodedAudio? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        // MP3 길이는 추정값이라 약간 더 받아 둔다.
        let capacity = AVAudioFrameCount(min(Double(file.length) + format.sampleRate, Double(UInt32.max - 1)))
        let chunkFrames: AVAudioFrameCount = 1 << 16
        guard file.length > 0,
              let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              let dst = whole.floatChannelData else { return nil }
        var filled = 0
        while !Task.isCancelled, file.framePosition < file.length {
            do { try file.read(into: chunk, frameCount: chunkFrames) } catch {
                // 파일 끝에서 eofErr를 돌려주는 디코더가 있다. 읽은 만큼은 쓴다.
                guard filled > 0 else { return nil }
                break
            }
            let n = Int(chunk.frameLength)
            guard n > 0, let src = chunk.floatChannelData else { break }
            let take = min(n, Int(capacity) - filled)
            guard take > 0 else { break }
            for ch in 0..<channels {
                (dst[ch] + filled).update(from: src[ch], count: take)
            }
            filled += take
        }
        guard !Task.isCancelled, filled > 0 else { return nil }
        whole.frameLength = AVAudioFrameCount(filled)
        return DecodedAudio(buffer: whole)
    }

    /// 조성 흐름 추정용 크로마
    func chroma() -> KeyAnalyzer.Chroma {
        guard let data = buffer.floatChannelData else { return KeyAnalyzer.Chroma(hop: 0.2, frames: []) }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
        return KeyAnalyzer.chroma(channels: channels, sampleRate: buffer.format.sampleRate)
    }

    /// 곡 전체 음량(BS.1770 통합 음량·피크·클리핑 흔적)
    func loudness() -> Loudness {
        guard let data = buffer.floatChannelData else { return Loudness(integrated: nil, peak: -120, clippedRuns: 0) }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
        return Loudness.measure(channels: channels, sampleRate: buffer.format.sampleRate)
    }

    /// `frame`부터 `end`(없으면 끝)까지를 가리키는 버퍼(복사하지 않는다). 버퍼가 살아 있는 동안 원본도 붙잡아 둔다.
    func segment(from frame: AVAudioFramePosition, to end: AVAudioFramePosition? = nil) -> AVAudioPCMBuffer? {
        let end = min(end ?? frameCount, frameCount)
        guard frame >= 0, frame < end, let data = buffer.floatChannelData else { return nil }
        let count = Int(end - frame)
        let channels = Int(buffer.format.channelCount)
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        for ch in 0..<channels {
            list[ch] = AudioBuffer(mNumberChannels: 1,
                                   mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                                   mData: UnsafeMutableRawPointer(data[ch] + Int(frame)))
        }
        let owner = self
        return AVAudioPCMBuffer(pcmFormat: buffer.format, bufferListNoCopy: list.unsafePointer) { _ in
            withExtendedLifetime(owner) {}
            free(list.unsafeMutablePointer)
        }
    }
}
