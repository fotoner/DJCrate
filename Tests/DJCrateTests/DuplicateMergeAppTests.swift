@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
@testable import RekordboxKit
import Testing

@MainActor
@Suite("중복 합치기 초안과 확인")
struct DuplicateMergeAppTests {
    func draft() -> DuplicateMergeDraft {
        .init(keeping: .init(contentID: "a", trackUUID: "a", title: "남길 곡", duration: 30, offset: 0, cues: []),
              removing: [.init(contentID: "b", trackUUID: "b", title: "뺄 곡", duration: 30, offset: 0, cues: [])], base: "base")
    }

    @Test func 초안은_재시작해도_남고_버리면_파일이_없어진다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "merge.json")
        try DuplicateMergeDraftStore.save([draft()], url: url)
        #expect(DuplicateMergeDraftStore.load(url: url) == [draft()])
        try DuplicateMergeDraftStore.save([], url: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func 같은_곡이나_기존_초안을_덮지_않는다() throws {
        var saved: [DuplicateMergeDraft] = []
        let store = LibraryStore.test(resultHistory: .init(), mergeDraftSaver: { saved = $0 })
        try store.stageMerge(draft())
        #expect(saved == [draft()] && store.pendingUUIDs.isSuperset(of: ["a", "b"]))
        #expect(throws: DuplicateMerge.Blocked.self) { try store.stageMerge(draft()) }
        try store.setMergeDrafts([])
        #expect(saved.isEmpty)
    }

    @Test func DB를_쓴_뒤_초안_저장실패는_경고로_남기고_쓰기결과를_유지한다() {
        let store = LibraryStore.test(resultHistory: .init(), mergeDraftSaver: { _ in throw FixtureFailure() })
        store.mergeDrafts = [draft()]
        store.saveMergeDraftsAfterWrite([])
        #expect(store.mergeDrafts.isEmpty)
        #expect(store.reflectionMessage?.kind == .warning)
    }
}
