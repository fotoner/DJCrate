import DJCAdapters
import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// coreaudiod가 응답하지 않아 출력 장치를 여는 호출이 끝나지 않아도 덱·편집 창이 메인 스레드를 막지 않는다(#142).
/// 엔진 만들기를 주입해 끝나지 않는 준비를 흉내 낸다(실제 오디오 장치는 열지 않는다).
@MainActor
@Suite(.serialized)
struct AudioStartupTests {
    /// 엔진 만들기가 `release()`(또는 `valve`초)까지 끝나지 않는다. 만들지 못한 것(nil)으로 끝난다.
    /// 시험은 걸린 시간이 아니라 이 상태(어느 스레드에서 불렸나·한 번이라도 끝났나)로 판정한다. `valve`는 메인 스레드가 이 호출을
    /// 동기로 기다리는 잘못된 구현일 때 시험이 영영 멈춰 있지 않게 하는 안전망이다. 부하로 메인 액터가 수십 초 밀려도 통과하는 경로에서
    /// 만료되지 않게(전체 실행이 최대 190초 걸린 부하 실험보다 길게) 넉넉히 잡는다.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let valve: Double
        private var count = 0
        private var finished = false
        private var onMain = false
        init(valve: Double = 3) { self.valve = valve }
        var calls: Int { lock.withLock { count } }
        /// 한 번이라도 끝났다(시험이 풀어 주기 전에 끝났다면 그 끝나기를 기다린 것이다)
        var hasFinished: Bool { lock.withLock { finished } }
        /// 메인 스레드에서 불렸다(막지 않고 바로 돌아가, 잘못된 구현이어도 시험이 멈추지 않는다)
        var calledOnMain: Bool { lock.withLock { onMain } }
        func wait() {
            let main = Thread.isMainThread
            lock.withLock {
                count += 1
                if main { onMain = true }
            }
            guard !main else { return }
            _ = semaphore.wait(timeout: .now() + valve)
            lock.withLock { finished = true }
        }
        func release() { semaphore.signal() }
        /// 엔진 만들기가 불려 막힌 상태가 될 때까지 기다린다(불리는 시각은 부하에 따라 다르다)
        func entered() async {
            while calls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    /// 만들기를 부른 횟수만 센다(바로 nil).
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func hit() { lock.withLock { count += 1 } }
    }

    /// 합성 WAV 곡 한 줄(파일은 시험이 끝나면 지운다)
    static func row(in root: URL) throws -> TrackRow {
        let url = try AudioFixture.wav(seconds: 1, in: root)
        let track = Track(id: "1", uuid: "audio-startup", title: "오디오 준비 시험", artist: nil, album: nil, albumArtist: nil,
                          genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 1,
                          folderPath: url.path, comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        return TrackRow(track: track, cues: [], playCount: 0, autoGain: nil)
    }

    static func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-audio-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func deckIsReadyWithoutWaitingForOutputDevice() async {
        // 엔진 만들기는 시험이 풀어 줄 때까지 나오지 않는다. 덱이 그것을 기다렸다면 초기화가 멈췄다 안전망(valve)이 지나서야 돌아온다.
        let gate = Gate(valve: 300)
        defer { gate.release() }
        let deck = DeckModel.test(audio: DeckAudio(makeGraph: { gate.wait(); return nil }), storage: .memory(MemoryDrafts()),
                             runsAnalysis: false)
        await gate.entered()
        #expect(!gate.hasFinished, "덱 준비가 출력 장치를 기다렸다(엔진 만들기가 끝난 뒤에야 초기화가 돌아옴)")
        #expect(!gate.calledOnMain, "덱이 출력 장치를 메인 스레드에서 열었다")
        #expect(deck.audio.isOutputUnavailable)
    }

    @Test func playIsBlockedWithGuidanceUntilOutputIsReady() async throws {
        let gate = Gate()
        defer { gate.release() }
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = DeckAudio(makeGraph: { gate.wait(); return nil })
        let deck = DeckModel.test(audio: audio, storage: .memory(MemoryDrafts()), runsAnalysis: false)
        // 출력이 준비되기 전에도 곡은 불러 둔다(파형·큐 편집은 그대로 쓴다).
        deck.load(try Self.row(in: root))
        await deck.loadTask?.value
        #expect(deck.canPlay)
        #expect(abs(deck.duration - 1) < 0.01)

        deck.togglePlay()
        #expect(!deck.isPlaying)
        #expect(!audio.isPlaying)
        #expect(audio.isPreparingOutput)
        #expect(deck.toast?.text == AudioSourceState.preparing.unavailableReason)
        #expect(deck.toast?.kind == .warning)
    }

    @Test func failedPreparationRetriesOnNextPlay() async throws {
        let counter = Counter()
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = DeckAudio(makeGraph: { counter.hit(); return nil })
        // 첫 준비가 끝나(실패) 메인 액터로 결과가 돌아올 때까지
        for _ in 0..<400 where audio.isPreparingOutput { try await Task.sleep(for: .milliseconds(5)) }
        #expect(counter.calls == 1)
        #expect(!audio.isPreparingOutput && audio.isOutputUnavailable)
        let deck = DeckModel.test(audio: audio, storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.load(try Self.row(in: root))
        await deck.loadTask?.value
        deck.togglePlay()
        #expect(!deck.isPlaying)
        #expect(audio.isPreparingOutput)
        #expect(deck.toast?.text == AudioSourceState.preparing.unavailableReason)
        // 막힌 재생은 출력 준비를 다시 시도한다(장치가 돌아왔으면 다음 재생에 쓴다).
        for _ in 0..<200 where counter.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(counter.calls == 2)
    }

    @Test func editPlayerPreparesWithoutBlockingMainActor() async throws {
        // 엔진 만들기가 막힌 채로 두고, 그동안 메인 액터가 원곡 준비를 끝내는지 본다. 걸린 시간이 아니라
        // "준비가 끝난 순간까지 엔진 만들기가 한 번도 끝나지 않았다"로 판정하므로 부하가 걸려 느려져도 결과가 같다.
        let gate = Gate(valve: 300)
        defer { gate.release() }
        let root = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try AudioFixture.wav(seconds: 1, in: root)

        let player = EditAudioPlayer(makeGraph: { gate.wait(); return nil })
        await gate.entered()
        let ready = await withCheckedContinuation { continuation in
            player.prepare(url: url) { continuation.resume(returning: $0) }
        }
        #expect(ready, "원곡을 메모리에 풀지 못함")
        #expect(!gate.hasFinished, "편집 창 재생기 준비가 엔진 만들기가 끝나기를 기다렸다(메인 액터가 막힘)")
        #expect(!gate.calledOnMain, "편집 창 재생기가 출력 장치를 메인 스레드에서 열었다")
        // 출력 장치가 준비되지 않았으면 재생만 막힌다(부른 쪽이 안내를 띄운다).
        #expect(!player.play([EditPlaybackItem(outputFrame: 0, frameCount: 44_100, sourceFrame: 0)], from: 0, volume: 0.5))
        #expect(!player.isPlaying)
    }
}
