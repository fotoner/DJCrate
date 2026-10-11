import Foundation

/// 단축키로 부를 수 있는 덱 동작. 순서는 설정 창의 순서이자, 키가 겹칠 때 먼저 받는 순서다.
public enum DeckAction: String, CaseIterable, Sendable {
    case playPause, cue
    case hotCueA, hotCueB, hotCueC, hotCueD, hotCueE, hotCueF, hotCueG, hotCueH
    case memoryCue, previousCue, nextCue, nudgeBack, nudgeForward, deleteCue
    case nextSuggestion, acceptSuggestion
    case loop, loopHalve, loopDouble
    case tapTempo, zoomIn, zoomOut

    public enum Group: String, CaseIterable, Sendable {
        case transport, hotCues, cues, loops, view

        public var title: String {
            switch self {
            case .transport: String(ui: "재생")
            case .hotCues: String(ui: "핫큐")
            case .cues: String(ui: "큐·박 이동·제안")
            case .loops: String(ui: "루프")
            case .view: String(ui: "템포·파형")
            }
        }
    }

    public var group: Group {
        switch self {
        case .playPause, .cue: .transport
        case .hotCueA, .hotCueB, .hotCueC, .hotCueD, .hotCueE, .hotCueF, .hotCueG, .hotCueH: .hotCues
        case .memoryCue, .previousCue, .nextCue, .nudgeBack, .nudgeForward, .deleteCue, .nextSuggestion, .acceptSuggestion: .cues
        case .loop, .loopHalve, .loopDouble: .loops
        case .tapTempo, .zoomIn, .zoomOut: .view
        }
    }

    /// 핫큐 칸(0 = A)
    public var hotCueSlot: Int? {
        switch self {
        case .hotCueA: 0
        case .hotCueB: 1
        case .hotCueC: 2
        case .hotCueD: 3
        case .hotCueE: 4
        case .hotCueF: 5
        case .hotCueG: 6
        case .hotCueH: 7
        default: nil
        }
    }

    public var title: String {
        if let slot = hotCueSlot { return String(ui: "핫큐 \(String(Character(UnicodeScalar(UInt8(65 + slot)))))") }
        switch self {
        case .playPause: return String(ui: "재생 / 정지")
        case .cue: return "CUE"
        case .memoryCue: return String(ui: "메모리 큐 찍기")
        case .previousCue: return String(ui: "이전 큐")
        case .nextCue: return String(ui: "다음 큐")
        case .nudgeBack: return String(ui: "1박 앞으로(선택한 큐 또는 재생 위치)")
        case .nudgeForward: return String(ui: "1박 뒤로(선택한 큐 또는 재생 위치)")
        case .deleteCue: return String(ui: "선택한 큐 지우기")
        case .nextSuggestion: return String(ui: "다음 제안으로")
        case .acceptSuggestion: return String(ui: "가까운 제안 받기")
        case .loop: return String(ui: "루프 걸기·나가기")
        case .loopHalve: return String(ui: "루프 길이 ½")
        case .loopDouble: return String(ui: "루프 길이 ×2")
        case .tapTempo: return String(ui: "탭 템포")
        case .zoomIn: return String(ui: "파형 확대")
        case .zoomOut: return String(ui: "파형 축소")
        default: return rawValue
        }
    }

    /// Shift와 함께 누르면 하는 일
    public var shiftTitle: String? {
        if hotCueSlot != nil { return String(ui: "Shift: 지우기") }
        switch self {
        case .memoryCue: return String(ui: "Shift: 이 자리 메모리 큐 지우기")
        case .nudgeBack, .nudgeForward: return String(ui: "Shift: 1마디")
        case .nextSuggestion: return String(ui: "Shift: 이전 제안으로")
        default: return nil
        }
    }
}

/// 덱 단축키 표: 동작 → 키 위치(ANSI 배열 키 코드) 목록. 글자가 아니라 자리로 정해서 한글 입력기에서도 같은 키가 같은 일을 한다.
/// 한 동작에 키를 여럿 둘 수 있다(1과 숫자 패드 1). ⌘·⌃·⌥ 조합은 메뉴 단축키라 여기서 다루지 않는다.
public struct DeckShortcuts: Equatable, Sendable {
    private var table: [DeckAction: [UInt16]]

