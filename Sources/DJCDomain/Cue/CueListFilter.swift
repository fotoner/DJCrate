import Foundation

public enum CueListFilter: String, CaseIterable, Sendable {
    case all, hot, memory

    public var title: String {
        switch self {
        case .all: String(ui: "전체")
        case .hot: String(ui: "핫큐")
        case .memory: String(ui: "메모리")
        }
    }

    public func includes(_ cue: EditableCue) -> Bool {
        switch (self, cue.kind) {
        case (.all, _), (.hot, .hot), (.memory, .memory): true
        default: false
        }
    }
}
