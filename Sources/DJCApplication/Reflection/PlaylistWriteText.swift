import DJCDomain
import Foundation

/// 재생 목록 편집을 반영 확인 창(막힌 편집)·결과에 보이는 말로 옮긴다.
public enum PlaylistWriteText {
    /// 편집 한 건이 바꾸는 것
    public static func change(_ edit: PlaylistEdit) -> String {
        switch edit {
        case let .create(_, _, isFolder, _): isFolder ? String(ui: "새 폴더 만들기") : String(ui: "새 재생 목록 만들기")
        case .rename: String(ui: "이름 바꾸기")
        case .move: String(ui: "다른 폴더로 옮기기")
        case .reorder: String(ui: "순서 바꾸기")
        case .delete: String(ui: "지우기")
        case let .addTracks(_, contentIDs): String(ui: "\(contentIDs.count)곡 넣기")
        case let .removeTracks(_, entries): String(ui: "\(entries.count)곡 빼기")
        case .moveTracks: String(ui: "곡 순서 바꾸기")
        }
    }

    /// "재생 목록 3건" — 확인 창 제목과 결과 제목
    public static func summary(_ count: Int) -> String { String(ui: "재생 목록 \(count)건") }

    /// 쓰지 않는 편집 한 줄
    public static func reason(_ outcome: PlaylistOutcome) -> String {
        // 줄 모양은 언어와 관계없고 내용만 번역한다.
        "• \(outcome.name): \(change(outcome.edit)) — \(outcome.reason ?? String(ui: "이유 없음"))"
    }

    /// 결과 한 줄
    public static func result(_ outcome: PlaylistOutcome) -> String {
        let change = change(outcome.edit)
        let text = switch outcome.status {
        case .written: String(ui: "재생 목록 쓰기 완료: \(change)")
        case .blocked: String(ui: "재생 목록 쓰지 않음(\(change)): \(outcome.reason ?? String(ui: "이유 없음"))")
        case .unchanged: String(ui: "재생 목록 변경 없음(\(change))")
        }
        return "• \(outcome.name) — " + text
    }
}
