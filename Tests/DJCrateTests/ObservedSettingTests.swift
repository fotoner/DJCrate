@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import Observation
import Testing

/// 화면 상태 설정을 뷰가 지켜보는 객체(#138). `@AppStorage`는 이름에 점이 든 설정(`sidebar.visible`)을 KVO로 지켜보지 못해
/// 창 크기를 바꾸는 동안 창 프레임 자동 저장처럼 관계없는 설정이 바뀔 때마다 주 창 본문을 다시 계산했다.
@MainActor
@Suite("설정 — 값이 바뀔 때만 화면에 알림")
struct ObservedSettingTests {
    private let defaults: UserDefaults

    init() {
        let suite = TestDefaults.suiteName("observed-setting")
        defaults = TestDefaults.open(suite)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 지켜보는 동안 알림이 왔는지
    private final class Fired: @unchecked Sendable { var value = false }

    private func track(_ setting: ObservedSetting<Bool>) -> Fired {
        let fired = Fired()
        withObservationTracking { _ = setting.value } onChange: { fired.value = true }
        return fired
    }

    @Test func 저장된_값을_읽고_없으면_기본값이다() {
        #expect(ObservedSetting(SettingKeys.sidebarVisible, defaults: defaults).value == true)
        defaults.set(false, forKey: SettingKeys.sidebarVisible.name)
        #expect(ObservedSetting(SettingKeys.sidebarVisible, defaults: defaults).value == false)
    }

    @Test func 바꾸면_저장하고_알린다() {
        let setting = ObservedSetting(SettingKeys.sidebarVisible, defaults: defaults)
        let fired = track(setting)
        setting.value = false
        #expect(fired.value)
        #expect(defaults.object(forKey: SettingKeys.sidebarVisible.name) as? Bool == false)
    }

    @Test func 같은_값을_다시_써도_알리지_않는다() {
        let setting = ObservedSetting(SettingKeys.sidebarVisible, defaults: defaults)
        let fired = track(setting)
        setting.value = true
        #expect(!fired.value)
    }

    @Test func 다른_설정이_바뀌어도_알리지_않는다() {
        let setting = ObservedSetting(SettingKeys.sidebarVisible, defaults: defaults)
        let fired = track(setting)
        defaults.set("0 0 1440 900 0 0 1728 1083", forKey: "NSWindow Frame djc.mainWindow")
        defaults.set(true, forKey: SettingKeys.sidebarVisible.name)
        #expect(!fired.value)
    }

    @Test func 밖에서_같은_설정을_바꾸면_따라간다() {
        // 자가 측정·설정 창처럼 UserDefaults에 바로 쓰는 곳도 있다.
        let setting = ObservedSetting(SettingKeys.sidebarVisible, defaults: defaults)
        let fired = track(setting)
        defaults.set(false, forKey: SettingKeys.sidebarVisible.name)
        #expect(fired.value)
        #expect(setting.value == false)
    }

    @Test func 저장된_값은_설정_규칙대로_읽는다() {
        defaults.set(Double.infinity, forKey: SettingKeys.textScale.name)
        #expect(ObservedSetting(SettingKeys.textScale, defaults: defaults).value == SettingKeys.textScale.defaultValue)
        defaults.set(1.27, forKey: SettingKeys.textScale.name)
        #expect(ObservedSetting(SettingKeys.textScale, defaults: defaults).value == TextScale.nearest(1.27))
    }
}
