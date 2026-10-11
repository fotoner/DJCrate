import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("탐색 위치 차이 진단")
struct SeekDiagnosticsTests {
    @Test func PVBR_미기록과_정보_프레임_차이를_구별한다() throws {
        let frames = try #require(SeekInfo.mp3Frames(url: TestResources.url("mp3-ffmpeg-cbr.mp3")))
        var facts = AudioFacts(sampleRate: 44_100, bitDepth: 16, bitRate: 128,
                               pvbrTotalSamples: UInt32((frames.offsets.count - 1) * frames.samplesPerFrame))
        let current = TrackAnalysisFiles.pvbr(facts)
        facts.pvbrTotalSamples = 0
        #expect(SeekDiagnostics.pvbr(stored: TrackAnalysisFiles.pvbr(facts), current: current, frames: frames).contains("미기록"))
        facts.pvbrTotalSamples = UInt32(frames.offsets.count * frames.samplesPerFrame)
        #expect(SeekDiagnostics.pvbr(stored: TrackAnalysisFiles.pvbr(facts), current: current, frames: frames).contains("정보 프레임 포함"))
        facts.pvbrTotalSamples += 1152
        #expect(SeekDiagnostics.pvbr(stored: TrackAnalysisFiles.pvbr(facts), current: current, frames: frames).contains("원인 미확인"))
    }

    @Test func PVB2는_샘플과_블록까지_같아야_바이트_위치만_다르다고_한다() throws {
        let folder = try TemporaryFolder()
        let facts = AudioFacts.read(url: try AudioFixture.flac(seconds: 1, in: folder.url))
        let current = try #require(TrackAnalysisFiles.pvb2(facts))
        var stored = current
        stored[32 + 20 + 15] ^= 1
        let file = try AnlzFile(data: AnlzBuilder.file([stored]))
        #expect(SeekDiagnostics.pvb2(stored: try #require(file.tag("PVB2")?.bytes), current: current).contains("바이트 위치만 다름"))
        stored[32 + 20 + 19] ^= 1
        #expect(!SeekDiagnostics.pvb2(stored: stored, current: current).contains("바이트 위치만 다름"))
        #expect(SeekDiagnostics.pvb2(stored: Data(current.prefix(40)), current: current).contains("형식"))
    }

    @Test func 큐의_프레임_경계_진단은_첫_프레임_기준이다() {
        let counted = [500, 700, 900]
        #expect(SeekDiagnostics.mp3Cue(stored: 201, counted: counted).contains("프레임 경계가 아님"))
        #expect(SeekDiagnostics.mp3Cue(stored: 201, counted: counted).contains("200/400"))
        #expect(SeekDiagnostics.mp3Cue(stored: 200, counted: counted).contains("프레임 경계는 맞음"))
        #expect(SeekDiagnostics.mp3Cue(stored: 0, counted: []).contains("프레임 없음"))
    }
}
