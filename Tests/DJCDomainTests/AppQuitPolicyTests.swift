import DJCDomain
import Foundation
import Testing

/// 쓰는 중 앱 종료(#300): rekordbox 쓰기는 끝날 때까지 기다렸다 끄고, 취소할 수 있는 단계면 취소하고 바로 끈다. USB는 끄지 않는다.
@Suite("앱 종료 판정")
struct AppQuitPolicyTests {
    static func activity(_ phase: RekordboxWritePhase, usb: Bool = false) -> AppWriteActivity {
        AppWriteActivity(rekordbox: phase, writingUsb: usb)
    }

    @Test func 아무것도_쓰지_않으면_바로_끈다() {
        #expect(AppQuitPolicy.decision(for: .idle) == .terminateNow)
    }

    // MARK: - 단계별

    /// 단계 → 종료 판정. 단계는 반영 세션이 알리는 순서(확인 → 미리 보기 → 확인 창 → 백업·DB·파일·초안 정리 → 다시 읽기)와 복원·실패다.
    @Test(arguments: [
        (RekordboxWritePhase.idle, AppQuitDecision.terminateNow),
        (.cancellable, .cancelPreparationThenTerminate),
        (.confirming, .terminateNow),
        (.writing, .waitForRekordboxWrite),
        (.readingBack, .terminateNow),
        (.acknowledging, .keepOpenForAcknowledgement),
    ])
    func 단계마다_종료_판정이_정해져_있다(_ phase: RekordboxWritePhase, _ expected: AppQuitDecision) {
        #expect(AppQuitPolicy.decision(for: Self.activity(phase)) == expected)
    }

    @Test func 모든_단계가_판정을_가진다() {
        // 단계를 더하면 이 시험이 빨개져 판정을 정하게 한다
        #expect(RekordboxWritePhase.allCases.count == 6)
    }

    // MARK: - USB

    @Test func USB에_쓰는_중이면_어느_단계든_끄지_않는다() {
        for phase in RekordboxWritePhase.allCases {
            #expect(AppQuitPolicy.decision(for: Self.activity(phase, usb: true)) == .refuseWhileWritingUsb)
        }
    }

    @Test func USB_거절_문구는_이유와_할_일을_쓴다() {
        let message = AppQuitDecision.refuseWhileWritingUsb.message
        #expect(message == "USB에 쓰는 중이라 지금은 종료하지 않았습니다. 쓰기가 끝나면 다시 종료하세요")
        #expect(message?.contains("끝난 뒤 종료하세요") == false)
        #expect(AppQuitDecision.terminateNow.message == nil)
        #expect(AppQuitDecision.waitForRekordboxWrite.message == nil)
    }

    // MARK: - 기다리는 동안

    /// 기다리는 중 다시 판정한다: 쓰기가 끝나는 단계(다시 읽기·쉼)가 오면 끄고, 복원까지 실패해 확인이 필요해지면 끄기를 취소한다.
    @Test func 기다리다가_단계가_바뀌면_다시_판정한다() {
        let waiting = AppQuitDecision.waitForRekordboxWrite
        #expect(waiting.isWaiting)
        #expect(!AppQuitDecision.terminateNow.isWaiting)
        let after: [(RekordboxWritePhase, AppQuitDecision)] = [(.readingBack, .terminateNow), (.idle, .terminateNow),
                                                               (.writing, .waitForRekordboxWrite), (.acknowledging, .keepOpenForAcknowledgement)]
        for (phase, expected) in after {
            #expect(AppQuitPolicy.decision(for: Self.activity(phase)) == expected)
        }
    }

    // MARK: - 지난 시간

    @Test func 지난_시간은_초_단위로_내림하고_음수가_되지_않는다() {
        let start = Date(timeIntervalSince1970: 1_000)
        let wait = QuitWait(startedAt: start)
        #expect(wait.elapsedSeconds(at: start) == 0)
        #expect(wait.elapsedSeconds(at: start.addingTimeInterval(0.99)) == 0)
        #expect(wait.elapsedSeconds(at: start.addingTimeInterval(1)) == 1)
        #expect(wait.elapsedSeconds(at: start.addingTimeInterval(125.4)) == 125)
        // 시계가 거꾸로 가도 0
        #expect(wait.elapsedSeconds(at: start.addingTimeInterval(-5)) == 0)
    }

    @Test func 기다림_문구는_쓰는_대상과_지난_시간을_담는다() {
        #expect(QuitWait.title == "rekordbox에 쓰는 중… 끝나면 종료합니다")
        #expect(QuitWait.elapsedText(seconds: 12) == "12초 지났습니다")
    }
}
