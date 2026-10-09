import Foundation

/// 덱이 읽은 rekordbox 원본 그리드(분석 파일의 PQTZ)
public enum AnalysisGridRead: Sendable, Hashable {
    /// 분석 경로가 없거나 그 파일이 없다(rekordbox에서 분석하지 않은 곡)
    case missing
    /// 파일은 있지만 읽지 못했다(권한·형식)
    case unreadable
    /// 읽었지만 박이 하나도 없다
    case noBeats
    case grid(BeatGrid)
}

/// 덱에 올린 곡의 그리드 편집 진입 판정: 원본·저장해 둔 초안·곡 길이 → 덱이 쓸 초안·막힘 이유·출처 안내.
/// 곡을 불러올 때와 그리드를 고친 뒤 다시 판정할 때 같은 규칙을 쓴다.
public struct DeckGridGate: Sendable, Equatable {
    public var originalGrid: BeatGrid?
    public var gridDraft: GridDraft?
    public var blockedReason: String?
    /// 원본 그리드가 없을 때 그 이유(덱이 추정 그리드를 권할 때 보인다)
    public var sourceNotice: String?

    public init(trackUUID: String, read: AnalysisGridRead, savedDraft: GridDraft?, duration: Double) {
        let reason: String
        switch read {
        case let .grid(original):
            originalGrid = original
            blockedReason = Self.editBlockedReason(trackUUID: trackUUID, original: original, draft: savedDraft, duration: duration)
            gridDraft = savedDraft ?? GridDraft(trackUUID: trackUUID, grid: original)
            return
        case .missing:
            reason = String(ui: "rekordbox 분석 파일이 없으니 추정 그리드를 적용하거나 rekordbox에서 트랙 분석을 먼저 하세요")
        case .unreadable:
            reason = String(ui: "rekordbox 분석 파일을 읽지 못했으니 파일 접근 권한을 확인하거나 rekordbox에서 다시 트랙 분석을 하세요")
        case .noBeats:
            reason = String(ui: "rekordbox 분석 파일에 박 정보가 없으니 추정 그리드를 적용하거나 rekordbox에서 다시 트랙 분석을 하세요")
        }
        // 그리드가 없는 곡: 앞서 적용해 둔 추정 그리드 초안이 있으면 그것을 쓴다.
        gridDraft = savedDraft
        sourceNotice = reason
        if savedDraft == nil || savedDraft?.replacementSource != nil { blockedReason = reason }
    }

    /// 원본이 있는 곡에서 지금 초안으로 그리드를 편집할 수 없는 이유(없으면 nil).
    /// 편집하지 않은 상태에서 원본과 2ms 넘게 다르게 재현되면 막는다. 원본에 맞춰 승인한 대체 초안만 예외다.
    public static func editBlockedReason(trackUUID: String, original: BeatGrid, draft: GridDraft?, duration: Double) -> String? {
        let fresh = GridDraft(trackUUID: trackUUID, grid: original)
        let rebuilt = fresh.grid(duration: max(duration + 1, (original.beats.last?.time ?? 0) + 0.01))
        let worst = GridEditEligibility.reconstructionErrorMilliseconds(original: original, rebuilt: rebuilt)
        let replacement = draft.map { $0.trackUUID == trackUUID && $0.isVerifiedReplacement(of: original, duration: duration) } ?? false
        if draft?.replacementSource != nil, !replacement {
            return String(ui: "초안을 만든 뒤 rekordbox에서 그리드가 바뀌었으니 그리드 현재값 가져오기로 비교하세요")
        }
        if worst > 2, !replacement {
            return String(ui: "이 곡의 그리드는 템포 구간 \(fresh.segments.count)개로 정확히 재현되지 않으니(최대 \(worst, specifier: "%.0f")ms) 추정 그리드를 적용하거나 rekordbox에서 직접 편집하세요")
        }
        return nil
    }
}

public extension BeatGrid {
    /// `time`이 있는 템포 구간의 BPM(그 시각 또는 그 앞 박의 템포, 첫 박 앞이면 첫 박). 박 1ms 앞은 그 박으로 본다.
    func bpm(at time: Double) -> Double? {
        guard let first = beats.first else { return nil }
        let index = firstIndex(atOrAfter: time + 0.001)
        return index > 0 ? beats[index - 1].bpm : first.bpm
    }
}
