import DJCDomain
import Foundation

/// rekordbox 쓰기 단계 안내(있으면 창 전체를 덮어 조작을 막는다). 유스케이스가 단계마다 알린다.
public struct WriteStage: Equatable, Sendable {
    public static var reloadingLibrary: Self { Self(String(ui: "쓴 라이브러리를 다시 읽는 중…")) }

    public var text: String
    public var completed: Int?
    public var total: Int?
    public var cancellable: Bool

    public init(_ text: String, completed: Int? = nil, total: Int? = nil, cancellable: Bool = false) {
        self.text = text
        self.completed = completed
        self.total = total
        self.cancellable = cancellable
    }
}
