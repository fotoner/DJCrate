import Foundation

/// 저장 큐에 맡기는 초안 종류(큐·그리드는 곡마다 파일, 게인은 모든 곡을 담은 파일 하나)
public enum DraftSaveKind: Hashable, Sendable {
    case cue, grid, gain
}

/// 초안 저장 실패. 메모리 입력은 남아 있어 다시 저장할 수 있다(#174).
public struct DraftSaveFailure: Equatable, Sendable {
    public var kind: DraftSaveKind
    public var trackUUID: String
    /// 실패한 입력의 저장 순번(뒤의 입력이 저장되면 해소된다)
    public var revision: UInt64
    /// 원인과 조치(개인 경로를 넣지 않는다)
    public var reason: String

    public init(kind: DraftSaveKind, trackUUID: String, revision: UInt64, reason: String) {
        self.kind = kind
        self.trackUUID = trackUUID
        self.revision = revision
        self.reason = reason
    }

    public var message: String {
        let title = switch kind {
        case .cue: String(ui: "큐 초안을 저장하지 못했습니다.")
        case .grid: String(ui: "그리드 초안을 저장하지 못했습니다.")
        case .gain: String(ui: "게인 초안을 저장하지 못했습니다.")
        }
        return title + " " + reason
    }

    /// 태그 초안 저장 실패 안내(태그는 곡마다 실패한 곡만 기록한다)
    public static var tagSaveMessage: String {
        String(ui: "태그 초안을 저장하지 못했으니 초안 폴더의 접근 권한을 확인한 뒤 동기화하거나 쓰기를 다시 시도하세요.")
    }
}
