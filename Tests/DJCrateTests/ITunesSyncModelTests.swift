@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// iTunes 동기화 창 화면 모델은 라이브러리 저장소 대신 좁은 포트(`ITunesSyncModel.Ports`)만 본다(#253, MVVM-5).
/// 어떤 목록·선택을 보일지는 유스케이스(`LibraryReadFlow.openSyncWindow`)가 정하므로, 여기서는 그 결과를 어떻게 표시하는지만 본다.
@MainActor
@Suite("iTunes 동기화 창 — 좁은 포트")
struct ITunesSyncModelTests {
    /// 포트가 받은 것과 포트가 돌려줄 것
    @MainActor private final class Calls {
        var opened: [(shown: ITunesSyncShown, forceRefresh: Bool)] = []
        var synced: [(selection: ITunesSyncSelection, source: ITunesLibrarySnapshot, database: URL)] = []
        var showing = true
        var busy = false
        var opening: ITunesSyncOpening = .superseded
        var syncError: (any Error)?
    }

    private let database = URL(filePath: "/synthetic/itunes-sync/master.db")

    private func model(_ calls: Calls) -> ITunesSyncModel {
        let database = database
        return ITunesSyncModel(ports: .init(database: { database },
                                            open: { shown, forceRefresh, _ in
                                                calls.opened.append((shown, forceRefresh))
                                                return calls.opening
                                            },
                                            isShowing: { _ in calls.showing },
                                            isLibraryBusy: { calls.busy },
                                            sync: { selection, source, database in
                                                calls.synced.append((selection, source, database))
                                                if let error = calls.syncError { throw error }
                                            }))
    }

    /// 동기화 원문이 있는 준비된 목록(쓸 수 있는 목록)
    private var ready: ITunesLibrarySnapshot {
        var source = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "합성 목록")],
                                           sourcePlaylists: [.init(id: "A", name: "합성 목록"), .init(id: "B", name: "둘째 목록")])
        source.syncData = Data("synthetic-sync".utf8)
        return source
    }

    @Test func 연_목록과_선택을_표시하고_지금_사본을_동기화_대상으로_든다() async {
        let calls = Calls()
        calls.opening = .opened(ITunesSyncOpened(source: ready, selection: ITunesSyncSelection(selectedIDs: ["A"])))
        let model = model(calls)
        await model.load(forceRefresh: true)
        #expect(calls.opened.count == 1 && calls.opened.first?.forceRefresh == true)
        #expect(calls.opened.first?.shown.source.status == .loading, "처음 연 창은 읽는 중인 빈 목록을 넘긴다")
        #expect(model.source == ready && model.selection.selectedIDs == ["A"])
        #expect(model.database == database && !model.isLoading && model.error == nil && model.canSync)
    }

    @Test func 막힘_이유가_있는_목록은_이유를_보인다() async {
        let calls = Calls()
        calls.opening = .opened(ITunesSyncOpened(source: ready, selection: ITunesSyncSelection(), error: "합성 막힘 이유"))
        let model = model(calls)
        await model.load()
        #expect(model.error == "합성 막힘 이유" && !model.isLoading)
    }

    @Test func 여는_사이_라이브러리가_바뀌면_대상을_비우고_다시_열라고_알린다() async {
        let calls = Calls()
        let model = model(calls)
        await model.load()
        #expect(model.database == nil && !model.isLoading && !model.canSync)
        #expect(model.error == LibraryReadFlow.libraryChangedMessage)
    }

    @Test func 닫았거나_새_창을_띄운_뒤_끝난_열기는_결과를_넣지_않는다() async {
        let calls = Calls()
        calls.opening = .opened(ITunesSyncOpened(source: ready, selection: ITunesSyncSelection(selectedIDs: ["A"])))
        calls.showing = false
        let model = model(calls)
        await model.load()
        #expect(model.source.status == .loading && model.selection.selectedIDs.isEmpty && !model.isLoading)
    }

    @Test func Music_최신화가_돌면_기다렸다가_끝나면_다시_연다() async {
        let calls = Calls()
        let (finished, finish) = AsyncStream<Void>.makeStream()
        let refresh = Task { for await _ in finished { break } }
        calls.opening = .opened(ITunesSyncOpened(source: ready, selection: ITunesSyncSelection(selectedIDs: ["A"]), refresh: refresh))
        let model = model(calls)
        model.startLoad()
        #expect(await waitForState { model.isWaitingForMusic })
        #expect(!model.canSync, "최신화가 끝나기 전의 목록으로 쓰지 않는다")
        calls.opening = .opened(ITunesSyncOpened(source: ready, selection: ITunesSyncSelection(selectedIDs: ["B"])))
        finish.yield()
        await model.task?.value
        #expect(calls.opened.count == 2 && !model.isWaitingForMusic && model.canSync)
        #expect(model.selection.selectedIDs == ["B"])
    }

    @Test func 동기화는_고른_선택과_목록과_연_사본을_포트로_넘긴다() async {
        let calls = Calls()
        calls.opening = .opened(ITunesSyncOpened(source: ready, selection: ITunesSyncSelection(selectedIDs: ["A"])))
        let model = model(calls)
        await model.load()
        model.selection = ITunesSyncSelection(selectedIDs: ["B"])
        var dismissed = false
        model.startSync { dismissed = true }
        await model.task?.value
        #expect(dismissed && !model.isSyncing && model.error == nil)
        #expect(calls.synced.count == 1)
        #expect(calls.synced.first?.selection.selectedIDs == ["B"] && calls.synced.first?.source == ready)
        #expect(calls.synced.first?.database == database)
    }

    @Test func 쓰지_못하면_이유를_보이고_창을_닫지_않는다() async {
        let calls = Calls()
        calls.opening = .opened(ITunesSyncOpened(source: ready, selection: ITunesSyncSelection(selectedIDs: ["A"])))
        let refusal = DJCError.writeRefused("합성 거부 이유")
        calls.syncError = refusal
        let model = model(calls)
        await model.load()
        var dismissed = false
        model.startSync { dismissed = true }
        await model.task?.value
        #expect(!dismissed && !model.isSyncing && model.error == DJCError.reason(of: refusal))
    }

    @Test func 쓸_수_없는_목록이면_포트를_부르지_않는다() async {
        let calls = Calls()
        let model = model(calls)
        #expect(await model.sync() == false)
        #expect(calls.synced.isEmpty)
    }

    @Test func 라이브러리를_읽거나_쓰는_중인지는_포트에서_읽는다() {
        let calls = Calls()
        let model = model(calls)
        #expect(!model.isLibraryBusy)
        calls.busy = true
        #expect(model.isLibraryBusy)
    }

    @Test func 띄우지_않은_창은_열거나_쓰지_않는다() async {
        let model = ITunesSyncModel(ports: .closed)
        await model.load()
        #expect(model.source.status == .loading && !model.isLoading && model.database == nil)
        #expect(await model.sync() == false)
    }
}
