import DJCApplication
import DJCDomain
import AppKit
import Foundation

/// 조성 흐름(추정): 크로마 + 그리드 마디 창
extension DeckModel {
    // MARK: 조성 흐름(추정)


    func keyName(for segment: KeySegment) -> String { KeyNotation.camelot(signature: segment.signature, minor: keyMinor) }

    /// 재생 위치의 조성(Camelot)
    func key(at time: Double) -> String? {
        guard let segment = keySegments.first(where: { time >= $0.start && time < $0.end }) ?? keySegments.last(where: { time >= $0.start })
        else { return row?.track.key }
        return keyName(for: segment)
    }

    /// 덱 제안 줄의 키 제안에 쓸 추정. 덱에 올린 곡의 것일 때만 돌려준다(앞 곡의 추정이 뒤 곡에 비치지 않게).
    func estimatedKey(for uuid: String) -> String? {
        guard let keyEstimate, keyEstimate.uuid == uuid, row?.track.uuid == uuid else { return nil }
        return keyEstimate.key
    }

    /// 크로마·그리드가 바뀌면 다시 계산한다(`AnalyzeDeckTrack.keyFlow`).
    func refreshKeySegments() {
        guard let chroma = keyChroma, !chroma.frames.isEmpty else {
            keySegments = []
            if keyEstimate != nil { keyEstimate = nil }
            return
        }
        // rekordbox 키가 빈 곡(추가한 곡 제외)만 주 조성을 키 제안으로 내놓는다. 헤더에 보이는 조성과 같은 계산이다.
        // 크로마는 덱이 지금 곡에서 구한 것만 들어온다(디코딩 결과는 곡이 바뀌면 버린다).
        let suggests = row.map { !$0.isStaged && ($0.track.key ?? "").isEmpty } ?? false
        let flow = analyzer.keyFlow(chroma: chroma, grid: grid, duration: duration, timelineOffset: timelineOffset,
                                    rekordboxKey: row?.track.key, suggestsMainKey: suggests)
        keyMinor = flow.minor
        keySegments = flow.segments
        var estimate: KeyEstimate?
        if let row, let key = flow.mainKey { estimate = KeyEstimate(uuid: row.track.uuid, key: key) }
        if keyEstimate != estimate { keyEstimate = estimate }
    }
}

/// 덱이 구한 곡의 주 조성(Camelot)과 그 곡
struct KeyEstimate: Equatable {
    var uuid: String
    var key: String
}
