import Foundation

/// 프리셋마다 다른 문법을 공통 분류·표시 결과로 바꾼다.
public protocol CommentRule: Sendable {
    func evaluate(normalized text: String) -> CommentEvaluation
}

public extension CommentRule {
    func evaluate(_ text: String) -> CommentEvaluation {
        evaluate(normalized: CommentText.normalize(text))
    }
}

public struct CommentEvaluation: Sendable, Hashable {
    public enum Tone: Sendable { case matched, empty, info, residue, secondary }
    public let classification: String
    public let displayName: String
    public let tone: Tone
    public let isMatch: Bool
    public let isEmpty: Bool
    public let summary: String
    public let prefix: String?
    public let usages: [String]

    public init(classification: String, displayName: String, tone: Tone, isMatch: Bool,
                isEmpty: Bool, summary: String, prefix: String? = nil, usages: [String] = []) {
        self.classification = classification
        self.displayName = displayName
        self.tone = tone
        self.isMatch = isMatch
        self.isEmpty = isEmpty
        self.summary = summary
        self.prefix = prefix
        self.usages = usages
    }
}

public enum CommentPreset: String, CaseIterable, Sendable {
    case none, anisong

    public var title: String {
        switch self { case .none: String(ui: "없음"); case .anisong: String(ui: "애니송") }
    }

    public var rule: (any CommentRule)? {
        switch self { case .none: nil; case .anisong: AnisongCommentRule() }
    }
}
