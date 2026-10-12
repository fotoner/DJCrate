import DJCApplication
import DJCDomain
import Testing

/// 앱 업데이트(#59): 쓰는 동안 미룬 설치·다시 켜기는 쓰기가 모두 끝난 뒤 한 번만 이어 간다.
@MainActor
@Suite("업데이트 미루기")
struct UpdateDeferralTests {
    final class Activity {
        var value = AppWriteActivity.idle
    }

    @Test func 쓰지_않으면_미루지_않고_맡지도_않는다() {
        let activity = Activity()
        let deferral = UpdateDeferral(activity: { activity.value })
        var resumed = 0
        #expect(deferral.postpone { resumed += 1 } == .proceed)
        #expect(!deferral.isHolding)
        deferral.activityChanged()
        #expect(resumed == 0)
    }

    @Test func 쓰는_중에_미룬_것은_쓰기가_끝나면_한_번만_이어_간다() {
        let activity = Activity()
        activity.value.writingRekordbox = true
        let deferral = UpdateDeferral(activity: { activity.value })
        var resumed = 0
        #expect(deferral.postpone { resumed += 1 } == .waitForRekordbox)
        #expect(deferral.isHolding)
        deferral.activityChanged()
        #expect(resumed == 0)
        activity.value.writingRekordbox = false
        deferral.activityChanged()
        #expect(resumed == 1)
        #expect(!deferral.isHolding)
        deferral.activityChanged()
        #expect(resumed == 1)
    }

    @Test func rekordbox_쓰기가_끝나도_USB에_쓰는_중이면_계속_미룬다() {
        let activity = Activity()
        activity.value = AppWriteActivity(writingRekordbox: true, writingUsb: true)
        let deferral = UpdateDeferral(activity: { activity.value })
        var resumed = 0
        _ = deferral.postpone { resumed += 1 }
        activity.value.writingRekordbox = false
        deferral.activityChanged()
        #expect(resumed == 0)
        #expect(deferral.isHolding)
        activity.value.writingUsb = false
        deferral.activityChanged()
        #expect(resumed == 1)
    }

    @Test func 이어_가는_중에_다시_쓰기가_시작돼도_맡은_것은_한_번만_부른다() {
        let activity = Activity()
        activity.value.writingUsb = true
        let deferral = UpdateDeferral(activity: { activity.value })
        var resumed = 0
        _ = deferral.postpone {
            resumed += 1
            // 이어 가는 블록 안에서 상태가 다시 바뀌어 알림이 겹쳐도 두 번 부르지 않는다
            deferral.activityChanged()
        }
        activity.value.writingUsb = false
        deferral.activityChanged()
        #expect(resumed == 1)
    }
}
