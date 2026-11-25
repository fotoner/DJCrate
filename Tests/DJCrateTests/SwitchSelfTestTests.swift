#if DEBUG
@testable import DJCrate
import AVFoundation
@testable import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

extension FakeDeckAudio: SwitchAudioObservation {}

@MainActor
@Suite(.serialized)
struct SwitchSelfTestTests {
    @Test(arguments: [FakeDeckAudio.Fault.engineStop, .configurationChange])
    func 복구를_기다릴_때와_이어_재생할_때_멈춘_위치를_유지한다(_ fault: FakeDeckAudio.Fault) async throws {
        let directory = try TemporaryFolder()
        let url = try AudioFixture.wav(seconds: 8, in: directory.url)
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let graph = DeckAudioGraph(engine: engine)
        let audio = DeckAudio(makeGraph: { graph })
        try #require(await waitForState { audio.isOutputReady })
        try audio.load(url: url)
        audio.seekWhilePaused(2)
        try #require(audio.play(from: 2))
        defer { audio.stop() }
        try #require(await waitForState { audio.position > 2.2 })
        let before = audio.position
        var resumedAt: Double?
        var interrupted = false
        audio.onRecovered = { resumedAt = audio.position }
        audio.onInterrupted = { _ in interrupted = true }
        defer { audio.onRecovered = nil }
        switch fault {
        case .engineStop:
            audio.debugStopEngine()
            #expect(!audio.isEngineRunning && audio.isPlaying)
            audio.recoverIfStalled()
        case .configurationChange:
            audio.debugConfigurationChange()
        }
        #expect(!audio.isPlaying && !audio.isEngineRunning)
        #expect(audio.position >= before)
        let stoppedAt = audio.position
        try #require(await waitForState(giveUp: { interrupted }) { resumedAt != nil })
        #expect(audio.isPlaying && audio.isEngineRunning)
        let resumed = try #require(resumedAt)
        // 파일 예약은 멈춘 시각이 들어 있는 PCM 프레임에서 시작한다.
        let firstFrameTime = floor(stoppedAt * format.sampleRate) / format.sampleRate
        #expect(resumed >= firstFrameTime)
        #expect(audio.position >= resumed)
    }

    enum RecoveryCase: Sendable, Equatable {
        case ignored(FakeDeckAudio.Fault)
        case missingCallback(FakeDeckAudio.Fault)
        case staleSignal(FakeDeckAudio.Fault)
        case recovered
    }

    @Test(arguments: [RecoveryCase.ignored(.engineStop), .ignored(.configurationChange),
                      .missingCallback(.engineStop), .missingCallback(.configurationChange),
                      .staleSignal(.engineStop), .staleSignal(.configurationChange), .recovered])
    func 복구_전이와_새_믹서_신호로_종료_코드를_정한다(_ scenario: RecoveryCase) async throws {
        let rows = ["101", "102"].map { TrackListTagEditTests.row($0) }
        let library = LibraryStore.test()
        let report = LibraryReport(library: RekordboxLibrary(allTracks: rows.map(\.track), cues: [], playCounts: [:]))
        library.applyLoadedRows(from: LoadedLibrary(rows: rows, report: report, filterCounts: [:], tagDrafts: [:],
            cueDraftUUIDs: [], gridDraftUUIDs: [], playlists: .init(), playlistDraft: .init(), histories: []))
        let h = try DeckHarness()
        try await h.loaded()
        h.audio.log.removeAll()
        library.onLoadToDeck = { h.deck.load($0) }
        var staleAfter: FakeDeckAudio.Fault?
        let failsAt: FakeDeckAudio.Fault?
        switch scenario {
        case .ignored(let fault): h.audio.ignoredFault = fault; failsAt = fault
        case .missingCallback(let fault): h.audio.missingRecoveryCallback = fault; failsAt = fault
        case .staleSignal(let fault): staleAfter = fault; failsAt = fault
        case .recovered: failsAt = nil
        }

        var oldBuffer: UInt64?
        var uptime = ProcessInfo.processInfo.systemUptime
        func nextSample() async {
            // 곡 읽기가 끝난 뒤 가상 시계와 렌더를 함께 전진시킨다. CI의 메인 스레드 부하가 재생 속도를 바꾸지 않는다.
            await h.deck.loadTask?.value
            uptime += 0.05
            // 복구 경계의 마지막 버퍼 하나는 도착한다. 그 뒤 위치와 게인 미터만 갱신된다.
            if let fault = h.audio.pendingFault, fault == staleAfter { oldBuffer = mach_absolute_time() }
            h.audio.finishPendingRecovery()
            guard h.audio.isPlaying else { return }
            h.audio.position += 0.05
            h.deck.tick()
            h.audio.meter.update(peak: (0.5, 0.5), rms: (0.3, 0.3), now: ProcessInfo.processInfo.systemUptime)
            h.audio.debugMixerSignalHostTime = oldBuffer ?? mach_absolute_time()
        }
        var lines: [String] = []
        let code = await DevSelfTests.switchSelfTestExitCode(store: library, deck: h.deck, uptime: { uptime }, nextSample: nextSample) {
            lines.append($0)
            print($0)
        }
        print("덱 전환 진단 · \(scenario) · 종료 \(code)")
        #expect(code == (failsAt == nil ? 0 : 1))
        #expect(lines.last == (failsAt == nil ? "덱 전환 시험 통과" : "덱 전환 시험 실패"))
        let lastStage = try #require(lines.dropLast().last)
        switch scenario {
        case .ignored: #expect(lastStage.contains("요청 직후 엔진 정지 또는 재생 예약 상태 불일치"))
        case .missingCallback: #expect(lastStage.contains("복구 콜백 false"))
        case .staleSignal: #expect(lastStage.contains("복구 콜백 true") && lastStage.contains("메인 믹서 새 신호 false"))
        case .recovered: #expect(lastStage.contains("메인 믹서 새 신호 true"))
        }
        let requests = h.audio.log.compactMap(FakeDeckAudio.Fault.init(rawValue:))
        #expect(requests == (failsAt == .engineStop ? [.engineStop] : [.engineStop, .configurationChange]))
        #expect(h.audio.log.filter { $0 == "load" }.count == (failsAt == nil ? 3 : 2))
    }
}
#endif
