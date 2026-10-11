@testable import DJCDomain
import Testing

@Suite("덱 단축키 표")
struct DeckShortcutsTests {
    /// 설정 창 전 KeyRouter에 고정돼 있던 표(키 위치 → 이름, 숫자 키 → 핫큐 칸)와 ←→⌫⌦·Space.
    static func legacyAction(for keyCode: UInt16) -> DeckAction? {
        switch keyCode {
        case 49: return .playPause
        case 8: return .cue
        case 46, 50: return .memoryCue
        case 17: return .tapTempo
        case 37: return .loop
        case 33: return .loopHalve
        case 30: return .loopDouble
        case 12: return .previousCue
        case 14: return .nextCue
        case 24, 69: return .zoomIn
        case 27, 78: return .zoomOut
        case 123: return .nudgeBack
        case 124: return .nudgeForward
        case 51, 117: return .deleteCue
        case 1: return .nextSuggestion      // S, #33에서 더함
        case 0: return .acceptSuggestion    // A, #33에서 더함
        case 18, 83: return .hotCueA
        case 19, 84: return .hotCueB
        case 20, 85: return .hotCueC
        case 21, 86: return .hotCueD
        case 23, 87: return .hotCueE
        case 22, 88: return .hotCueF
        case 26, 89: return .hotCueG
        case 28, 91: return .hotCueH
        default: return nil
        }
    }

    @Test func 기본_표는_예전_고정_단축키와_같다() {
        let standard = DeckShortcuts.standard
        for keyCode in UInt16(0)...UInt16(255) {
            #expect(standard.action(for: keyCode) == Self.legacyAction(for: keyCode), "키 \(keyCode)")
        }
        #expect(standard.conflicts.isEmpty)
        #expect(standard.isStandard)
    }

    @Test func 핫큐_칸은_A부터_H() {
        #expect(DeckAction.hotCueA.hotCueSlot == 0)
        #expect(DeckAction.hotCueH.hotCueSlot == 7)
        #expect(DeckAction.cue.hotCueSlot == nil)
        #expect(DeckAction.allCases.compactMap(\.hotCueSlot) == Array(0..<8))
    }

    @Test func 키를_바꾸면_새_키로_찾고_옛_키는_비운다() throws {
        var shortcuts = DeckShortcuts.standard
        try shortcuts.replace(8, with: 7, in: .cue)   // C → X
        #expect(shortcuts.action(for: 7) == .cue)
        #expect(shortcuts.action(for: 8) == nil)
        #expect(shortcuts.keys(for: .cue) == [7])
        #expect(!shortcuts.isStandard)
        #expect(!shortcuts.isStandard(.cue))
        #expect(shortcuts.isStandard(.playPause))
    }

    @Test func 한_동작에_키를_더하고_뺀다() throws {
        var shortcuts = DeckShortcuts.standard
        try shortcuts.add(35, to: .playPause)   // P
        #expect(shortcuts.keys(for: .playPause) == [49, 35])
        try shortcuts.add(35, to: .playPause)   // 같은 키는 한 번만
        #expect(shortcuts.keys(for: .playPause) == [49, 35])
        shortcuts.remove(49, from: .playPause)
        #expect(shortcuts.keys(for: .playPause) == [35])
        #expect(shortcuts.action(for: 49) == nil)
        shortcuts.remove(35, from: .playPause)
        #expect(shortcuts.keys(for: .playPause).isEmpty)
    }

    @Test(arguments: [36, 76, 53, 48, 126, 125, 115, 119, 116, 121] as [UInt16])
    func 목록_확정_취소_탐색_키는_지정할_수_없다(_ keyCode: UInt16) {
        var shortcuts = DeckShortcuts.standard
        #expect(DeckShortcuts.isReserved(keyCode))
        #expect(throws: DeckShortcuts.AssignError.reserved) { try shortcuts.add(keyCode, to: .cue) }
        #expect(throws: DeckShortcuts.AssignError.reserved) { try shortcuts.replace(8, with: keyCode, in: .cue) }
        #expect(shortcuts == .standard)
    }

    @Test func 기본_키에는_예약_키가_없다() {
        for action in DeckAction.allCases {
            #expect(DeckShortcuts.standard.keys(for: action).allSatisfy { !DeckShortcuts.isReserved($0) })
        }
    }

