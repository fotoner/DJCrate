import DJCDomain
import Foundation

/// rekordbox 쓰기 단계 안내(있으면 창 전체를 덮어 조작을 막는다). 유스케이스가 단계마다 알린다.
public struct WriteStage: Equatable, Sendable {
    public static var reloadingLibrary: Self { Self(String(ui: "쓴 라이브러리를 다시 읽는 중…"), readsBack: true) }

    public var text: String
    public var completed: Int?
    public var total: Int?
    public var cancellable: Bool
    /// 쓴 뒤 읽기만 하는 단계다. 쓰기·초안 정리·백업 사본 남기기가 모두 끝났고 남은 것은 다시 읽기뿐이라, 이 단계에서는 앱을 꺼도 쓴 것이 그대로다(#300).
    /// 읽은 뒤에도 초안을 되살리거나 쌓는 일이 남은 복원의 다시 읽기에는 붙이지 않는다.
    public var readsBack: Bool

    public init(_ text: String, completed: Int? = nil, total: Int? = nil, cancellable: Bool = false, readsBack: Bool = false) {
        self.text = text
        self.completed = completed
        self.total = total
        self.cancellable = cancellable
        self.readsBack = readsBack
    }

    /// 진행 카드에 보이는 안내 한 줄: 아직 쓰기 전이면 취소해도 된다는 것, 쓰는 동안은 rekordbox를 켜지 말라는 것(#310)
    public var notice: String {
        cancellable ? ReflectionPrompts.beforeWriteNotice : ReflectionPrompts.progressNotice
    }

    /// 앱 종료 판정의 단계(취소할 수 있으면 아직 쓰지 않은 단계가 먼저다)
    public var phase: RekordboxWritePhase {
        if cancellable { return .cancellable }
        return readsBack ? .readingBack : .writing
    }
}
