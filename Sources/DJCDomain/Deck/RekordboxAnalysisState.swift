import Foundation

/// 덱에 올린 곡의 rekordbox 분석 파일 상태. 분석 파일이 없는 곡과 파형 파일이 빠진 곡은 그리드 쓰기 조건이 다르다.
/// 곡을 불러올 때 읽기 포트(`TrackAssetReader.analysisState`)가 쓰기 대상 share에서 함께 읽는다(뷰가 파일을 보지 않게, #167).
public enum RekordboxAnalysisState: Sendable, Equatable {
    /// 분석 경로가 빈 곡. `attachesAnalysis`면 그리드 초안을 쓸 때 분석 파일을 붙인다.
    case notAnalyzed(attachesAnalysis: Bool)
    /// 분석 경로는 있는데 파형 파일(.EXT)이 없다(rekordbox 분석이 끝나지 않은 곡)
    case waveformMissing
    case ready

    /// 덱 머리의 경고(제목·도움말). 쓸 수 있는 곡이면 nil
    public var note: (title: String, help: String)? {
        switch self {
        case .notAnalyzed(let attaches):
            (String(ui: "rekordbox 분석 전"), attaches
                ? String(ui: "그리드 초안을 쓰면 이 미분석 곡에 파형·그리드·오토게인 분석 파일을 붙입니다.")
                : String(ui: "rekordbox가 이 곡을 아직 분석하지 않았습니다. rekordbox에서 트랙 분석을 먼저 해야 그리드를 쓸 수 있습니다"))
        case .waveformMissing:
            (String(ui: "rekordbox 분석 전 · 파형 없음"),
             String(ui: "rekordbox 분석이 끝나지 않은 곡입니다(파형 파일 없음). rekordbox에서 트랙 분석을 다시 해야 그리드를 쓸 수 있습니다"))
        case .ready:
            nil
        }
    }
}
