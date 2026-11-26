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

    // MARK: - ⌘Q 때 대기 중인 대상 편집(R17)

    /// 자동 저장하는 실행의 ⌘Q는 끝나지 않은 쓰기를 기다린 뒤 엔진의 ⌘Q 저장(`prepareToQuit`)을 기다린다.
    /// 엔진이 최신 초안으로 다시 판정하므로 앱은 칩 상태를 해석하지 않는다(쉬는 단계면 늘 엔진에 묻는다)
    @Test(arguments: [RekordboxWritePhase.idle, .readingBack])
    func 쓰기가_끝난_단계면_엔진의_종료_저장을_기다린다(_ phase: RekordboxWritePhase) {
        #expect(AppQuitPolicy.decision(for: Self.activity(phase), autoSave: .saveFirst) == .waitForAutoSave)
        #expect(AppQuitPolicy.decision(for: Self.activity(phase), autoSave: .autoWriting) == .waitForAutoSave)
        #expect(AppQuitDecision.waitForAutoSave.isWaiting && AppQuitDecision.cancelPreparationThenAutoSave.isWaiting)
        #expect(AppQuitDecision.waitForAutoSave.message == nil)
    }

    /// 자동 저장하지 않는 실행·시스템 종료·이미 저장을 마친 다시 요청은 지금 판정 그대로다
    @Test func 저장을_먼저_하지_않으면_지금처럼_판정한다() {
        for phase in RekordboxWritePhase.allCases {
            #expect(AppQuitPolicy.decision(for: Self.activity(phase), autoSave: .off) == AppQuitPolicy.decision(for: Self.activity(phase)))
        }
    }

    /// 엔진의 자동 저장이 미리 보기 중이면 취소하지 않고 끝까지 기다린다. 수동 저장의 미리 보기는 취소하고 대기 중인 자동 저장을 한다
    @Test func 미리_보기는_누구의_쓰기인지에_따라_기다리거나_취소한다() {
        #expect(AppQuitPolicy.decision(for: Self.activity(.cancellable), autoSave: .autoWriting) == .waitForRekordboxWrite)
        #expect(AppQuitPolicy.decision(for: Self.activity(.cancellable), autoSave: .saveFirst) == .cancelPreparationThenAutoSave)
        #expect(AppQuitPolicy.decision(for: Self.activity(.cancellable), autoSave: .off) == .cancelPreparationThenTerminate)
    }

    /// 저장을 먼저 해도 USB 쓰기·경고창·확인 창·끊으면 안 되는 쓰기는 지금 판정을 따른다
    @Test func 저장을_먼저_해도_USB_경고창_확인_창_쓰기는_지금_판정을_따른다() {
        for autoSave in [QuitAutoSave.saveFirst, .autoWriting] {
            #expect(AppQuitPolicy.decision(for: Self.activity(.idle, usb: true), autoSave: autoSave) == .refuseWhileWritingUsb)
            #expect(AppQuitPolicy.decision(for: Self.activity(.acknowledging), autoSave: autoSave) == .keepOpenForAcknowledgement)
            #expect(AppQuitPolicy.decision(for: Self.activity(.confirming), autoSave: autoSave) == .terminateNow)
            #expect(AppQuitPolicy.decision(for: Self.activity(.writing), autoSave: autoSave) == .waitForRekordboxWrite)
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
        #expect(QuitWait.title == "rekordbox에 저장하는 중… 끝나면 종료합니다")
        #expect(QuitWait.elapsedText(seconds: 12) == "12초 지났습니다")
    }
}
