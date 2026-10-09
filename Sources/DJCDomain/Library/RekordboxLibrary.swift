import Foundation

/// 스냅샷에서 읽은 rekordbox 컬렉션(값). 읽기(`load(snapshot:)`)는 RekordboxKit이 한다.
public struct RekordboxLibrary: Sendable {
    /// tombstone(삭제 행)까지 포함한 전체 행. 코멘트 문법·사전 학습에만 쓴다.
    public let allTracks: [Track]
    public let cues: [Cue]
    /// ContentID → 재생 기록 수 (djmdSongHistory).
    public let playCounts: [String: Int]
    public let playlists: [RekordboxPlaylist]
    public let histories: [RekordboxHistory]
    /// ContentID → rekordbox 오토게인(djmdMixerParam)
    public var autoGains: [String: RekordboxAutoGain] = [:]
    /// ContentID → 살아 있는 그림 파일 행(`contentFile`의 `/PIONEER/Artwork/…`). 그림 초안의 base로 쓴다(#66).
    public var artworkFiles: [String: [ArtworkFileRow]] = [:]
    /// rekordbox 곡 색 목록(`djmdColor`의 살아 있는 줄, `SortKey` 순서, #65). 읽지 못했으면 비어 있다(앱은 rekordbox 기본 여덟 색을 쓴다).
    public var colors: [TrackColor] = []

    /// 실제 컬렉션. 제안·커버리지·백로그 집계는 이것만 대상으로 한다.
    public var tracks: [Track] { allTracks.filter { !$0.isDeleted } }

    public func cues(for track: Track) -> [Cue] { cuesByContent[track.id] ?? [] }

    private let cuesByContent: [String: [Cue]]

    public init(allTracks: [Track], cues: [Cue], playCounts: [String: Int], playlists: [RekordboxPlaylist] = [],
                histories: [RekordboxHistory] = []) {
        self.allTracks = allTracks
        self.cues = cues
        self.playCounts = playCounts
        self.playlists = playlists
        self.histories = histories
        self.cuesByContent = Dictionary(grouping: cues, by: \.contentID)
    }
}
