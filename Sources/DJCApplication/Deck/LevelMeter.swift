import Foundation

/// 게인 뒤·볼륨 앞 레벨. 오디오 탭 스레드가 쓰고 화면이 읽는다(잠금으로 보호).
public final class LevelMeter: @unchecked Sendable {
    public struct Reading: Sendable {
        public var peak: (left: Float, right: Float) = (0, 0)
        public var rms: (left: Float, right: Float) = (0, 0)
        /// 마지막으로 받은 시각(재생이 멈추면 더 오지 않는다)
        public var time: Double = 0
        /// 마지막으로 0dBFS 이상이 나온 시각
        public var clipTime: Double = -.infinity
        /// 곡을 불러온 뒤 가장 큰 피크와 0dBFS를 넘은 횟수(버퍼 단위)
        public var maxPeak: Float = 0
        public var clipCount = 0
        public init() {}
    }

    public init() {}

    private let lock = NSLock()
    private var reading = Reading()

    /// - Parameter now: 받은 시각(`ProcessInfo.systemUptime`, 화면이 같은 시계로 읽는다). 시계는 부르는 엔진이 준다.
    public func update(peak: (Float, Float), rms: (Float, Float), now: Double) {
        lock.lock()
        reading.peak = peak
        reading.rms = rms
        reading.time = now
        let top = max(peak.0, peak.1)
        reading.maxPeak = max(reading.maxPeak, top)
        if top >= 1 {
            reading.clipTime = now
            reading.clipCount += 1
        }
        lock.unlock()
    }

    public func read() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    public func reset() {
        lock.lock()
        reading = Reading()
        lock.unlock()
    }

    /// 최고 피크·CLIP 기록만 지운다.
    public func resetPeaks() {
        lock.lock()
        reading.maxPeak = 0
        reading.clipCount = 0
        reading.clipTime = -.infinity
        lock.unlock()
    }
}
