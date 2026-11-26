import Foundation

/// 곡 편집 창 두 줄 위에서 포인터가 가리키는 것. 커서 모양과 가장자리 핸들을 정한다(글로 알리지 않는다).
/// 뷰는 좌표를 시각으로 바꿔 넘기기만 한다. 누르기·끌기 규칙(`EditPointer`)과 같은 자리 판정을 쓴다.
public enum EditHover: Sendable, Equatable {
    /// 원곡 파형 위: 끌면 마디 구간 고르기
    case waveform
    /// 원곡에서 고른 구간 위: 아래로 끌면 결과에 넣기
    case selection
    /// 결과 클립 가운데(클립 순서): 끌면 순서 바꾸기
    case clip(Int)
    /// 결과 클립 가장자리: 끌면 마디 줄에 붙여 다듬기
    case edge(EditEdgeHit)
}

public extension EditPointerContext {
    /// 원곡 줄 위의 포인터. 위 눈금은 재생선만 옮기고 편집할 수 없는 곡은 가리키는 것이 없다.
    func sourceHover(at time: Double, inRuler: Bool) -> EditHover? {
        guard layout != nil, !inRuler else { return nil }
        return selectionContains(time) ? .selection : .waveform
    }

    /// 결과 줄 위의 포인터. `secondsPerPoint`는 지금 확대에서 한 포인트의 길이(초)라 가장자리를 잡는 폭을 시각으로 바꾼다.
    /// 눌렀을 때 다듬기·옮기기가 되는 자리만 가리킨다(`EditPointer.output`과 같은 판정).
    func outputHover(atOutput time: Double, inRuler: Bool, secondsPerPoint: Double) -> EditHover? {
        guard !inRuler, !clips.isEmpty else { return nil }
        if let hit = clips.edge(atOutput: time, tolerance: EditPointer.edgeReach * secondsPerPoint), entries.indices.contains(hit.clip) {
            return .edge(hit)
        }
        guard let index = clips.clipIndex(atOutput: time), entries.indices.contains(index) else { return nil }
        return .clip(index)
    }
}
