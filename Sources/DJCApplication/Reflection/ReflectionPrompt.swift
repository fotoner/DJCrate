import Foundation

/// 사용자에게 보여 주는 창 한 개. `confirm`이 있으면 확인·취소, 없으면 알림.
public struct ReflectionPrompt: Equatable, Sendable {
    public var title: String
    public var text: String
    public var confirm: String?
    public var critical = false
    public var destructive = false
    public var details: [String] = []
    /// 세 갈래 창(`choose`)의 둘째 동작 단추
    public var alternate: String?
    /// 취소 단추 이름(nil이면 "취소")
    public var cancel: String?

    public init(title: String, text: String, confirm: String? = nil, critical: Bool = false, destructive: Bool = false,
                details: [String] = [], alternate: String? = nil, cancel: String? = nil) {
        self.title = title
        self.text = text
        self.confirm = confirm
        self.critical = critical
        self.destructive = destructive
        self.details = details
        self.alternate = alternate
        self.cancel = cancel
    }
}

/// 세 갈래 창의 답
public enum ReflectionChoice: Equatable, Sendable {
    case confirm, alternate, cancel
}
