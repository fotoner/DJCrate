import DJCDomain
import Testing

/// 앱 업데이트(#59): rekordbox·USB에 쓰는 동안에는 설치·다시 켜기를 미룬다.
@Suite("업데이트 설치 판정")
struct UpdateInstallPolicyTests {
    @Test func 아무것도_쓰지_않으면_바로_설치한다() {
        #expect(UpdateInstallPolicy.decision(for: .idle) == .proceed)
        #expect(UpdateInstallPolicy.decision(for: .idle).waitMessage == nil)
    }

    @Test func rekordbox에_쓰는_중이면_미룬다() {
        let decision = UpdateInstallPolicy.decision(for: AppWriteActivity(writingRekordbox: true, writingUsb: false))
        #expect(decision == .waitForRekordbox)
        #expect(decision.waitMessage != nil)
    }

    @Test func USB에_쓰는_중이면_미룬다() {
        let decision = UpdateInstallPolicy.decision(for: AppWriteActivity(writingRekordbox: false, writingUsb: true))
        #expect(decision == .waitForUsb)
        #expect(decision.waitMessage != nil)
    }

    @Test func 둘_다_쓰는_중이면_rekordbox_쓰기를_먼저_알린다() {
        #expect(UpdateInstallPolicy.decision(for: AppWriteActivity(writingRekordbox: true, writingUsb: true)) == .waitForRekordbox)
    }

    /// 종료 대기(#300)와 같은 판단 하나를 쓴다: 끊으면 안 되는 쓰기가 끝났는가. 다시 읽기만 남았으면 끝난 것이다.
    @Test(arguments: [
        (RekordboxWritePhase.idle, UpdateInstallDecision.proceed),
        (.cancellable, .waitForRekordbox),
        (.confirming, .waitForRekordbox),
        (.writing, .waitForRekordbox),
        (.readingBack, .proceed),
        (.acknowledging, .waitForRekordbox),
    ])
    func 단계마다_설치를_미룰지_정한다(_ phase: RekordboxWritePhase, _ expected: UpdateInstallDecision) {
        #expect(UpdateInstallPolicy.decision(for: AppWriteActivity(rekordbox: phase, writingUsb: false)) == expected)
    }

    /// 끊으면 안 되는 쓰기가 끝났는가는 `isFinished` 하나다. 종료 대기와 업데이트 설치 미루기가 이 판단을 같이 쓴다.
    @Test func 쓰기가_끝났는지는_종료_대기와_같은_판단을_쓴다() {
        for phase in [RekordboxWritePhase.idle, .writing, .readingBack] {
            let activity = AppWriteActivity(rekordbox: phase, writingUsb: false)
            #expect((AppQuitPolicy.decision(for: activity) == .terminateNow) == phase.isFinished, "\(phase)")
            #expect((UpdateInstallPolicy.decision(for: activity) == .proceed) == phase.isFinished, "\(phase)")
        }
        // 미리 보기·확인 창·경고창은 아직 쓰지 않았거나 확인이 남은 단계라 끝난 것이 아니다(업데이트는 사용자의 작업을 취소하지 않고 기다린다)
        for phase in [RekordboxWritePhase.cancellable, .confirming, .acknowledging] {
            #expect(!phase.isFinished && UpdateInstallPolicy.decision(for: AppWriteActivity(rekordbox: phase, writingUsb: false)) == .waitForRekordbox)
        }
    }

    @Test func 시스템_보호는_끊으면_안_되는_쓰기와_USB_쓰기에만_건다() {
        for phase in RekordboxWritePhase.allCases {
            #expect(AppWriteActivity(rekordbox: phase, writingUsb: false).isWritingNow == (phase == .writing), "\(phase)")
        }
        #expect(AppWriteActivity(rekordbox: .idle, writingUsb: true).isWritingNow)
        #expect(!AppWriteActivity.idle.isWritingNow)
    }

    @Test func 쓰기_잠금_호환_접근자는_쓰는_중_단계로_바꾼다() {
        var activity = AppWriteActivity.idle
        activity.writingRekordbox = true
        #expect(activity.rekordbox == .writing && activity.writingRekordbox)
        activity.writingRekordbox = false
        #expect(activity == .idle)
        #expect(AppWriteActivity(rekordbox: .readingBack, writingUsb: false).writingRekordbox, "다시 읽는 중에도 잠금은 걸려 있다")
    }
}
