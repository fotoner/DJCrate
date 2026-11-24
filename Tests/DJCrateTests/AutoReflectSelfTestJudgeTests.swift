@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 자동 저장 자가 테스트(`--auto-reflect-selftest`)의 판정 함수: 조립 전 거절(S1), 소리 끊김(S8), E1 측정(S9).
/// 자가 테스트가 무엇을 통과로 볼지는 앱을 띄우지 않고 여기서 값으로 본다
@MainActor
@Suite("자동 저장 자가 테스트 판정")
struct AutoReflectSelfTestJudgeTests {
    // MARK: - 조립 전 거절(S1)

    @Test func 사본과_데이터_폴더를_함께_주지_않으면_조립_전에_거절한다() throws {
        let temp = try TemporaryFolder(prefix: "djc-auto-reflect-startup")
        let args = ["DJCrate", "--auto-reflect-selftest=save"]
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: ["DJCrate"], environment: [:]) == nil, "자가 테스트가 아니면 상관하지 않는다")
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: ["DJCrate", "--auto-reflect-selftest=what"], environment: [:]) != nil)
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: args, environment: [:]) != nil, "DJC_HOME 없이 띄우면 사용자 폴더를 쓴다")
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: args, environment: ["DJC_HOME": temp.url.path]) != nil)
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: args, environment: ["DJC_REKORDBOX_DIR": temp.url.path]) != nil)
    }

    @Test func 쓰기_전_확인을_채우지_못하면_조립_전에_거절한다() throws {
        let temp = try TemporaryFolder(prefix: "djc-auto-reflect-startup")
        let rekordbox = temp.url.appending(path: "rb"), home = temp.url.appending(path: "home")
        try FileManager.default.createDirectory(at: rekordbox.appending(path: "share/PIONEER/USBANLZ"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = ["DJC_REKORDBOX_DIR": rekordbox.path, "DJC_HOME": home.path]
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: ["DJCrate", "--auto-reflect-selftest=save"], environment: env) == nil)
        // 명시한 사본은 쓰기 대상이 아니다
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: ["DJCrate", "--auto-reflect-selftest=save", "--db",
                                                                  rekordbox.appending(path: "master.db").path], environment: env) != nil)
        // 사본의 분석 폴더가 링크면 쓰지 않는다(SAFE-8)
        let linked = temp.url.appending(path: "linked")
        try FileManager.default.createDirectory(at: linked.appending(path: "share/PIONEER"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "share/PIONEER/USBANLZ"),
                                                   withDestinationURL: rekordbox.appending(path: "share/PIONEER/USBANLZ"))
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: ["DJCrate", "--auto-reflect-selftest=save"],
                                                      environment: ["DJC_REKORDBOX_DIR": linked.path, "DJC_HOME": home.path]) != nil)
    }

    // MARK: - 소리 끊김(S8)

    private static func continuous(seconds: Int, rms: Float = 0.2) -> [Float] { Array(repeating: rms, count: seconds * 100) }
    private static func arrivals(seconds: Double, every: Double = 1024.0 / 44_100) -> [Double] {
        stride(from: 0, through: seconds, by: every).map { $0 }
    }

    @Test func 끊김_없는_연속_신호는_통과한다() {
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Self.continuous(seconds: 60), arrivals: Self.arrivals(seconds: 60),
                                                                    seconds: 60, playheadAdvance: 60)
        #expect(result.problems.isEmpty, "\(result.problems)")
    }

    @Test func 무음_버퍼로는_통과하지_않는다() {
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Self.continuous(seconds: 60, rms: 0), arrivals: Self.arrivals(seconds: 60),
                                                                    seconds: 60, playheadAdvance: 60)
        #expect(!result.problems.isEmpty && result.problems.contains { $0.contains("신호가 약하다") })
    }

    @Test func 잠깐_조용해진_구간을_끊김으로_센다() {
        var windows = Self.continuous(seconds: 60)
        for index in 3000..<3005 { windows[index] = 0.001 }
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: windows, arrivals: Self.arrivals(seconds: 60), seconds: 60, playheadAdvance: 60)
        #expect(result.quietWindows == 5 && !result.problems.isEmpty)
    }

    @Test func 빠진_샘플은_재생_위치와_대조해_끊김으로_센다() {
        // 재생 위치는 66초 나아갔는데 받은 샘플은 60초어치다(엔진이 버퍼를 건너뜀)
        let skipped = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Self.continuous(seconds: 60), arrivals: Self.arrivals(seconds: 66),
                                                                     seconds: 66, playheadAdvance: 66)
        #expect(skipped.problems.contains { $0.contains("재생 위치") })
        // 버퍼가 한동안 오지 않았다(엔진이 멈췄다 다시 섬)
        let stalled = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Self.continuous(seconds: 60), arrivals: [0, 0.5] + Self.arrivals(seconds: 60).map { $0 + 1 },
                                                                     seconds: 60, playheadAdvance: 60)
        #expect(stalled.problems.contains { $0.contains("오지 않았다") })
    }

    // MARK: - E1 측정(S9)

    private typealias Event = (RekordboxWriteMoment, ContinuousClock.Instant)

    @Test func 커밋과_파일_교체의_짝으로_관문_값과_참고값을_잰다() throws {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }
        let events: [Event] = [(.recheck(.commit), at(0)), (.recheck(.commit), at(10)), (.after(.commit), at(110)), (.after(.verify), at(900)),
                               (.recheck(.fileReplace), at(1000)), (.after(.fileReplace), at(1030)),
                               (.recheck(.fileReplace), at(1100)), (.after(.fileReplace), at(1160))]
        let measured = try #require(AutoReflectAppSelfTest.E1Measurement.measure(events))
        #expect(measured.gate == .milliseconds(100), "마지막 커밋 재확인부터 커밋 끝까지가 가장 길다")
        #expect(measured.perStep[.fileReplace] == .milliseconds(60))
        #expect(measured.reference == .milliseconds(1050), "참고값은 커밋 완료부터 마지막 파일 단계 완료까지다")
    }

    @Test func 필수_측정_구간이_없으면_그_회를_받지_않는다() {
        let t0 = ContinuousClock.now
        let onlyCommit: [Event] = [(.recheck(.commit), t0), (.after(.commit), t0 + .milliseconds(50))]
        #expect(AutoReflectAppSelfTest.E1Measurement.measure(onlyCommit) == nil, "파일 교체가 없다")
        let noRecheck: [Event] = [(.after(.commit), t0), (.recheck(.fileReplace), t0), (.after(.fileReplace), t0 + .milliseconds(5))]
        #expect(AutoReflectAppSelfTest.E1Measurement.measure(noRecheck) == nil, "커밋의 재확인 짝이 없다")
        #expect(AutoReflectAppSelfTest.E1Measurement.measure([]) == nil)
    }

    @Test func 실제로_쓴_결과가_섞인_K행이_아니면_그_회를_받지_않는다() {
        let judge = AutoReflectAppSelfTest.E1Measurement.mixedBatchProblem
        #expect(judge(79, 60, 2, 2, 200, 200) == nil)
        #expect(judge(79, 0, 2, 2, 200, 200) != nil, "그리드가 빠졌다")
        #expect(judge(0, 60, 2, 2, 200, 200) != nil, "큐가 빠졌다")
        #expect(judge(79, 60, 1, 2, 200, 200) != nil, "재생 목록 단계가 다 쓰이지 않았다")
        #expect(judge(79, 60, 0, 0, 139, 200) != nil, "재생 목록이 없다")
        #expect(judge(40, 30, 2, 2, 120, 200) != nil, "약 K행이 아니다")
    }
}