    @Test func 겹친_키를_찾고_목록_위쪽_동작이_받는다() throws {
        var shortcuts = DeckShortcuts.standard
        try shortcuts.add(46, to: .tapTempo)   // M: 메모리 큐와 겹침
        #expect(shortcuts.conflicts == [46: [.memoryCue, .tapTempo]])
        #expect(shortcuts.conflictingKeys(for: .tapTempo) == [46])
        #expect(shortcuts.conflictingKeys(for: .memoryCue) == [46])
        #expect(shortcuts.conflictingKeys(for: .cue).isEmpty)
        #expect(shortcuts.otherActions(using: 46, besides: .tapTempo) == [.memoryCue])
        #expect(shortcuts.action(for: 46) == .memoryCue)
        // 겹침을 풀면 나머지가 받는다
        shortcuts.remove(46, from: .memoryCue)
        #expect(shortcuts.conflicts.isEmpty)
        #expect(shortcuts.action(for: 46) == .tapTempo)
    }

    @Test func 동작_하나와_전체를_기본값으로_되돌린다() throws {
        var shortcuts = DeckShortcuts.standard
        try shortcuts.replace(8, with: 7, in: .cue)
        shortcuts.remove(49, from: .playPause)
        shortcuts.reset(.cue)
        #expect(shortcuts.keys(for: .cue) == [8])
        #expect(shortcuts.keys(for: .playPause).isEmpty)
        shortcuts.resetAll()
        #expect(shortcuts == .standard)
    }

    @Test func 바꾼_동작만_저장하고_다시_읽으면_같다() throws {
        #expect(DeckShortcuts.standard.overrides.isEmpty)
        var shortcuts = DeckShortcuts.standard
        try shortcuts.replace(8, with: 7, in: .cue)
        shortcuts.remove(49, from: .playPause)
        try shortcuts.add(35, to: .playPause)
        shortcuts.remove(123, from: .nudgeBack)
        #expect(shortcuts.overrides == ["cue": [7], "playPause": [35], "nudgeBack": []])
        #expect(DeckShortcuts(overrides: shortcuts.overrides) == shortcuts)
        // 다른 동작으로 옮겼다가 기본으로 돌리면 저장할 것이 없다
        shortcuts.resetAll()
        #expect(shortcuts.overrides.isEmpty)
    }

    @Test func 저장값이_이상하면_그_부분만_버린다() {
        let stored: [String: Any] = [
            "cue": [7, 7, 36],               // 중복·예약 키(Return)는 뺀다
            "playPause": ["P"],              // 숫자가 아니면 뺀다
            "nextCue": 14,                   // 배열이 아니면 기본값
            "hotCueA": [6, 70_000, -1],      // 키 코드 범위 밖은 뺀다
            "someFutureAction": [1],         // 모르는 동작은 무시
        ]
        let shortcuts = DeckShortcuts(overrides: stored)
        #expect(shortcuts.keys(for: .cue) == [7])
        #expect(shortcuts.keys(for: .playPause).isEmpty)
        #expect(shortcuts.keys(for: .nextCue) == [14])
        #expect(shortcuts.keys(for: .hotCueA) == [6])
        // 저장되지 않은 동작은 기본값(나중에 새 동작이 생겨도 기본 키를 받는다)
        #expect(shortcuts.keys(for: .loop) == [37])
        #expect(DeckShortcuts(overrides: nil) == .standard)
    }

    @Test func 키_이름은_자리_기준으로_보인다() {
        #expect(KeyLabel.name(for: 8) == "C")
        #expect(KeyLabel.name(for: 49) == "Space")
        #expect(KeyLabel.name(for: 50) == "`")
        #expect(KeyLabel.name(for: 18) == "1")
        #expect(KeyLabel.name(for: 83) == "숫자패드 1")
        #expect(KeyLabel.name(for: 69) == "숫자패드 +")
        #expect(KeyLabel.name(for: 123) == "←")
        #expect(KeyLabel.name(for: 51) == "⌫")
        #expect(KeyLabel.name(for: 117) == "⌦")
        #expect(KeyLabel.name(for: 122) == "F1")
        #expect(KeyLabel.name(for: 36) == "Return")
        #expect(KeyLabel.name(for: 250) == "키 250")
    }

    @Test func 기본_키는_모두_이름이_있다() {
        for action in DeckAction.allCases {
            #expect(!action.title.isEmpty)
            for key in DeckShortcuts.standard.keys(for: action) {
                #expect(!KeyLabel.name(for: key).hasPrefix("키 "), "\(action) \(key)")
            }
        }
    }
}
