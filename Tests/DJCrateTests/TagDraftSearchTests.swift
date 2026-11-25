@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

/// 검색은 표에 보이는 값으로도 찾는다(#376): 아직 rekordbox에 저장하지 않은 태그 편집(제목·코멘트 등)도 곡 목록 검색에 잡힌다.
/// 저장된 값으로도 계속 찾는다: 목록 구성은 정렬·필터처럼 rekordbox 값이 정하므로, 검색 중에 곡을 고쳐도 그 곡이 목록에서 사라지지 않는다.
/// 합성 라이브러리: 101(제목 「시험 Alpha」·아티스트 「합성 아티스트」·코멘트 「TVA 시험 OP 1」·파일 alpha.mp3), 102(제목 「시험 Beta」·파일 beta.mp3)
@MainActor
@Suite("편집한 태그로 검색(#376)", .serialized)
struct TagDraftSearchTests {
    private func makeStore(_ fixture: RekordboxFixture, persistTags: Bool = false) async -> LibraryStore {
        let store = LibraryStore.test(
            settings: SettingsStore(defaults: TestDefaults.make("tag-draft-search"), persist: false),
            activityLog: ActivityLog(url: nil), saveTagDrafts: persistTags ? nil : { _ in }, backupDirectory: fixture.backups,
            playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
            draftHome: fixture.root.appending(path: "drafts"))
        await store.load(snapshot: fixture.database)
        return store
    }

    private func ids(_ store: LibraryStore) -> [String] { store.displayRows.map(\.track.id).sorted() }

    private func row(_ store: LibraryStore, _ uuid: String) throws -> TrackRow { try #require(store.rowsByUUID[uuid]) }

    @Test func 편집한_제목과_코멘트는_저장_전에도_새_값으로_찾는다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101")
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        store.tags.setTag(.comment, "새 코멘트 Sigma", rows: [alpha])
        // 편집한 뒤 검색어를 넣는다
        store.search = "omega"
        #expect(ids(store) == ["101"])
        store.search = "SIGMA"
        #expect(ids(store) == ["101"])
        // 낱말이 칸을 가로질러도 모두 있으면 찾는다(AND)
        store.search = "omega sigma 합성 아티스트"
        #expect(ids(store) == ["101"])
        store.search = "베타 omega"
        #expect(ids(store).isEmpty)
    }

