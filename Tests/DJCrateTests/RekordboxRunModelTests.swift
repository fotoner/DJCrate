@testable import DJCrate
import DJCApplication
import DJCDomain
import Synchronization
import Testing

/// rekordbox 실행 감지 서비스(#323)의 연결: 감시 판정을 화면 값으로 옮기고, 조립 지점은 하나만 들되 화면 시험에서는 돌리지 않는다.
/// 판정·신호·시계 규칙은 `RekordboxRunWatchTests`(DJCApplicationTests)가 본다
@MainActor
@Suite("rekordbox 실행 감지 서비스")
struct RekordboxRunModelTests {
    /// 판정을 시험이 정하고 신호를 보내는 감시. 시계는 멈춰 둔다(취소하면 끝난다)
    final class Processes: Sendable {
        let current: Mutex<RekordboxRunState>
        let feeds = Mutex<[AsyncStream<Void>.Continuation]>([])
        init(_ state: RekordboxRunState) { current = Mutex(state) }

        func signal() { feeds.withLock { $0.forEach { $0.yield() } } }
        var subscribers: Int { feeds.withLock { $0.count } }

        var source: RekordboxProcessSource {
            RekordboxProcessSource(read: { [self] in current.withLock { $0 } },
                                   changes: { [self] in
                                       let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
                                       feeds.withLock { $0.append(continuation) }
                                       continuation.onTermination = { [self] _ in feeds.withLock { $0.removeAll() } }
                                       return stream
                                   },
                                   sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        }
    }

    @Test func 감시_판정을_따르고_멈추면_신호를_놓는다() async {
        let processes = Processes(.agentOnly)
        let model = RekordboxRunModel(source: processes.source)
        #expect(model.state == nil, "처음 읽기 전에는 판정이 없다")
        model.start()
        model.start()
        #expect(await waitForState { model.state == .agentOnly && processes.subscribers == 1 })
        processes.current.withLock { $0 = .stopped }
        processes.signal()
        #expect(await waitForState { model.state == .stopped })
        #expect(processes.subscribers == 1, "두 번 시작해도 하나만 돈다")
        model.stop()
        #expect(await waitForState { processes.subscribers == 0 })
        #expect(model.state == .stopped)
    }

    /// 화면 시험의 조립은 이 Mac의 프로세스 목록을 읽지 않는 자리(`.none`)를 둔다. 돌려도 늘 모름이다(실제 목록이면 보통 꺼짐이 나온다)
    @Test func 화면_시험의_조립은_프로세스_목록을_읽지_않는다() async {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in })
        let app = AppComposition(store: store, deck: DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false))
        #expect(app.rekordboxRun.state == nil)
        app.rekordboxRun.start()
        defer { app.rekordboxRun.stop() }
        #expect(await waitForState { app.rekordboxRun.state == .unknown })
    }
}
