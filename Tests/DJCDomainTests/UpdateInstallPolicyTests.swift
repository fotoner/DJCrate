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

    /// 앱 끄기도 같은 쓰기 상태로 막는다. 업데이트 설치·다시 켜기가 미룸 위임을 거치지 않고 앱을 끄는 경로가 있다(받아 둔 업데이트, 끌 때 설치).
    @Test func 쓰는_중에는_앱_끄기를_막고_이유를_알린다() {
        #expect(AppWriteActivity.idle.quitBlockedReason == nil)
        #expect(AppWriteActivity(writingRekordbox: true, writingUsb: false).quitBlockedReason == "rekordbox에 쓰는 중입니다. 끝난 뒤 종료하세요")
        #expect(AppWriteActivity(writingRekordbox: false, writingUsb: true).quitBlockedReason == "USB에 쓰는 중입니다. 끝난 뒤 종료하세요")
        #expect(AppWriteActivity(writingRekordbox: true, writingUsb: true).quitBlockedReason == "rekordbox에 쓰는 중입니다. 끝난 뒤 종료하세요")
    }
}
