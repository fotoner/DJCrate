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

    static let rekordbox = PlaylistLayout([
        (PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
        (PlaylistLayout.Item(id: "B", name: "나"), 2),
    ])

    init() {
        home = FileManager.default.temporaryDirectory.appending(path: "djc-undo-writing-\(UUID().uuidString)")
        // 앱의 편집 포트처럼 사람 편집 출처로 저장한다(되살린 단계가 그 출처를 잇는지 본다)
        store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, draftHome: home, movesDamagedDrafts: false,
                                  draftOrigin: .human)
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
