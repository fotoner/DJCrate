import DJCDomain
import Foundation

/// 애니송 파트 라벨 v0 (휴리스틱, 미검증).
///
/// Music Understanding의 섹션에는 라벨이 없다. 섹션별 음량·보컬·드럼 에너지로
/// 사비 후보를 고르고, 순서로 1사비·2사비·라사비·간주를 붙인다.
/// 정확도 게이트(1사비·라사비 ±1마디 ≥ 70%)를 통과하기 전까지는 큐 시트 제안용이다.
public enum PartLabeler {
    /// 라벨·자리 값은 DJCDomain에 있다(#167, CLI가 값만 보인다)
    public typealias Label = PartLabel
    public typealias Marker = PartMarker

    /// 섹션 에너지 값은 DJCDomain에 있다(#167, 덱 화면이 그린다)
    public typealias SectionEnergy = DJCDomain.SectionEnergy

    public static func energies(_ analysis: PartAnalysis) -> [SectionEnergy] {
        let raw = analysis.sections.map { span in
            (span,
             PartAnalysis.mean(analysis.loudness, in: span),
             PartAnalysis.mean(analysis.vocal, in: span),
             PartAnalysis.mean(analysis.drum, in: span))
        }
        // 음량(LUFS)은 곡마다 범위가 달라서 곡 안에서 0~1로 정규화한다.
        let louds = raw.map(\.1)
        let lo = louds.min() ?? 0, hi = louds.max() ?? 1
        return raw.map { span, loud, vocal, drum in
            let normalized = hi > lo ? (loud - lo) / (hi - lo) : 0.5
            return SectionEnergy(span: span, loudness: loud, vocal: vocal, drum: drum,
                                 score: normalized * 0.5 + vocal * 0.3 + drum * 0.2)
        }
    }

    public static func label(_ analysis: PartAnalysis) -> [Marker] {
        let sections = energies(analysis).filter { $0.span.duration >= 8 }
        guard sections.count >= 3 else { return [] }

        // 사비 후보: 보컬이 있고 에너지가 곡 안 상위권인 섹션.
        let scores = sections.map(\.score).sorted()
        let threshold = scores[Int(Double(scores.count) * 0.55)]
        let choruses = sections.filter { $0.vocal >= 0.3 && $0.score >= threshold }
        guard let first = choruses.first else { return [] }

        func marker(_ label: Label, _ energy: SectionEnergy, _ confidence: Double) -> Marker {
            let time = analysis.snap(energy.span.start)
            return Marker(label: label, time: time, bar: analysis.barNumber(at: time), confidence: confidence)
        }

        var markers = [marker(.firstChorus, first, 0.5)]
        if choruses.count >= 2, let last = choruses.last, last.span.start > first.span.start {
            // 직전 사비와 라사비 사이에 에너지가 낮은 구간(간주·C메로)이 있어야 라사비로 본다.
            let before = sections.filter { $0.span.end <= last.span.start && $0.span.start >= first.span.end }
            let hasBreak = before.contains { $0.score < threshold }
            markers.append(marker(.lastChorus, last, hasBreak ? 0.5 : 0.3))
            if choruses.count >= 3 {
                markers.append(marker(.secondChorus, choruses[1], 0.4))
                // 간주: 2사비 뒤, 라사비 앞의 보컬이 약한 섹션.
                if let interlude = sections.first(where: {
                    $0.span.start >= choruses[1].span.end && $0.span.end <= last.span.start && $0.vocal < 0.25
                }) {
                    markers.append(marker(.interlude, interlude, 0.3))
                }
            }
        }
        return markers.sorted { $0.time < $1.time }
    }
}
