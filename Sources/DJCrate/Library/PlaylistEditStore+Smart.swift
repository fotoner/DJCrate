import DJCDomain
import Foundation

/// 인텔리전트 재생 목록 읽기 전용 보기(#68, 실험실 설정 `SettingKeys.labSmartPlaylists`, 켜고 끄는 값은 핵심 `LibraryStore.showSmartPlaylists`).
/// 조건 칸은 스냅샷을 읽을 때 `smartPlaylistSources`에 담아 두고, 설정이 켜 있을 때만 계산해 사이드바 트리에 곡을 채운다.
/// 계산 결과는 rekordbox와 아직 견주지 않았다(묶음 3 M1). 끄면 이 파일의 어떤 것도 화면·편집·쓰기에 닿지 않는다.
extension PlaylistEditStore {
    /// 켜 있으면 인텔리전트 목록마다 조건을 계산해 사이드바 트리(`playlistTree`)에 곡을 채우고, 꺼 있으면 아무것도 하지 않는다.
    /// 폴더가 모은 곡에는 넣지 않는다(`PlaylistOutlineNode.fillingSmartTracks`). 곡은 컬렉션의 살아 있는 곡(`rows`)에서만 고른다.
    func fillSmartPlaylists() {
        guard library.showSmartPlaylists else {
            if !smartPlaylistResults.isEmpty { smartPlaylistResults = [:] }
            return
        }
        var results: [String: SmartPlaylistResult] = [:]
        var tracks: [Track]?
        for item in playlistProjection.layout.outline where item.isSmart {
            guard let source = smartPlaylistSources[item.id] else { continue }
            if source.definition != nil, tracks == nil { tracks = library.rows.map(\.track) }
            results[item.id] = SmartPlaylistEvaluator.evaluate(source, tracks: tracks ?? [])
        }
        smartPlaylistResults = results
        let filled = results.mapValues(\.trackIDs)
        playlistTree = playlistTree.map { $0.fillingSmartTracks(filled) }
    }

    /// 지금 고른 사이드바 항목이 인텔리전트 목록이면 그 계산 결과(켜 있을 때만)
    var selectedSmartPlaylistResult: SmartPlaylistResult? {
        guard library.showSmartPlaylists, case let .playlist(id) = library.sidebar else { return nil }
        return smartPlaylistResults[id]
    }

    /// 켜 있을 때 인텔리전트 목록을 고치려 하면(이름·지우기·옮기기·곡 넣기) 이유를 알리고 막는다. 꺼 있거나 인텔리전트 목록이 아니면 하지 않는다.
    /// - Returns: 막고 알렸으면 true
    @discardableResult
    func blockSmartPlaylistEdit(_ id: String) -> Bool {
        guard library.showSmartPlaylists, playlistItem(id)?.isSmart == true else { return false }
        playlistMessage = AppMessage(kind: .warning, text: SmartPlaylistSource.readOnlyReason)
        return true
    }
}

extension SmartPlaylistResult {
    /// 계산하지 못한 이유 한 줄(여러 개면 첫 이유와 나머지 수). 계산했으면 nil.
    var unsupportedSummary: String? {
        guard let first = unsupportedReasons.first else { return nil }
        return unsupportedReasons.count > 1 ? String(ui: "\(first) 외 \(unsupportedReasons.count - 1)건") : first
    }
}
