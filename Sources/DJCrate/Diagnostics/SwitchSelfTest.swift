#if DEBUG
import DJCAdapters
import DJCApplication
import DJCDomain
import Foundation

/// 덱 화면의 재생 상태와 별개로 엔진 정지와 메인 믹서의 실제 렌더를 읽는다.
@MainActor
protocol SwitchAudioObservation: AnyObject {
    var isEngineRunning: Bool { get }
    var debugMixerSignalHostTime: UInt64 { get }
}

extension DeckAudio: SwitchAudioObservation {}

extension DevSelfTests {
    static func switchSelfTestExitCode(store: LibraryStore, deck: DeckModel,
                                       log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) async -> Int32 {
        let ok = await runSwitchSelfTest(store: store, deck: deck, log: log)
        log(ok ? "덱 전환 시험 통과" : "덱 전환 시험 실패")
        return ok ? 0 : 1
    }

    private static func runSwitchSelfTest(store: LibraryStore, deck: DeckModel, log: (String) -> Void) async -> Bool {
        let rows = store.rows.filter { !$0.track.isStreaming }
        let audio = deck.audio
        guard rows.count >= 2, let engine = audio as? any SwitchAudioObservation else { return false }
        let a = rows[0], b = rows[1]
        deck.volume = 0.0003
        defer { if deck.isPlaying { deck.togglePlay() } }

        func until(_ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition() {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return true
        }
        func load(_ row: TrackRow) async -> Bool {
            store.loadToDeck(row)
            return await until { deck.row?.id == row.id && deck.canPlay && !audio.isPreparingOutput }
        }
        func playing(_ stage: String, playerScheduledAfterStop: Bool? = nil, after action: () -> Void) async -> Bool {
            let position = deck.currentTime
            let stamp = ProcessInfo.processInfo.systemUptime
            let original = audio.onRecovered
            var recovered = false
            if playerScheduledAfterStop != nil {
                guard engine.isEngineRunning, audio.isPlaying else { return false }
                audio.onRecovered = {
                    recovered = engine.isEngineRunning && audio.isPlaying
                    original?()
                }
            }
            defer { audio.onRecovered = original }
            action()
            if let playerScheduledAfterStop {
                // 알림 없는 정지는 틱이 발견한다. 구성 변경 알림은 동기로 재생 예약을 풀고 재시작을 예약한다.
                guard !engine.isEngineRunning, audio.isPlaying == playerScheduledAfterStop else {
                    log("[덱 시험] \(stage) · 요청 직후 엔진 정지 또는 재생 예약 상태 불일치")
                    return false
                }
            }
            var rewound = false
            var measureAfter: UInt64?
            let completed = await until {
                if deck.currentTime < position - 0.1 { rewound = true; return true }
                let elapsed = ProcessInfo.processInfo.systemUptime - stamp
                guard playerScheduledAfterStop == nil || recovered,
                      engine.isEngineRunning, deck.isPlaying, audio.isPlaying,
                      deck.currentTime > position + 0.15, deck.currentTime <= position + elapsed * deck.rate + 0.2 else { return false }
                // 위치가 전진한 뒤부터 센다. 늦게 배달된 옛 버퍼는 렌더 시각이 이 경계를 넘지 못한다.
                guard let measureAfter else {
                    measureAfter = max(mach_absolute_time(), engine.debugMixerSignalHostTime)
                    return false
                }
                return engine.debugMixerSignalHostTime > measureAfter
            }
            let ok = completed && !rewound
            let transition = playerScheduledAfterStop == nil ? "" : " · 엔진 정지 확인 · 복구 콜백 \(recovered)"
            let fresh = measureAfter.map { engine.debugMixerSignalHostTime > $0 } ?? false
            log("[덱 시험] \(stage)\(transition) · 위치 \(position) → \(deck.currentTime) · 메인 믹서 새 신호 \(fresh) · \(ok)")
            return ok
        }
        guard await load(a), await playing("첫 곡 재생", after: { deck.togglePlay() }),
              await load(b), !deck.isPlaying,
              await playing("다음 곡 재생", after: { deck.togglePlay() }) else { return false }
        deck.togglePlay()
        let paused = deck.currentTime
        deck.tick()
        guard !deck.isPlaying, !audio.isPlaying, abs(audio.position - paused) < 0.001,
              abs(deck.currentTime - paused) < 0.001 else { return false }
        // 복구가 처음부터 다시 재생해도 통과하지 않게 곡 중간에서 고장을 낸다.
        deck.seek(min(2, deck.duration / 3))
        guard await playing("일시정지 뒤 재생", after: { deck.togglePlay() }),
              await playing("엔진 정지 뒤 복구", playerScheduledAfterStop: true, after: { audio.debugStopEngine() }),
              await playing("출력 구성 변경 알림 뒤 복구", playerScheduledAfterStop: false, after: { audio.debugConfigurationChange() }) else { return false }
        deck.togglePlay()
        guard await load(a), !deck.isPlaying, !audio.isPlaying,
              await playing("멈춘 채 곡 전환 뒤 재생", after: { deck.togglePlay() }) else { return false }
        return true
    }
}
#endif
