import AVFoundation
import Foundation

/// 오디오 엔진을 만드는 곳.
///
/// 출력 장치 IO 유닛을 여는 `AVAudioEngine.mainMixerNode`·`outputNode`는 coreaudiod가 응답하지 않으면 끝없이 기다린다
/// (#142: 메인 스레드에서 불러 앱이 첫 화면 전에 멈췄다). 그래서 엔진 그래프는 모두 이 직렬 큐에서 만들고, 다 만든 뒤에만
/// 메인 액터로 넘긴다. 넘긴 뒤에는 메인 액터만 만지므로 한 엔진을 두 스레드가 함께 만지는 일이 없다.
/// 스레드 풀(Swift 동시성)이 아니라 GCD 큐라서 여기서 오래 막혀도 다른 비동기 작업은 멈추지 않는다.
enum AudioEngineQueue {
    private static let queue = DispatchQueue(label: "djc.audio.engine", qos: .userInitiated)

    static func make<Graph: Sendable>(_ build: @escaping @Sendable () -> Graph) async -> Graph {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: build()) }
        }
    }
}

/// 덱 재생 그래프: 곡(trackNode → 게인 → 볼륨)과 메트로놈(clickNode)을 서브믹서에 모아 속도 변환을 거쳐 출력에 잇는다.
/// 곡 쪽 연결은 곡 형식을 알아야 해서 곡을 불러올 때 잇는다(`DeckAudio.connectTrack`).
///
/// `AudioEngineQueue`에서 만들고 메인 액터로 넘긴 뒤에는 메인 액터만 만진다(그래서 `@unchecked Sendable`).
public final class DeckAudioGraph: @unchecked Sendable {
    /// 메트로놈 클릭 형식(48kHz 스테레오). 클릭 버퍼와 clickNode 연결이 같은 형식이어야 한다.
    static let clickSampleRate = 48_000.0

    let engine = AVAudioEngine()
    let trackNode = AVAudioPlayerNode()
    /// 곡 게인(오토게인·트림). 대역은 쓰지 않고 전역 게인만 쓴다(−96…+24dB).
    let gainUnit = AVAudioUnitEQ(numberOfBands: 1)
    /// 곡 볼륨(페이더). 미터는 이 앞(게인 뒤)에서 읽는다.
    let trackMixer = AVAudioMixerNode()
    let clickNode = AVAudioPlayerNode()
    let subMixer = AVAudioMixerNode()
    let varispeed = AVAudioUnitVarispeed()
    let timePitch = AVAudioUnitTimePitch()

    /// 실제 출력 장치에 잇는다. coreaudiod를 기다리다 끝나지 않을 수 있어 메인 스레드에서 부르지 않는다.
    public static func make() -> DeckAudioGraph? { DeckAudioGraph() }

    private init() {
        for node in [trackNode, gainUnit, trackMixer, clickNode, subMixer, varispeed, timePitch] as [AVAudioNode] { engine.attach(node) }
        gainUnit.bands[0].bypass = true
        // 옛 API도 잘못된 연결은 예외로 종료했다. 같은 형식·자동 믹서 버스를 쓰고 실패를 숨기지 않는다.
        try! engine.connectNode(clickNode, to: subMixer, format: AVAudioFormat(standardFormatWithSampleRate: Self.clickSampleRate, channels: 2))
        try! engine.connectNode(subMixer, to: varispeed, format: nil)
        try! engine.connectNode(varispeed, to: timePitch, format: nil)
        // 여기서 출력 장치 IO 유닛이 생긴다(coreaudiod가 응답하지 않으면 멈추는 곳).
        try! engine.connectNode(timePitch, to: engine.mainMixerNode, format: nil)
    }
}
