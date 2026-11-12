import DJCDomain
import Foundation

/// 사이드바 재생 기록 줄의 저장 상태 표시(#311). 출처는 줄 아이콘(USB·LINK)이 보이고, 상태는 이 표시가 보인다.
/// 툴팁은 상태 낱말 한 줄이고, 할 일이 있는 상태에만 할 일을 붙인다(STR-13).
struct HistoryStatusMark: Equatable {
    /// 줄에 보일 아이콘(SF Symbol)
    let symbol: String
    /// 저장 대기 표식(`DraftMark`)과 같은 초안 색을 쓰는지. 아니면 보조색
    let usesDraftColor: Bool
    /// 상태 낱말(VoiceOver 이름)
    let word: String
    /// 툴팁: 상태 낱말, 할 일이 있으면 뒤에 붙인다
    let help: String

    /// 같은 낱말을 쓰는 상태(저장 안 함 셋)는 아이콘도 같다. 할 일이 붙는 곳은 연결 중 LINK 기록과,
    /// 같은 곡이 두 번 든 USB 기록(LINK 기록은 USB를 꽂아 가져올 수 없어 할 일이 없다)뿐이다
    static func of(_ status: ArchivedHistoryStatus, isLink: Bool) -> HistoryStatusMark {
        switch status {
        case .recording:
            let word = String(ui: "기록 중")
            return HistoryStatusMark(symbol: "record.circle", usesDraftColor: false, word: word,
                                     help: String(ui: "기록 중 · LINK를 끄면 저장 대기에 오릅니다"))
        case .pending:
            return HistoryStatusMark(symbol: DraftMark.symbol, usesDraftColor: true, word: DraftMark.spoken, help: DraftMark.spoken)
        case .written:
            let word = String(ui: "저장함")
            return HistoryStatusMark(symbol: "checkmark.circle", usesDraftColor: false, word: word, help: word)
        case .excluded, .noCollectionTracks:
            return notSaved(help: nil)
        case .repeatedTracks:
            return notSaved(help: isLink ? nil : String(ui: "저장 안 함 · rekordbox에서 USB를 연결해 직접 가져오세요"))
        case .notInRekordbox:
            let word = String(ui: "rekordbox에 없음")
            return HistoryStatusMark(symbol: "circle.dashed", usesDraftColor: false, word: word, help: word)
        }
    }

    private static func notSaved(help: String?) -> HistoryStatusMark {
        let word = String(ui: "저장 안 함")
        return HistoryStatusMark(symbol: "minus.circle", usesDraftColor: false, word: word, help: help ?? word)
    }
}
