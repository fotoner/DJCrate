@testable import DJCAdapters
import DJCApplication
import AVFoundation
import Testing

/// 새 탭 API에서도 프레임 수·채널별 피크·RMS를 기존과 같이 읽는다(실제 장치는 열지 않는다).
struct AudioTapTests {
    @Test(arguments: [1, 2, 4])
    func monoAndStereoLevelsUseOnlyValidFrames(channels: Int) throws {
        let tag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Quadraphonic
        let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 4
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<channels {
            for frame in 0..<8 { data[channel][frame] = frame < 4 ? (channel == 0 ? 0.5 : 0.25) : 1 }
        }
        let meter = LevelMeter()
        DeckAudio.meterTap(meter)(AVReadOnlyAudioPCMBuffer(copying: buffer), AVAudioTime(sampleTime: 0, atRate: 44_100))
        let result = meter.read()
        #expect(result.peak.left == 0.5 && result.rms.left == 0.5)
        let right: Float = channels == 1 ? 0.5 : 0.25
        #expect(result.peak.right == right && result.rms.right == right)
    }

    @Test func emptyAndNonFloatBuffersLeaveMeterUntouched() throws {
        for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            let format = try #require(AVAudioFormat(commonFormat: commonFormat, sampleRate: 44_100, channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
            buffer.frameLength = commonFormat == .pcmFormatInt16 ? 4 : 0
            let meter = LevelMeter()
            meter.update(peak: (0.5, 0.25), rms: (0.25, 0.125), now: 1)
            DeckAudio.meterTap(meter)(AVReadOnlyAudioPCMBuffer(copying: buffer), AVAudioTime(sampleTime: 0, atRate: 44_100))
            let result = meter.read()
            #expect(result.peak.left == 0.5 && result.peak.right == 0.25 && result.rms.left == 0.25 && result.rms.right == 0.125)
        }
    }
}
