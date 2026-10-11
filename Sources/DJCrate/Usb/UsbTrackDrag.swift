import AppKit
import DJCDomain
import Foundation

/// 곡 목록에서 끈 USB 곡 한 줄(#240). 페이스트보드 항목 하나에 JSON 한 개로 싣는다(`PlaylistDragType.usbTracks`).
/// 같은 곡이 목록에 여러 번 있어도 줄마다 끌 수 있게 USB 재생 목록에서 끌었으면 그 목록과 자리(1부터)도 싣는다
struct UsbTrackDrag: Codable, Hashable, Sendable {
    var volumeKey: String
    var contentID: Int
    var playlist: Int?
    var trackNo: Int?

    init(volumeKey: String, contentID: Int, playlist: Int? = nil, trackNo: Int? = nil) {
        self.volumeKey = volumeKey
        self.contentID = contentID
        self.playlist = playlist
        self.trackNo = trackNo
    }

    /// 보고 있는 USB 컬렉션·목록의 곡 줄(USB 곡이 아니면 nil)
    @MainActor
    init?(row: TrackRow, target: UsbSidebarTarget) {
        guard let id = UsbEditActions.usbContentID(row, volumeKey: target.volumeKey) else { return nil }
        switch target {
        case .collection: self.init(volumeKey: target.volumeKey, contentID: id)
        case let .playlist(_, playlist):
            guard let number = row.playlistOccurrence?.number else { return nil }
            self.init(volumeKey: target.volumeKey, contentID: id, playlist: playlist, trackNo: number)
        case .pending: return nil
        }
    }

    var pasteboardString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    init?(pasteboardString: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(pasteboardString.utf8)) else { return nil }
        self = value
    }

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(pasteboardString, forType: PlaylistDragType.pasteboardUsbTracks)
        return item
    }

    /// 페이스트보드 항목들의 USB 곡(끈 차례)
    static func read(_ items: [NSPasteboardItem]) -> [UsbTrackDrag] {
        items.compactMap { $0.string(forType: PlaylistDragType.pasteboardUsbTracks).flatMap(UsbTrackDrag.init(pasteboardString:)) }
    }

    /// 놓은 USB 목록 안에서 옮길 항목(그 목록에서 끈 줄만, 자리 차례, 같은 자리는 한 번)
    static func entries(_ dragged: [UsbTrackDrag], volumeKey: String, playlist: Int) -> [PlaylistEntry] {
        var seen: Set<Int> = []
        return dragged.compactMap { drag -> PlaylistEntry? in
            guard drag.volumeKey == volumeKey, drag.playlist == playlist, let number = drag.trackNo, seen.insert(number).inserted else { return nil }
            return PlaylistEntry(trackNo: number, contentID: String(drag.contentID))
        }.sorted { $0.trackNo < $1.trackNo }
    }
}
