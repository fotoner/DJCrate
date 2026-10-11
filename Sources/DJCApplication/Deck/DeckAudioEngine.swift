import DJCDomain
import Foundation

/// 덱이 쓰는 재생 엔진. 실제는 DJCAdapters의 `DeckAudio`(AVAudioEngine)를 조립 지점이 넣고, 시험에서는 가짜로 바꾼다.
/// 메인 액터 동기로 부른다(덱 재생 경로는 화면 모델이 이 포트를 직접 부르는 예외다).
@MainActor
public protocol DeckAudioEngine: AnyObject {
    var volume: Float { get set }
    var metronome: Bool { get set }
    var metronomeVolume: Float { get set }
    /// 멈춘 뒤 엔진을 끄기까지(초)
    var idleSeconds: Double { get set }
    var rate: Double { get set }
    var keyLock: Bool { get set }
    var gainDB: Float { get set }
    var meter: LevelMeter { get }
    var needsChroma: Bool { get set }
    var onChroma: ((KeyChroma) -> Void)? { get set }
    var onLoudness: ((Loudness) -> Void)? { get set }
    var onRecovered: (() -> Void)? { get set }
    var onInterrupted: ((Double) -> Void)? { get set }

    var isLoaded: Bool { get }
    var isPlaying: Bool { get }
    /// rekordbox 시간축 길이
    var duration: Double { get }
    /// 지금 들리는 곡 위치(rekordbox 시간축)
    var position: Double { get }
    /// 오디오가 루프를 샘플 단위로 되풀이하고 있는지
    var handlesLoop: Bool { get }
    /// 마지막 position 조회에서 예약한 점프 경계에 아직 닿지 않았는지
    var hasPendingJump: Bool { get }
    /// 출력 장치를 쓸 수 없어 재생을 막는지(엔진 준비 전·엔진 시작 실패). `play`가 false를 돌려준 이유를 가른다.
    var isOutputUnavailable: Bool { get }
    var isPreparingOutput: Bool { get }

    func load(url: URL, timelineOffset: Double) throws
    func unload()
    @discardableResult func play(from position: Double) -> Bool
    func pause()
    func stop()
    func seekWhilePaused(_ position: Double)
    func recoverIfStalled()
    func scheduleClicks(_ grid: BeatGrid?)
    func resetClicks()
    @discardableResult func setLoop(_ range: ClosedRange<Double>?, reschedule: Bool) -> Bool
    /// 재생 퀀타이즈: 다음 박 조각 경계에서 `cue` 쪽으로 넘어가게 예약한다(루프 핫큐면 착지 뒤 `loop`를 되풀이).
    /// 샘플 단위로 예약했으면 그 점프, 못 하면 nil(부른 쪽이 화면 틱으로 넘긴다).
    func scheduleJump(to cue: Double, loop: ClosedRange<Double>?, quantize: PlayQuantize) -> PlayQuantize.Jump?

    /// Flip 기록: 재생 한 번이 끝날 때(멈춤·다른 자리에서 다시 재생) 그동안 들린 구간(루프는 바퀴마다)을 알린다.
    var onPlayedRun: ((PlayedRun) -> Void)? { get set }
    /// Flip 기록: 지금 재생에서 아직 알리지 않은 들린 구간(재생 중이 아니면 nil). 다음에 알릴 구간은 지금부터다.
    func takePlayedRun() -> PlayedRun?

    /// 음원을 열지 못한 오류(`load`가 던진 것)를 화면에 보일 이유로 가른다. 확정된 형식 오류만 지원 밖이다.
    func failureState(for error: any Error) -> AudioSourceState
    /// 상시 오디오 사건 기록에 한 줄 남긴다(덱 조작: 재생·CUE·핫큐). 재생 경로의 기록과 같은 곳에 쓴다.
    func recordEvent(_ message: String)

    // 진단(자가 테스트)
    func debugStopEngine()
    func debugConfigurationChange()
}

extension DeckAudioEngine {
    public var isPreparingOutput: Bool { false }
    /// 루프를 걸거나 푼다(재생 중이면 지금 흐름에 이어 붙인다).
    @discardableResult public func setLoop(_ range: ClosedRange<Double>?) -> Bool { setLoop(range, reschedule: true) }
}
