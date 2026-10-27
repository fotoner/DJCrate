import SwiftUI

/// 비활성인 컨트롤에 이유를 거는 값. 이유가 있으면 비활성 + 이유 툴팁 + 접근성 값을 한 번에 정한다.
/// 이유가 없으면 컨트롤은 켜져 있고 평소 툴팁(`enabledHelp`)만 남는다.
/// 이유를 줄 곳: 지금 막혀서 할 일이 있거나, 막힌 사정을 알아야 하는 컨트롤. 늘 보이는 설명 줄 대신 쓴다.
struct DisabledReason: Equatable {
    /// 화면 낭독이 이유를 읽는 자리
    enum Announcement: Equatable {
        /// 컨트롤 이름 뒤의 값으로 읽는다(단추). 값이 이유로 바뀐다
        case value
        /// 힌트로 읽는다. 토글처럼 켜짐·꺼짐이 값인 컨트롤은 그 값을 지키려고 이쪽을 쓴다
        case hint
    }

    /// 막는 이유. nil이거나 공백뿐이면 막지 않는다
    let text: String?
    let enabledHelp: String?
    let announcement: Announcement

    init(_ text: String?, enabledHelp: String? = nil, announcedAs announcement: Announcement = .value) {
        self.text = text?.allSatisfy(\.isWhitespace) == false ? text : nil
        self.enabledHelp = enabledHelp
        self.announcement = announcement
    }

    var isDisabled: Bool { text != nil }
    /// 막혔으면 이유, 아니면 평소 툴팁
    var help: String? { text ?? enabledHelp }
    /// 화면 낭독이 컨트롤 이름 뒤에 읽는 값. 막혔고 `.value`로 알릴 때만 이유가 값이 된다
    var accessibilityValue: String? { announcement == .value ? text : nil }
    /// 막혔고 `.hint`로 알릴 때만 이유가 힌트가 된다
    var accessibilityHint: String? { announcement == .hint ? text : nil }
}

extension View {
    /// `reason`이 있으면 비활성으로 두고 이유를 툴팁과 접근성 값(토글은 `.hint`)으로 건다. 다른 이유로 막는 `.disabled(_:)`와 함께 써도 된다(둘 중 하나라도 막으면 막힌다).
    /// 막히지 않았을 때의 툴팁은 `enabledHelp`로 준다(안쪽에 따로 단 `.help`는 이 수정자가 덮는다).
    func disabled(because reason: String?, enabledHelp: String? = nil,
                  announcedAs announcement: DisabledReason.Announcement = .value) -> some View {
        modifier(DisabledReasonModifier(reason: DisabledReason(reason, enabledHelp: enabledHelp, announcedAs: announcement)))
    }
}

private struct DisabledReasonModifier: ViewModifier {
    let reason: DisabledReason

    func body(content: Content) -> some View {
        content
            .disabled(reason.isDisabled)
            .help(reason.help ?? "")
            // 막힌 동안만 덮는다. 켜져 있을 때는 토글의 켜짐·꺼짐 같은 원래 값을 그대로 읽게 둔다.
            .accessibilityValue(Text(verbatim: reason.accessibilityValue ?? ""), isEnabled: reason.accessibilityValue != nil)
            .accessibilityHint(Text(verbatim: reason.accessibilityHint ?? ""), isEnabled: reason.accessibilityHint != nil)
    }
}
