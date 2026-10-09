import DJCDomain
import Foundation

/// 막힌 초안 복구(#232)가 줄로 나누는 초안 종류
public enum DraftRecoveryKind: CaseIterable, Sendable {
    case tags, cues, grid
    public var label: String { switch self { case .tags: String(ui: "태그"); case .cues: String(ui: "큐"); case .grid: String(ui: "그리드") } }
    /// 목록·태그 인스펙터·편집 창이 같은 문구를 쓴다(번역에서 단수·복수가 갈리지 않게 종류마다 한 문장).
    public var recoveryButtonTitle: String {
        switch self {
        case .tags: String(ui: "태그 현재값 가져오기…")
        case .cues: String(ui: "큐 현재값 가져오기…")
        case .grid: String(ui: "그리드 현재값 가져오기…")
        }
    }
}

/// 미리 보기에서 막힌 초안: 곡마다 막힌 종류, 막힌 재생 목록이 있는지
public struct BlockedDrafts: Equatable, Sendable {
    public var kinds: [String: Set<DraftRecoveryKind>]
    public var playlists: Bool

    public init(kinds: [String: Set<DraftRecoveryKind>], playlists: Bool) {
        self.kinds = kinds
        self.playlists = playlists
    }

    public init(report: RekordboxWriteReport) {
        var kinds: [String: Set<DraftRecoveryKind>] = [:]
        for outcome in report.tagBlocked { kinds[outcome.trackUUID, default: []].insert(.tags) }
        for outcome in report.blocked { kinds[outcome.trackUUID, default: []].insert(.cues) }
        for outcome in report.gridBlocked + report.analysisBlocked { kinds[outcome.trackUUID, default: []].insert(.grid) }
        self.init(kinds: kinds, playlists: !report.playlistBlocked.isEmpty)
    }
}
