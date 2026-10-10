import DJCDomain
import Foundation

/// 보존 흐름(`ArchiveUsbHistories`)이 순서를 정할 때 보는 재생 기록 화면 상태(앱: 재생 기록 조각의 값). 부를 때마다 지금 값을 새로 읽는다.
public struct UsbHistoryState: Sendable {
    /// 지금 보존본(쓰기 대기에서 빼기·rekordbox에 쓴 표시를 고친 것까지)
    public var archived: [ArchivedHistory]
    /// 채택한 스냅샷의 짝짓기 키(USB를 뺀 뒤에도 보존본의 짝·쓴 표시를 검증한다)
    public var local: LocalLibraryKeys?
    /// rekordbox도 가져온 기록이라 트리에서 숨긴 보존본
    public var shadowed: Set<String>
    /// rekordbox 쓰기 대기에 오른 보존본
    public var pending: Set<String>

    public init(archived: [ArchivedHistory] = [], local: LocalLibraryKeys? = nil, shadowed: Set<String> = [], pending: Set<String> = []) {
        self.archived = archived
        self.local = local
        self.shadowed = shadowed
        self.pending = pending
    }
}

/// 보존 흐름이 화면에 알리는 것. 무엇을 바꾸고 알릴지는 흐름이 정하고, 화면은 표시만 바꾼다.
public enum UsbHistoryChange: Sendable {
    /// 보존본 목록을 바꾼다(읽기·보존 채택·짝 다시 검증·쓰기 대기에서 빼기·쓴 표시). 화면은 트리·쓰기 대기를 다시 고른다
    case archived([ArchivedHistory])
    /// rekordbox에 쓴 기록 ID. 다시 읽을 때까지 rekordbox에 있는 것으로 보고 쓰기 대기를 다시 고른다
    case awaitingReload(Set<String>)
    /// 보존본을 다 읽었다(라이브러리를 읽었으면 처음 한 번 펼치고, 보던 기록 목록을 다시 만든다)
    case loaded(UsbHistoryNotice?)
    /// USB에서 새로 보존했다: 펼칠 기록(`shown`, 숨긴 기록은 빠진다), 보던 기록이면 목록을 다시 만들 기록(`saved`).
    /// 알림은 성공 알림이라 닫을 때까지 남는 알림·동작 단추가 있는 알림은 덮지 않는다
    case imported(shown: [String], saved: Set<String>, notice: UsbHistoryNotice?)
    /// 알린다(보존본 저장 실패 등)
    case notice(UsbHistoryNotice)
}

/// 보존 흐름의 알림(USB 알림으로 보인다)
public struct UsbHistoryNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case success, warning
    }

    public var kind: Kind
    public var title: String
    public var detail: String?

    public init(kind: Kind, title: String, detail: String?) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    static func warning(_ title: String, _ detail: String?) -> Self { Self(kind: .warning, title: title, detail: detail) }
}

/// 보존 흐름이 보는 재생 기록 화면(앱: 재생 기록 조각 `HistoryStore`). 흐름은 상태를 읽고(`state`) 바꿀 것을 알린다(`apply`).
@MainActor
public struct UsbHistoryScreen {
    public var state: @MainActor () -> UsbHistoryState
    public var apply: @MainActor (UsbHistoryChange) -> Void

    public init(state: @escaping @MainActor () -> UsbHistoryState, apply: @escaping @MainActor (UsbHistoryChange) -> Void) {
        self.state = state
        self.apply = apply
    }
}
