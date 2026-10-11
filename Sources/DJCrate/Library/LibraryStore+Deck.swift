import DJCDomain
import Foundation

/// 덱과 잇는 곳(#93): 목록에서 고른 곡을 덱에 올리고, 다시 읽은 뒤 덱의 곡을 새 값으로 맞춘다.
extension LibraryStore {
    /// 이 곡을 덱에 올린다(더블클릭·⌘→·오른쪽 클릭·끌어다 놓기). 재생 기록의 반복 행도 컬렉션 곡으로 올린다.
    /// USB 곡은 짝인 로컬 곡을 올린다(#255). rekordbox에 쓰는 동안은 덱을 바꾸지 않는다.
    func loadToDeck(_ row: TrackRow?) {
        guard writeLockPolicy.allowsLibraryInteraction, let row else { return }
        let target: TrackRow
        if row.isUsb {
            guard let local = localDeckRow(localTrackID(ofUsb: row)) else { return }
            target = local
        } else {
            target = rowsByID[row.track.id] ?? row
        }
        // 다른 곡으로 바꾸기 전에 덱이 버릴 것(Flip 기록)을 묻는다. 취소하면 덱도 덱 곡 ID도 그대로다.
        if target.track.id != deckTrackID, confirmDeckReplacement?(target) == false { return }
        setDeckTrack(target)
    }

    /// 짝 없는 USB 곡을 골라도 막지 않는다: 누르면 이유를 알린다
    var canLoadSelectionToDeck: Bool { writeLockPolicy.allowsLibraryInteraction && primaryRow != nil }

    /// 고른 곡 중 표 순서로 첫 곡을 덱에 올린다(⌘→·덱 메뉴).
    func loadSelectionToDeck() {
        guard writeLockPolicy.allowsLibraryInteraction else { return }
        guard let row = primaryRow else {
            staging.stagingMessage = AppMessage(kind: .warning, text: String(ui: "고른 곡을 찾을 수 없으니 목록에서 곡을 다시 선택한 뒤 덱에 불러오세요"))
            return
        }
        loadToDeck(row)
    }

    /// 덱 위에 놓은 곡(ContentID 또는 추가한 곡 ID) 중 라이브러리에 있는 첫 곡을 올린다.
    func loadDroppedTracks(_ ids: [String]) {
        loadToDeck(ids.lazy.compactMap { self.rowsByID[$0] }.first)
    }

    /// 덱 위에 놓은 USB 곡(#240 끌기 형식) 중 첫 곡의 짝 로컬 곡을 올린다(#255).
    func loadDroppedUsbTracks(_ dragged: [UsbTrackDrag]) {
        guard writeLockPolicy.allowsLibraryInteraction, let first = dragged.first else { return }
        loadToDeck(localDeckRow(usb?.localMatches[first.volumeKey]?[first.contentID]))
    }

    /// 이 줄의 곡이 덱의 곡과 같은지: USB 줄은 짝인 로컬 곡으로 본다(# 칸 덱 표시)
    func isDeckTrack(_ row: TrackRow, deckTrackID: String?) -> Bool {
        guard let deckTrackID else { return false }
        return row.isUsb ? localTrackID(ofUsb: row) == deckTrackID : row.track.id == deckTrackID
    }

    /// USB 곡 줄의 짝 로컬 ContentID. 재생 기록 보존 곡 줄(`usb:history:`)은 USB 볼륨 곡이 아니라 짝이 없다
    private func localTrackID(ofUsb row: TrackRow) -> String? {
        guard !row.track.id.hasPrefix(HistoryStore.archivedTrackIDPrefix), let matches = usb?.localMatches else { return nil }
        return UsbDeckLoad.localContentID(usbTrackID: row.track.id, matches: matches)
    }

    /// 짝 로컬 ContentID → 덱에 올릴 줄. 짝이 없거나 목록에 없으면 덱을 바꾸지 않고 할 일을 알린다
    private func localDeckRow(_ id: String?) -> TrackRow? {
        guard let id else {
            staging.stagingMessage = AppMessage(kind: .warning, text: String(ui: "로컬 rekordbox에 없는 USB 곡이라 덱에 올릴 수 없으니 rekordbox 컬렉션에 먼저 더하세요"))
            return nil
        }
        guard let row = rowsByID[id] else {
            staging.stagingMessage = AppMessage(kind: .warning, text: String(ui: "USB 곡과 짝인 로컬 곡을 찾을 수 없으니 라이브러리를 다시 읽은 뒤 덱에 불러오세요"))
            return nil
        }
        return row
    }

    /// 라이브러리를 새로 읽거나 추가한 곡을 뺀 뒤: 덱의 곡을 새 값으로 맞추고, 없어진 곡은 내린다(지워진 곡을 붙들지 않게).
    func refreshDeckTrack() {
        guard let id = deckTrackID else { return }
        setDeckTrack(rowsByID[id])
    }
}

