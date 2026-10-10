import DJCDomain
import AppKit
import SwiftUI

extension TrackListCoordinator {
    // MARK: 끌어다 놓기

    /// 곡을 끌면 ID를 싣는다: 덱 위에 놓아 불러오기(#93), 사이드바 목록에 놓아 넣기, 목록 안에서 순서 바꾸기.
    /// 추가한 곡은 아직 rekordbox에 없어 재생 목록용으로는 싣지 않는다(덱에는 올릴 수 있다).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), !isEditing else { return nil }
        // USB 곡은 USB 곡 형식만 싣는다: 같은 USB의 목록에 넣기·목록 안 순서 바꾸기(초안, #240), 덱에 놓아 짝인 로컬 곡 올리기(#255).
        // 로컬 목록·앱 밖으로는 끌지 않는다. USB 목록 쪽 놓기는 받는 곳이 초안을 받는 볼륨인지 본다(`acceptsUsbDrop`·`usbReorderPlaylist`)
        if rows[row].isUsb {
            guard case let .usb(target) = store.sidebar else { return nil }
            return UsbTrackDrag(row: rows[row], target: target)?.pasteboardItem
        }
        let item = NSPasteboardItem()
        item.setString(rows[row].track.id, forType: DeckDragType.pasteboard)
        if !rows[row].isStaged { item.setString(rows[row].track.id, forType: PlaylistDragType.pasteboardTracks) }
        let track = rows[row].track
        if !track.isStreaming {
            let url = URL(filePath: track.folderPath)
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
               values.isRegularFile == true, values.isReadable == true {
                item.setString(url.absoluteString, forType: .fileURL)
            }
        }
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        dragGeneration += 1
        cancelPendingEdit()
        // 사이드바 USB 줄이 같은 USB의 목록에서만 USB 곡을 받게 끄는 볼륨을 알린다
        if case let .usb(target) = store.sidebar, rowIndexes.contains(where: { rows.indices.contains($0) && rows[$0].isUsb }) {
            store.usbDragVolume = target.volumeKey
        } else {
            store.usbDragVolume = nil
        }
        tableView.draggingDestinationFeedbackStyle = dragFeedbackStyle
    }

    /// 끌기 강조 모양. 간격 표시는 끄는 동안 끄는 줄을 숨긴다. 숨긴 채 덱에 곡이 올라가 목록 높이가 바뀌면 표 높이가 틀어지고(#143),
    /// 끌 항목이 없어 끌기가 시작되지 않으면 숨긴 줄이 돌아오지 않아 고른 줄이 사라졌다(#240). 목록 안에 놓아 순서를 바꿀 수 있을 때만 쓴다
    var dragFeedbackStyle: NSTableView.DraggingDestinationFeedbackStyle {
        store.canReorderDisplayedTracks || store.usbReorderPlaylist != nil ? .gap : .regular
    }

    /// 끄는 줄을 숨긴 채 목록 높이가 바뀌면 AppKit이 표 높이를 줄 끝보다 짧게 잡고, 끌기가 끝나 줄을 다시 보여도 다시 재지 않는다.
    /// 그러면 놓은 뒤 휠 스크롤이 짧은 높이에 막혔다(#143). 표는 이 대리자를 부른 뒤에 줄을 다시 보이므로 다음 차례에 잰다.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        store.usbDragVolume = nil
        Task { @MainActor [weak tableView] in tableView?.tile() }
    }

    /// 목록을 # 순서로 볼 때만 줄 사이에 놓아 순서를 바꾼다(로컬 재생 목록, 초안을 받는 USB 목록).
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === tableView else { return [] }
        if store.usbReorderPlaylist != nil {
            guard !usbEntries(info).isEmpty else { return [] }
        } else {
            guard store.canReorderDisplayedTracks else { return [] }
        }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    /// 지금 보는 USB 목록에서 끈 항목(자리·곡)
    private func usbEntries(_ info: any NSDraggingInfo) -> [PlaylistEntry] {
        guard let target = store.usbReorderPlaylist else { return [] }
        return UsbTrackDrag.entries(UsbTrackDrag.read(info.draggingPasteboard.pasteboardItems ?? []), volumeKey: target.volumeKey, playlist: target.id)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if let target = store.usbReorderPlaylist {
            guard (info.draggingSource as? NSTableView) === tableView, let actions = store.usbEdits else { return false }
            let dragged = UsbTrackDrag.read(info.draggingPasteboard.pasteboardItems ?? [])
            let moving = Set(UsbTrackDrag.entries(dragged, volumeKey: target.volumeKey, playlist: target.id).map(\.trackNo))
            guard !moving.isEmpty else { return false }
            // 놓은 자리 아래에서 옮기지 않는 첫 항목 앞으로(없으면 맨 끝). 줄 번호는 초안을 얹은 목록의 자리다
            let before = rows[min(row, rows.count)...].lazy.compactMap(\.playlistTrackNumber).first { !moving.contains($0) }
            Task { await actions.moveEntries(dragged, before: before, volumeKey: target.volumeKey, playlist: target.id) }
            return true
        }
        guard let id = store.editablePlaylistID, store.canReorderDisplayedTracks else { return false }
        let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: PlaylistDragType.pasteboardTracks) }
        guard !ids.isEmpty else { return false }
        let moving = Set(ids)
        // 놓은 자리 아래에서 옮기지 않는 첫 곡 앞으로(없으면 맨 끝)
        let before = rows[min(row, rows.count)...].first { !moving.contains($0.track.id) }?.track.id
        store.moveTracks(ids, inPlaylist: id, before: before)
        return true
    }
}
