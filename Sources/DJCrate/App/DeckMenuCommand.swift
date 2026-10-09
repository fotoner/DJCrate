import DJCDomain
import Foundation

/// 메뉴에는 키 이름만 표시한다. 실제 키 입력은 포커스·누르기/떼기를 아는 KeyRouter가 맡는다.
enum DeckMenuCommand: Hashable {
    case action(DeckAction)
    case deleteHotCue(Int), moveHotCue(Int)
    case deleteMemoryCue
    /// ⇧←→: 선택한 큐 또는 재생 위치를 1마디
    case stepBar(forward: Bool)
    /// ⇧S
    case previousSuggestion

    static func actions(in group: DeckAction.Group) -> [DeckAction] {
        DeckAction.allCases.filter { $0.group == group }
    }

    /// 핫큐 밖에서 Shift와 함께 누르는 동작(메뉴에서 원래 동작 바로 아래에 둔다)
    static func variants(after action: DeckAction) -> [DeckMenuCommand] {
        switch action {
        case .memoryCue: [.deleteMemoryCue]
        case .nudgeBack: [.stepBar(forward: false)]
        case .nudgeForward: [.stepBar(forward: true)]
        case .nextSuggestion: [.previousSuggestion]
        default: []
        }
    }

    var title: String {
        switch self {
        case .action(let action): action.title
        case .deleteHotCue: String(ui: "지우기")
        case .moveHotCue: String(ui: "플레이헤드로 옮기기")
        case .deleteMemoryCue: String(ui: "이 자리 메모리 큐 지우기")
        case .stepBar(let forward): forward ? String(ui: "1마디 뒤로(선택한 큐 또는 재생 위치)") : String(ui: "1마디 앞으로(선택한 큐 또는 재생 위치)")
        case .previousSuggestion: String(ui: "이전 제안으로")
        }
    }

    func keyLabel(shortcuts: DeckShortcuts) -> String {
        let action: DeckAction
        let shift: Bool
        switch self {
        case .action(let value): action = value; shift = false
        case .deleteHotCue(let slot):
            guard let value = DeckAction.allCases.first(where: { $0.hotCueSlot == slot }) else { return "" }
            action = value; shift = true
        case .deleteMemoryCue: action = .memoryCue; shift = true
        case .stepBar(let forward): action = forward ? .nudgeForward : .nudgeBack; shift = true
        case .previousSuggestion: action = .nextSuggestion; shift = true
        case .moveHotCue: return ""
        }
        return shortcuts.keys(for: action).map { (shift ? "⇧" : "") + KeyLabel.name(for: $0) }.joined(separator: " · ")
    }

    @MainActor func isEnabled(on deck: DeckModel) -> Bool {
        guard deck.row != nil, !deck.isWriteLocked else { return false }
        switch self {
        case .action(.playPause), .action(.cue), .action(.previousCue), .action(.nextCue):
            return deck.canPlay
        case .action(.nudgeBack), .action(.nudgeForward), .stepBar:
            // 선택한 큐가 없으면 재생 위치를 옮긴다(`DeckModel.beatJump`와 같은 조건).
            return deck.cue(deck.selectedCueID) != nil || deck.canPlay || deck.grid != nil
        case .action(.deleteCue):
            return deck.cue(deck.selectedCueID) != nil
        case .action(.nextSuggestion), .action(.acceptSuggestion), .previousSuggestion:
            return !deck.suggestions.isEmpty
        case .deleteHotCue(let slot), .moveHotCue(let slot):
            return deck.hotCue(slot: slot) != nil
        case .deleteMemoryCue:
            return deck.draft?.memoryCue(near: [deck.currentTime, deck.snapped(deck.currentTime)], closestTo: deck.currentTime) != nil
        default:
            return true
        }
    }

    @MainActor func perform(on deck: DeckModel) {
        guard isEnabled(on: deck) else { return }
        switch self {
        case .deleteHotCue(let slot): deck.deleteHotCue(slot: slot)
        case .moveHotCue(let slot): deck.moveHotCueToPlayhead(slot: slot)
        case .deleteMemoryCue: deck.deleteMemoryCue(at: deck.currentTime)
        case .stepBar(let forward): deck.step(beats: forward ? BeatJump.beatsPerBar : -BeatJump.beatsPerBar)
        case .previousSuggestion: deck.jumpToSuggestion(forward: false)
        case .action(let action):
            if let slot = action.hotCueSlot { deck.pressHotCue(slot: slot); return }
            switch action {
            case .playPause: deck.togglePlay()
            // 메뉴에는 누르고 있기 동작이 없으므로 클릭 한 번처럼 떼기까지 마친다.
            case .cue: deck.cueDown(); deck.cueUp()
            case .previousCue: deck.jumpToCue(forward: false)
            case .nextCue: deck.jumpToCue(forward: true)
            case .memoryCue: deck.addMemoryCue()
            case .nudgeBack: deck.step(beats: -1)
            case .nudgeForward: deck.step(beats: 1)
            case .deleteCue: _ = deck.deleteSelectedCue()
            case .nextSuggestion: deck.jumpToSuggestion(forward: true)
            case .acceptSuggestion: deck.acceptNearestSuggestion()
            case .loop: deck.toggleLoop()
            case .loopHalve: deck.resizeLoop(-1)
            case .loopDouble: deck.resizeLoop(1)
            case .tapTempo: deck.tapTempo()
            case .zoomIn: deck.zoom(by: 0.8)
            case .zoomOut: deck.zoom(by: 1.25)
            case .hotCueA, .hotCueB, .hotCueC, .hotCueD, .hotCueE, .hotCueF, .hotCueG, .hotCueH: break
            }
        }
    }
}
