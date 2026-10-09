import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

/// 라이브러리 읽기는 저장소의 초안 폴더(`draftHome`)만 본다. 시험 프로세스가 함께 쓰는 기본 폴더의 초안이 섞이면
/// 병렬 시험에서 초안 수가 흔들렸다(`RatingColorEditingTests`의 `tagDrafts.count`).
@Suite("라이브러리 초안 폴더")
@MainActor
struct LibraryDraftFolderTests {
    @Test func 읽기는_주입한_초안_폴더의_초안만_본다() async throws {
        let fixture = try RekordboxFixture()
        let mine = TrackSpec(id: "101"), other = TrackSpec(id: "102")
        try fixture.add(mine)
        try fixture.add(other)
        let home = fixture.root.appending(path: "drafts"), elsewhere = fixture.root.appending(path: "elsewhere")
        var tag = TagDraft(trackUUID: mine.uuid, base: TagFields())
        tag.fields.comment = "내 폴더"
        try TagDraftStore.save(tag, directory: home.appending(path: "tag-drafts"))
        var cue = CueDraft(trackUUID: mine.uuid)
        cue.place(EditableCue(kind: .hot(0), time: 1))
        try CueDraftStore.save(cue, directory: home.appending(path: "cue-drafts"))
        try GridDraftStore.save(GridDraft(trackUUID: mine.uuid, base: [], segments: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)]),
                                directory: home.appending(path: "grid-drafts"))
        try GainDraftStore.save(-3, trackUUID: mine.uuid, url: home.appending(path: "gain-drafts.json"))
        // 다른 폴더의 초안은 읽지 않는다
        var stray = TagDraft(trackUUID: other.uuid, base: TagFields())
        stray.fields.comment = "다른 폴더"
        try TagDraftStore.save(stray, directory: elsewhere.appending(path: "tag-drafts"))

        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: fixture.root.appending(path: "result.json")),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups, draftHome: home)
        await store.load(snapshot: fixture.database)
        #expect(Set(store.tagDrafts.keys) == [mine.uuid])
        #expect(store.tagDrafts[mine.uuid]?.fields.comment == "내 폴더")
        #expect(store.draftCueCounts[mine.uuid]?.hot == 1)
        #expect(store.hasDraft(.cue, trackUUID: mine.uuid) && store.hasDraft(.grid, trackUUID: mine.uuid)
            && store.hasDraft(.gain, trackUUID: mine.uuid))
        #expect(store.pendingUUIDs == [mine.uuid] && store.editedUUIDs == [mine.uuid])
    }

    @Test func 초안_폴더만_준_저장소는_쓰기_결과와_가져오기_기록도_그_폴더에서_읽는다() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-draft-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // 읽지 못하는 파일을 두어 그 폴더를 읽었는지 본다
        try Data("{".utf8).write(to: home.appending(path: "last-write-result.json"))
        try Data("{".utf8).write(to: home.appending(path: "playlist-imports.json"))
        let store = LibraryStore.test(saveTagDrafts: { _ in }, draftHome: home)
        #expect(store.resultHistory.storageError != nil)
        #expect(store.playlistImportsLoadFailed)
    }
}

/// 메인 밖에서 읽은 바깥 초안 확인 결과를 버리는 경우. 읽는 사이 덱에서 큐·그리드를 끌기 시작하면(`allowsLibrarySync`) 버린다(f3 P3-3).
/// 버려도 이미 옮긴 손상 파일은 알리고 메모리의 태그 초안은 다시 저장한다. 버리면 다음 확인이 디스크에 없는 초안으로 보고
/// 메모리 입력을 지웠다(f1 P2-1).
@Suite("버린 바깥 초안 확인")
@MainActor
struct ExternalDraftDiscardTests {
    func loadedStore(_ fixture: RekordboxFixture, home: URL) async -> LibraryStore {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), backupDirectory: fixture.backups, draftHome: home)
        await store.load(snapshot: fixture.database)
        return store
    }

    @Test func 결과를_버린_확인도_옮긴_파일을_알리고_태그_초안을_다시_저장한다() async throws {
        let fixture = try RekordboxFixture()
        let track = TrackSpec(id: "101")
        try fixture.add(track)
        let home = fixture.root.appending(path: "drafts"), tags = home.appending(path: "tag-drafts")
        var tag = TagDraft(trackUUID: track.uuid, base: TagFields())
        tag.fields.comment = "메모리 입력"
        try TagDraftStore.save(tag, directory: tags)
        let store = await loadedStore(fixture, home: home)
        #expect(store.tagDrafts[track.uuid]?.fields.comment == "메모리 입력")
        // 다른 프로세스가 태그 초안 파일을 깨뜨리고, 확인하는 사이 덱에서 끌기 시작해 이 확인의 결과를 버린다
        try Data("{".utf8).write(to: tags.appending(path: "\(track.uuid).json"))
        store.allowsLibrarySync = { false }
        await store.refreshExternalDrafts()
        store.testDrafts.flush()

        #expect(FileManager.default.fileExists(atPath: home.appending(path: "damaged-drafts").path))
        #expect(store.draftFileMessage != nil)
        #expect(TagDraftStore.load(trackUUID: track.uuid, directory: tags)?.fields.comment == "메모리 입력")
        // 다음 확인도 메모리 입력을 지우지 않는다
        store.allowsLibrarySync = { true }
        await store.refreshExternalDrafts()
        #expect(store.tagDrafts[track.uuid]?.fields.comment == "메모리 입력")
    }

    @Test func 확인하는_사이_덱에서_끌기_시작하면_적용하지_않고_다음_확인에서_읽는다() async throws {
        let fixture = try RekordboxFixture()
        let track = TrackSpec(id: "101")
        try fixture.add(track)
        let home = fixture.root.appending(path: "drafts")
        let store = await loadedStore(fixture, home: home)
        // 다른 프로세스가 그리드 초안을 만든다
        try GridDraftStore.save(GridDraft(trackUUID: track.uuid, base: [], segments: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)]),
                                directory: home.appending(path: "grid-drafts"))
        store.allowsLibrarySync = { false }
        await store.refreshExternalDrafts()
        #expect(!store.hasDraft(.grid, trackUUID: track.uuid))
        store.allowsLibrarySync = { true }
        await store.refreshExternalDrafts()
        #expect(store.hasDraft(.grid, trackUUID: track.uuid))
    }
}
