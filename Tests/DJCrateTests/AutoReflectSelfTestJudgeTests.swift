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

    /// 다른 개발용 인자(예: `--sheet`)는 사용자 환경설정에 쓸 수 있어 함께 주면 조립 전에 거절한다. ⌘Q 저장 자가 테스트만 함께 돈다(컨실 2라운드 K)
    @Test func 다른_개발용_인자를_함께_주면_조립_전에_거절한다() throws {
        let temp = try TemporaryFolder(prefix: "djc-auto-reflect-startup")
        let rekordbox = temp.url.appending(path: "rb"), home = temp.url.appending(path: "home")
        try FileManager.default.createDirectory(at: rekordbox.appending(path: "share/PIONEER/USBANLZ"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = ["DJC_REKORDBOX_DIR": rekordbox.path, "DJC_HOME": home.path]
        let base = ["DJCrate", "--auto-reflect-selftest=save"]
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: base + ["--sheet"], environment: env) != nil)
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: base + ["--inspector"], environment: env) != nil)
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: base + ["--quit-wait-selftest"], environment: env) == nil)
        #expect(AutoReflectAppSelfTest.startupRefusal(arguments: base + ["-NSDocumentRevisionsDebugMode", "YES"], environment: env) == nil,
                "AppKit 인자는 상관하지 않는다")
    }

    // MARK: - 소리 끊김(S8)

    private typealias Arrival = AutoReflectAppSelfTest.AudioContinuity.Arrival
    private static func continuous(seconds: Int, rms: Float = 0.2) -> [Float] { Array(repeating: rms, count: seconds * 100) }
    private static func arrivals(seconds: Double, every: Double = 1024.0 / 44_100) -> [Arrival] {
        stride(from: 0, through: seconds, by: every).map { Arrival(time: $0, received: $0) }
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
        let stalled = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Self.continuous(seconds: 60),
                                                                     arrivals: [Arrival(time: 0, received: 0), Arrival(time: 0.5, received: 0.5)]
                                                                         + Self.arrivals(seconds: 60).map { Arrival(time: $0.time + 1, received: $0.received + 1) },
                                                                     seconds: 60, playheadAdvance: 60)
        #expect(stalled.problems.contains { $0.contains("오지 않았다") })
    }

    /// 출력이 0.15초씩 10번 멈췄다 따라잡지 않고 이어졌다: 버퍼 간격(0.25초)·받은 시간(5%) 기준은 지나지만 소리는 끊겼다(컨실 2라운드 L)
    @Test func 짧게_빠진_구간이_쌓이면_누적_부족분으로_끊김을_센다() throws {
        let period = 1024.0 / 44_100
        var arrivals: [Arrival] = [], time = 0.0, received = 0.0
        for index in 0..<2600 {
            arrivals.append(Arrival(time: time, received: received))
            time += period + (index % 250 == 249 && index < 2500 ? 0.15 : 0)
            received += period
        }
        let last = try #require(arrivals.last)
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Array(repeating: 0.2, count: Int(last.received * 100)), arrivals: arrivals,
                                                                    seconds: last.time, playheadAdvance: last.received)
        #expect(result.problems.contains { $0.contains("누적") }, "\(result.problems)")
    }

    /// 측정 끝 직전에 끊겨 그 뒤 버퍼 없이 측정이 닫혀도 끊김이다: 마지막 버퍼부터 끝 표식까지도 본다(컨실 3라운드 R)
    @Test(arguments: [0.15, 2.0])
    func 마지막_버퍼부터_측정_끝까지_빈_시간도_끊김으로_센다(_ silent: Double) throws {
        let arrivals = Self.arrivals(seconds: 58)
        let last = try #require(arrivals.last)
        let end = last.time + 1024.0 / 44_100 + silent
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Array(repeating: 0.2, count: Int(last.received * 100)), arrivals: arrivals,
                                                                    seconds: end, playheadAdvance: last.received)
        #expect(!result.problems.isEmpty, "\(silent)초")
    }

    @Test func 측정_시작부터_첫_버퍼까지_빈_시간도_끊김으로_센다() throws {
        let arrivals = Self.arrivals(seconds: 58).map { Arrival(time: $0.time + 0.15, received: $0.received) }
        let last = try #require(arrivals.last)
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Array(repeating: 0.2, count: Int(last.received * 100)), arrivals: arrivals,
                                                                    seconds: last.time + 1024.0 / 44_100, playheadAdvance: last.received)
        #expect(!result.problems.isEmpty)
    }

    /// 누적 부족분은 버퍼의 렌더 시각으로 잰다: 콜백이 늦게 도착한 지터(120ms)는 소리가 빠진 것이 아니다(컨실 3라운드 O15)
    @Test func 렌더_시각이_있으면_누적_부족분을_렌더_시각으로_잰다() {
        let arrivals = Self.arrivals(seconds: 60).enumerated().map { index, arrival in
            Arrival(time: arrival.time + (index % 40 == 20 ? 0.12 : 0), received: arrival.received, rendered: 1_000 + arrival.time)
        }
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Self.continuous(seconds: 60), arrivals: arrivals, seconds: 60,
                                                                    playheadAdvance: 60)
        #expect(result.problems.isEmpty, "\(result.problems)")
    }

    /// 렌더 시각이 빠진 버퍼가 하나라도 있으면 그 회 전체를 도착 시각으로 잰다: 절대 시각(렌더)과 측정 시작에서 잰 시각을 섞지 않는다(컨실 4라운드 X)
    @Test func 렌더_시각이_하나라도_빠지면_그_회는_도착_시각으로_잰다() {
        let arrivals = Self.arrivals(seconds: 60).enumerated().map { index, arrival in
            Arrival(time: arrival.time, received: arrival.received, rendered: index == 1000 ? nil : 1_000 + arrival.time)
        }
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Self.continuous(seconds: 60), arrivals: arrivals, seconds: 60,
                                                                    playheadAdvance: 60)
        #expect(result.problems.isEmpty, "\(result.problems)")
    }

    /// 경계 간격 기준은 0.125초다(버퍼 하나 + 표식 지터): 0.11초는 끊김이 아니고 0.15초는 끊김이다(컨실 4라운드 Z)
    @Test func 경계_간격은_0_125초까지_받는다() throws {
        for (lead, broken) in [(0.11, false), (0.15, true)] {
            let arrivals = Self.arrivals(seconds: 58).map { Arrival(time: $0.time + lead, received: $0.received) }
            let last = try #require(arrivals.last)
            let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Array(repeating: 0.2, count: Int(last.received * 100)), arrivals: arrivals,
                                                                        seconds: last.time + 1024.0 / 44_100, playheadAdvance: last.received)
            #expect(result.problems.isEmpty == !broken, "\(lead)초: \(result.problems)")
        }
    }

    /// 버퍼 하나 안의 도착 지터(앞뒤로 20ms)는 끊김이 아니다
    @Test func 버퍼_하나_안의_도착_지터는_끊김이_아니다() {
        let arrivals = Self.arrivals(seconds: 60).enumerated().map { index, arrival in
            Arrival(time: arrival.time + (index.isMultiple(of: 2) ? 0.02 : -0.02), received: arrival.received)
        }
        let result = AutoReflectAppSelfTest.AudioContinuity.measure(windows: Self.continuous(seconds: 60), arrivals: arrivals, seconds: 60,
                                                                    playheadAdvance: 60)
        #expect(result.problems.isEmpty, "\(result.problems)")
    }

    // MARK: - E1 측정(S9)

    private typealias Event = (RekordboxWriteMoment, ContinuousClock.Instant)

    @Test func 커밋과_파일_교체의_짝으로_관문_값과_참고값을_잰다() throws {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }
        let events: [Event] = [(.recheck(.commit), at(0)), (.recheck(.commit), at(10)), (.after(.commit), at(110)), (.after(.verify), at(900)),
                               (.recheck(.fileReplace), at(1000)), (.before(.fileReplace), at(1001)), (.after(.fileReplace), at(1030)),
                               (.recheck(.fileReplace), at(1100)), (.before(.fileReplace), at(1101)), (.after(.fileReplace), at(1160))]
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

    /// 시작한 파일 교체(`before`)마다 그 앞의 재확인과 뒤의 완료가 있어야 그 회를 받는다(컨실 2라운드 M)
    @Test func 시작한_파일_교체마다_재확인과_완료_짝이_없으면_그_회를_받지_않는다() {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }
        let base: [Event] = [(.recheck(.commit), at(0)), (.after(.commit), at(100)),
                             (.recheck(.fileReplace), at(200)), (.before(.fileReplace), at(201)), (.after(.fileReplace), at(230))]
        #expect(AutoReflectAppSelfTest.E1Measurement.measure(base) != nil)
        #expect(AutoReflectAppSelfTest.E1Measurement.measure(base + [(.recheck(.fileReplace), at(300)), (.before(.fileReplace), at(301))]) == nil,
                "시작한 파일 교체의 완료가 없다")
        #expect(AutoReflectAppSelfTest.E1Measurement.measure(base + [(.before(.fileReplace), at(300)), (.after(.fileReplace), at(330))]) == nil,
                "재확인 없이 시작한 파일 교체다")
    }

    /// 측정 끝에 시작으로 이어지지 않은 파일 교체 재확인이 남으면 그 회를 받지 않는다. 쓰기 기록 직전처럼 다음 재확인으로 이어지는 재확인은 괜찮다(컨실 3라운드 S)
    @Test func 시작으로_이어지지_않은_재확인이_끝에_남으면_그_회를_받지_않는다() {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }
        let base: [Event] = [(.recheck(.commit), at(0)), (.after(.commit), at(100)),
                             (.recheck(.fileReplace), at(150)), (.recheck(.fileReplace), at(200)), (.before(.fileReplace), at(201)),
                             (.after(.fileReplace), at(230))]
        #expect(AutoReflectAppSelfTest.E1Measurement.measure(base) != nil, "쓰기 기록 직전 재확인은 다음 시작으로 이어진다")
        #expect(AutoReflectAppSelfTest.E1Measurement.measure(base + [(.recheck(.fileReplace), at(300))]) == nil, "다음 교체의 재확인만 남았다")
    }

    /// E1 관문(2×E1 < E2′ 최솟값 2.154초)을 넘지 못하면 자가 테스트는 종료 코드 1이다(컨실 2라운드 N)
    @Test func E1_관문을_넘지_못하면_종료_코드_1이다() {
        #expect(AutoReflectAppSelfTest.E1Measurement.exitCode(gate: .milliseconds(279)) == 0)
        #expect(AutoReflectAppSelfTest.E1Measurement.exitCode(gate: .milliseconds(1077)) == 1, "2배가 2.154초와 같으면 넘지 못한다")
        #expect(AutoReflectAppSelfTest.E1Measurement.exitCode(gate: .seconds(2)) == 1)
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