    @Test func 검색어를_둔_채_편집하면_목록이_바로_따라간다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101"), beta = try row(store, "track-102")
        store.search = "omega"
        #expect(ids(store).isEmpty)
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        #expect(ids(store) == ["101"], "검색어를 둔 채 곡을 고치면 그 곡이 들어온다")
        store.tags.setTag(.comment, "OMEGA 코멘트", rows: [beta])
        #expect(ids(store) == ["101", "102"], "다른 곡도 같은 검색어에 들어온다")
        store.tags.setTag(.title, "새 제목 Delta", rows: [alpha])
        #expect(ids(store) == ["102"], "다시 고쳐 검색어가 없어지면 저장된 값에도 없던 곡은 나간다")
    }

    @Test func 검색어에_맞던_곡을_고쳐도_목록에서_사라지지_않고_옛_값으로도_찾는다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101")
        store.search = "tva"
        store.selection = [alpha.id]
        #expect(ids(store) == ["101"])
        store.tags.setTag(.comment, "OP 1 정리", rows: [alpha])
        #expect(ids(store) == ["101"], "저장된 코멘트로 찾은 곡을 고쳐도 목록에 남는다(고르던 곡·이어 고칠 곡이 사라지지 않는다)")
        #expect(store.selectedRows.map(\.track.id) == ["101"])
        store.search = "정리"
        #expect(ids(store) == ["101"], "고친 값으로도 찾는다")
        // 코멘트를 비워도 저장하기 전까지는 저장된 값으로 찾는다. 비운 값을 새로 찾지는 않는다
        store.tags.setTag(.comment, "", rows: [alpha])
        #expect(ids(store).isEmpty, "비운 코멘트에는 낱말이 없다")
        store.search = "tva"
        #expect(ids(store) == ["101"])
        store.search = "tva 정리"
        #expect(ids(store).isEmpty)
    }

    @Test func 저장된_값과_편집_값의_낱말은_섞어_맞추지_않는다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101")
        store.tags.setTag(.comment, "정리 끝", rows: [alpha])
        store.search = "tva 정리"
        #expect(ids(store).isEmpty, "옛 코멘트의 낱말과 새 코멘트의 낱말을 섞지 않는다")
        store.search = "tva 합성 아티스트 alpha.mp3"
        #expect(ids(store) == ["101"], "저장된 값 전체로 맞는다")
        store.search = "정리 합성 아티스트 alpha.mp3"
        #expect(ids(store) == ["101"], "편집 값 전체로 맞는다(고치지 않은 칸은 그대로)")
    }

    @Test func 고치지_않은_칸과_파일_이름_다른_곡은_그대로_찾는다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101")
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        store.search = "합성 아티스트"
        #expect(ids(store) == ["101"], "초안이 덮지 않은 아티스트")
        store.search = "alpha.mp3"
        #expect(ids(store) == ["101"], "초안에 없는 파일 이름")
        store.search = "tva"
        #expect(ids(store) == ["101"], "고치지 않은 코멘트")
        store.search = "beta"
        #expect(ids(store) == ["102"], "편집하지 않은 다른 곡")
        store.search = "시험 Alpha"
        #expect(ids(store) == ["101"], "고친 제목도 저장하기 전까지는 저장된 값으로 찾는다")
    }

    @Test func 편집을_되돌리면_옛_값으로_찾고_새_값은_찾지_않는다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101")
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        store.search = "omega"
        #expect(ids(store) == ["101"])
        store.tags.revertTags(rows: [alpha])
        #expect(ids(store).isEmpty)
        store.search = "시험 alpha"
        #expect(ids(store) == ["101"])
    }

    @Test func 실행_취소와_실행_복귀도_검색이_따라간다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let undo = UndoManager()
        store.undoManager = undo
        let alpha = try row(store, "track-101")
        store.search = "omega"
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        #expect(ids(store) == ["101"])
        undo.undo()
        #expect(ids(store).isEmpty)
        undo.redo()
        #expect(ids(store) == ["101"])
    }

    @Test func 검색_칸을_고친_초안만_목록을_다시_거르고_한_번에_한_번만_거른다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101"), beta = try row(store, "track-102")
        // 검색어가 없으면 초안을 고쳐도 거르지 않는다
        var count = store.filterRefreshCount
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        #expect(store.filterRefreshCount == count)
        store.tags.revertTags(rows: [alpha])
        store.search = "alpha"
        #expect(ids(store) == ["101"])
        // 연도·평점처럼 검색이 보지 않는 칸은 다시 거르지 않는다
        count = store.filterRefreshCount
        store.tags.setTag(.year, "1999", rows: [alpha])
        store.tags.setTag(.rating, "3", rows: [alpha])
        #expect(store.filterRefreshCount == count)
        #expect(ids(store) == ["101"])
        store.search = "1999"
        #expect(ids(store).isEmpty)
        // 검색 칸을 고친 초안은 곡이 여러 개여도 한 번만 거른다
        store.search = "omega"
        count = store.filterRefreshCount
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha, beta])
        #expect(store.filterRefreshCount == count + 1)
        #expect(ids(store) == ["101", "102"])
        // 같은 값을 다시 넣거나 편집 값이 같은 채 다른 칸을 고쳐도 거르지 않는다
        count = store.filterRefreshCount
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha, beta])
        store.tags.setTag(.year, "2001", rows: [alpha])
        #expect(store.filterRefreshCount == count)
    }

    @Test func 저장한_태그_초안을_한꺼번에_비우면_검색도_한_번만_한다() async throws {
        let fixture = try readLibraryFixture()
        let store = await makeStore(fixture)
        let rows = try [row(store, "track-101"), row(store, "track-102")]
        store.search = "omega"
        store.tags.setTag(.title, "Omega", rows: rows)
        let count = store.filterRefreshCount
        store.replaceTagDrafts(rows.map { TagDraft(trackUUID: $0.track.uuid, base: TagFields()) })
        #expect(store.filterRefreshCount == count + 1)
        #expect(ids(store).isEmpty)
    }

    @Test func 한글은_조합_방식이_달라도_편집한_값을_찾는다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101")
        // 초안 값이 NFD여도 NFC로 친 검색어가 맞는다
        store.tags.setTag(.title, "한글 제목".decomposedStringWithCanonicalMapping, rows: [alpha])
        store.search = "한글 제목".precomposedStringWithCanonicalMapping
        #expect(ids(store) == ["101"])
    }

    @Test func 다시_읽어도_저장_대기_값으로_찾는다() async throws {
        let fixture = try readLibraryFixture()
        let store = await makeStore(fixture, persistTags: true)
        let alpha = try row(store, "track-101")
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        store.search = "omega"
        #expect(ids(store) == ["101"])
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(ids(store) == ["101"], "라이브러리를 다시 읽은 뒤에도 초안은 남고 검색에 잡힌다")
        // rekordbox에서 같은 곡의 다른 칸이 바뀌어도 고친 칸은 초안 값이다
        try fixture.execute("UPDATE djmdContent SET Commnt = '외부 코멘트 Zeta' WHERE ID = '101'")
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(ids(store) == ["101"])
        store.search = "zeta"
        #expect(ids(store) == ["101"], "고치지 않은 칸은 rekordbox의 새 값을 따른다")
    }

    @Test func 저장_대기_목록과_중복_후보도_같은_값으로_찾는다() async throws {
        let fixture = try duplicateLibraryFixture()
        let store = await makeStore(fixture)
        let beta = try row(store, "track-102")
        store.tags.setTag(.comment, "고유 Zeta", rows: [beta])
        store.sidebar = .pending
        store.search = "zeta"
        #expect(ids(store) == ["102"])
        store.sidebar = .duplicates
        #expect(ids(store) == ["101", "102"], "중복 후보는 검색한 곡이 든 묶음을 통째로 보인다")
        store.search = "없는 낱말"
        #expect(ids(store).isEmpty)
        store.search = "zeta"
        store.sidebar = .filter(.all)
        #expect(ids(store) == ["102"])
        // 중복 후보 화면에서 검색어를 둔 채 고쳐도 따라간다
        store.sidebar = .duplicates
        store.tags.revertTags(rows: [beta])
        #expect(ids(store).isEmpty && store.displayDuplicateGroups.isEmpty)
        store.tags.setTag(.comment, "고유 Zeta", rows: [beta])
        #expect(ids(store) == ["101", "102"] && store.displayDuplicateGroups.count == 1)
    }

    @Test func 재생_기록의_반복_행도_편집한_곡의_값으로_찾는다() async throws {
        let fixture = try historyFixture()
        let store = await makeStore(fixture)
        let alpha = try row(store, "history-track-101")
        store.sidebar = .history("new-a")
        #expect(store.displayRows.map(\.historyTrackNumber) == [1, 2, 3])
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        store.search = "omega"
        #expect(store.displayRows.map(\.historyTrackNumber) == [2, 3], "같은 곡을 다시 재생한 행이 모두 나온다")
        store.tags.revertTags(rows: [alpha])
        #expect(store.displayRows.isEmpty)
    }

    @Test func 검색어가_없으면_초안이_있어도_목록을_바꾸지_않는다() async throws {
        let store = await makeStore(try readLibraryFixture())
        let alpha = try row(store, "track-101")
        store.tags.setTag(.title, "새 제목 Omega", rows: [alpha])
        #expect(ids(store) == ["101", "102"])
        store.search = "  "
        #expect(ids(store) == ["101", "102"])
        #expect(store.searchedDraftEdits.isEmpty, "검색어가 없으면 곡마다 편집 값을 만들지 않는다")
    }
}
