import Observation

/// 사이드바 재생 목록 칸의 화면 모델(#251): 펼친 폴더와 이름을 고치는 목록. 조립 지점이 한 번 만든다(`AppComposition.playlistSidebar`).
/// 목록을 만들면(메뉴·곡 목록·사이드바 어디서든) 재생 목록 조각이 알린다(`PlaylistEditStore.onCreate`). 그러면 조상 폴더만 펼치고
/// (다른 폴더의 펼침은 그대로) 새 목록의 이름을 고치게 한다. 재생 기록 칸의 펼침은 흐름이 바꾸므로 재생 기록 조각(`HistoryStore`)이 든다.
@MainActor
@Observable
final class PlaylistSidebarModel {
    /// 펼친 폴더(새 항목의 부모만 펼치고 다른 폴더의 펼침 상태는 유지한다)
    var expandedPlaylistIDs: Set<String> = []
    /// 사이드바에서 이름을 고치는 중인 목록
    private(set) var renamingPlaylistID: String?
    @ObservationIgnored private let playlists: PlaylistEditStore

    /// 조각의 만들기 알림을 이 모델이 받는다(조각 하나에 모델 하나)
    init(playlists: PlaylistEditStore) {
        self.playlists = playlists
        playlists.onCreate = { [weak self] id, ancestors in self?.created(id, ancestors: ancestors) }
    }

    func isExpanded(_ id: String) -> Bool { expandedPlaylistIDs.contains(id) }

    func setExpanded(_ id: String, _ expanded: Bool) {
        if expanded { expandedPlaylistIDs.insert(id) } else { expandedPlaylistIDs.remove(id) }
    }

    func startRenaming(_ id: String) { renamingPlaylistID = id }

    func cancelRenaming() { renamingPlaylistID = nil }

    /// 이름 바꾸기를 끝낸다. 고친 이름은 다듬어 초안에 쓴다(비었거나 같으면 쓰지 않는다)
    func finishRenaming(_ id: String, to name: String) {
        renamingPlaylistID = nil
        playlists.renamePlaylist(id, to: name)
    }

    private func created(_ id: String, ancestors: [String]) {
        expandedPlaylistIDs.formUnion(ancestors)
        renamingPlaylistID = id
    }
}
