import DJCApplication
import DJCDomain
import Foundation

/// 파일 메뉴의 "rekordbox XML 가져오기…"(#72)가 초안을 만들 때 쓰는 화면 상태. 읽기·미리 보기·결과는 `XMLImportModel`(`xmlImport`)이 맡는다.
extension LibraryStore {
    /// 가져오기가 덮지 않을 초안(메모리 태그 초안), 재생 목록 메모리 초안, 덱에 올린 곡의 그리드 초안(유스케이스 `ImportXML.makeDrafts`)
    func xmlImportContext() -> ImportXML.Context {
        ImportXML.Context(
            existing: [.tag: Set(tagDrafts.keys)],
            playlists: ImportXML.PlaylistTarget(current: { [weak self] in self?.playlists.playlistDraft ?? PlaylistDraft() },
                                                save: { [weak self] draft in
                                                    guard let self else { return }
                                                    playlists.playlistDraft = draft
                                                    playlists.savePlaylistDraft()
                                                    playlists.refreshPlaylists()
                                                }),
            deck: ImportXML.DeckGrid(state: { [weak self] in self?.deckGridDraftState?() },
                                     adopt: { [weak self] in self?.adoptImportedGridDraft?($0) ?? false }))
    }
}
