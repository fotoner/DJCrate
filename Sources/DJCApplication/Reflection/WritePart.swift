import DJCDomain
import Foundation

/// 한 번에 쓰는 것의 종류. 종류 이름이 문장 안에서 어순·조사가 달라지므로 종류마다 문장 전체를 번역한다.
public enum WritePart: Hashable, Sendable {
    case cue, grid, analysis, gain, tag, artwork, merge

    /// "큐 3곡" — 확인 창 제목과 결과 제목에 쓴다.
    public func summary(_ count: Int) -> String {
        switch self {
        case .cue: String(ui: "큐 \(count)곡")
        case .grid: String(ui: "그리드 \(count)곡")
        case .analysis: String(ui: "분석 \(count)곡")
        case .gain: String(ui: "게인 \(count)곡")
        case .tag: String(ui: "태그 \(count)곡")
        case .artwork: String(ui: "앨범아트 \(count)곡")
        case .merge: String(ui: "합치기 \(count)묶음")
        }
    }

    public var written: String {
        switch self {
        case .cue: String(ui: "큐 쓰기 완료")
        case .grid: String(ui: "그리드 쓰기 완료")
        case .analysis: String(ui: "분석 쓰기 완료")
        case .gain: String(ui: "게인 쓰기 완료")
        case .tag: String(ui: "태그 쓰기 완료")
        case .artwork: String(ui: "앨범아트 쓰기 완료")
        case .merge: String(ui: "합치기 쓰기 완료")
        }
    }

    public func blocked(_ reason: String) -> String {
        switch self {
        case .cue: String(ui: "큐 쓰지 않음: \(reason)")
        case .grid: String(ui: "그리드 쓰지 않음: \(reason)")
        case .analysis: String(ui: "분석 쓰지 않음: \(reason)")
        case .gain: String(ui: "게인 쓰지 않음: \(reason)")
        case .tag: String(ui: "태그 쓰지 않음: \(reason)")
        case .artwork: String(ui: "앨범아트 쓰지 않음: \(reason)")
        case .merge: String(ui: "합치지 않음: \(reason)")
        }
    }

    public var unchanged: String {
        switch self {
        case .cue: String(ui: "큐 변경 없음")
        case .grid: String(ui: "그리드 변경 없음")
        case .analysis: String(ui: "분석 변경 없음")
        case .gain: String(ui: "게인 변경 없음")
        case .tag: String(ui: "태그 변경 없음")
        case .artwork: String(ui: "앨범아트 변경 없음")
        case .merge: String(ui: "합치기 변경 없음")
        }
    }
}
