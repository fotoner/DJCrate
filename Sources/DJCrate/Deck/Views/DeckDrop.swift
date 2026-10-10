import AppKit
import DJCDomain
import SwiftUI
import UniformTypeIdentifiers

/// 곡 목록에서 덱 위로 끌어 놓은 곡(#93). 추가한 곡도 올릴 수 있게 재생 목록용 형식과 따로 둔다.
enum DeckDragType {
    static let track = UTType(exportedAs: "com.djcrate.deck-track", conformingTo: .data)
    static let pasteboard = NSPasteboard.PasteboardType(track.identifier)
}

/// 덱 영역: 곡 목록에서 끌어 온 곡을 덱에 올린다(rekordbox처럼). Finder에서 끌어 온 음원은 창의 다른 곳과 같이 추가한다.
struct DeckDropTarget: ViewModifier {
    let store: LibraryStore
    @State private var highlight = DropHighlight()

    func body(content: Content) -> some View {
        content
            .onDrop(of: [DeckDragType.track, PlaylistDragType.usbTracks, .fileURL], delegate: DeckDropDelegate(store: store, highlight: $highlight))
            .overlay {
                if highlight.isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .overlay(alignment: .top) {
                            Label(.ui("덱에 불러오기"), systemImage: "arrow.up.to.line")
                                .font(.callout.bold())
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.top, 10)
                        }
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct DeckDropDelegate: DropDelegate {
    let store: LibraryStore
    @Binding var highlight: DropHighlight

    /// 곡 목록에서 끈 곡: 로컬 곡 ID, USB 곡(#255, 짝인 로컬 곡을 올린다)
    static let trackTypes = [DeckDragType.track, PlaylistDragType.usbTracks]

    /// 덱 표시는 곡을 끌 때만(음원 파일은 덱에 올리지 않고 추가한다)
    func dropEntered(info: DropInfo) {
        highlight.enter(accepted: info.hasItemsConforming(to: Self.trackTypes) && store.writeLockPolicy.allowsLibraryInteraction)
    }

    func dropExited(info: DropInfo) { highlight.exit() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: Self.trackTypes) ? .move : .copy)
    }

    func validateDrop(info: DropInfo) -> Bool {
        store.writeLockPolicy.allowsLibraryInteraction
    }

    func performDrop(info: DropInfo) -> Bool {
        highlight.drop()
        let store = store
        if let provider = info.itemProviders(for: [DeckDragType.track]).first {
            // 여러 곡을 끌었으면 첫 곡을 올린다.
            _ = provider.loadDataRepresentation(forTypeIdentifier: DeckDragType.track.identifier) { data, _ in
                let id = data.flatMap { String(data: $0, encoding: .utf8) }
                Task { @MainActor in store.loadDroppedTracks(id.map { [$0] } ?? []) }
            }
            return true
        }
        if let provider = info.itemProviders(for: [PlaylistDragType.usbTracks]).first {
            // USB 곡도 첫 곡만 올린다(짝인 로컬 곡, 없으면 이유를 알린다)
            _ = provider.loadDataRepresentation(forTypeIdentifier: PlaylistDragType.usbTracks.identifier) { data, _ in
                let dragged = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(UsbTrackDrag.init(pasteboardString:))
                Task { @MainActor in store.loadDroppedUsbTracks(dragged.map { [$0] } ?? []) }
            }
            return true
        }
        let files = info.itemProviders(for: [.fileURL])
        guard !files.isEmpty else { return false }
        let box = URLBox()
        let group = DispatchGroup()
        for provider in files {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = box.values
            Task { @MainActor in await store.addFiles(urls) }
        }
        return true
    }
}

/// 끌어다 놓은 파일 주소를 다른 스레드에서 읽는 동안 모아 둔다.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var values: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}
