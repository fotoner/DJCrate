import AppKit
import DJCDomain
import SwiftUI

struct AppMessage: Equatable {
    var kind: AppToast.Kind = .success
    var text: String
}

/// 토스트·덱·안내 줄의 접근성 알림은 이 주입 지점 하나를 거친다.
@MainActor
struct AppFeedback {
    var announce: (AppMessage) -> Void = { message in
        var text = AttributedString(message.text)
        if message.kind != .success { text.accessibilitySpeechAnnouncementPriority = .high }
        AccessibilityNotification.Announcement(text).post()
    }
    var isVoiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
}

struct AppMessageView: View {
    let message: AppMessage
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Label(message.text, systemImage: message.kind.icon)
                .foregroundStyle(message.kind.tint)
                .textSelection(.enabled)
            Spacer()
            Button(.ui("닫기"), action: onClose).controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.edge).padding(.vertical, 6)
    }
}