    /// 기본 단축키: 설정 창 전부터 쓰던 고정 키와 제안 키(S·A, #33)
    public static let standard = DeckShortcuts(table: [
        .playPause: [49],          // Space
        .cue: [8],                 // C
        .hotCueA: [18, 83], .hotCueB: [19, 84], .hotCueC: [20, 85], .hotCueD: [21, 86],   // 1~4, 숫자 패드 1~4
        .hotCueE: [23, 87], .hotCueF: [22, 88], .hotCueG: [26, 89], .hotCueH: [28, 91],   // 5~8, 숫자 패드 5~8
        .memoryCue: [46, 50],      // M, `(한글 자판에선 ₩)
        .previousCue: [12],        // Q
        .nextCue: [14],            // E
        .nudgeBack: [123],         // ←
        .nudgeForward: [124],      // →
        .deleteCue: [51, 117],     // ⌫, ⌦
        .nextSuggestion: [1],      // S
        .acceptSuggestion: [0],    // A
        .loop: [37],               // L
        .loopHalve: [33],          // [
        .loopDouble: [30],         // ]
        .tapTempo: [17],           // T
        .zoomIn: [24, 69],         // =, 숫자 패드 +
        .zoomOut: [27, 78],        // -, 숫자 패드 −
    ])

    /// 곡 목록·창에서 확정·취소·이동에 쓰는 키(Return·Enter·Esc·Tab·↑↓·Home·End·Page Up/Down).
    /// 덱 동작에 주면 곡을 고르거나 칸을 빠져나올 수 없게 되어 막는다(#28 규칙).
    public static let reservedKeys: Set<UInt16> = [36, 76, 53, 48, 126, 125, 115, 119, 116, 121]

    public static func isReserved(_ keyCode: UInt16) -> Bool { reservedKeys.contains(keyCode) }

    public enum AssignError: Error, Equatable {
        case reserved
    }

    private init(table: [DeckAction: [UInt16]]) {
        self.table = table
    }

    /// 저장해 둔 바꾼 동작(`overrides`)을 기본 표 위에 얹는다. 모르는 동작·숫자가 아닌 값·예약 키·중복은 버린다.
    public init(overrides: [String: Any]?) {
        var table = Self.standard.table
        for action in DeckAction.allCases {
            guard let raw = overrides?[action.rawValue] as? [Any] else { continue }
            var keys: [UInt16] = []
            for case let code as Int in raw {
                guard let key = UInt16(exactly: code), !Self.isReserved(key), !keys.contains(key) else { continue }
                keys.append(key)
            }
            table[action] = keys
        }
        self.table = table
    }

    public func keys(for action: DeckAction) -> [UInt16] { table[action] ?? [] }

    /// 이 키를 받는 동작. 여럿이 겹치면 목록 위쪽 동작.
    public func action(for keyCode: UInt16) -> DeckAction? {
        DeckAction.allCases.first { keys(for: $0).contains(keyCode) }
    }

    /// 두 동작 이상에 지정된 키 → 그 동작들(목록 순서)
    public var conflicts: [UInt16: [DeckAction]] {
        var users: [UInt16: [DeckAction]] = [:]
        for action in DeckAction.allCases {
            for key in keys(for: action) { users[key, default: []].append(action) }
        }
        return users.filter { $0.value.count > 1 }
    }

    /// 이 동작의 키 중 다른 동작과 겹치는 것
    public func conflictingKeys(for action: DeckAction) -> [UInt16] {
        keys(for: action).filter { !otherActions(using: $0, besides: action).isEmpty }
    }

    public func otherActions(using keyCode: UInt16, besides action: DeckAction) -> [DeckAction] {
        DeckAction.allCases.filter { $0 != action && keys(for: $0).contains(keyCode) }
    }

    // MARK: 바꾸기

    public mutating func add(_ keyCode: UInt16, to action: DeckAction) throws {
        guard !Self.isReserved(keyCode) else { throw AssignError.reserved }
        if !keys(for: action).contains(keyCode) { table[action, default: []].append(keyCode) }
    }

    /// 키 하나를 다른 키로 바꾼다(자리는 그대로). 옛 키가 없으면 더한다.
    public mutating func replace(_ old: UInt16, with new: UInt16, in action: DeckAction) throws {
        guard !Self.isReserved(new) else { throw AssignError.reserved }
        var keys = keys(for: action)
        if let index = keys.firstIndex(of: old), !keys.contains(new) {
            keys[index] = new
        } else {
            keys.removeAll { $0 == old }
            if !keys.contains(new) { keys.append(new) }
        }
        table[action] = keys
    }

    public mutating func remove(_ keyCode: UInt16, from action: DeckAction) {
        table[action]?.removeAll { $0 == keyCode }
    }

    public mutating func reset(_ action: DeckAction) {
        table[action] = Self.standard.keys(for: action)
    }

    public mutating func resetAll() {
        self = .standard
    }

    public var isStandard: Bool { self == .standard }

    public func isStandard(_ action: DeckAction) -> Bool { keys(for: action) == Self.standard.keys(for: action) }

    /// 기본과 다른 동작만(저장용). 나중에 기본 키가 바뀌거나 동작이 늘어도 안 바꾼 동작은 새 기본을 따른다.
    public var overrides: [String: [Int]] {
        var result: [String: [Int]] = [:]
        for action in DeckAction.allCases where !isStandard(action) {
            result[action.rawValue] = keys(for: action).map(Int.init)
        }
        return result
    }
}
