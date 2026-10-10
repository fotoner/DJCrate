import DJCDomain
import Foundation
import Observation

/// '재생 목록에 넣기…' 시트의 화면 모델(#249). 연 때 고른 곡과 찾는 말·고른 줄을 들고, 고른 목록에 곡을 넣는다.
/// 고를 목록 규칙(찾기, 최근 목록 먼저)은 DJCDomain `PlaylistChoices`가 한다.
@MainActor @Observable
final class PlaylistPickerModel {
    var query = ""
    var selection: String?
    @ObservationIgnored let tracks: [TrackRow]
    /// 지금 고를 수 있는 목록(시트를 연 동안 재생 목록이 바뀌면 따라간다)
    @ObservationIgnored private let source: @MainActor () -> PlaylistChoices
    @ObservationIgnored private let addTracks: @MainActor ([TrackRow], String) -> Void

    init(tracks: [TrackRow], choices: @escaping @MainActor () -> PlaylistChoices,
         add: @escaping @MainActor (_ tracks: [TrackRow], _ playlistID: String) -> Void) {
        self.tracks = tracks
        source = choices
        addTracks = add
    }

    /// 넣는 길은 아직 `LibraryStore`의 재생 목록 메서드다(재생 목록 조각은 다음 단계에서 나눈다).
    convenience init(store: LibraryStore, tracks: [TrackRow]) {
        self.init(tracks: tracks,
                  choices: { [weak store] in
                      guard let store else { return PlaylistChoices(playlists: [], recentIDs: []) }
                      return PlaylistChoices(playlists: store.trackPlaylists, recentIDs: store.recentPlaylists.map(\.id))
                  },
                  add: { [weak store] tracks, id in store?.addTracks(tracks, toPlaylist: id) })
    }

    var trackCount: Int { tracks.count }
    var choices: [PlaylistChoices.Choice] { source().choices(matching: query) }
    var canAdd: Bool { !choices.isEmpty }

    /// 고른 줄(없으면 맨 위 목록)에 넣는다. 넣었으면 true(시트를 닫는다).
    func addSelection() -> Bool { add(selection ?? choices.first?.id) }

    /// 그 목록에 연 때의 곡을 넣는다. 넣을 목록이 없으면 false.
    func add(_ playlistID: String?) -> Bool {
        guard let playlistID else { return false }
        addTracks(tracks, playlistID)
        return true
    }
}
