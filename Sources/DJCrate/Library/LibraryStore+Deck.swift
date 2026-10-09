import DJCDomain
import Foundation

/// 덱과 잇는 곳(#93): 목록에서 고른 곡을 덱에 올리고, 다시 읽은 뒤 덱의 곡을 새 값으로 맞춘다.
extension LibraryStore {
    /// 이 곡을 덱에 올린다(더블클릭·⌘→·오른쪽 클릭·끌어다 놓기). 재생 기록의 반복 행도 컬렉션 곡으로 올린다.
    /// rekordbox에 쓰는 동안은 덱을 바꾸지 않는다.
    func loadToDeck(_ row: TrackRow?) {
        // USB 곡은 아직 덱에 올리지 않는다(덱이 로컬 분석 파일·초안을 기준으로 읽는다)
        guard writeLockPolicy.allowsLibraryInteraction, let row, !row.isUsb else { return }
        let target = rowsByID[row.track.id] ?? row
        // 다른 곡으로 바꾸기 전에 덱이 버릴 것(Flip 기록)을 묻는다. 취소하면 덱도 덱 곡 ID도 그대로다.
        if target.track.id != deckTrackID, confirmDeckReplacement?(target) == false { return }
        setDeckTrack(target)
    }

    var canLoadSelectionToDeck: Bool { writeLockPolicy.allowsLibraryInteraction && primaryRow.map { !$0.isUsb } == true }

    /// 고른 곡 중 표 순서로 첫 곡을 덱에 올린다(⌘→·덱 메뉴).
    func loadSelectionToDeck() {
        guard writeLockPolicy.allowsLibraryInteraction else { return }
        guard let row = primaryRow else {
            stagingMessage = AppMessage(kind: .warning, text: String(ui: "고른 곡을 찾을 수 없으니 목록에서 곡을 다시 선택한 뒤 덱에 불러오세요"))
            return
        }
        guard !row.isUsb else { return }
        loadToDeck(row)
    }

    /// 덱 위에 놓은 곡(ContentID 또는 추가한 곡 ID) 중 라이브러리에 있는 첫 곡을 올린다.
    func loadDroppedTracks(_ ids: [String]) {
        loadToDeck(ids.lazy.compactMap { self.rowsByID[$0] }.first)
    }

    /// 라이브러리를 새로 읽거나 추가한 곡을 뺀 뒤: 덱의 곡을 새 값으로 맞추고, 없어진 곡은 내린다(지워진 곡을 붙들지 않게).
    func refreshDeckTrack() {
        guard let id = deckTrackID else { return }
        setDeckTrack(rowsByID[id])
    }
}
