#if DEBUG
@testable import DJCrate
import Testing

@Suite("키 전달 자가 테스트 실행 조건")
struct KeyRoutingSelfTestModeTests {
    private let environment = ["DJC_HOME": "/tmp/djc-key-home", "DJC_REKORDBOX_DIR": "/tmp/djc-key-fixture"]

    @Test
    func 기본은_기존_비활성_모드다() {
        #expect(KeyRoutingSelfTestMode.requested(arguments: ["--key-routing-selftest"], environment: environment) == .inactive)
    }

    @Test
    func 활성_모드는_명시적인_한_덩어리_인자가_필요하다() {
        #expect(KeyRoutingSelfTestMode.requested(arguments: ["--key-routing-selftest", "--key-routing-mode=active"], environment: environment) == .active)
    }

    @Test(arguments: [
        ["--key-routing-mode"], ["--key-routing-mode", "active"], ["--key-routing-mode="],
        ["--key-routing-mode=unknown"], ["--key-routing-mode=active", "--key-routing-mode=inactive"],
    ])
    func 잘못된_모드와_중복은_거부한다(_ mode: [String]) {
        #expect(KeyRoutingSelfTestMode.requested(arguments: ["--key-routing-selftest"] + mode, environment: environment) == nil)
    }

    @Test(arguments: [
        [:], ["DJC_HOME": "/tmp/home"], ["DJC_REKORDBOX_DIR": "/tmp/fixture"],
        ["DJC_HOME": "", "DJC_REKORDBOX_DIR": "/tmp/fixture"],
        ["DJC_HOME": "/tmp/home", "DJC_REKORDBOX_DIR": ""],
    ] as [[String: String]])
    func 격리_환경_둘_다_없으면_활성_모드도_거부한다(_ environment: [String: String]) {
        #expect(KeyRoutingSelfTestMode.requested(arguments: ["--key-routing-selftest", "--key-routing-mode=active"], environment: environment) == nil)
    }

    @Test
    func 모드_인자만으로는_자가_테스트를_시작하지_않는다() {
        #expect(KeyRoutingSelfTestMode.requested(arguments: ["--key-routing-mode=active"], environment: environment) == nil)
    }
}
#endif
