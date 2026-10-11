import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// #178: 손상된 합치기 초안·추가 목록을 앱이 읽고 저장할 때 옮겨 보관하고 할 일을 알린다.
/// 저장소의 옮기기 규칙은 DJCStorageTests `DamagedMergeStagedTests`.
@Suite("합치기 초안·추가 목록 손상 파일 알림", .serialized)
struct DamagedMergeStagedAppTests {
    func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-damaged-merge-staged-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    let broken = Data("{\"깨진".utf8)

    func preserved(in home: URL) -> [URL] {
        let root = home.appending(path: DamagedDrafts.folderName)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    func merge(_ id: String = "a") -> DuplicateMergeDraft {
        .init(keeping: .init(contentID: id, trackUUID: id, title: "남길 곡", duration: 30, offset: 0, cues: []),
              removing: [.init(contentID: "\(id)-뺄", trackUUID: "\(id)-뺄", title: "뺄 곡", duration: 30, offset: 0, cues: [])], base: "base")
    }

    func track(_ name: String = "a") -> StagedTrack {
        StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/fixtures/\(name).wav", title: "합성 곡 \(name)", duration: 30, addedOn: "2026-10-02")
    }

    @MainActor func store(home: URL, fixture: RekordboxFixture? = nil) -> LibraryStore {
        let mergeURL = home.appending(path: DuplicateMergeDraftStore.fileName), stagedURL = home.appending(path: StagedTrackFile.fileName)
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture?.backups ?? home.appending(path: "backups"), playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { try DuplicateMergeDraftStore.save($0, url: mergeURL) },
                                 playlistImportURL: nil, stagingSaver: { try StagedTrackFile.save($0, url: stagedURL) }, draftHome: home)
        return store
    }

    @Test @MainActor func 읽을_때_손상된_합치기_초안과_추가_목록을_옮기고_할_일까지_알린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: DuplicateMergeDraftStore.fileName))
        try broken.write(to: home.appending(path: StagedTrackFile.fileName))
        let store = store(home: home, fixture: fixture)
        await store.load(snapshot: fixture.database)
        #expect(preserved(in: home).count == 2 && preserved(in: home).allSatisfy { (try? Data(contentsOf: $0)) == broken })
        #expect(store.mergeDrafts.isEmpty && store.staging.staged.isEmpty)
        let message = try #require(store.draftFileMessage)
        #expect(message.kind == .warning)
        // 합치기 초안은 초안 파일로 세고, 추가 목록은 다시 추가할 일을 따로 안내한다.
        #expect(message.text == LibraryStore.damagedDraftText(1, stagedList: true))
        #expect(message.text.contains("damaged-drafts") && message.text.contains("추가했던 곡 파일을 다시 추가하세요"))
        // 새 합치기 초안을 만들어도 보관한 파일은 그대로다.
        try store.setMergeDrafts([merge()])
        #expect(DuplicateMergeDraftStore.load(url: home.appending(path: DuplicateMergeDraftStore.fileName)) == [merge()])
        #expect(preserved(in: home).count == 2 && preserved(in: home).allSatisfy { (try? Data(contentsOf: $0)) == broken })
    }

    @Test @MainActor func 추가_목록만_손상됐으면_초안_파일_수에_세지_않고_추가_안내만_한다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: StagedTrackFile.fileName))
        let store = store(home: home, fixture: fixture)
        await store.load(snapshot: fixture.database)
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(0, stagedList: true))
        #expect(store.draftFileMessage?.text.contains("초안 파일") == false)
    }

    @Test @MainActor func 편집본을_넣다가_옮긴_추가_목록은_새_목록이_차_있어도_알린다() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: StagedTrackFile.fileName))
        let output = try AudioFixture.wav(seconds: 4, in: home, name: "원곡 (Edit).wav")
        let edit = try TrackEdit(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], sourceDuration: 4, bars: BarRange.list("1-1"))
        let store = store(home: home)
        // 앱과 같은 넣기: 추가 목록은 저장소가 든 목록과 디스크를 한 길로 고친다
        let staged = try await AppComposition.renderEdit(store: store).stager.stage(
            EditStagingRequest(file: output, grid: [edit.outputGrid], cues: [], source: nil, title: "원곡 (Edit)"))
        store.staging.showStagedEdit(staged)
        // 옛 추가 목록은 보관만 됐고 새로 읽은 목록에는 편집본뿐이므로 다시 추가할 일을 알려야 한다.
        #expect(store.staging.staged.map(\.uuid) == [staged.uuid])
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(0, stagedList: true))
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
    }

    @Test @MainActor func 합치기_초안_저장이_손상된_파일을_옮기면_메모리_초안이_비었을_때만_알린다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        let store = store(home: home)
        // 읽은 뒤 바깥에서 깨졌다. 메모리 초안을 새로 썼으니 잃은 것이 없어 알리지 않는다.
        try store.setMergeDrafts([merge("a")])
        try broken.write(to: url)
        try store.setMergeDrafts([merge("a"), merge("b")])
        #expect(DuplicateMergeDraftStore.load(url: url).count == 2)
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(store.draftFileMessage == nil)
        // 메모리 초안이 비었는데 파일이 깨져 있었다: 옛 내용은 보관만 되므로 알린다.
        try store.setMergeDrafts([])
        try broken.write(to: url)
        try store.setMergeDrafts([])
        #expect(preserved(in: home).count == 2)
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(1))
    }

    @Test @MainActor func 추가_목록_저장이_손상된_파일을_옮기면_메모리_목록이_비었을_때만_알린다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: StagedTrackFile.fileName)
        let store = store(home: home)
        // 읽은 뒤 바깥에서 깨졌다. 메모리 목록을 새로 썼으니 잃은 것이 없어 알리지 않는다.
        store.staging.staged = [track("a")]
        try broken.write(to: url)
        #expect(store.staging.restage([track("b")]) == 1)
        #expect(StagedTrackFile.load(url: url).map(\.path) == [track("a").path, track("b").path])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(store.draftFileMessage == nil)
        // 메모리 목록이 비었는데 파일이 깨져 있었다: 옛 목록은 보관만 되므로 다시 추가할 일을 알린다.
        try broken.write(to: url)
        #expect(store.staging.unstage(uuids: Set(store.staging.staged.map(\.uuid))).count == 2 && store.staging.staged.isEmpty)
        #expect(preserved(in: home).count == 2)
        #expect(store.draftFileMessage?.text == LibraryStore.damagedDraftText(0, stagedList: true))
    }
}
