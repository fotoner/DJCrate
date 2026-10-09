import DJCDomain
import Foundation
import Testing

@Suite("가져온 곡의 재생 목록 연결")
struct PlaylistImportTests {
    func origins(_ path: String, position: Int, playlist: String = "P", name: String = "세트") -> [String: [AppleMusicOrigin]] {
        [path: [.init(libraryID: "L", trackID: position + 1,
                      playlists: [.init(id: playlist, name: name, parentID: nil, position: position)])]]
    }

    @Test func 빈_파일_선택은_연결을_만들지_않는다() {
        var imports = PlaylistImports()
        imports.addFiles([], to: .id("P"))
        #expect(imports.requests.isEmpty)
    }

    @Test func 파일을_다시_놓으면_목록에서_뺐던_곡도_다시_넣는다() {
        var imports = PlaylistImports(), draft = PlaylistDraft()
        let rb = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        imports.addFiles(["/a"], to: .id("P"))
        _ = imports.reconcile(contentIDsByPath: ["/a": "1"], draft: &draft, rekordbox: rb)
        draft = PlaylistDraft()
        imports.addFiles(["/a"], to: .id("P"))
        _ = imports.reconcile(contentIDsByPath: ["/a": "1"], draft: &draft, rekordbox: rb)
        #expect(draft.edits == [.addTracks(playlist: .id("P"), contentIDs: ["1"])])
    }

    @Test func 컬렉션에_있는_곡만_초안에_넣고_같은_이름은_새로_만든다() throws {
        var imports = PlaylistImports()
        imports.addAppleMusic(origins("/a", position: 0).merging(origins("/b", position: 1)) { $0 + $1 }, unidentifiedLibraryID: UUID().uuidString,
                              newKey: { UUID().uuidString.lowercased() })
        let rb = PlaylistLayout([(.init(id: "old", name: "세트"), 1), (.init(id: "folder", name: "세트 (2)", isFolder: true), 2)])
        var draft = PlaylistDraft()
        #expect(imports.reconcile(contentIDsByPath: [:], draft: &draft, rekordbox: rb).isEmpty)
        #expect(draft.isEmpty)
        #expect(imports.reconcile(contentIDsByPath: ["/b": "2"], draft: &draft, rekordbox: rb).isEmpty)
        let id = try #require(imports.requests.first?.target.layoutID)
        #expect(draft.project(onto: rb).layout.item(id)?.name == "세트 (3)")
        #expect(draft.project(onto: rb).layout.item(id)?.trackIDs == ["2"])
        #expect(imports.pendingCount == 1)
        #expect(imports.reconcile(contentIDsByPath: ["/a": "1", "/b": "2"], draft: &draft, rekordbox: rb).isEmpty)
        #expect(draft.project(onto: rb).layout.item(id)?.trackIDs == ["1", "2"])
        #expect(draft.project(onto: rb).layout.item("old")?.trackIDs == [])
        #expect(imports.pendingCount == 0)
        let before = draft
        imports.addAppleMusic(origins("/a", position: 0), unidentifiedLibraryID: UUID().uuidString, newKey: { UUID().uuidString.lowercased() })
        _ = imports.reconcile(contentIDsByPath: ["/a": "1", "/b": "2"], draft: &draft, rekordbox: rb)
        #expect(draft == before && imports.requests.count == 1)
    }

    @Test func 다른_출처의_같은_이름과_한_곡의_여러_목록을_구분한다() {
        var imports = PlaylistImports()
        imports.addAppleMusic(origins("/a", position: 0).merging(origins("/a", position: 0, playlist: "Q")) { $0 + $1 },
                              unidentifiedLibraryID: UUID().uuidString, newKey: { UUID().uuidString.lowercased() })
        var draft = PlaylistDraft()
        _ = imports.reconcile(contentIDsByPath: ["/a": "1"], draft: &draft, rekordbox: PlaylistLayout())
        let items = draft.project(onto: PlaylistLayout()).layout.items.values
        #expect(Set(items.map(\.name)) == ["세트", "세트 (2)"])
        #expect(items.allSatisfy { $0.trackIDs == ["1"] })
    }

    @Test func 파일_놓기는_중복을_빼고_지운_목록에는_보류한다() throws {
        var imports = PlaylistImports()
        imports.addFiles(["/a", "/a", "/b"], to: .id("P"))
        var draft = PlaylistDraft()
        #expect(imports.reconcile(contentIDsByPath: ["/a": "1"], draft: &draft, rekordbox: PlaylistLayout()).count == 1)
        #expect(draft.isEmpty && imports.pendingCount == 2)
        let rb = PlaylistLayout([(.init(id: "P", name: "세트", entries: [.init(trackNo: 1, contentID: "1")]), 1)])
        _ = imports.reconcile(contentIDsByPath: ["/a": "1", "/b": "2"], draft: &draft, rekordbox: rb)
        #expect(draft.edits == [.addTracks(playlist: .id("P"), contentIDs: ["2"])])
        #expect(imports.pendingCount == 0)
    }

    @Test func 새_목록을_반영한_ID로_남은_곡을_잇고_취소한_파일은_뺀다() throws {
        var imports = PlaylistImports()
        imports.addFiles(["/a", "/b"], to: .new("test"))
        imports.remapTargets(["new:test": "real"])
        imports.removePending(paths: ["/b"])
        var draft = PlaylistDraft()
        let rb = PlaylistLayout([(.init(id: "real", name: "세트"), 1)])
        _ = imports.reconcile(contentIDsByPath: ["/a": "1"], draft: &draft, rekordbox: rb)
        #expect(draft.edits == [.addTracks(playlist: .id("real"), contentIDs: ["1"])])
        #expect(imports.pendingCount == 0)
        imports.reset(contentIDs: ["1"])
        #expect(imports.pendingCount == 1)
    }
}
