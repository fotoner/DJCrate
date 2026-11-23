import DJCDomain
import Foundation

extension DraftStore {
    /// 초안 하나의 지금 내용의 해시(디스크에 있는 내용. 저장 큐에 걸린 입력은 `flush()` 뒤에 본다). 초안이 없거나 읽지 못하면 nil.
    /// 해시 함수는 도장을 적을 때와 같다(곡 초안은 `DraftContentHash(of:)`, 그림은 `DraftContentHash(artwork:)`)
    public func currentHash(_ key: DraftKey) -> DraftContentHash? {
        switch key.kind {
        case .cue: cueDraft(key.id).flatMap { try? DraftContentHash(of: $0) }
        case .grid: gridDraft(key.id).flatMap { try? DraftContentHash(of: $0) }
        case .tag: tagDraft(key.id).flatMap { try? DraftContentHash(of: $0) }
        case .gain: (try? gainDrafts())?[key.id].flatMap { try? DraftContentHash(of: $0) }
        case .artwork: (try? artworkEdit(key.id)).flatMap { try? DraftContentHash(artwork: $0) }
        case .merge: mergeDrafts().first { $0.id == key.id }.flatMap { try? DraftContentHash(of: $0) }
        }
    }

    /// 곡 초안의 제안 사유(R5). nil이면 자동 저장 대상이다(사람 편집만 들고 해시가 맞는다). 초안이 없으면 nil이다.
    /// 도장은 디스크의 것이라 저장 큐에 걸린 저장은 `flush()` 뒤에 본다
    public func suggestion(_ key: DraftKey) -> DraftSuggestion? {
        guard let current = currentHash(key) else { return nil }
        return DraftSuggestion.judge(stamp: stamp(key), currentHash: current)
    }

    /// 재생 목록 단계별 제안 사유(`playlistDraft().steps`와 같은 차례). nil인 단계는 자동 저장 대상이다.
    /// 단계 하나라도 제안이면 같은 목록에 닿는 단계를 함께 자동으로 쓰지 않는 판정은 엔진이 한다(R4·R14)
    public func playlistSuggestions() -> [DraftSuggestion?] {
        let draft = playlistDraft()
        let stamps = playlistStamps()
        return draft.steps.indices.map { index in
            let hash = try? DraftContentHash(step: draft.steps[index], in: draft)
            return DraftSuggestion.judge(stamp: stamps.indices.contains(index) ? stamps[index] : nil, currentHash: hash)
        }
    }
}
