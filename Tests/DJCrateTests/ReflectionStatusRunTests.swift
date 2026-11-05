@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 상태 줄 쓰기 상태 칩에 rekordbox 켜짐·꺼짐 이유를 붙인다(#326): 켜짐·Agent만·끝나는 중·꺼짐 강조.
/// 이유는 쓰기 대기가 있을 때만 붙는다. 모름(읽기 전 포함)은 이유도 강조도 없다. 쓰는 중이 모든 것보다 앞선다.
/// 감지 값은 가짜(`FakeRun`)와 가짜 시계(`settle`)로 정한다. 이 값은 표시만 바꾼다: 쓸지 말지는 늘 기존 판단과 쓰기 관문이 정한다.
@MainActor
@Suite("상태 줄 rekordbox 켜짐·꺼짐")
struct ReflectionStatusRunTests {
    typealias Harness = ReflectionStatusModelTests.Harness

    /// 곡 초안 하나(쓰기 대기 1건)가 있는 하네스
    static func pendingHarness(_ run: RekordboxRunState?) -> Harness {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.run.state = run
        h.model.refresh()
        return h
    }

    // MARK: - 켜짐

    @Test func rekordbox가_켜져_있으면_쓰기_대기에_이유를_붙인다() {
        let h = Self.pendingHarness(.running)
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0, reason: .rekordboxRunning))
        #expect(h.model.chip.title == "rekordbox가 켜져 있습니다 · 쓰기 대기 1건")
        // [쓰기] 단추는 지금처럼 두되 강조하지 않는다. 막힘은 기존 판단·관문이 한다
        #expect(h.model.showsWriteButton && !h.model.emphasizesWrite && h.model.writeButtonTitle == "쓰기")
    }

    @Test func rekordboxAgent만_켜져_있으면_Agent로_말한다() {
        let h = Self.pendingHarness(.agentOnly)
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0, reason: .agentRunning))
        #expect(h.model.chip.title == "rekordboxAgent가 켜져 있습니다 · 쓰기 대기 1건")
        #expect(!h.model.emphasizesWrite)
    }

    @Test func 재생_목록_편집만_있어도_이유를_붙이고_단위는_칩과_같다() throws {
        let h = Harness()
        try h.addPlaylistEdit("가")
        h.run.state = .running
        h.model.refresh()
        #expect(h.model.chip.title == "rekordbox가 켜져 있습니다 · 재생 목록 편집 1건")
    }

    @Test func 쓰기_대기가_없으면_이유를_붙이지_않고_쓰기_대기_없음을_보인다() {
        for run in [RekordboxRunState.running, .agentOnly, .stopped, .unknown] {
            let h = Harness()
            h.run.state = run
            h.model.refresh()
            #expect(h.model.chip == .clean && h.model.chip.title == "쓰기 대기 없음", "감지 \(run)")
            #expect(!h.model.showsWriteButton)
        }
    }

    @Test func 팝오버는_켜진_것마다_할_일을_한_줄로_알린다() {
        #expect(Self.pendingHarness(.running).model.todoLine == "rekordbox를 끈 뒤 쓰세요")
        #expect(Self.pendingHarness(.agentOnly).model.todoLine == "rekordboxAgent를 종료한 뒤 쓰세요")
        #expect(Self.pendingHarness(.stopped).model.todoLine == nil)
        #expect(Self.pendingHarness(nil).model.todoLine == nil)
    }

    // MARK: - 모름·처음부터 꺼짐

    @Test func 모르면_이유도_강조도_없다() {
        for run in [RekordboxRunState?.none, .some(.unknown)] {
            let h = Self.pendingHarness(run)
            #expect(h.model.chip == .pending(items: 1, playlistEdits: 0), "감지 \(String(describing: run))")
            #expect(h.model.chip.title == "쓰기 대기 1건" && !h.model.emphasizesWrite)
            #expect(h.model.todoLine == nil)
        }
    }

    @Test func 앱을_켤_때_이미_꺼져_있으면_강조하지_않고_지금_칩_그대로다() async {
        let h = Self.pendingHarness(.stopped)
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0) && !h.model.emphasizesWrite)
        await drainMainActor()
        #expect(h.settle.requested.isEmpty, "전이가 아니니 확인 시간을 걸지 않는다")
        // 모름에서 꺼짐으로 바뀐 것도 켜짐→꺼짐 전이가 아니다
        let unknown = Self.pendingHarness(.unknown)
        unknown.run.state = .stopped
        unknown.model.refresh()
        await drainMainActor()
        #expect(unknown.model.chip == .pending(items: 1, playlistEdits: 0) && unknown.settle.requested.isEmpty)
    }

    // MARK: - 끝나는 중 → 꺼짐 강조

    @Test(arguments: [RekordboxRunState.running, .agentOnly])
    func 켜짐에서_꺼짐으로_바뀐_직후에는_끝나는_중이고_강조를_미룬다(_ before: RekordboxRunState) async {
        let h = Self.pendingHarness(before)
        h.run.state = .stopped
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0, reason: .rekordboxStopping))
        #expect(h.model.chip.title == "rekordbox가 끝나는 중… · 쓰기 대기 1건")
        #expect(!h.model.emphasizesWrite && h.model.writeButtonTitle == "쓰기", "[지금 쓰기] 강조를 미룬다")
        #expect(ReflectionStatusModel.settleDelay == .seconds(3))
        h.model.refresh()
        h.model.refresh()
        #expect(await waitForState { h.settle.requested == [.seconds(3)] }, "확인 시간은 한 번만 건다")
    }

    @Test func 확인_시간_뒤에도_꺼져_있으면_꺼짐_강조로_바뀐다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        h.settle.release()
        #expect(await waitForState { h.model.chip == .pending(items: 1, playlistEdits: 0, reason: .rekordboxStopped) })
        #expect(h.model.chip.title == "rekordbox가 꺼졌습니다 · 쓰기 대기 1건")
        #expect(h.model.emphasizesWrite && h.model.writeButtonTitle == "지금 쓰기" && h.model.showsWriteButton)
        #expect(h.model.todoLine == nil)
    }

    @Test func 확인_시간_안에_다시_켜지면_켜짐으로_돌아가고_강조하지_않는다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        h.run.state = .running
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0, reason: .rekordboxRunning))
        #expect(await waitForState { h.settle.cancelled == 1 }, "기다리던 확인을 거둔다")
        h.settle.release()
        await drainMainActor()
        #expect(h.model.chip.title == "rekordbox가 켜져 있습니다 · 쓰기 대기 1건" && !h.model.emphasizesWrite)
    }

    @Test func 확인_시간이_끝나는_때_다시_켜져_있으면_켜짐이다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        // 값만 바뀌고 모델이 아직 못 알아챈 사이 확인 시간이 끝나도 그때 다시 읽는다
        h.run.state = .agentOnly
        h.settle.release()
        #expect(await waitForState { h.model.chip == .pending(items: 1, playlistEdits: 0, reason: .agentRunning) })
        #expect(!h.model.emphasizesWrite)
    }

    @Test func 확인_시간_뒤_모름이면_강조하지_않는다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        h.run.state = .unknown
        h.settle.release()
        await drainMainActor()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0) && !h.model.emphasizesWrite)
    }

    @Test func 모름이_끼어도_마지막으로_안_상태가_켜짐이면_꺼짐은_전이다() {
        let h = Self.pendingHarness(.running)
        h.run.state = .unknown
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0), "모르는 동안은 이유가 없다")
        h.run.state = .stopped
        h.model.refresh()
        #expect(h.model.chip.title == "rekordbox가 끝나는 중… · 쓰기 대기 1건")
    }

    @Test func Agent만_남으면_끝나는_중이_아니라_Agent가_켜져_있다고_말한다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .agentOnly
        h.model.refresh()
        #expect(h.model.chip.title == "rekordboxAgent가 켜져 있습니다 · 쓰기 대기 1건")
        await drainMainActor()
        #expect(h.settle.requested.isEmpty)
    }

    @Test func 다시_켜졌다_꺼지면_새_전이로_다시_강조한다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        h.settle.release()
        #expect(await waitForState { h.model.emphasizesWrite })
        h.run.state = .running
        h.model.refresh()
        #expect(!h.model.emphasizesWrite && h.model.chip.title == "rekordbox가 켜져 있습니다 · 쓰기 대기 1건")
        h.run.state = .stopped
        h.model.refresh()
        #expect(h.model.chip.title == "rekordbox가 끝나는 중… · 쓰기 대기 1건")
        #expect(await waitForState { h.settle.requested == [.seconds(3), .seconds(3)] })
    }

    // MARK: - 강조를 끝내는 때

    @Test func 쓰기를_시작하면_강조를_끝내고_쓰기가_끝나도_다시_강조하지_않는다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        h.settle.release()
        #expect(await waitForState { h.model.emphasizesWrite })
        // 미리 보기 단계(아직 쓰지 않았다)부터 강조를 끝낸다
        h.store.writeStage = WriteStage("바꿀 내용을 확인하는 중…", cancellable: true)
        h.store.isWritingRekordbox = true
        h.model.refresh()
        #expect(!h.model.emphasizesWrite && h.model.chip == .pending(items: 1, playlistEdits: 0))
        // 쓰기가 실패해 대기가 남아도 새 전이가 없으면 강조하지 않는다
        h.store.writeStage = nil
        h.store.isWritingRekordbox = false
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0) && !h.model.emphasizesWrite)
    }

    @Test func 대기가_0이_되면_강조를_끝내고_다시_쌓여도_강조하지_않는다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        h.settle.release()
        #expect(await waitForState { h.model.emphasizesWrite })
        h.store.setDraftMarks(cue: [], grid: [], gain: [])
        h.model.refresh()
        #expect(h.model.chip == .clean && !h.model.emphasizesWrite)
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0), "전이에서만 강조를 시작한다")
    }

    @Test func 확인_시간_중_대기가_0이_되면_확인_시간이_끝나도_강조하지_않는다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        h.store.setDraftMarks(cue: [], grid: [], gain: [])
        h.model.refresh()
        #expect(h.model.chip == .clean)
        #expect(await waitForState { h.settle.cancelled == 1 })
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.model.refresh()
        h.settle.release()
        await drainMainActor()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0) && !h.model.emphasizesWrite)
    }

    // MARK: - 쓰는 중이 앞선다

    @Test func 쓰는_중이_켜짐_끝나는_중_꺼짐_강조보다_앞선다() async {
        let h = Self.pendingHarness(.running)
        h.store.isWritingRekordbox = true
        h.store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        h.model.refresh()
        h.gate.release()
        #expect(await waitForState { h.model.chip == .writing })
        #expect(h.model.chip.title == "rekordbox에 쓰는 중…" && !h.model.emphasizesWrite)
    }

    @Test func 꺼짐_전이_중_쓰기가_시작되면_쓰는_중이다() async {
        let h = Self.pendingHarness(.running)
        h.run.state = .stopped
        h.model.refresh()
        h.store.isWritingRekordbox = true
        h.store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        h.model.refresh()
        h.gate.release()
        #expect(await waitForState { h.model.chip == .writing })
        #expect(!h.model.emphasizesWrite)
    }

    // MARK: - [지금 쓰기]는 [쓰기]·메뉴 막대와 같은 명령, 같은 막힘 조건

    @Test func 지금_쓰기는_같은_활성_조건과_이유를_쓰고_감지_값으로_막힘이_풀리지_않는다() async {
        let h = Self.pendingHarness(.running)
        func expectSameAsMenu(_ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(h.model.canWrite == LibraryMenuAction.reflect.isEnabled(in: h.window), Comment(rawValue: "활성 — \(note)"), sourceLocation: sourceLocation)
            #expect(h.model.writeDisabledReason == LibraryMenuAction.reflect.disabledReason(in: h.window), Comment(rawValue: "이유 — \(note)"), sourceLocation: sourceLocation)
        }
        // 켜짐·끝나는 중·꺼짐 강조 어느 때든 활성 조건은 메뉴와 같다. 켜져 있다는 값이 쓰기를 열지도 막지도 않는다(관문이 정한다)
        expectSameAsMenu("켜짐")
        h.run.state = .stopped
        h.model.refresh()
        expectSameAsMenu("끝나는 중")
        h.settle.release()
        #expect(await waitForState { h.model.emphasizesWrite })
        expectSameAsMenu("꺼짐 강조")
        #expect(h.model.canWrite, "초안이 있으면 메뉴처럼 활성이다")

        // 막힌 초안 비교 창이 열려 있는 동안은 메뉴처럼 막는다
        h.store.recoverySheet = RecoverySheetModel(host: h.store, requests: [])
        expectSameAsMenu("막힌 초안 비교 창")
        #expect(!h.model.canWrite && h.model.emphasizesWrite, "강조는 막힘을 풀지 않는다")
        LibraryMenuAction.reflect.perform(in: h.window)
        let menuToast = h.store.toast?.title
        h.store.dismissToast()
        h.model.perform(.reflect)
        #expect(menuToast != nil && h.store.toast?.title == menuToast, "메뉴 막대와 같은 막힘 알림")
        #expect(h.store.isWritingRekordbox == false && h.store.writeTask == nil)
    }

    // MARK: - 관찰

    @Test func 감지_값이_바뀌면_모델이_스스로_알아채고_칩을_고친다() async {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.model.start()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0))
        h.run.state = .running
        #expect(await waitForState { h.model.chip.title == "rekordbox가 켜져 있습니다 · 쓰기 대기 1건" })
        h.run.state = .stopped
        #expect(await waitForState { h.model.chip.title == "rekordbox가 끝나는 중… · 쓰기 대기 1건" })
        h.settle.release()
        #expect(await waitForState { h.model.emphasizesWrite })
    }
}
