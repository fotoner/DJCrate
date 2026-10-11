@testable import DJCrate
import AppKit
import DJCDomain
import Testing
import UniformTypeIdentifiers

@MainActor
struct PlaylistDragTests {
    private func node(id: String, folder: Bool = false, smart: Bool = false) throws -> PlaylistOutlineNode {
        let item = PlaylistLayout.Item(id: id, name: "합성 목록", isFolder: folder, isSmart: smart)
        return try #require(PlaylistOutlineNode.tree(PlaylistLayout([(item, 1)])).first)
    }

    @Test(arguments: [false, true])
    func regularPlaylistsAndFoldersKeepTheirCustomTypeAndUTF8ID(folder: Bool) async throws {
        let id = "new:합성 목록-1"
        let provider = PlaylistDragType.provider(for: try node(id: id, folder: folder))
        #expect(provider.registeredTypeIdentifiers == [PlaylistDragType.playlist.identifier])
        let bytes: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: PlaylistDragType.playlist.identifier) { data, error in
                #expect(error == nil)
                continuation.resume(returning: data)
            }
        }
        #expect(bytes == Data(id.utf8))
        let moved: String? = await withCheckedContinuation { continuation in
            let accepted = PlaylistDrop.movePlaylist([provider]) { continuation.resume(returning: $0) }
            #expect(accepted)
            if !accepted { continuation.resume(returning: nil) }
        }
        #expect(moved == id)
    }

    @Test func smartPlaylistDoesNotAdvertiseDragData() throws {
        let provider = PlaylistDragType.provider(for: try node(id: "smart", smart: true))
        #expect(provider.registeredTypeIdentifiers.isEmpty)
        #expect(!PlaylistDrop.movePlaylist([provider]) { _ in Issue.record("인텔리전트 목록을 옮겼습니다") })
    }
}
