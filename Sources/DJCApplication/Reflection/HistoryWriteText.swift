import DJCDomain
import Foundation

/// 쓰기 대기 재생 기록(USB에서 보존한 기록, #43)의 rekordbox 쓰기 결과를 확인 창·결과에 보이는 말로 옮긴다(`PlaylistWriteText`와 같은 모양).
public enum HistoryWriteText {
    public typealias Outcome = RekordboxHistoryOutcome

    /// 쓴 결과 + 미리 보기에서 막혀 넘기지 않은 기록(쓰기에는 미리 보기에서 쓸 수 있던 기록만 넘긴다, 곡 초안 결과와 같다)
    public static func merged(_ report: RekordboxWriteReport, preview: RekordboxWriteReport) -> [Outcome] {
        let actual = report.historyOutcomes ?? []
        let seen = Set(actual.map(\.id))
        return actual + (preview.historyOutcomes ?? []).filter { $0.status != .written && !seen.contains($0.id) }
    }

    /// "재생 기록 2건" — 확인 창 제목과 결과 제목. 결과 경고 문장("…은 쓰지 않았습니다")의 조사와 맞게 "건"으로 센다
    public static func summary(_ count: Int) -> String { String(ui: "재생 기록 \(count)건") }

    /// 쓰지 않는 기록 한 줄(확인 창)
    public static func reason(_ outcome: Outcome) -> String {
        // 줄 모양은 언어와 관계없고 내용만 번역한다.
        "• \(outcome.name): \(outcome.reason ?? String(ui: "이유 없음"))"
    }

    /// 결과 한 줄
    public static func result(_ outcome: Outcome) -> String {
        let text: String
        if outcome.status == .written {
            text = outcome.skipped > 0
                ? String(ui: "재생 기록 쓰기 완료: \(outcome.entries)곡 · 컬렉션에 없는 \(outcome.skipped)곡은 뺐습니다")
                : String(ui: "재생 기록 쓰기 완료: \(outcome.entries)곡")
        } else if outcome.status == .unchanged {
            text = String(ui: "rekordbox에 이미 있는 재생 기록입니다")
        } else {
            text = String(ui: "재생 기록 쓰지 않음: \(outcome.reason ?? String(ui: "이유 없음"))")
        }
        return "• \(outcome.name) — " + text
    }
}
