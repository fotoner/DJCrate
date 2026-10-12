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
        let provider = PlaylistDragType.provider(for: try node(id: id, folder: folder), ids: [id])
        #expect(provider.registeredTypeIdentifiers == [PlaylistDragType.playlist.identifier])
        let bytes: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: PlaylistDragType.playlist.identifier) { data, error in
                #expect(error == nil)
                continuation.resume(returning: data)
            }
        }
        #expect(bytes == Data(id.utf8))
        #expect(await moved([provider]) == [id])
    }

    private func moved(_ providers: [NSItemProvider]) async -> [String]? {
        await withCheckedContinuation { continuation in
            let accepted = PlaylistDrop.movePlaylists(providers) { continuation.resume(returning: $0) }
            #expect(accepted)
            if !accepted { continuation.resume(returning: nil) }
        }
    }

    @Test func 여럿을_끌면_고른_목록을_순서대로_모두_싣는다() async throws {
        // 여럿에 섞인 인텔리전트 목록도 싣는다(놓을 때 그 항목만 건너뛰고 이유를 보인다, #261)
        let provider = PlaylistDragType.provider(for: try node(id: "smart", smart: true), ids: ["B", "smart", "new:키"])
        #expect(provider.registeredTypeIdentifiers == [PlaylistDragType.playlist.identifier])
        #expect(await moved([provider]) == ["B", "smart", "new:키"])
    }

    @Test func smartPlaylistDoesNotAdvertiseDragData() throws {
        let provider = PlaylistDragType.provider(for: try node(id: "smart", smart: true), ids: ["smart"])
        #expect(provider.registeredTypeIdentifiers.isEmpty)
        #expect(!PlaylistDrop.movePlaylists([provider]) { _ in Issue.record("인텔리전트 목록을 옮겼습니다") })
    }
}
