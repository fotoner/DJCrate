import AudioToolbox
import AVFoundation
@testable import DJCAdapters
import DJCApplication
@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// 오디오 엔진 포트(`DeckAudioEngine`·`EditAudio`)의 가짜와 실제 구현이 같은 계약을 지키는지 본다.
/// 실제 구현은 엔진 만들기를 nil로 주어 출력 장치를 열지 않는다(#142 시험과 같은 방식).
@MainActor
@Suite("오디오 엔진 포트 계약")
struct AudioEngineContractTests {
    /// 음원을 열지 못한 이유는 확정된 형식 오류만 지원 밖으로 가르고 나머지는 읽기 실패다(`AudioSourceState`).
    static func checkFailureStates(_ engine: any DeckAudioEngine) {
        let cases: [(any Error, AudioSourceState)] = [
            (CocoaError(.fileReadNoPermission), .readFailed),
            (NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileUnsupportedFileTypeError)), .unsupportedFormat),
            (NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileUnsupportedDataFormatError)), .unsupportedFormat),
            (NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileInvalidFileError)), .decodeFailed),
            (NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue), .decodeFailed),
            (NSError(domain: "unknown", code: Int(kAudioFileUnsupportedDataFormatError)), .readFailed),
        ]
        for (error, state) in cases { #expect(engine.failureState(for: error) == state, "\(error)") }
    }

    /// 곡을 불러오기 전: 재생·루프·점프 예약이 없고, 사건 기록은 받기만 한다.
    static func checkUnloaded(_ engine: any DeckAudioEngine) {
        #expect(!engine.isLoaded && !engine.isPlaying && !engine.handlesLoop && !engine.hasPendingJump)
        engine.recordEvent("계약 시험 기록")
    }

    /// 원곡을 풀기 전: 준비되지 않았고 재생을 막는다(부른 쪽이 안내를 띄운다).
    static func checkEditUnprepared(_ player: any EditAudio) {
        #expect(!player.isReady && !player.isPlaying && player.elapsed == 0)
        #expect(!player.play([EditPlaybackItem(outputFrame: 0, frameCount: 44_100, sourceFrame: 0)], from: 0, volume: 0.5))
    }

    @Test func 덱_가짜() {
        let fake = FakeDeckAudio()
        Self.checkFailureStates(fake)
        Self.checkUnloaded(fake)
    }

    @Test func 덱_실제() {
        let audio = DeckAudio(makeGraph: { nil })
        Self.checkFailureStates(audio)
        Self.checkUnloaded(audio)
    }

    @Test func 편집_가짜() {
        let fake = FakeEditAudio()
        fake.isReady = false
        Self.checkEditUnprepared(fake)
    }

    @Test func 편집_실제() {
        Self.checkEditUnprepared(EditAudioPlayer(makeGraph: { nil }))
    }
}
