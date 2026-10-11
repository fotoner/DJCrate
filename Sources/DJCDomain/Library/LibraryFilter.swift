import Foundation

/// 앱과 CLI가 공유하는 컬렉션 필터. rawValue는 식별자로만 쓰고(바꾸면 저장한 선택을 잃는다), 화면에는 `title`을 쓴다.
public enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case emptyComment = "빈 코멘트 전체"
    case offConvention = "규칙 밖 코멘트"
    case noCues = "큐 없음"
    case played = "재생한 곡"
    case streaming = "스트리밍"
    case noBPM = "BPM·그리드 없음"
    case missingFile = "파일 없음"
    case tempoChange = "변속 곡"
    case all = "전체"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .emptyComment: String(ui: "빈 코멘트 전체")
        case .offConvention: String(ui: "규칙 밖 코멘트")
        case .noCues: String(ui: "큐 없음")
        case .played: String(ui: "재생한 곡")
        case .streaming: String(ui: "스트리밍")
        case .noBPM: String(ui: "BPM·그리드 없음")
        case .missingFile: String(ui: "파일 없음")
        case .tempoChange: String(ui: "변속 곡")
        case .all: String(ui: "전체")
        }
    }

    public var cliName: String {
        switch self {
        case .emptyComment: "empty-comment"
        case .offConvention: "off-convention"
        case .noCues: "no-cues"
        case .played: "played"
        case .streaming: "streaming"
        case .noBPM: "no-bpm"
        case .missingFile: "missing-file"
        case .tempoChange: "tempo-change"
        case .all: "all"
        }
    }

    /// 규칙이 있어야 고를 수 있는 필터. 빈 코멘트는 규칙과 상관없이 정리한 코멘트가 비었는지로 고른다(현황 집계와 같은 판정).
    public var requiresCommentRule: Bool { self == .offConvention }

    /// 사이드바에 보이는 필터. 스트리밍 곡을 숨기는 동안은 '스트리밍' 필터도 보이지 않는다.
    public static func visible(commentPreset: CommentPreset, hidingStreaming: Bool = false) -> [LibraryFilter] {
        allCases.filter { (!$0.requiresCommentRule || commentPreset.rule != nil) && !(hidingStreaming && $0 == .streaming) }
    }

    /// - Parameter fileMissing: 음원 파일을 찾지 못한 곡인지(`MissingFiles`). 스트리밍 곡은 세지 않는다.
    public func includes(track: Track, comment: CommentEvaluation?, hasCues: Bool, playCount: Int, tempoChanges: [Double],
                         fileMissing: Bool) -> Bool {
        switch self {
        case .emptyComment: CommentText.normalize(track.comment).isEmpty
        case .offConvention: comment.map { !$0.isEmpty && !$0.isMatch } ?? false
        case .noCues: !hasCues
        case .played: playCount > 0
        case .streaming: track.isStreaming
        case .noBPM: !track.isStreaming && (track.bpm ?? 0) <= 0
        case .missingFile: !track.isStreaming && fileMissing
        case .tempoChange: !tempoChanges.isEmpty
        case .all: true
        }
    }
}
