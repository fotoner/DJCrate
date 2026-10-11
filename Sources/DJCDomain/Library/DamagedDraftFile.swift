import Foundation

/// 읽지 못해 `damaged-drafts`에 옮겨 둔 초안 파일 하나(#174)
public struct DamagedDraftFile: Equatable, Sendable {
    /// 원래 자리(데이터 폴더 기준, 예: `cue-drafts/<UUID>.json`)
    public var name: String
    public var preserved: URL
    /// 곡 하나의 초안이면 그 곡 UUID(게인·재생 목록처럼 한 파일에 모은 초안은 nil)
    public var trackUUID: String?

    public init(name: String, preserved: URL, trackUUID: String?) {
        self.name = name
        self.preserved = preserved
        self.trackUUID = trackUUID
    }
}

/// 데이터 폴더의 초안 파일·폴더 이름(파일 위치 규칙은 DJCStorage `DraftLocations`가 이 이름으로 정한다)
public enum DraftFileNames {
    public static let cue = "cue-drafts"
    public static let grid = "grid-drafts"
    public static let tag = "tag-drafts"
    public static let artwork = "artwork-drafts"
    public static let gain = "gain-drafts.json"
    public static let playlist = "playlist-drafts.json"
    public static let merge = "merge-drafts.json"
    public static let staged = "staged.json"
}

extension DamagedDraftFile {
    /// 옮긴 파일의 종류(원래 자리로 가른다)
    public enum Kind: Sendable, Equatable {
        case cue, grid, tag, artwork, gain, playlist, merge, staged
    }

    public var kind: Kind? {
        switch name {
        case DraftFileNames.gain: return .gain
        case DraftFileNames.playlist: return .playlist
        case DraftFileNames.merge: return .merge
        case DraftFileNames.staged: return .staged
        default: break
        }
        switch name.split(separator: "/").first.map(String.init) ?? "" {
        case DraftFileNames.cue: return .cue
        case DraftFileNames.grid: return .grid
        case DraftFileNames.tag: return .tag
        case DraftFileNames.artwork: return .artwork
        default: return nil
        }
    }
}
