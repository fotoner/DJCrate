import DJCDomain
import DJCStorage
import Foundation
import Testing

@Suite("가져온 곡의 목록 연결 저장")
struct PlaylistImportStorageTests {
    @Test func 재시작해도_남은_연결과_새_목록_키를_유지한다() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-playlist-import-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var imports = PlaylistImports()
        imports.addFiles(["/fixtures/a.wav", "/fixtures/b.wav"], to: .new("test"))
        var draft = PlaylistDraft()
        try draft.append(.create(key: "test", name: "세트", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
        _ = imports.reconcile(contentIDsByPath: ["/fixtures/b.wav": "2"], draft: &draft, rekordbox: PlaylistLayout())
        try PlaylistImportStore.save(imports, url: url)
        let saved = try PlaylistImportStore.load(url: url)
        #expect(saved == imports && saved.pendingCount == 1)
    }

    @Test func 없는_파일은_빈_연결이고_손상된_파일은_오류다() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-playlist-import-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try PlaylistImportStore.load(url: url).requests.isEmpty)
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try PlaylistImportStore.load(url: url) }
    }
}
