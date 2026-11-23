@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 자동 저장 사본 자가 테스트 인자(`--auto-reflect-selftest=<경우>`, R18): 값이 무엇이든(빈 값·모르는 값 포함) 두 빌드 모두 진단 실행이다.
/// 진단 실행이면 환경설정을 저장하지 않고 옛 데이터 옮기기·LINK·자동 시점 스냅샷·창 위치 저장·포커스 가져오기를 하지 않는다.
@Suite("자동 저장 자가 테스트 실행")
struct AutoReflectSelfTestRunTests {
    private static let values = ["save", "two-process", "kill-detect", "", "copy"]

    @Test func 인자가_있으면_진단_실행이다() {
        for value in Self.values {
            let arguments = ["djcrate", "--auto-reflect-selftest=\(value)"]
            #expect(DiagnosticRun.isActive(arguments: arguments))
            #expect(DiagnosticRun.isAutoReflectSelfTest(arguments: arguments))
            #expect(LibraryLaunchOptions(arguments: arguments).isDiagnosticRun)
        }
        #expect(DiagnosticRun.isActive(arguments: ["djcrate", "--auto-reflect-selftest"]))
        #expect(!DiagnosticRun.isActive(arguments: ["djcrate"]) && !DiagnosticRun.isAutoReflectSelfTest(arguments: ["djcrate"]))
        #expect(!DiagnosticRun.isAutoReflectSelfTest(arguments: ["djcrate", "--write-selftest"]))
    }

    /// 사용자 환경설정 저장 0: 저장 판정이 거짓이면 설정을 바꿔도 영역에 아무것도 남지 않고 기본값을 읽는다
    @Test func 인자가_있으면_환경설정을_저장하지_않는다() {
        for value in Self.values {
            #expect(!SettingsStore.persists(arguments: ["djcrate", "--auto-reflect-selftest=\(value)"]))
        }
        #expect(SettingsStore.persists(arguments: ["djcrate"]))
        let defaults = TestDefaults.make("auto-reflect-selftest")
        let settings = SettingsStore(defaults: defaults, persist: SettingsStore.persists(arguments: ["djcrate", "--auto-reflect-selftest=save"]))
        let key = SettingKeys.pointSnapshotAutoDays
        settings.set(key, key.defaultValue + 1)
        #expect(settings.value(key) == key.defaultValue)
        #expect(defaults.object(forKey: key.name) == nil)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0 == key.name }.isEmpty)
    }
}
