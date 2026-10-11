import DJCDomain
import Foundation
import QuartzCore
import SwiftUI

/// 개발용 성능 기록(디버그 빌드의 `--scroll-perf`일 때만). 재생 화면 갱신 간격과 파형 그리기 시간을 잰다.
@MainActor
enum PerfProbe {
    #if DEBUG
    /// `--scroll-perf`·`--ui-perf=`(#129) 측정 중. 표 칸 배치·설정을 저장하지 않는다.
    static let enabled = ProcessInfo.processInfo.arguments.contains {
        $0 == "--scroll-perf" || $0.hasPrefix("--ui-perf=") || $0.hasPrefix("--resize-perf=")
    }
    static let previewCuesVisible = !ProcessInfo.processInfo.arguments.contains("--perf-cues=off")
    /// A/B: 확대 파형 막대를 그리지 않는다
    static let skipBands = ProcessInfo.processInfo.arguments.contains("--skip-bands")
    /// A/B: 이름을 준 화면 요소를 숨긴다(`--perf-hide=zoom,label,overview,meter`)
    static let hidden: Set<String> = {
        // `--perf-hide=zoom,label` 한 덩어리로 받는다(따로 쓰면 AppKit이 뒤 단어를 열 파일로 본다).
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--perf-hide=") }) else { return [] }
        return Set(arg.dropFirst("--perf-hide=".count).components(separatedBy: ","))
    }()
    /// 사용자 열 설정을 저장하지 않고 미리 보기 열만 켜거나 끈다.
    static let previewColumnVisible: Bool? = {
        guard enabled else { return nil }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--perf-preview=on") { return true }
        if args.contains("--perf-preview=off") { return false }
        return nil
    }()
    /// 화면 확인용 글자 배율(`--text-scale=1.3`). 사용자 설정을 바꾸지 않는다.
    static let textScale: Double? = {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--text-scale=") }),
              let value = Double(arg.dropFirst("--text-scale=".count)) else { return nil }
        return TextScale.nearest(value)
    }()
    #else
    // 릴리스 빌드에서는 늘 꺼져 있다(부르는 쪽은 그대로 두고 아무 일도 하지 않는다).
    static let enabled = false
    static let previewCuesVisible = true
    static let skipBands = false
    static let hidden: Set<String> = []
    static let previewColumnVisible: Bool? = nil
    static let textScale: Double? = nil
    #endif

    #if DEBUG
    /// 뷰 본문이 계산된 횟수(이름별). `--ui-perf=`가 조작마다 찍는다(#138). `--perf-trace-body`는 계산된 이유도 찍는다.
    private static var bodyCounts: [String: Int] = [:]
    /// 덱에 전달된 실제 파형 높이. 단독 배치 시험에서 곡 로드·수동 조절 계약을 확인한다.
    private(set) static var lastWaveformHeight: Double?

    @discardableResult
    static func recordWaveformHeight(_ height: Double) -> Bool {
        if countsBodies { lastWaveformHeight = height }
        return true
    }
    /// 측정 중이거나 시험이 켰을 때만 센다.
    static var countsBodies = enabled
    private static let tracesBodies = ProcessInfo.processInfo.arguments.contains("--perf-trace-body")

    /// 뷰의 `body` 첫머리에서 `let _ = PerfProbe.body(Self.self)`로 부른다.
    @discardableResult
    static func body<V: View>(_ type: V.Type) -> Bool {
        guard countsBodies else { return true }
        bodyCounts[String(describing: type), default: 0] += 1
        if tracesBodies { V._printChanges() }
        return true
    }

    /// 뷰가 아닌 갱신 지점(`updateNSView` 등)을 이름으로 센다.
    static func count(_ name: String) {
        guard countsBodies else { return }
        bodyCounts[name, default: 0] += 1
    }

    static func resetBodyCounts() { bodyCounts = [:] }

    static func bodyCount(_ name: String) -> Int { bodyCounts[name] ?? 0 }

    static func bodySnapshot() -> [String: Int] { bodyCounts }

    /// 현재 구간의 파형 Canvas 실행 시간(ms). 화면 표시 완료 시간과는 다르다.
    static func drawSnapshot() -> [Double] { draws.map { $0 * 1000 } }

    static var measuresIntervals = enabled
    private static var intervals: [String: [Double]] = [:]

    /// 서로 포함될 수 있는 호출 구간이다. 다른 이름의 시간을 합산하지 않는다.
    static func measure<T>(_ name: String, _ body: () -> T) -> T {
        guard measuresIntervals else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        intervals[name, default: []].append((CACurrentMediaTime() - start) * 1000)
        return result
    }

    static func intervalSnapshot() -> [String: [Double]] { intervals }

    static func beginInterval() -> Double? { measuresIntervals ? CACurrentMediaTime() : nil }
    static func endInterval(_ name: String, from start: Double?) {
        if let start { intervals[name, default: []].append((CACurrentMediaTime() - start) * 1000) }
    }

    static func bodySummary() -> String? {
        guard !bodyCounts.isEmpty else { return nil }
        return bodyCounts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }
    #else
    @discardableResult
    static func body<V: View>(_ type: V.Type) -> Bool { true }
    static func count(_ name: String) {}
    @discardableResult
    static func recordWaveformHeight(_ height: Double) -> Bool { true }
    static func measure<T>(_ name: String, _ body: () -> T) -> T { body() }
    static func beginInterval() -> Double? { nil }
    static func endInterval(_ name: String, from start: Double?) {}
    #endif

    private static var ticks: [Double] = []
    private static var draws: [Double] = []
    /// 메인 런루프가 한 번 깨어나 일한 시간(ms)
    private static var busy: [Double] = []
    private static var wokeAt: Double = 0
    private static var observer: CFRunLoopObserver?

    /// 메인 런루프가 깨어 있던 시간을 잰다(깨어남 → 잠들기 직전).
    static func startRunLoopProbe() {
        guard enabled, observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                if activity == .afterWaiting { wokeAt = now } else if wokeAt > 0 { busy.append((now - wokeAt) * 1000) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    static func tick() {
        guard enabled else { return }
        ticks.append(CACurrentMediaTime())
    }

    static func measureDraw<T>(_ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        draws.append(CACurrentMediaTime() - start)
        return result
    }

    static func reset() {
        ticks = []; draws = []; busy = []
        #if DEBUG
        intervals = [:]
        #endif
    }

    /// 갱신 간격(ms): 평균·최대·25ms 넘은 횟수, 파형 그리기(ms): 평균·최대
    static func summary() -> String {
        let gaps = zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
        let avg = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        let drawAvg = draws.isEmpty ? 0 : draws.reduce(0, +) / Double(draws.count) * 1000
        return String(format: "갱신 %d번 · 간격 평균 %.1fms 최대 %.1fms · 25ms 넘음 %d번 · 파형 그리기 %d번 평균 %.2fms 최대 %.2fms",
                      ticks.count, avg, gaps.max() ?? 0, gaps.filter { $0 > 25 }.count,
                      draws.count, drawAvg, (draws.max() ?? 0) * 1000)
            + String(format: " · 메인 스레드 일한 시간 합 %.0fms/초 · 한 번 최대 %.1fms · 10ms 넘은 번 %d",
                      busy.reduce(0, +) / 3, busy.max() ?? 0, busy.filter { $0 > 10 }.count)
    }
}
