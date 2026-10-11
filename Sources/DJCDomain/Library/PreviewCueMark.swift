import Foundation

/// 큐 이름·ID는 그림에 필요 없다. 위치만 비교해 이름 편집 때 파형을 다시 만들지 않는다.
public struct PreviewCueMark: Hashable, Sendable {
    public let time: Double
    public let end: Double?
    public let hot: Bool

    public init(_ cue: EditableCue) {
        time = cue.time; end = cue.loop?.end
        if case .hot = cue.kind { hot = true } else { hot = false }
    }

    /// rekordbox 큐 → 눈금. 편집할 수 없는 큐(Kind 4)는 덱 목록처럼 뺀다
    public init?(_ cue: Cue) {
        guard let kind = EditableCue.Kind(rekordbox: cue.kind) else { return nil }
        time = Double(cue.inMsec) / 1000
        end = cue.isLoop ? Double(cue.outMsec) / 1000 : nil
        if case .hot = kind { hot = true } else { hot = false }
    }

    public static func current(saved: [Cue], draft: [Self]?) -> [Self] {
        // rekordbox 자동 큐도 메모리 큐로 보인다(#145, 덱 목록과 같다).
        draft ?? saved.compactMap(Self.init)
    }
}
