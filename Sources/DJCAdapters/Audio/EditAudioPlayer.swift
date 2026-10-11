import AVFoundation
import DJCAnalysis
import DJCApplication
import DJCDomain
import Foundation

/// 편집 창 재생 그래프(엔진·재생 노드). 출력 장치 IO 유닛(`mainMixerNode`)까지 `AudioEngineQueue`에서 만든다(#142).
/// 메인 액터로 넘긴 뒤에는 메인 액터만 만진다(그래서 `@unchecked Sendable`).
public final class EditAudioGraph: @unchecked Sendable {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()

    /// 실제 출력 장치를 연다. coreaudiod를 기다리다 끝나지 않을 수 있어 메인 스레드에서 부르지 않는다.
    public static func make() -> EditAudioGraph? { EditAudioGraph() }

    private init() {
        engine.attach(node)
        _ = engine.mainMixerNode
    }
}

/// 원곡을 메모리에 풀어 두고, 원곡 그대로(원곡 줄) 또는 편집 결과(결과 줄)를 렌더하지 않고 바로 재생한다.
///
/// 결과는 `TrackEdit.playbackItems`의 칸을 재생 노드 샘플 시각에 이어 예약한다. 조각 본문은 원곡 버퍼를 복사 없이 잘라 쓰고,
/// 이음새 섞는 칸만 새로 만든다(`EditRenderer.playbackBuffer`, 렌더 파일과 같은 소리). 칸 사이 빈자리(원곡 밖)는 무음이다.
/// 멈출 때는 `AVAudioEngine.pause()`가 아니라 `stop()`을 쓴다(덱과 같은 이유: 다시 켤 때 시작 시각이 밀린다).
@MainActor
public final class EditAudioPlayer: EditAudio {
    /// 엔진과 재생 노드. 넘겨받기 전(출력 장치가 응답하지 않음)에는 재생하지 못하고, 부른 쪽이 안내를 띄운다.
    private var graph: EditAudioGraph?
    private var graphTask: Task<Void, Never>?
    private var decoded: DecodedAudio?
    private var decodeTask: Task<Void, Never>?
    private var latency: Double = 0
    private var started = false

    /// - Parameter makeGraph: 엔진 그래프 만들기. 출력 장치를 열어 오래 걸릴 수 있어 `AudioEngineQueue`에서 부른다
    ///   (시험에서는 끝나지 않는 가짜를 준다). 원곡을 푸는 동안 함께 만든다.
    public init(makeGraph: @escaping @Sendable () -> EditAudioGraph? = EditAudioGraph.make) {
        graphTask = Task { [weak self] in
            let graph = await AudioEngineQueue.make(makeGraph)
            guard let self else { return }
            self.graph = graph
            connect()
        }
    }

    public var isReady: Bool { decoded != nil }
    public var sampleRate: Double { decoded?.buffer.format.sampleRate ?? 44_100 }
    /// 장치가 바뀌어 엔진이 멈췄으면 재생 중이 아니다.
    public var isPlaying: Bool { started && graph?.engine.isRunning == true }

    public var elapsed: Double {
        guard isPlaying, let node = graph?.node, let time = node.lastRenderTime, let player = node.playerTime(forNodeTime: time) else { return 0 }
        return max(0, Double(player.sampleTime) / player.sampleRate - latency)
    }

    public func prepare(url: URL, done: @escaping @MainActor (Bool) -> Void) {
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 아주 긴 믹스 파일은 메모리를 너무 많이 써서 덱처럼 풀지 않는다.
            let length = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            let decoded = length <= DecodedAudio.maxDuration ? DecodedAudio.decode(url: url) : nil
            guard !Task.isCancelled else { return }
            await self?.adopt(decoded, done: done)
        }
    }

    private func adopt(_ decoded: DecodedAudio?, done: @MainActor (Bool) -> Void) {
        if let decoded {
            self.decoded = decoded
            connect()
        }
        done(decoded != nil)
    }

    /// 원곡 형식으로 재생 노드를 출력에 잇는다(원곡과 그래프가 모두 있을 때).
    private func connect() {
        guard let graph, let decoded else { return }
        try! graph.engine.connectNode(graph.node, to: graph.engine.mainMixerNode, format: decoded.buffer.format)
        graph.engine.prepare()
    }

    public func play(_ items: [EditPlaybackItem], from frame: Int64, volume: Float) -> Bool {
        guard let decoded, let graph else { return false }
        let engine = graph.engine, node = graph.node
        node.stop()
        if !engine.isRunning {
            do { try engine.start() } catch {
                started = false
                return false
            }
        }
        let rate = decoded.buffer.format.sampleRate
        for item in items.starting(at: frame) {
            let at = item.outputFrame - frame
            if item.fade != nil {
                guard let buffer = EditRenderer.playbackBuffer(item, source: decoded.buffer) else { continue }
                node.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: at, atRate: rate), options: [], completionHandler: nil)
            } else {
                // 원곡 안쪽만 복사 없이 예약한다. 앞뒤 빈자리는 예약하지 않아 무음이다.
                let first = max(item.sourceFrame, 0), last = min(item.sourceFrame + item.frameCount, decoded.frameCount)
                guard first < last, let segment = decoded.segment(from: first, to: last) else { continue }
                node.scheduleBuffer(segment, at: AVAudioTime(sampleTime: at + first - item.sourceFrame, atRate: rate),
                                    options: [], completionHandler: nil)
            }
        }
        node.volume = volume
        latency = engine.outputNode.presentationLatency
        try! node.playAudio()
        started = true
        return true
    }

    public func stop() {
        graph?.node.stop()
        started = false
        if let engine = graph?.engine, engine.isRunning { engine.stop() }
    }

    public func close() {
        stop()
        decodeTask?.cancel()
        decodeTask = nil
        decoded = nil
    }
}
