import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 재생 목록 얼리기(R21, #402): 초안을 쓰는 동안 재생 목록 편집은 쓰는 단계를 얼려 두고 받는다. 쓰는 단계와 합치지 않고 뒤에 쌓으며,
/// 쓴 뒤 정리는 쓴 단계만 빼고 쓰는 동안 더한 단계를 남긴다. 또 단계 식별자를 메모리가 이어 받고(출처 세탁 방지), 디스크 초안을 읽지 못하면
/// 옛 메모리로 저장하지 않는다.
@Suite("재생 목록 쓰는 동안 편집(앱)")
@MainActor
struct PlaylistWriteFreezeTests {
    let store: LibraryStore
    let undo = UndoManager()
    let home: URL

    static let rekordbox = PlaylistLayout([
        (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
        (PlaylistLayout.Item(id: "B", name: "나"), 2),
    ])

    init() {
        home = FileManager.default.temporaryDirectory.appending(path: "djc-freeze-\(UUID().uuidString)")
        store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, draftHome: home, movesDamagedDrafts: false)
        store.undoManager = undo
        store.phase = .loaded
        store.playlists.rekordboxPlaylists = Self.rekordbox
        store.playlists.refreshPlaylists()
    }

    var playlists: PlaylistEditStore { store.playlists }
    var file: URL { DraftLocations(home: home).playlist }
    var lock: WriteLock { store.reflection.session.ports.lock }

    /// 세션이 초안을 쓸 때 거는 순서와 같다(`ReflectionSession.lockDraftWrite`): 재생 목록만 쓰는 묶음이라 곡은 없다
    func beginDraftWrite() {
        lock.setTracks([])
        lock.setDraftWriting(true)
        lock.set(true, false)
    }

    func endDraftWrite() {
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
    }

    /// 디스크 초안(식별자·판을 채워 읽는다)과 단계마다 판·읽어 넣은 해시
    func staged() throws -> (draft: PlaylistDraft, entries: [DraftBatchEntry]) {
        let draft = try store.useCases.playlists.loadDraft()
        let entries = zip(draft.steps, store.testDrafts.playlistStamps()).map { step, stamp in
            DraftBatchEntry(stamp: stamp, contentHash: (try? DraftContentHash(step: step, in: draft)) ?? DraftContentHash(hex: ""))
        }
        return (draft, entries)
    }

    // MARK: - 단계 식별자

    @Test func 저장하면_메모리_단계도_저장소가_준_식별자를_갖는다() throws {
        playlists.renamePlaylist("B", to: "새 이름")
        let ids = playlists.playlistDraft.stepIDs
        #expect(ids.count == 1 && ids.allSatisfy { $0 != nil })
        #expect(ids == (try store.useCases.playlists.loadDraft()).stepIDs, "디스크와 같은 식별자다")
        // 같은 단계를 다시 저장해도 단계는 그대로다(식별자 없는 메모리가 저장마다 새 단계를 만들지 않는다)
        let stamps = store.testDrafts.playlistStamps()
        playlists.addTracks([ReflectionPresenterTests.row("9")], toPlaylist: "A")
        #expect(store.testDrafts.playlistStamps().first == stamps.first)
    }

    @Test func 내용이_같고_식별자만_다른_디스크_초안은_조용히_받고_되돌리기는_그대로다() throws {
        playlists.renamePlaylist("B", to: "새 이름")
        let disk = try store.useCases.playlists.loadDraft()
        // 식별자 없이 같은 내용을 가진 메모리 초안(저장하지 않은 단계가 식별자를 받기 전)
        var memory = PlaylistDraft()
        try memory.append(.rename(playlist: .id("B"), name: "새 이름"), rekordbox: Self.rekordbox)
        playlists.playlistDraft = memory
        #expect(playlists.playlistDraft.stepIDs != disk.stepIDs)
        #expect(undo.canUndo)

        let adopted = playlists.adoptExternalDraft(disk)

        #expect(!adopted, "내용이 바뀐 것이 아니다")
        #expect(playlists.playlistDraft.stepIDs == disk.stepIDs)
        #expect(undo.canUndo, "내용이 같으니 되돌리기 기록은 그대로다")
    }

    // MARK: - 읽기 실패

    @Test func 디스크_초안을_읽지_못하면_옛_메모리로_편집하거나_저장하지_않고_다시_읽으면_이어_간다() throws {
        playlists.renamePlaylist("B", to: "새 이름")
        let draft = playlists.playlistDraft
        try Data("깨진 파일".utf8).write(to: file)

        playlists.renamePlaylist("A", to: "다른 이름")
        #expect(playlists.playlistDraft == draft, "읽지 못해 편집하지 않았다")
        #expect(playlists.playlistDraftNeedsSync)
        #expect(!playlists.savePlaylistDraft(), "디스크 초안을 받을 때까지 저장하지 않는다")
        let state = store.reflectionState()
        #expect(state.playlistDraftNeedsSync && state.playlistDraft == draft, "공용 상태는 실제 메모리 초안과 동기화 실패 표시를 함께 준다(쓰기 묶음에서 빼는 것은 세션이 한다)")
        #expect(try Data(contentsOf: file) == Data("깨진 파일".utf8), "깨진 파일을 메모리로 덮지 않았다")

        // 디스크 초안이 다시 읽히면(바깥이 고쳤다) 받고 이어 간다
        var disk = PlaylistDraft()
        try disk.append(.rename(playlist: .id("B"), name: "바깥에서 고친 이름"), rekordbox: Self.rekordbox)
        try PlaylistDraftStore.save(disk, url: file)
        #expect(playlists.syncExternal() == .adopted)
        #expect(!playlists.playlistDraftNeedsSync && playlists.playlistDraft == disk)
        playlists.renamePlaylist("A", to: "다른 이름")
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "바깥에서 고친 이름"), .rename(playlist: .id("A"), name: "다른 이름")])
    }

    // MARK: - 쓰는 동안 편집

    @Test func 쓰는_동안_얼리지_않았으면_재생_목록_편집을_받지_않는다() {
        playlists.renamePlaylist("B", to: "새 이름")
        beginDraftWrite()
        #expect(playlists.isEditBlocked)
        playlists.renamePlaylist("A", to: "다른 이름")
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "새 이름")])
        endDraftWrite()
        #expect(!playlists.isEditBlocked)
    }

    @Test func 복원처럼_초안_쓰기가_아닌_쓰기는_얼리지_못하고_늘_막는다() {
        playlists.renamePlaylist("B", to: "새 이름")
        store.isWritingRekordbox = true
        #expect(!playlists.freezeWrite(playlists.playlistDraft))
        #expect(playlists.isEditBlocked)
        store.isWritingRekordbox = false
    }

    @Test func 식별자가_없는_단계가_있으면_얼리지_못한다() throws {
        var unsaved = PlaylistDraft()
        try unsaved.append(.rename(playlist: .id("B"), name: "새 이름"), rekordbox: Self.rekordbox)
        beginDraftWrite()
        #expect(!playlists.freezeWrite(unsaved))
        #expect(playlists.isEditBlocked)
        endDraftWrite()
    }

    @Test func 쓰는_동안_더한_편집은_쓰는_단계와_합치지_않고_뒤에_쌓인다() throws {
        let id = try #require(playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "새 목록"))
        playlists.renamePlaylist("B", to: "쓰는 이름")
        let written = playlists.playlistDraft
        beginDraftWrite()
        #expect(playlists.freezeWrite(written))
        #expect(!playlists.isEditBlocked)
        // 쓰는 동안 실행 취소를 쌓았는지 보려고 빈 되돌리기 관리자로 바꾼다(`registerUndo`는 묶음을 열어 `groupingLevel`이 오른다)
        let writing = UndoManager()
        store.undoManager = writing

        // 쓰는 만들기 단계에는 이름을 합치지 않고, 쓰는 이름 바꾸기를 마지막 것으로 바꾸지 않는다
        playlists.renamePlaylist(id, to: "고친 이름")
        playlists.renamePlaylist("B", to: "나중 이름")
        #expect(playlists.playlistDraft.edits == written.edits + [.rename(playlist: PlaylistRef(id), name: "고친 이름"),
                                                                 .rename(playlist: .id("B"), name: "나중 이름")])
        #expect(try store.useCases.playlists.loadDraft() == playlists.playlistDraft, "더한 편집도 바로 저장한다")
        #expect(playlists.playlistProjection.blocked.allSatisfy { $0 == nil }, "쓰는 동안 옛 사본 위에서도 더한 편집이 보인다")
        #expect(writing.groupingLevel == 0 && !writing.canUndo, "쓰는 동안 한 편집은 실행 취소에 남기지 않는다")

        // 쓰는 단계는 버리지 않고 더한 단계만 버린다
        playlists.discardPlaylistDraft()
        #expect(playlists.playlistDraft.edits == written.edits)
        endDraftWrite()
        #expect(playlists.playlistDraft.edits == written.edits, "쓰기를 마치면 얼림이 풀리고 편집은 다시 받는다")
        #expect(!playlists.isEditBlocked)
    }

    @Test func 쓴_뒤_정리는_쓴_단계만_빼고_쓰는_동안_더한_단계를_남기며_연결_ID를_옮긴다() throws {
        let id = try #require(playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "새 목록"))
        playlists.renamePlaylist("B", to: "막힐 이름")
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        playlists.renamePlaylist(id, to: "쓰는 동안 고친 이름")
        playlists.renamePlaylist("A", to: "다른 목록 이름")
        playlists.recentPlaylistIDs = [id]
        let outcomes = [PlaylistOutcome(edit: batch.draft.steps[0].edit, playlistID: "777", name: "새 목록", status: .written),
                        PlaylistOutcome(edit: batch.draft.steps[1].edit, playlistID: nil, name: "나", status: .blocked, reason: "바뀜")]

        let cleanup = store.useCases.playlists.finishWrite(batch.draft, outcomes: outcomes, current: playlists.playlistDraft,
                                                            imports: playlists.playlistImports, importsLoadFailed: false,
                                                            entries: batch.entries, backups: URL(filePath: "/tmp/djc-freeze/backups"),
                                                            backupFolder: "w1")
        store.applyReflection(.playlistWritten(cleanup))

        #expect(cleanup.isComplete)
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "막힐 이름"),
                                                  .rename(playlist: .id("777"), name: "쓰는 동안 고친 이름"),
                                                  .rename(playlist: .id("A"), name: "다른 목록 이름")])
        #expect(try store.useCases.playlists.loadDraft() == playlists.playlistDraft)
        #expect(playlists.recentPlaylistIDs == ["777"])
        #expect(playlists.playlistDraft.stepIDs.allSatisfy { $0 != nil })
        #expect(playlists.writeFreeze == nil && playlists.isEditBlocked, "정리한 뒤 새 사본을 읽을 때까지(쓰기를 마칠 때까지) 편집은 받지 않는다")
        endDraftWrite()
        #expect(!playlists.isEditBlocked)
    }

    @Test func 바깥에서_고친_쓴_단계는_백업_폴더에_사본을_남기고_경고를_알린다() throws {
        playlists.renamePlaylist("B", to: "쓴 이름")
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        // 바깥에서 쓴 단계의 내용만 고친다(단계 식별자·도장은 그대로)
        var outside = PlaylistDraft()
        try outside.append(.rename(playlist: .id("B"), name: "바깥에서 고친 이름"), rekordbox: Self.rekordbox)
        outside.setStepIDs(batch.draft.stepIDs)
        try PlaylistDraftStore.save(outside, url: file)
        let backups = home.appending(path: "backups")
        let outcomes = [PlaylistOutcome(edit: batch.draft.steps[0].edit, playlistID: "B", name: "나", status: .written)]

        let cleanup = store.useCases.playlists.finishWrite(batch.draft, outcomes: outcomes, current: batch.draft, imports: playlists.playlistImports,
                                                            importsLoadFailed: false, entries: batch.entries, backups: backups, backupFolder: "w1")
        store.applyReflection(.playlistWritten(cleanup))

        #expect(cleanup.isComplete && cleanup.copied.count == 1)
        let copyURL = try #require(cleanup.copied.values.first)
        #expect(copyURL.path.hasPrefix(backups.appending(path: "w1").path) && FileManager.default.fileExists(atPath: copyURL.path))
        let copy = try JSONDecoder().decode(PlaylistStepCopy.self, from: Data(contentsOf: copyURL))
        #expect(copy.playlistID == "B" && copy.step.edit == .rename(playlist: .id("B"), name: "바깥에서 고친 이름"))
        #expect(playlists.playlistDraft.isEmpty, "고친 단계도 쓴 단계라 빠진다")
        #expect(store.activityLog.latest?.kind == .warning, "사본을 남겼다고 경고한다")
        endDraftWrite()
    }

    // MARK: - 리뷰 1라운드(S6·S7)

    @Test func S6_동기화_실패_표시가_남은_채_쓰기_잠금이_걸리면_재생_목록은_쓰기_묶음에서_빠지고_다른_초안은_막지_않는다() throws {
        playlists.renamePlaylist("B", to: "새 이름")
        let draft = playlists.playlistDraft
        try Data("깨진 파일".utf8).write(to: file)

        // 쓰기 잠금을 거는 순간의 동기화가 디스크 초안을 읽지 못한다
        beginDraftWrite()
        #expect(playlists.playlistDraftNeedsSync)
        #expect(store.reflectionState().playlistDraftNeedsSync && store.reflectionState().playlistDraft == draft,
                "⌘S·자동 저장이 이 표시를 보고 재생 목록을 쓰기 묶음에서 뺀다. 실제 초안은 그대로 둔다(곡 추가 복원이 빈 초안을 저장하지 않게)")
        #expect(playlists.ensurePlaylistDraftSaved(), "다른 종류 초안을 쓰는 것은 막지 않는다")
        #expect(playlists.syncExternal() != .current, "쓰기 잠금 때문에 읽지 않은 것을 맞춘 것으로 보지 않는다")
        #expect(playlists.playlistDraft == draft)
        endDraftWrite()

        // 디스크 초안을 다시 읽으면 재생 목록도 쓰기 묶음에 든다
        try PlaylistDraftStore.save(draft, url: file)
        #expect(playlists.syncExternal() == .current && !playlists.playlistDraftNeedsSync)
        #expect(!store.reflectionState().playlistDraftNeedsSync && store.reflectionState().playlistDraft == draft)
    }

    @Test func S7_동기화_실패_동안은_가져온_곡의_재생_목록_연결과_연결_기록_저장을_미룬다() throws {
        playlists.playlistImports.addFiles(["/fixtures/a"], to: .id("A"))
        playlists.renamePlaylist("B", to: "새 이름")
        let draft = playlists.playlistDraft
        try Data("깨진 파일".utf8).write(to: file)

        playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "9"])

        #expect(playlists.playlistDraft == draft, "옛 메모리에 곡을 더하지 않는다")
        #expect(playlists.playlistImports.pendingCount == 1, "연결은 소비하지 않고 기다린다")
        #expect(try Data(contentsOf: file) == Data("깨진 파일".utf8), "읽지 못한 파일을 옛 메모리로 덮지 않는다")

        // 디스크 초안을 다시 읽으면 이어서 연결한다
        try PlaylistDraftStore.save(draft, url: file)
        playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "9"])
        #expect(playlists.playlistImports.pendingCount == 0)
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "새 이름"), .addTracks(playlist: .id("A"), contentIDs: ["9"])])
    }

    // MARK: - 리뷰 3라운드(S1·S11·S12)

    @Test func S1_공용_상태는_초안_파일_잠금을_쥔_동안만_잠금을_쥐었다고_알린다() async throws {
        let cli = try #require(PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: file)))
        beginDraftWrite()   // CLI가 잠금을 들고 있어 0.3초를 기다려도 잡지 못한다
        #expect(!store.reflectionState().playlistDraftFileLocked, "쥐지 못했으면 이번 쓰기 묶음에서 재생 목록을 뺀다")
        cli()
        // 쓰는 동안 다시 잡으면(한 번 못 잡았다고 쓰기 내내 잠금 없이 두지 않는다) 그 뒤 상태는 쥔 것이다
        var held = false
        for _ in 0..<100 where !held {
            try await Task.sleep(for: .milliseconds(20))
            held = store.reflectionState().playlistDraftFileLocked
        }
        #expect(held)
        endDraftWrite()
    }

    @Test func S11_동기화_실패로_건너뛴_곡_추가_복원의_연결_초기화는_보관했다가_초안을_받은_뒤_한다() throws {
        playlists.playlistImports.addFiles(["/fixtures/a"], to: .id("A"))
        playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "9"])
        let draft = playlists.playlistDraft
        #expect(playlists.playlistImports.pendingCount == 0 && draft.edits == [.addTracks(playlist: .id("A"), contentIDs: ["9"])])
        try Data("깨진 파일".utf8).write(to: file)
        #expect(playlists.syncExternal() == .failed)

        // 세션이 동기화 실패로 건너뛴 곡 추가 복원: 화면이 곡을 보관한다
        store.applyReflection(.playlistImportsReset(EditPlaylists.ImportsReset(contentIDs: ["9"], deferred: true)))
        #expect(playlists.playlistImports.pendingCount == 0 && playlists.playlistDraft == draft, "아직 연결도 초안도 건드리지 않는다")
        #expect(try Data(contentsOf: file) == Data("깨진 파일".utf8))

        // 디스크 초안을 다시 읽으면(동기화 실패 표시가 풀리면) 그 초안으로 초기화한다
        try PlaylistDraftStore.save(draft, url: file)
        _ = playlists.syncExternal()
        #expect(!playlists.playlistDraftNeedsSync)
        #expect(playlists.playlistImports.pendingCount == 1, "복원으로 사라진 곡의 연결이 다시 기다리는 연결이 된다")
        #expect(playlists.playlistDraft.isEmpty, "초안에서 그 곡 편집이 빠진다")
        #expect(try store.useCases.playlists.loadDraft().isEmpty)
    }

    @Test func S12_동기화_실패_중_복원한_재생_목록_편집은_저장하지_않고_대기열에_남기며_회복하면_받은_초안_위에_쌓는다() throws {
        playlists.renamePlaylist("B", to: "새 이름")
        try Data("깨진 파일".utf8).write(to: file)
        #expect(playlists.syncExternal() == .failed)
        playlists.playlistEditsAwaitingReload = [.addTracks(playlist: .id("A"), contentIDs: ["7"])]

        playlists.restoreAwaitingPlaylistEdits()

        #expect(try Data(contentsOf: file) == Data("깨진 파일".utf8), "메모리 초안으로 읽지 못한 파일을 다시 저장하지 않는다")
        #expect(playlists.playlistEditsAwaitingReload.count == 1, "복원한 편집은 대기열에 남는다")

        // 대기열이 남아 있어도 디스크 초안을 읽어 표시를 풀 수 있다(서로 기다리며 멈추지 않는다)
        var disk = PlaylistDraft()
        try disk.append(.rename(playlist: .id("A"), name: "바깥에서 고친 이름"), rekordbox: Self.rekordbox)
        try PlaylistDraftStore.save(disk, url: file)
        _ = playlists.syncExternal()

        #expect(!playlists.playlistDraftNeedsSync && playlists.playlistEditsAwaitingReload.isEmpty)
        let expected: [PlaylistEdit] = [.addTracks(playlist: .id("A"), contentIDs: ["7"]), .rename(playlist: .id("A"), name: "바깥에서 고친 이름")]
        #expect(playlists.playlistDraft.edits == expected, "받은 디스크 초안 위에 복원한 편집을 쌓는다")
        #expect(try store.useCases.playlists.loadDraft().edits == expected)
    }

    @Test func S11_S12_보관한_연결_초기화와_대기열의_복원_편집은_한_번의_회복에서_차례로_이어_하고_서로_기다리지_않는다() throws {
        playlists.playlistImports.addFiles(["/fixtures/a"], to: .id("A"))
        playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "9"])
        let draft = playlists.playlistDraft
        try Data("깨진 파일".utf8).write(to: file)
        #expect(playlists.syncExternal() == .failed)
        store.applyReflection(.playlistImportsReset(EditPlaylists.ImportsReset(contentIDs: ["9"], deferred: true)))
        playlists.playlistEditsAwaitingReload = [.addTracks(playlist: .id("B"), contentIDs: ["7"])]
        playlists.restoreAwaitingPlaylistEdits()
        #expect(playlists.playlistEditsAwaitingReload.count == 1 && playlists.playlistDraft == draft, "실패 중에는 둘 다 미룬다")

        // 한 번 읽어 표시를 풀면 초기화를 먼저 하고 그 초안 위에 복원한 편집을 쌓는다
        try PlaylistDraftStore.save(draft, url: file)
        _ = playlists.syncExternal()

        #expect(!playlists.playlistDraftNeedsSync && playlists.playlistEditsAwaitingReload.isEmpty && playlists.playlistImports.pendingCount == 1)
        #expect(playlists.playlistDraft.edits == [.addTracks(playlist: .id("B"), contentIDs: ["7"])])
        #expect(try store.useCases.playlists.loadDraft().edits == playlists.playlistDraft.edits)
    }
}
