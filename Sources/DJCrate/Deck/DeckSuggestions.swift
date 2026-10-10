import DJCDomain
import Foundation

/// 덱 제안 줄의 상태와 동작: 덱에 올린 곡의 게인·그리드·키 제안을 한곳에 모은다(문구 규칙은 `DeckSuggestion`).
/// 게인·그리드 제안은 덱 초안이라 덱이, 키 제안은 태그 초안이라 태그 편집 조각(`TagEditStore`)이 가진다. 어느 쪽이든 [적용]해야만
/// 초안이 되고(실행 취소 가능), [무시]한 제안은 곡마다 기억해 "무시한 제안 다시 보기"로 한 번에 되살린다.
/// 덱 본문이 목록 상태를 읽지 않도록 제안 줄 뷰 안에서만 만든다(태그를 고칠 때마다 덱 전체를 다시 그리지 않게).
@MainActor
struct DeckSuggestions {
    /// 그리드 제안 대신 보이는 그리드 상태
    enum GridStatus: Equatable {
        /// rekordbox 그리드가 없고 추정하는 중
        case estimating
        /// rekordbox 그리드가 없고 분석에 실패해 추정하지 못했다
        case failed
        /// 추정이 지금 그리드와 사실상 같다
        case matches
    }

    let deck: DeckModel
    let tags: TagEditStore

    var list: DeckSuggestionList {
        var candidates: [DeckSuggestion] = []
        var dismissed: Set<DeckSuggestion.Kind> = []
        if let gain = deck.gainSuggestionCandidate, let rekordbox = deck.rekordboxGainDB {
            candidates.append(.gain(gain, rekordbox: rekordbox, mismatch: deck.gainMismatchDB ?? 0))
            if deck.isGainSuggestionDismissed { dismissed.insert(.gain) }
        }
        if let grid = deck.gridSuggestionItem {
            candidates.append(grid)
            if deck.isGridSuggestionDismissed { dismissed.insert(.grid) }
        }
        if let row = keyRow {
            let estimate = keyEstimate(row)
            let fromFileTag = KeyPicker.suggestionSource([row]) == .fileTag
            if let key = tags.keySuggestion(estimate: estimate, rows: [row]) {
                candidates.append(.key(key, fromFileTag: fromFileTag))
            } else if let key = tags.dismissedKeySuggestion(estimate: estimate, rows: [row]) {
                candidates.append(.key(key, fromFileTag: fromFileTag))
                dismissed.insert(.key)
            }
        }
        return DeckSuggestionList(candidates, dismissed: dismissed)
    }

    var gridStatus: GridStatus? {
        if deck.needsGrid, deck.gridSuggestion == nil { return deck.analysisError == nil ? .estimating : .failed }
        if !deck.needsGrid, deck.gridSuggestion != nil, deck.gridSuggestionItem == nil { return .matches }
        return nil
    }

    /// rekordbox에 쓰는 동안: 줄은 그대로 두고 단추만 막는다(쓰는 동안 줄이 접혔다 펴지지 않게).
    var isLocked: Bool { deck.isWriteLocked || tags.isWritingRekordbox }

    func apply(_ kind: DeckSuggestion.Kind) {
        guard !isLocked else { return }
        switch kind {
        case .gain: deck.acceptGainSuggestion()
        case .grid: deck.applyGridSuggestion()
        case .key:
            guard let row = keyRow else { return }
            tags.applyKeySuggestion(estimate: keyEstimate(row), rows: [row])
        }
    }

    func dismiss(_ kind: DeckSuggestion.Kind) {
        guard !isLocked else { return }
        switch kind {
        case .gain: deck.dismissGainSuggestion()
        case .grid: deck.dismissGridSuggestion()
        case .key: if let row = keyRow { tags.dismissKeySuggestion(rows: [row]) }
        }
    }

    /// 이 곡에서 무시한 제안(게인·그리드·키)을 모두 다시 보인다. 다른 곡의 무시는 그대로다.
    func restoreDismissed() {
        guard !isLocked, let uuid = deck.row?.track.uuid else { return }
        deck.restoreGainSuggestion()
        deck.restoreGridSuggestion()
        tags.restoreKeySuggestion(uuid: uuid)
    }

    // MARK: 키 제안

    /// 키 제안을 볼 곡: 덱에 올린 곡. 목록에 같은 곡의 새 행이 있으면 그것을 본다(동기화로 rekordbox 키가 생겼으면
    /// 덱의 옛 행으로 제안하지 않고, 초안의 기준도 새 값이 되게).
    private var keyRow: TrackRow? {
        guard let row = deck.row else { return nil }
        if let fresh = tags.listedRow(uuid: row.track.uuid), fresh.id == row.id { return fresh }
        return row
    }

    /// 추가한 곡은 추가 목록의 키(음원 태그, 없으면 추가할 때의 추정), rekordbox 곡은 덱이 구한 주 조성.
    private func keyEstimate(_ row: TrackRow) -> String? {
        row.isStaged ? row.track.key : deck.estimatedKey(for: row.track.uuid)
    }
}
