import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// LINK 플레이어 칸에 놓은 곡(#274). 곡 목록이 덱에 끌 때와 같은 형식(`DeckDragType.track`, rekordbox 곡 ID)을 읽는다.
enum LinkTrackDrop {
    /// 곡 ID를 읽어 메인 액터에서 넘긴다. 곡이 없는 끌기면 false.
    /// 형식이 실제로 있는 제공자만 고른다(macOS 27의 빈 제공자, #255). 여러 곡을 끌었으면 첫 곡만 싣는다(덱과 같다)
    static func read(_ providers: [NSItemProvider], then deliver: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(DeckDragType.track.identifier) }) else {
            return false
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: DeckDragType.track.identifier) { data, _ in
            guard let id = data.flatMap({ String(data: $0, encoding: .utf8) }), !id.isEmpty else { return }
            Task { @MainActor in deliver(id) }
        }
        return true
    }
}

/// 플레이어 칸의 놓기 판정. 덱처럼 delegate로 받는다: 받을 형식은 늘 같게 두고(바뀌는 형식 목록은 SwiftUI가 다시 등록하지 않았다),
/// 받을지는 놓을 때마다 본다. 곡 목록은 끌기를 복사·이동으로 내므로 이동으로 제안한다(덱과 같다)
struct LinkTrackDropDelegate: DropDelegate {
    /// 곡을 놓았을 때(rekordbox 곡 ID). nil이면 받지 않는다
    let onDrop: (@MainActor @Sendable (String) -> Void)?
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool { onDrop != nil && info.hasItemsConforming(to: [DeckDragType.track]) }
    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .move : .forbidden) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let onDrop else { return false }
        return LinkTrackDrop.read(info.itemProviders(for: [DeckDragType.track]), then: onDrop)
    }
}
