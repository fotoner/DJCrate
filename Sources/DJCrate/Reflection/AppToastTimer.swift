import AppKit

/// 알림이 저절로 닫히기까지 남은 시간을 센다. 마우스를 올려 둔 동안은 세지 않는다.
/// 실패·경고와 VoiceOver를 켠 동안은 닫지 않는다(`AppToast.automaticallyDismisses`). 알림 뷰가 하나씩 든다.
@MainActor
final class AppToastTimer {
    /// 마우스를 올려 둔 동안 참(본문이 읽지 않아 바뀌어도 다시 그리지 않는다)
    var hovering = false
    private let voiceOver: () -> Bool
    private let sleep: (Duration) async throws -> Void
    private static let tick = 0.25

    init(voiceOver: @escaping () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.voiceOver = voiceOver
        self.sleep = sleep
    }

    /// `.task(id: toast.id)`가 부른다. 알림이 사라지거나 바뀌면(작업 취소) 닫지 않고 멈춘다.
    func run(_ toast: AppToast, close: () -> Void) async {
        // 올려 둔 동안은 기다린다.
        guard toast.automaticallyDismisses(voiceOverEnabled: voiceOver()) else { return }
        var remaining = toast.duration
        while remaining > 0 {
            try? await sleep(.milliseconds(Int(Self.tick * 1000)))
            if Task.isCancelled || voiceOver() { return }
            if !hovering { remaining -= Self.tick }
        }
        close()
    }
}
