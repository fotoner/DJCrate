import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 쓴 뒤 재생 목록 정리(R22, #402): 시도한 단계마다 판과 결과로 적고, 쓴 단계만 판으로 찾아 뺀다. 막힌 단계와 쓰는 동안 더한 단계는 남는다.
/// 새 목록의 연결 ID는 가져오기 연결과 남은 단계의 대상·목적지에 옮긴다. 정리는 다시 해도 결과가 같고(재시작 정리), 정리가 끝나지 않으면 알린다.
@MainActor
@Suite("재생 목록 쓴 뒤 정리")
struct EditPlaylistsCleanupTests {
    typealias I = StageTracksFlowTests.Imports

    static let rekordbox = PlaylistLayout(rekordbox: [
        RekordboxPlaylist(id: "P", name: "목록", parentID: "root", seq: 1, isFolder: false, trackIDs: []),
    ])
    static let backups = URL(filePath: "/tmp/djc-cleanup-tests/backups")
    static let folder = "2026-11-24_120000"
    static let key = RekordboxWriteLockKey(device: 1, inode: 2)

    let memory = MemoryDrafts()

    var playlists: EditPlaylists { EditPlaylists(imports: .none, drafts: memory.store) }

    /// 초안을 저장소에 저장해(단계 식별자·판을 받는다) 읽어 온 초안과 쓰기 묶음에 읽어 넣은 항목(판·해시)을 돌려준다
    func stage(_ edits: [PlaylistEdit]) throws -> (draft: PlaylistDraft, entries: [DraftBatchEntry]) {
        var draft = PlaylistDraft()
        for edit in edits { try draft.append(edit, rekordbox: Self.rekordbox) }
        try memory.store.savePlaylistDraft(draft)
        return reread()
    }

    func reread() -> (draft: PlaylistDraft, entries: [DraftBatchEntry]) {
        let draft = (try? memory.store.readPlaylistDraft()) ?? PlaylistDraft()
        let entries = zip(draft.steps, memory.store.playlistStamps()).map { step, stamp in
            DraftBatchEntry(stamp: stamp, contentHash: (try? DraftContentHash(step: step, in: draft)) ?? DraftContentHash(hex: ""))
        }
        return (draft, entries)
    }

    static func outcomes(_ draft: PlaylistDraft, _ statuses: [RekordboxWriteOutcome.Status], ids: [Int: String] = [:]) -> [PlaylistOutcome] {
        zip(draft.steps, statuses).enumerated().map { index, pair in
            PlaylistOutcome(edit: pair.0.edit, playlistID: ids[index], name: "", status: pair.1,
                            reason: pair.1 == .blocked ? "막힘" : nil)
        }
    }

    static func pending(_ keys: String...) -> PlaylistImports {
        var imports = PlaylistImports()
        for key in keys { imports.addFiles(["/m/\(key).mp3"], to: .new(key)) }
        return imports
    }

    /// 앱·관문이 쓰기 뒤에 적는 미정리 목록(재생 목록 몫)
    func list(_ written: PlaylistDraft, _ outcomes: [PlaylistOutcome], _ entries: [DraftBatchEntry]) -> DraftCleanupList {
        DraftCleanupList(operationID: "op1", target: Self.key, draftHome: "/tmp/h", backupFolder: Self.folder,
                         playlistSteps: EditPlaylists.attempts(written, outcomes: outcomes, entries: entries),
                         newPlaylistIDs: EditPlaylists.newPlaylistIDs(written, outcomes: outcomes))
    }

    /// CLI가 디스크 초안 뒤에 단계를 더한다
    func addFromCLI(_ edit: PlaylistEdit) throws {
        var draft = try memory.store.readPlaylistDraft()
        try draft.append(edit, rekordbox: Self.rekordbox)
        try memory.store(origin: .cli).savePlaylistDraft(draft)
    }

    // MARK: - 시도한 단계를 적는다

    @Test func 시도한_단계마다_판과_결과를_적고_못_시도한_단계는_시도하지_않음으로_적는다() throws {
        let staged = try stage([.create(key: "k", name: "새 목록", isFolder: false, parent: .root), .rename(playlist: .id("P"), name: "막힐 이름"),
                                .addTracks(playlist: .id("P"), contentIDs: ["c1"])])
        let outcomes = Self.outcomes(staged.draft, [.written, .blocked], ids: [0: "900"])

        let steps = EditPlaylists.attempts(staged.draft, outcomes: outcomes, entries: staged.entries)

        #expect(steps.map(\.revision) == staged.entries.map(\.revision))
        #expect(steps.map(\.contentHash) == staged.entries.map(\.contentHash))
        #expect(steps.map(\.outcome) == [.written, .blocked("막힘"), .notTried])
        #expect(EditPlaylists.newPlaylistIDs(staged.draft, outcomes: outcomes) == ["new:k": "900"])
    }

    @Test func 이미_그_모양이라_바꾸지_않은_단계는_쓴_것으로_적는다() throws {
        let staged = try stage([.rename(playlist: .id("P"), name: "새 이름")])
        let steps = EditPlaylists.attempts(staged.draft, outcomes: Self.outcomes(staged.draft, [.unchanged]), entries: staged.entries)
        #expect(steps.map(\.outcome) == [.written])
    }

    // MARK: - 쓴 단계만 판으로 빼고 막힌 단계·더한 단계는 남긴다

    @Test func 세_단계_중_하나가_막힌_쓰기_뒤_정리_전에_멈추고_CLI가_단계를_더한_뒤_재시작하면_쓴_단계만_빠진다() throws {
        let staged = try stage([.create(key: "k", name: "새 목록", isFolder: false, parent: .root),
                                .addTracks(playlist: .new("k"), contentIDs: ["c1"]), .rename(playlist: .id("P"), name: "막힐 이름")])
        let outcomes = Self.outcomes(staged.draft, [.written, .written, .blocked], ids: [0: "900", 1: "900"])
        let list = list(staged.draft, outcomes, staged.entries)
        // 정리 전에 멈췄다. 그동안 CLI가 단계를 더했다(쓴 새 목록 `new:k`와 기존 목록 P에)
        try addFromCLI(.addTracks(playlist: .new("k"), contentIDs: ["c9"]))
        try addFromCLI(.addTracks(playlist: .id("P"), contentIDs: ["c8"]))

        // 재시작 정리
        let cleanup = playlists.resumeCleanup(list, backups: Self.backups, imports: Self.pending("k"), importsLoadFailed: false)

        #expect(cleanup.isComplete)
        let edits = memory.store.playlistDraft().edits
        #expect(edits == [.rename(playlist: .id("P"), name: "막힐 이름"), .addTracks(playlist: .id("900"), contentIDs: ["c9"]),
                          .addTracks(playlist: .id("P"), contentIDs: ["c8"])], "쓴 단계만 빠지고 막힌 단계와 더한 단계가 남는다. 더한 단계의 새 목록 키는 받은 ID로 옮겨진다")
        #expect(!edits.contains { if case .create = $0 { true } else { false } }, "같은 목록을 다시 만들지 않는다")
        #expect(cleanup.draft?.edits == edits)
        #expect(cleanup.ids == ["new:k": "900"])
    }

    @Test func 재시작_정리는_다시_해도_결과가_같다() throws {
        let staged = try stage([.create(key: "k", name: "새 목록", isFolder: false, parent: .root), .rename(playlist: .id("P"), name: "막힐 이름")])
        let outcomes = Self.outcomes(staged.draft, [.written, .blocked], ids: [0: "900"])
        let list = list(staged.draft, outcomes, staged.entries)
        try addFromCLI(.addTracks(playlist: .new("k"), contentIDs: ["c9"]))

        let first = playlists.resumeCleanup(list, backups: Self.backups, imports: Self.pending("k"), importsLoadFailed: false)
        let draft = memory.store.playlistDraft()
        let again = playlists.resumeCleanup(list, backups: Self.backups, imports: Self.pending("k"), importsLoadFailed: false)

        #expect(first.isComplete && again.isComplete)
        #expect(memory.store.playlistDraft() == draft && again.draft == draft)
        #expect(draft.edits == [.rename(playlist: .id("P"), name: "막힐 이름"), .addTracks(playlist: .id("900"), contentIDs: ["c9"])])
    }

    @Test func 쓰는_동안_더한_단계는_쓴_뒤에도_남고_연결_ID를_받는다_메모리_초안도_같다() throws {
        // 앱이 쓰는 동안 새 편집을 더하고 그때마다 저장해 메모리가 디스크를 따라간다
        let staged = try stage([.create(key: "k", name: "새 목록", isFolder: false, parent: .root), .rename(playlist: .id("P"), name: "막힐 이름")])
        let outcomes = Self.outcomes(staged.draft, [.written, .blocked], ids: [0: "900"])
        var current = staged.draft
        try current.append(.rename(playlist: .new("k"), name: "쓰는 동안 고친 이름"), rekordbox: Self.rekordbox,
                           frozen: Set(staged.draft.stepIDs.compactMap { $0 }))
        try memory.store.savePlaylistDraft(current)
        current = reread().draft

        let cleanup = playlists.finishWrite(staged.draft, outcomes: outcomes, current: current, imports: Self.pending("k"), importsLoadFailed: false,
                                            entries: staged.entries, backups: Self.backups, backupFolder: Self.folder)

        #expect(cleanup.isComplete && cleanup.draftError == nil)
        let expected: [PlaylistEdit] = [.rename(playlist: .id("P"), name: "막힐 이름"), .rename(playlist: .id("900"), name: "쓰는 동안 고친 이름")]
        #expect(memory.store.playlistDraft().edits == expected)
        #expect(cleanup.draft?.edits == expected)
        #expect(cleanup.draft?.stepIDs.allSatisfy { $0 != nil } == true, "받은 메모리 초안은 단계 식별자를 가진다")
        #expect(cleanup.ids == ["new:k": "900"])
        #expect(cleanup.imports?.imports.requests.first?.target == PlaylistRef("900") && cleanup.imports?.stored == true)
    }

    @Test func 쓴_단계가_없으면_정리는_아무것도_바꾸지_않는다() throws {
        // 커밋 전에 멈춘 쓰기(막힘·시도하지 않음만 있다) 뒤 재시작: 정리 0
        let staged = try stage([.create(key: "k", name: "새 목록", isFolder: false, parent: .root), .rename(playlist: .id("P"), name: "막힐 이름")])
        let outcomes = Self.outcomes(staged.draft, [.blocked])
        let list = list(staged.draft, outcomes, staged.entries)
        let before = memory.store.playlistDraft()
        let stamps = memory.store.playlistStamps()

        let cleanup = playlists.resumeCleanup(list, backups: Self.backups, imports: Self.pending("k"), importsLoadFailed: false)

        #expect(cleanup.isComplete && cleanup.ids.isEmpty && cleanup.imports == nil && cleanup.copied.isEmpty)
        #expect(memory.store.playlistDraft() == before && memory.store.playlistStamps() == stamps)
    }

    // MARK: - 정리 도중 멈춤: 두 새 목록이 각각 하나

    @Test func 목록_만들기_다른_목록의_막힌_편집_또_다른_목록_만들기를_쓴_뒤_초안과_연결_ID_저장_사이에_멈춰도_두_새_목록이_각각_하나다() throws {
        let staged = try stage([.create(key: "k1", name: "첫 목록", isFolder: false, parent: .root), .rename(playlist: .id("P"), name: "막힐 이름"),
                                .create(key: "k2", name: "둘째 목록", isFolder: false, parent: .root)])
        let outcomes = Self.outcomes(staged.draft, [.written, .blocked, .written], ids: [0: "900", 2: "901"])
        let list = list(staged.draft, outcomes, staged.entries)
        let pending = Self.pending("k1", "k2")

        // 초안은 저장했는데 연결 기록 저장에 실패해 멈춘 것과 같다
        let crashed = EditPlaylists(imports: I(failing: true).store, drafts: memory.store)
            .finishWrite(staged.draft, outcomes: outcomes, current: staged.draft, imports: pending, importsLoadFailed: false,
                         entries: staged.entries, backups: Self.backups, backupFolder: Self.folder)
        #expect(crashed.imports?.stored == false && !crashed.isComplete, "연결 ID를 저장하지 못했으니 정리가 끝나지 않았다(미정리 목록을 지우지 않는다)")
        #expect(memory.store.playlistDraft().edits == [.rename(playlist: .id("P"), name: "막힐 이름")])

        // 재시작: 연결 기록은 옛 것(`new:키`)이다
        let saved = I()
        let restarted = EditPlaylists(imports: saved.store, drafts: memory.store)
            .resumeCleanup(list, backups: Self.backups, imports: pending, importsLoadFailed: false)

        #expect(restarted.isComplete && saved.count == 1)
        #expect(restarted.imports?.imports.requests.map(\.target) == [PlaylistRef("900"), PlaylistRef("901")])
        #expect(memory.store.playlistDraft().edits == [.rename(playlist: .id("P"), name: "막힐 이름")], "막힌 편집만 남고 만들기는 다시 남지 않는다")
    }

    // MARK: - 바깥에서 고친 단계

    @Test func 쓴_단계를_바깥에서_고쳤으면_사본을_남기고_빼며_연결_ID도_옮긴다() throws {
        let staged = try stage([.create(key: "a", name: "폴더 A", isFolder: true, parent: .root),
                                .create(key: "c", name: "목록 C", isFolder: false, parent: .new("a"))])
        let outcomes = Self.outcomes(staged.draft, [.written, .written], ids: [0: "900", 1: "901"])
        let list = list(staged.draft, outcomes, staged.entries)
        // C에 곡 넣기를 더한 뒤, A만 바깥에서 고친다(단계 식별자는 그대로, 도장은 그대로 두고 내용만 바뀐다)
        try addFromCLI(.addTracks(playlist: .new("c"), contentIDs: ["c1"]))
        var outside = PlaylistDraft()
        try outside.append(.create(key: "a", name: "바깥에서 고친 A", isFolder: true, parent: .root), rekordbox: Self.rekordbox)
        try outside.append(.create(key: "c", name: "목록 C", isFolder: false, parent: .new("a")), rekordbox: Self.rekordbox)
        try outside.append(.addTracks(playlist: .new("c"), contentIDs: ["c1"]), rekordbox: Self.rekordbox)
        outside.setStepIDs(try memory.store.readPlaylistDraft().stepIDs)
        memory.editPlaylistOutside(outside)

        let cleanup = playlists.resumeCleanup(list, backups: Self.backups, imports: Self.pending("c"), importsLoadFailed: false)

        #expect(cleanup.isComplete)
        #expect(memory.store.playlistDraft().edits == [.addTracks(playlist: .id("901"), contentIDs: ["c1"])], "곡 넣기는 쓴 C로 가고 목록이 갈라지지 않는다")
        #expect(cleanup.copied.count == 1, "바깥에서 고친 A의 사본이 남는다(상태 줄에 경고한다)")
        let copy = try #require(memory.playlistCopies.first)
        #expect(copy.value.playlistID == "900" && copy.key.path.hasPrefix(Self.backups.appending(path: Self.folder).path))
        #expect(cleanup.imports?.imports.requests.first?.target == PlaylistRef("901"))
    }

    @Test func 사본을_남기지_못하면_그_단계와_연결_ID는_그대로_두고_정리가_끝나지_않았다고_알리며_다시_하면_된다() throws {
        let staged = try stage([.create(key: "k", name: "새 목록", isFolder: false, parent: .root), .rename(playlist: .id("P"), name: "막힐 이름")])
        let outcomes = Self.outcomes(staged.draft, [.written, .blocked], ids: [0: "900"])
        let list = list(staged.draft, outcomes, staged.entries)
        try addFromCLI(.addTracks(playlist: .new("k"), contentIDs: ["c9"]))
        var outside = PlaylistDraft()
        try outside.append(.create(key: "k", name: "바깥에서 고친 이름", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        try outside.append(.rename(playlist: .id("P"), name: "막힐 이름"), rekordbox: Self.rekordbox)
        try outside.append(.addTracks(playlist: .new("k"), contentIDs: ["c9"]), rekordbox: Self.rekordbox)
        outside.setStepIDs(try memory.store.readPlaylistDraft().stepIDs)
        memory.editPlaylistOutside(outside)
        let before = memory.store.playlistDraft()
        memory.failPlaylistCopies()
        let pending = Self.pending("k")

        let failed = playlists.resumeCleanup(list, backups: Self.backups, imports: pending, importsLoadFailed: false)

        #expect(!failed.isComplete && failed.copyFailed.count == 1 && failed.copied.isEmpty)
        #expect(memory.store.playlistDraft() == before, "사본을 남기지 못한 단계(만들기)가 남고, 그 키를 가리키는 단계도 `new:키` 그대로다")
        #expect(failed.imports == nil, "연결 ID도 옮기지 않는다")

        // 다음 정리(재시작 뒤)에서 다시 한다
        memory.failPlaylistCopies(false)
        let retried = playlists.resumeCleanup(list, backups: Self.backups, imports: pending, importsLoadFailed: false)

        #expect(retried.isComplete && retried.copied.count == 1)
        #expect(memory.store.playlistDraft().edits == [.rename(playlist: .id("P"), name: "막힐 이름"), .addTracks(playlist: .id("900"), contentIDs: ["c9"])])
        #expect(retried.imports?.imports.requests.first?.target == PlaylistRef("900"))
    }

    // MARK: - 판을 모르는 묶음은 지금 동작

    @Test func 판을_모르는_묶음은_지금처럼_자리로_빼고_남은_단계의_연결_ID도_옮긴다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        try draft.append(.addTracks(playlist: .new("k"), contentIDs: ["c1"]), rekordbox: Self.rekordbox)
        try draft.append(.rename(playlist: .id("P"), name: "막힐 이름"), rekordbox: Self.rekordbox)
        let outcomes = Self.outcomes(draft, [.written, .blocked, .blocked], ids: [0: "900"])
        // 쓴 만들기만 빠지고 막힌 단계가 남는다: 막힌 곡 넣기는 새 목록의 연결 ID를 받는다
        let cleanup = playlists.finishWrite(draft, outcomes: outcomes, current: draft, imports: PlaylistImports(), importsLoadFailed: false)
        #expect(cleanup.draft?.edits == [.addTracks(playlist: .id("900"), contentIDs: ["c1"]), .rename(playlist: .id("P"), name: "막힐 이름")])
        #expect(cleanup.isComplete)
    }
}
