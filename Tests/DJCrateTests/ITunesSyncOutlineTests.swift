@testable import DJCrate
import DJCDomain
import DJCStorage
import Testing

struct ITunesSyncOutlineTests {
    @MainActor @Test func 선택_창은_경로와_무관하게_계층과_선택을_표시한다() {
        let source: [ITunesLibrarySnapshot.Playlist] = [
            .init(id: "F", name: "빈 폴더", isFolder: true),
            .init(id: "D", name: "중첩 폴더", isFolder: true),
            .init(id: "A", name: "첫 목록", parentID: "D", paths: ["/합성/곡 1", nil]),
            .init(id: "B", name: "둘째 목록", parentID: "D", paths: ["/합성/곡 2"]),
            .init(id: "C", name: "최상위 목록", paths: ["/합성/곡 3"]),
        ]
        let model = ITunesSyncModel(ports: .closed)
        model.source = ITunesLibrarySnapshot(playlists: source, sourcePlaylists: source)

        #expect(model.tree.map(\.id) == ["itunes:F", "itunes:D", "itunes:C"])
        #expect(model.tree.first?.children?.isEmpty == true)
        #expect(model.tree.dropFirst().first?.children?.map(\.name) == ["첫 목록", "둘째 목록"])

        model.selection = .init(selectedIDs: ["A"])
        #expect(model.preview.tree.map(\.id) == ["itunes:D"])
        #expect(model.preview.tree.first?.children?.map(\.id) == ["itunes:A"])
        #expect(model.preview.playlistCount == 1)

        model.selection = .init(selectedIDs: ["F", "B"])
        #expect(model.preview.tree.map(\.id) == ["itunes:F", "itunes:D"])
        #expect(model.preview.tree.first?.children?.isEmpty == true)
        #expect(model.preview.tree.dropFirst().first?.children?.map(\.id) == ["itunes:B"])
        #expect(model.preview.playlistCount == 1)

        model.selection = .init(selectedIDs: ["0"])
        #expect(model.preview.tree.map(\.id) == model.tree.map(\.id))
        #expect(model.preview.tree.dropFirst().first?.children?.map(\.id) == ["itunes:A", "itunes:B"])
        #expect(model.preview.playlistCount == 3)
    }

    @MainActor @Test func 선택_창_노드는_곡_연결을_담지_않는다() {
        let model = ITunesSyncModel(ports: .closed)
        model.source = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "목록", paths: ["/합성/곡"])])
        model.selection = .init(selectedIDs: ["0"])
        let node: ITunesSyncOutline.Node? = model.preview.tree.first
        #expect(node?.id == "itunes:A")
    }
}
