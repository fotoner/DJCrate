import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 쓰는 중에 한 재생 목록 편집의 ⌘Z(#295 E6): 편집 순간 ⌘Z 단계를 걸고, 실행 때 그 편집의 단계가 쓰였는지·지금 초안이 편집 뒤와 맞는지로
/// 저장 전 경로(편집 전 초안)·저장 뒤 경로(역편집)·되돌리지 않음(기록 비움·알림)을 고른다. 지금 디스크 초안에 없는 단계는 기록한 출처를 잇는다.
/// 합치기·재생 기록의 쓰는 중 ⌘Z는 미뤘다가 쓰기 뒤 실행하고, 그새 저장돼 무효면 알린다. 쓰기는 쓰기 잠금과 쓴 뒤 정리(`finishWrite`)로 흉내 낸다.
@Suite("쓰는 중 재생 목록 편집의 실행 취소(앱)")
@MainActor
struct PlaylistUndoDuringWriteTests {
    let store: LibraryStore
    let undo = UndoManager()
    let home: URL
    /// 재생 목록 초안을 저장한 직후 한 번 할 일(저장과 다시 읽기 사이에 바깥 편집을 끼운다)
    let afterSave = AfterPlaylistSave()

    @MainActor final class AfterPlaylistSave {
        var once: (() -> Void)?
        func run() {
            let body = once
            once = nil
            body?()
        }
    }

    /// 재생 목록 초안 저장(보통·출처 잇기) 뒤에 `hook`을 부른다
    static func hookingSaves(_ drafts: inout DraftStore, hook: AfterPlaylistSave) {
        let plain: @MainActor (PlaylistDraft) throws -> Void = drafts.savePlaylistDraft
        drafts.savePlaylistDraft = { (draft: PlaylistDraft) throws in
            try plain(draft)
            hook.run()
        }
        guard let origins = drafts.savePlaylistDraftOrigins else { return }
        drafts.savePlaylistDraftOrigins = { (draft: PlaylistDraft, fresh: [Int: Set<DraftOrigin>]) throws in
            try origins(draft, fresh)
            hook.run()
        }
    }

    static let rekordbox = PlaylistLayout([
        (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
        (PlaylistLayout.Item(id: "B", name: "나"), 2),
    ])

    init() {
        home = FileManager.default.temporaryDirectory.appending(path: "djc-undo-writing-\(UUID().uuidString)")
        // 앱의 편집 포트처럼 사람 편집 출처로 저장한다(되살린 단계가 그 출처를 잇는지 본다)
        let hook = afterSave
        store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, draftHome: home, movesDamagedDrafts: false,
                                  draftOrigin: .human, ports: { Self.hookingSaves(&$0.drafts, hook: hook) })
        store.undoManager = undo
        store.phase = .loaded
        store.playlists.rekordboxPlaylists = Self.rekordbox
        store.playlists.refreshPlaylists()
    }

    var playlists: PlaylistEditStore { store.playlists }
    var file: URL { DraftLocations(home: home).playlist }
    var lock: WriteLock { store.reflection.session.ports.lock }
    var clearedText: String { LibraryStore.undoClearedText }

    /// 사용자 동작 하나(앱에서는 이벤트가 끝나면 ⌘Z 묶음이 닫힌다)
    func event(_ body: () -> Void) {
        let byEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
        undo.groupsByEvent = byEvent
    }

    /// 세션이 초안을 쓸 때 거는 순서와 같다(재생 목록만 쓰는 묶음)
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

    /// 디스크 초안의 앞 `count` 단계(없으면 모두)와 단계마다 판·읽어 넣은 해시: 쓰기 묶음
    func staged(_ count: Int? = nil) throws -> (draft: PlaylistDraft, entries: [DraftBatchEntry]) {
        var draft = try store.useCases.playlists.loadDraft()
        var entries = zip(draft.steps, store.testDrafts.playlistStamps()).map { step, stamp in
            DraftBatchEntry(stamp: stamp, contentHash: (try? DraftContentHash(step: step, in: draft)) ?? DraftContentHash(hex: ""))
        }
        if let count, count < draft.steps.count {
            draft.removeSteps(at: count..<draft.steps.count)
            entries = Array(entries.prefix(count))
        }
        return (draft, entries)
    }

    /// 쓰기 묶음을 모두 썼다고 정리하고(관문 결과), rekordbox 목록도 쓴 모양으로 바꾼다(다시 읽은 사본).
    /// `created`는 만든 목록의 실제 ID, `rekordbox`를 주면 쓴 뒤 rekordbox 목록을 그것으로 둔다(만든 목록이 실제 ID로 든 모양)
    func finish(_ batch: (draft: PlaylistDraft, entries: [DraftBatchEntry]), created: [String] = [], backups: URL? = nil,
                rekordbox: PlaylistLayout? = nil) throws {
        var created = created
        var layout = playlists.rekordboxPlaylists
        let outcomes = batch.draft.steps.map { step -> PlaylistOutcome in
            var id: String?
            if case .create = step.edit, !created.isEmpty { id = created.removeFirst() }
            return PlaylistOutcome(edit: step.edit, playlistID: id, name: "", status: .written)
        }
        for step in batch.draft.steps { try? layout.apply(step.edit) }
        let cleanup = store.useCases.playlists.finishWrite(batch.draft, outcomes: outcomes, current: playlists.playlistDraft,
                                                            imports: playlists.playlistImports, importsLoadFailed: false, entries: batch.entries,
                                                            backups: backups ?? home.appending(path: "backups"), backupFolder: "w1")
        store.applyReflection(.playlistWritten(cleanup))
        playlists.rekordboxPlaylists = rekordbox ?? layout
        playlists.refreshPlaylists()
    }

    // MARK: - 쓰는 중 편집도 단계를 건다

    @Test func 쓰는_중_목록_편집_두_번_뒤_실행_취소_한_번은_마지막_편집만_되돌린다() throws {
        event { playlists.renamePlaylist("B", to: "쓰는 이름") }
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        event { playlists.renamePlaylist("A", to: "첫 이름") }
        event { playlists.addTracks([ReflectionPresenterTests.row("9")], toPlaylist: "A") }
        try finish(batch)
        endDraftWrite()
        undo.undo()
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("A"), name: "첫 이름")], "마지막 편집(곡 넣기)만 되돌린다")
        #expect(undo.canUndo)
    }

    @Test func 쓰는_중_목록_지우기는_쓰기_뒤_실행_취소로_취소하고_아래_기록은_남는다() throws {
        event { playlists.renamePlaylist("B", to: "쓰는 이름") }
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        event { playlists.deletePlaylist("A") }
        try finish(batch)
        endDraftWrite()
        undo.undo()
        #expect(playlists.playlistDraft.isEmpty, "지우기를 취소했다")
        #expect(playlists.playlistItem("A") != nil)
        #expect(undo.canUndo, "아래 기록(쓴 이름 바꾸기)은 남는다")
    }

    @Test func 쓰는_중_만든_목록에_넣은_곡은_쓰기_뒤_곡_넣기만_취소한다() throws {
        var created: String?
        event { created = playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "새 목록") }
        let id = try #require(created)
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        event { playlists.addTracks([ReflectionPresenterTests.row("9")], toPlaylist: id) }
        try finish(batch, created: ["777"], rekordbox: PlaylistLayout([
            (PlaylistLayout.Item(id: "777", name: "새 목록"), 0),
            (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
            (PlaylistLayout.Item(id: "B", name: "나"), 2),
        ]))
        endDraftWrite()
        #expect(playlists.playlistDraft.edits == [.addTracks(playlist: .id("777"), contentIDs: ["9"])])
        undo.undo()
        #expect(playlists.playlistDraft.isEmpty, "곡 넣기만 취소한다")
        #expect(playlists.playlistItem("777") != nil, "만든 목록은 남는다")
    }

    @Test func 첫_저장_중_다른_목록_이름과_지우기를_더하고_두_번째_저장_뒤_실행_취소는_지우기만_취소한다() throws {
        event { playlists.renamePlaylist("B", to: "쓰는 이름") }
        let first = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(first.draft))
        event { playlists.renamePlaylist("A", to: "새 가") }
        event { playlists.deletePlaylist("B") }
        try finish(first)
        endDraftWrite()
        // 두 번째 저장은 이름 바꾸기만 쓴다(지우기는 자동 저장 대상 밖)
        let second = try staged(1)
        beginDraftWrite()
        #expect(playlists.freezeWrite(second.draft))
        try finish(second)
        endDraftWrite()
        undo.undo()
        #expect(playlists.playlistDraft.isEmpty, "지우기만 취소한다")
        #expect(playlists.playlistItem("A")?.name == "새 가" && playlists.playlistItem("B") != nil)
    }

    @Test func 쓰는_중_새_목록을_만들고_이름을_바꾸면_실행_취소는_이름만_되돌리고_실행_복귀하면_목록_하나에_새_이름이다() throws {
        event { playlists.renamePlaylist("B", to: "쓰는 이름") }
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        var created: String?
        event { created = playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "새 목록") }
        let id = try #require(created)
        event { playlists.renamePlaylist(id, to: "고친 이름") }
        try finish(batch)
        endDraftWrite()
        undo.undo()
        #expect(playlists.playlistItem(id)?.name == "새 목록", "이름만 되돌리고 목록은 남는다")
        undo.redo()
        let made = playlists.playlistProjection.layout.outline.filter { $0.id.hasPrefix("new:") }
        #expect(made.count == 1 && made.first?.name == "고친 이름")
    }

    // MARK: - 출처 잇기

    /// rekordbox가 켜진 동안(쓰지 못함) 새 목록 + 곡 넣기 + 지우기 → ⌘Z로 목록과 곡이 돌아온다. 되살린 단계는 기록한 출처(사람 편집)를 잇는다:
    /// 실제 도장 저장소에서 `{human}`이라 rekordbox를 끄면 자동 저장 대상이다. ⇧⌘Z 뒤에는 목록이 없다
    @Test func 지운_새_목록을_실행_취소로_되살리면_사람_편집_출처라_자동_저장_대상이고_실행_복귀하면_없다() throws {
        var created: String?
        event { created = playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "새 목록") }
        let id = try #require(created)
        event { playlists.addTracks([ReflectionPresenterTests.row("9")], toPlaylist: id) }
        event { playlists.deletePlaylist(id) }
        #expect(playlists.playlistDraft.isEmpty)
        undo.undo()
        #expect(playlists.playlistItem(id) != nil && playlists.playlistDraft.steps.count == 2, "목록과 곡 넣기가 돌아온다")
        let stamps = store.testDrafts.playlistStamps()
        #expect(!stamps.isEmpty && stamps.allSatisfy { $0.origins == [.human] }, "되살린 단계는 사람 편집 출처다: \(stamps.map(\.origins))")
        #expect(store.testDrafts.playlistSuggestions().allSatisfy { $0 == nil }, "제안이 아니라 자동 저장 대상이다")
        undo.redo()
        #expect(playlists.playlistItem(id) == nil && playlists.playlistDraft.isEmpty)
    }

    /// 바깥에서 내용만 바뀐 사람 단계(식별자·도장 그대로, 해시가 어긋나 제안)를 버린 뒤 ⌘Z하면 되살린 단계도 제안으로 남는다(리뷰 F1)
    @Test func 바깥에서_내용만_바뀐_사람_단계를_버린_뒤_실행_취소하면_제안으로_남는다() throws {
        event { playlists.renamePlaylist("B", to: "사람 이름") }
        var outside = PlaylistDraft()
        try outside.append(.rename(playlist: .id("B"), name: "바깥 이름"), rekordbox: Self.rekordbox)
        outside.setStepIDs(playlists.playlistDraft.stepIDs)
        try PlaylistDraftStore.save(outside, url: file)
        #expect(playlists.syncExternal() == .adopted)
        #expect(store.testDrafts.playlistSuggestions().first.flatMap { $0 } != nil, "해시가 어긋나 제안이다")
        event { playlists.discardPlaylistDraft("B") }
        #expect(playlists.playlistDraft.isEmpty)
        undo.undo()
        #expect(playlists.playlistDraft.edits == outside.edits)
        #expect(store.testDrafts.playlistStamps().first?.origins.contains(.unknown) == true, "바깥 변경을 모름으로 잇는다")
        #expect(store.testDrafts.playlistSuggestions().first.flatMap { $0 } != nil, "되살린 단계도 제안으로 남는다")
    }

    @Test func CLI_단계가_든_목록을_버린_뒤_실행_취소하면_CLI_제안으로_남는다() throws {
        var cli = PlaylistDraft()
        try cli.append(.rename(playlist: .id("A"), name: "CLI 이름"), rekordbox: Self.rekordbox)
        _ = try StampedDrafts.savePlaylist(cli, url: file, origin: .cli)
        #expect(playlists.syncExternal() == .adopted)
        event { playlists.discardPlaylistDraft("A") }
        #expect(playlists.playlistDraft.isEmpty)
        undo.undo()
        #expect(playlists.playlistDraft.edits == cli.edits)
        #expect(store.testDrafts.playlistStamps().map(\.origins) == [[.cli]], "기록한 출처(CLI)를 잇는다")
    }

    /// 도장 사이드카를 고칠 수 없게 해 초안 저장을 실패시킨다(`restore`로 되돌린다)
    func failingSaves() throws -> () -> Void {
        let stamps = DraftStampStore.folder(home: home)
        try FileManager.default.createDirectory(at: stamps, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stamps.path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stamps.path) }
    }

    /// 디스크에 CLI 이름 바꾸기(A)를 두고 앱이 받는다
    func adoptCLIRename() throws -> PlaylistDraft {
        var cli = PlaylistDraft()
        try cli.append(.rename(playlist: .id("A"), name: "CLI 이름"), rekordbox: Self.rekordbox)
        _ = try StampedDrafts.savePlaylist(cli, url: file, origin: .cli)
        #expect(playlists.syncExternal() == .adopted)
        return cli
    }

    /// CLI 단계를 버린 뒤 ⌘Z로 되살리되 그 저장이 실패한다(식별자 없는 CLI 단계가 메모리에만 남는다)
    func revivedCLIStepUnsaved() throws -> PlaylistDraft {
        let cli = try adoptCLIRename()
        event { playlists.discardPlaylistDraft("A") }
        let restore = try failingSaves()
        undo.undo()
        restore()
        #expect(playlists.playlistDraftUnsaved && playlists.playlistDraft.edits == cli.edits, "되살렸지만 저장하지 못했다")
        return cli
    }

    /// ⌘Z가 되살린 CLI 단계의 저장이 실패한 뒤 다른 편집이 저장되면 그 단계는 CLI 제안으로 남는다(사람 출처로 바뀌지 않는다, 리뷰 F5·F10).
    /// 저장에 실패한 동안의 출처는 식별자 없는 단계 모두에 더한다(단계 대응을 찾지 않는다): 그새 한 사람 편집도 제안이 된다
    @Test func 실행_취소가_되살린_CLI_단계를_저장하지_못한_뒤_다른_편집을_저장해도_CLI_제안으로_남는다() throws {
        _ = try revivedCLIStepUnsaved()
        event { playlists.renamePlaylist("B", to: "사람 이름") }
        #expect(!playlists.playlistDraftUnsaved)
        let stamps = store.testDrafts.playlistStamps()
        #expect(stamps.map(\.origins) == [[.cli, .human], [.cli, .human]], "되살린 단계는 CLI 출처를 잇는다: \(stamps.map(\.origins))")
    }

    /// 복원이 되살린 재생 목록 단계의 저장이 실패한 뒤 다른 편집이 저장되면 그 단계는 복원 출처(제안)로 남는다(리뷰 F5·F10)
    @Test func 복원이_되살린_단계를_저장하지_못한_뒤_다른_편집을_저장해도_복원_출처로_남는다() throws {
        let restore = try failingSaves()
        let failed = playlists.restorePlaylistEdits([.rename(playlist: .id("A"), name: "되살린 이름")])
        restore()
        #expect(failed == 0 && playlists.playlistDraftUnsaved, "되살렸지만 저장하지 못했다")
        event { playlists.renamePlaylist("B", to: "사람 이름") }
        #expect(!playlists.playlistDraftUnsaved)
        let stamps = store.testDrafts.playlistStamps()
        #expect(stamps.map(\.origins) == [[.restored, .human], [.restored, .human]], "되살린 단계는 복원 출처를 잇는다: \(stamps.map(\.origins))")
    }

    /// 복원은 그대로 둔 단계도 다시 쌓아 식별자 없이 저장한다. 그 저장이 실패하면 기존 CLI 단계도 복원 출처를 기억해 다음 저장에서 제안이다(리뷰 F10: G7)
    @Test func 복원_저장이_실패하면_다시_쌓은_기존_CLI_단계도_다음_저장에서_제안이다() throws {
        _ = try adoptCLIRename()
        let restore = try failingSaves()
        playlists.restorePlaylistEdits([.rename(playlist: .id("B"), name: "되살린 이름")])
        restore()
        #expect(playlists.playlistDraftUnsaved && playlists.playlistDraft.stepIDs.allSatisfy { $0 == nil }, "다시 쌓은 단계는 식별자가 없다")
        event { _ = playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "새 목록") }
        #expect(!playlists.playlistDraftUnsaved)
        let stamps = store.testDrafts.playlistStamps()
        #expect(stamps.count == 3 && stamps.allSatisfy { $0.origins == [.restored, .human] }, "\(stamps.map(\.origins))")
    }

    /// 복원 저장도 기억한 출처를 더하고, 성공하면 비운다(리뷰 F10: G7). 그 뒤 사람 편집은 사람 출처다
    @Test func 복원_저장은_기억한_출처를_더하고_성공하면_비운다() throws {
        _ = try revivedCLIStepUnsaved()
        playlists.restorePlaylistEdits([.rename(playlist: .id("B"), name: "되살린 이름")])
        #expect(!playlists.playlistDraftUnsaved)
        let restored = store.testDrafts.playlistStamps().map(\.origins)
        #expect(restored == [[.cli, .restored], [.cli, .restored]], "\(restored)")
        event { _ = playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, name: "새 목록") }
        let created = store.testDrafts.playlistStamps().map(\.origins)
        #expect(created.count == 3 && created.last == [.human], "\(created)")
    }

    /// 저장하지 못한 되살린 CLI 만들기 단계의 이름을 바꾸면(만들기에 합쳐져 단계 내용이 바뀐다) 다음 저장에서도 제안이다(리뷰 F10: G8)
    @Test func 저장하지_못한_되살린_CLI_만들기의_이름을_바꿔도_제안이다() throws {
        var cli = PlaylistDraft()
        try cli.append(.create(key: "K", name: "CLI 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        _ = try StampedDrafts.savePlaylist(cli, url: file, origin: .cli)
        #expect(playlists.syncExternal() == .adopted)
        event { playlists.discardPlaylistDraft(PlaylistRef.new("K").layoutID) }
        #expect(playlists.playlistDraft.isEmpty)
        let restore = try failingSaves()
        undo.undo()
        restore()
        #expect(playlists.playlistDraftUnsaved && playlists.playlistDraft.edits == cli.edits)
        event { playlists.renamePlaylist(PlaylistRef.new("K").layoutID, to: "사람 이름") }
        #expect(!playlists.playlistDraftUnsaved)
        #expect(playlists.playlistDraft.edits == [.create(key: "K", name: "사람 이름", isFolder: false, parent: .root)], "이름 바꾸기가 만들기에 합쳐졌다")
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human]], "\(origins)")
    }

    /// 저장하지 못한 되살린 CLI 단계는 곡 넣기 연결 저장에서도 제안이다(리뷰 F10: O10)
    @Test func 저장하지_못한_되살린_CLI_단계는_곡_넣기_연결_저장에서도_제안이다() throws {
        _ = try revivedCLIStepUnsaved()
        playlists.playlistImports.addFiles(["/fixtures/a"], to: .id("B"))
        playlists.resolvePlaylistImports(contentIDsByPath: ["/fixtures/a": "9"])
        #expect(try store.useCases.playlists.loadDraft().steps.count == 2, "곡을 넣어 저장했다")
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human], [.cli, .human]], "\(origins)")
        // 메모리 초안을 모두 저장했으니 저장 실패 표시와 알림을 거둔다(리뷰 F12)
        #expect(!playlists.playlistDraftUnsaved && playlists.saveFailureToast == nil)
    }

    /// 곡 넣기를 되돌릴 때 세션이 하는 초안 저장도 기억한 출처를 더한다(리뷰 F10: O10, `restoreStaged`의 `resetImports`)
    @Test func 저장하지_못한_되살린_CLI_단계는_곡_넣기_되돌리기_저장에서도_제안이다() throws {
        _ = try revivedCLIStepUnsaved()
        store.resetPlaylistImports(contentIDs: ["9"])
        #expect(try store.useCases.playlists.loadDraft().edits == playlists.playlistDraft.edits, "되살린 단계를 저장했다")
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human]], "\(origins)")
        // 메모리 초안을 모두 저장했으니 저장 실패 표시와 알림을 거둔다(리뷰 F12)
        #expect(!playlists.playlistDraftUnsaved && playlists.saveFailureToast == nil)
    }

    /// 손상된 재생 목록 초안 파일을 옮긴 뒤 메모리 초안을 다시 저장해도 저장하지 못한 되살린 CLI 단계는 제안이다(F10과 같은 원칙, `WatchDrafts.recoverMoved`)
    @Test func 손상_파일을_옮긴_뒤_다시_저장해도_저장하지_못한_되살린_CLI_단계는_제안이다() throws {
        _ = try revivedCLIStepUnsaved()
        store.applyMovedDrafts([DamagedDraftFile(name: DraftFileNames.playlist, preserved: home.appending(path: "damaged"), trackUUID: nil)],
                               reporting: false)
        #expect(!playlists.playlistDraftUnsaved, "메모리 초안을 다시 저장했다")
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human]], "\(origins)")
        #expect(playlists.unsavedStepOrigins.isEmpty, "저장에 성공하면 기억한 출처를 비운다")
    }

    /// 막힌 편집 복구 시트가 초안을 저장해도 저장하지 못한 되살린 CLI 단계는 제안이다(F10과 같은 원칙, `applyPlaylistRecovery`)
    @Test func 막힌_편집_복구가_저장해도_저장하지_못한_되살린_CLI_단계는_제안이다() async throws {
        let cli = try adoptCLIRename()
        event { playlists.discardPlaylistDraft("A") }
        let restore = try failingSaves()
        undo.undo()
        // 저장하지 못하는 동안 B 이름도 바꾼다(rekordbox에서 B 이름이 바뀌어 그 편집은 막힌다)
        event { playlists.renamePlaylist("B", to: "사람 이름") }
        restore()
        let rename = PlaylistEdit.rename(playlist: .id("B"), name: "사람 이름")
        #expect(playlists.playlistDraftUnsaved && playlists.playlistDraft.edits == cli.edits + [rename])
        let changed = PlaylistLayout([
            (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
            (PlaylistLayout.Item(id: "B", name: "바깥 이름"), 2),
        ])
        let current = PlaylistRecoveryCurrent(layout: changed, contentIDs: ["1"], titles: [:], rows: [:])
        let review = try RecoverDrafts.review(playlist: "B", draft: playlists.playlistDraft, current: current)
        try await playlists.applyPlaylistRecovery(review, reapply: false, latest: current)
        #expect(playlists.playlistDraft.edits == cli.edits, "막힌 B 편집만 버렸다")
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human]], "\(origins)")
        #expect(playlists.unsavedStepOrigins.isEmpty, "저장에 성공하면 기억한 출처를 비운다")
    }

    /// A·B·C 목록(복구 시험에서 막힌 목록 두 개를 만든다)
    static let threeLists = PlaylistLayout([
        (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
        (PlaylistLayout.Item(id: "B", name: "나"), 2),
        (PlaylistLayout.Item(id: "C", name: "다"), 3),
    ])

    /// 막힌 목록 두 개를 복구 시트처럼 차례로 복구해도(앞 목록을 저장한 뒤 다음 목록을 새로 비교) 저장하지 못한 되살린 CLI 단계는 제안이다(리뷰 F11).
    /// 앞 복구가 저장한 단계의 식별자를 받지 않으면 다음 복구 저장이 그 단계를 새 사람 단계로 다시 쓴다
    @Test func 막힌_목록_두_개를_차례로_복구해도_저장하지_못한_되살린_CLI_단계는_제안이다() async throws {
        playlists.rekordboxPlaylists = Self.threeLists
        playlists.refreshPlaylists()
        let cli = try adoptCLIRename()
        event { playlists.discardPlaylistDraft("A") }
        let restore = try failingSaves()
        undo.undo()
        event { playlists.renamePlaylist("B", to: "사람 B") }
        event { playlists.renamePlaylist("C", to: "사람 C") }
        restore()
        #expect(playlists.playlistDraftUnsaved && playlists.playlistDraft.steps.count == 3)
        let changed = PlaylistLayout([
            (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
            (PlaylistLayout.Item(id: "B", name: "바깥 B"), 2),
            (PlaylistLayout.Item(id: "C", name: "바깥 C"), 3),
        ])
        let current = PlaylistRecoveryCurrent(layout: changed, contentIDs: ["1"], titles: [:], rows: [:])
        for id in ["B", "C"] {
            let review = try RecoverDrafts.review(playlist: id, draft: playlists.playlistDraft, current: current)
            try await playlists.applyPlaylistRecovery(review, reapply: false, latest: current)
        }
        #expect(playlists.playlistDraft.edits == cli.edits, "막힌 B·C 편집만 버렸다")
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human]], "\(origins)")
    }

    /// 손상 초안 복구가 저장한 직후 곡 넣기 되돌리기(세션)가 저장해도 저장하지 못한 되살린 CLI 단계는 제안이다(리뷰 F11)
    @Test func 손상_초안_복구_직후_곡_넣기_되돌리기가_저장해도_제안이다() throws {
        _ = try revivedCLIStepUnsaved()
        store.applyMovedDrafts([DamagedDraftFile(name: DraftFileNames.playlist, preserved: home.appending(path: "damaged"), trackUUID: nil)],
                               reporting: false)
        store.resetPlaylistImports(contentIDs: ["9"])
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human]], "\(origins)")
    }

    /// 디스크 재생 목록 초안을 읽지 못한 동안은 막힌 편집 복구가 초안을 덮지 않는다(리뷰 F11: 저장한 단계의 식별자를 다시 받지 못한 경우)
    @Test func 디스크_초안을_읽지_못한_동안은_막힌_편집을_복구하지_않는다() async throws {
        event { playlists.renamePlaylist("B", to: "사람 이름") }
        let edits = playlists.playlistDraft.edits
        try Data("손상".utf8).write(to: file)
        #expect(playlists.syncExternal() == .failed && playlists.playlistDraftNeedsSync)
        let changed = PlaylistLayout([
            (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
            (PlaylistLayout.Item(id: "B", name: "바깥 이름"), 2),
        ])
        let current = PlaylistRecoveryCurrent(layout: changed, contentIDs: ["1"], titles: [:], rows: [:])
        let review = try RecoverDrafts.review(playlist: "B", draft: playlists.playlistDraft, current: current)
        await #expect(throws: DJCError.self) { try await playlists.applyPlaylistRecovery(review, reapply: false, latest: current) }
        #expect(playlists.playlistDraft.edits == edits, "메모리 초안을 바꾸지 않는다")
        #expect((try? Data(contentsOf: file)) == Data("손상".utf8), "디스크 초안을 덮지 않는다")
    }

    /// B·C 이름이 rekordbox에서 바뀐 A·B·C 목록(그 목록의 이름 바꾸기가 막힌다)
    static let threeListsChanged = PlaylistLayout([
        (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
        (PlaylistLayout.Item(id: "B", name: "바깥 B"), 2),
        (PlaylistLayout.Item(id: "C", name: "바깥 C"), 3),
    ])

    /// 막힌 편집 복구가 저장한 뒤 다시 읽기 전에 CLI가 단계를 더하면(내용이 달라 식별자를 받지 못한다) 다시 읽기를 기다린다:
    /// 다음 복구 줄이 그 초안을 덮지 않고, 다음 동기화가 바깥 초안을 받는다(리뷰 F14)
    @Test func 복구_저장과_다시_읽기_사이에_CLI가_단계를_더하면_다음_복구가_덮지_않는다() async throws {
        playlists.rekordboxPlaylists = Self.threeLists
        playlists.refreshPlaylists()
        event { playlists.renamePlaylist("B", to: "사람 B") }
        event { playlists.renamePlaylist("C", to: "사람 C") }
        let cliStep = PlaylistEdit.rename(playlist: .id("A"), name: "CLI 이름")
        let url = file
        afterSave.once = {
            // CLI(`djc draft playlist`)가 디스크 초안에 단계를 더한다
            var disk = PlaylistDraftStore.load(url: url)
            try? disk.append(cliStep, rekordbox: Self.threeLists)
            _ = try? StampedDrafts.savePlaylist(disk, url: url, origin: .cli)
        }
        let current = PlaylistRecoveryCurrent(layout: Self.threeListsChanged, contentIDs: ["1"], titles: [:], rows: [:])
        let first = try RecoverDrafts.review(playlist: "B", draft: playlists.playlistDraft, current: current)
        try await playlists.applyPlaylistRecovery(first, reapply: false, latest: current)
        #expect(playlists.playlistDraftNeedsSync, "다시 읽은 초안이 메모리와 달라 식별자를 받지 못했다")
        let second = try RecoverDrafts.review(playlist: "C", draft: playlists.playlistDraft, current: current)
        await #expect(throws: DJCError.self) { try await playlists.applyPlaylistRecovery(second, reapply: false, latest: current) }
        #expect(try store.useCases.playlists.loadDraft().edits.contains(cliStep), "CLI가 더한 단계가 디스크에 남는다")
        #expect(playlists.syncExternal() == .adopted && playlists.playlistDraft.edits.contains(cliStep), "다음 동기화가 바깥 초안을 받는다")
    }

    /// 복구를 준비한 뒤 적용하기 전에 손상 초안 복구가 단계 식별자를 채우면 낡은 준비로 적용하지 않는다(내용만 같고 식별자가 다르다).
    /// 다시 준비해 적용하면 저장하지 못했던 되살린 CLI 단계는 제안이다(리뷰 F15)
    @Test func 복구_준비와_적용_사이에_식별자가_채워지면_다시_준비하고_CLI_단계는_제안이다() async throws {
        let cli = try adoptCLIRename()
        event { playlists.discardPlaylistDraft("A") }
        let restore = try failingSaves()
        undo.undo()
        event { playlists.renamePlaylist("B", to: "사람 이름") }
        restore()
        let changed = PlaylistLayout([
            (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
            (PlaylistLayout.Item(id: "B", name: "바깥 이름"), 2),
        ])
        let current = PlaylistRecoveryCurrent(layout: changed, contentIDs: ["1"], titles: [:], rows: [:])
        let stale = try await playlists.preparePlaylistRecovery(playlist: "B", prefetched: current)
        store.applyMovedDrafts([DamagedDraftFile(name: DraftFileNames.playlist, preserved: home.appending(path: "damaged"), trackUUID: nil)],
                               reporting: false)
        #expect(playlists.playlistDraft.stepIDs.allSatisfy { $0 != nil }, "손상 초안 복구가 식별자를 채웠다")
        await #expect(throws: DJCError.self) { try await playlists.applyPlaylistRecovery(stale, reapply: false, latest: current) }
        let fresh = try await playlists.preparePlaylistRecovery(playlist: "B", prefetched: current)
        try await playlists.applyPlaylistRecovery(fresh, reapply: false, latest: current)
        #expect(playlists.playlistDraft.edits == cli.edits, "막힌 B 편집만 버렸다")
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human]], "\(origins)")
    }

    /// 쓰는 동안 저장하지 못한 편집을 쓴 뒤 정리가 메모리 초안으로 저장하면 기억한 출처를 비운다(리뷰 F13)
    @Test func 쓴_뒤_정리가_메모리_초안을_저장하면_기억한_출처를_비운다() throws {
        event { playlists.renamePlaylist("B", to: "쓰는 이름") }
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        let restore = try failingSaves()
        event { playlists.renamePlaylist("A", to: "쓰는 중 이름") }
        restore()
        #expect(playlists.playlistDraftUnsaved && !playlists.unsavedStepOrigins.isEmpty, "쓰는 중 편집을 저장하지 못했다")
        let outcomes = batch.draft.steps.map { PlaylistOutcome(edit: $0.edit, playlistID: nil, name: "", status: .written) }
        let cleanup = store.useCases.playlists.finishWrite(batch.draft, outcomes: outcomes, current: playlists.playlistDraft,
                                                            imports: playlists.playlistImports, importsLoadFailed: false, entries: batch.entries,
                                                            backups: home.appending(path: "backups"), backupFolder: "w1", memoryUnsaved: true)
        store.applyReflection(.playlistWritten(cleanup))
        endDraftWrite()
        #expect(cleanup.draftError == nil && !playlists.playlistDraftUnsaved, "쓴 뒤 정리가 메모리 초안을 저장했다")
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("A"), name: "쓰는 중 이름")])
        #expect(playlists.unsavedStepOrigins.isEmpty)
    }

    /// 되살린 CLI 단계의 저장이 실패한 뒤 그 단계를 다시 버려 저장하고 ⌘Z하면, 되살린 단계는 그 ⌘Z 기록이 든 출처로 제안이다(리뷰 F10: S4).
    /// 디스크에 없는 식별자 없는 단계라 디스크 도장으로는 출처를 알 수 없다
    @Test func 저장하지_못한_되살린_CLI_단계를_다시_버린_뒤_실행_취소해도_제안이다() throws {
        let cli = try revivedCLIStepUnsaved()
        event { playlists.discardPlaylistDraft("A") }
        #expect(!playlists.playlistDraftUnsaved && playlists.playlistDraft.isEmpty)
        undo.undo()
        #expect(playlists.playlistDraft.edits == cli.edits)
        let origins = store.testDrafts.playlistStamps().map(\.origins)
        #expect(origins == [[.cli, .human]], "\(origins)")
    }

    // MARK: - 저장 전 경로·역편집

    @Test func 이름을_A에서_B_C로_바꾼_뒤_실행_취소하면_B다() throws {
        event { playlists.renamePlaylist("A", to: "B") }
        event { playlists.renamePlaylist("A", to: "C") }
        undo.undo()
        #expect(playlists.playlistItem("A")?.name == "B")
    }

    /// 얼린 이름 바꾸기(A→B)를 미리 보는 중 B→C → 앞 저장이 보류됨(쓰지 않음) → ⌘Z가 B→C만 취소한다
    @Test func 얼린_이름_바꾸기를_미리_보는_중_다시_바꾸고_저장이_보류되면_실행_취소는_나중_바꾸기만_취소한다() throws {
        event { playlists.renamePlaylist("A", to: "B") }
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        event { playlists.renamePlaylist("A", to: "C") }
        playlists.thawWrite()
        endDraftWrite()
        undo.undo()
        #expect(playlists.playlistItem("A")?.name == "B")
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("A"), name: "B")])
    }

    /// DB에는 썼지만 초안 정리가 실패해 단계가 초안에 남았다: ⌘Z는 초안에서 그 단계만 빼지 않고 역편집을 쌓는다
    @Test func DB에_썼지만_초안_정리가_실패하면_실행_취소는_역편집이다() throws {
        event { playlists.renamePlaylist("B", to: "쓴 이름") }
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        // 도장 사이드카를 고칠 수 없어 쓴 단계 정리가 실패한다: 초안은 편집 뒤 그대로 남는다
        let stamps = DraftStampStore.folder(home: home)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stamps.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stamps.path) }
        try finish(batch)
        endDraftWrite()
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "쓴 이름")], "정리가 실패해 쓴 단계가 초안에 그대로 남았다")
        undo.undo()
        #expect(playlists.playlistDraft.edits.last == .rename(playlist: .id("B"), name: "나"), "초안에서 빼지 않고 쓴 이름을 되돌리는 역편집을 쌓는다")
    }

    // MARK: - 되돌리지 않음(기록 비움·알림)

    @Test func 미룬_실행_취소_뒤_같은_목록을_또_옮기면_적용하지_않고_알린다() throws {
        event { playlists.renamePlaylist("B", to: "쓰는 이름") }
        let batch = try staged()
        beginDraftWrite()
        #expect(playlists.freezeWrite(batch.draft))
        event { playlists.movePlaylist("A", into: PlaylistLayout.root) }
        undo.undo()
        event { playlists.movePlaylist("A", into: PlaylistLayout.root, before: "B") }
        let draft = playlists.playlistDraft
        try finish(batch)
        endDraftWrite()
        #expect(playlists.playlistDraft.edits == Array(draft.edits.dropFirst()), "미룬 실행 취소를 적용하지 않았다")
        #expect(store.activityLog.latest?.title == clearedText, "이유를 알린다")
        #expect(!undo.canUndo)
    }

    /// rekordbox에서 바뀐 목록의 막힌 편집을 버린 뒤 ⌘Z → 되살아난다(편집 전에도 막혀 있던 단계라 새로 막힌 것으로 치지 않는다)
    @Test func 막힌_편집을_버린_뒤_실행_취소하면_되살아난다() throws {
        event { playlists.renamePlaylist("B", to: "새 이름") }
        var changed = Self.rekordbox
        try changed.apply(.rename(playlist: .id("B"), name: "바깥 이름"))
        playlists.rekordboxPlaylists = changed
        playlists.refreshPlaylists()
        #expect(playlists.blockedPlaylistEditCount == 1)
        event { playlists.discardBlockedPlaylistEdits() }
        #expect(playlists.playlistDraft.isEmpty)
        undo.undo()
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "새 이름")])
    }

    // MARK: - 합치기의 쓰는 중 실행 취소

    static func merge(_ id: String) -> DuplicateMergeDraft {
        DuplicateMergeDraft(keeping: .init(contentID: "1", trackUUID: id, title: "가", duration: 60, offset: 0, cues: []), removing: [], base: "b")
    }

    @Test func 쓰는_중_누른_합치기_실행_취소는_쓰기_뒤_실행하고_실행_복귀는_남기지_않는다() throws {
        event { try? store.setMergeDrafts([Self.merge("m1")]) }
        beginDraftWrite()
        undo.undo()
        #expect(store.mergeDrafts == [Self.merge("m1")], "쓰는 동안은 미룬다")
        endDraftWrite()
        store.pendingUndo.flush()
        #expect(store.mergeDrafts.isEmpty, "쓰기 뒤 실행한다")
        #expect(!undo.canRedo, "미룬 실행 취소는 실행 복귀를 남기지 않는다")
    }

    /// 쓰는 중 ⌘Z 두 번: 앞 요청(합치기)이 무효라 ⌘Z 기록을 비우면 뒤 요청(재생 목록)도 실행하지 않는다(리뷰 F3)
    @Test func 쓰는_중_누른_실행_취소_두_번은_앞이_무효면_뒤도_실행하지_않는다() throws {
        event { playlists.renamePlaylist("B", to: "새 이름") }
        event { try? store.setMergeDrafts([Self.merge("m1")]) }
        beginDraftWrite()
        undo.undo()
        undo.undo()
        store.mergeWriteGeneration += 1
        endDraftWrite()
        store.pendingUndo.flush()
        #expect(store.activityLog.latest?.title == clearedText)
        #expect(playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "새 이름")], "뒤 요청을 실행하지 않았다")
        #expect(store.pendingUndo.isEmpty)
    }

    @Test func 쓰는_중_누른_합치기_실행_취소는_그새_저장되면_실행하지_않고_알린다() throws {
        event { try? store.setMergeDrafts([Self.merge("m1")]) }
        beginDraftWrite()
        undo.undo()
        // 그 쓰기가 합치기를 썼다
        store.mergeWriteGeneration += 1
        endDraftWrite()
        store.pendingUndo.flush()
        #expect(store.mergeDrafts == [Self.merge("m1")], "무효라 실행하지 않는다")
        #expect(store.activityLog.latest?.title == clearedText)
    }
}
