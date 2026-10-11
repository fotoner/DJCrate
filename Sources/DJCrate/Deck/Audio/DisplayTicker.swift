import AppKit
import QuartzCore

/// 디스플레이 주사율에 맞춘 갱신(CADisplayLink). 16ms 타이머보다 움직임이 고르다.
@MainActor
final class DisplayTicker: NSObject {
    private var link: CADisplayLink?
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    func start() {
        guard link == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        // 파형 갱신은 60Hz면 충분하다(ProMotion 120Hz에서 CPU를 반으로 줄인다).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private var pending = false

    /// 디스플레이 링크는 AppKit 레이아웃 패스 도중에 불린다. 여기서 바로 상태를 바꾸면
    /// 레이아웃이 다시 무효화되어 무한 갱신(NSGenericException)이 난다. 다음 런루프로 미룬다.
    @objc private func step(_ link: CADisplayLink) {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pending = false
            self.onTick()
        }
    }
}
