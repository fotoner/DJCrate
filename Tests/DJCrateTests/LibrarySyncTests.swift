import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

@MainActor
@Suite("초안을 보존하는 라이브러리 동기화")
struct LibrarySyncTests {
    /// 시험마다 새 저장 큐(저장소와 시험이 같은 큐를 본다)
    let writer = DraftWriter()

    /// 초안은 픽스처 폴더 아래(`drafts`)에 둔다. 데이터 폴더(`DJC_HOME`)는 병렬로 도는 다른 시험과 함께 써서
    /// 다른 시험의 초안이 섞이거나 지워진다(r4 P1-2). 기본은 명시한 사본(`--db`)으로 연 창이다.
    func store(_ fixture: RekordboxFixture, arguments: [String]? = nil, environment: [String: String] = [:],
               takeLiveSnapshot: (@Sendable (Bool) throws -> URL)? = nil) -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("sync"), persist: false),
                          resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                          backupDirectory: fixture.backups, playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in },
                          playlistImportURL: nil, stagingSaver: { _ in }, draftHome: drafts(fixture),
                          arguments: arguments ?? ["test", "--db", fixture.database.path], environment: environment,
                          takeLiveSnapshot: takeLiveSnapshot, writer: writer)
    }

    func drafts(_ fixture: RekordboxFixture) -> URL { fixture.root.appending(path: "drafts") }
    func tags(_ fixture: RekordboxFixture) -> URL { drafts(fixture).appending(path: "tag-drafts") }
    func grids(_ fixture: RekordboxFixture) -> URL { drafts(fixture).appending(path: "grid-drafts") }

    @Test(.enabled(if: LiveDraftHome.isIsolated), arguments: [false, true])
    func 명시적_동기화만_안_고친_태그를_갱신한다(explicit: Bool) async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        let row = try #require(store.rowsByUUID[spec.uuid])
        store.tags.setTag(.comment, "내 코멘트", rows: [row])
        writer.flush()
        let before = try #require(TagDraftStore.load(trackUUID: spec.uuid, directory: tags(fixture)))
        try fixture.execute("UPDATE djmdContent SET Title = '최신 제목' WHERE ID = ?", [.text(spec.id)])
        await store.load(snapshot: fixture.database, synchronizingDrafts: explicit)
        writer.flush()
        let actual = try #require(TagDraftStore.load(trackUUID: spec.uuid, directory: tags(fixture)))
        #expect(store.rowsByUUID[spec.uuid]?.track.title == "최신 제목")
        #expect(actual == store.tagDrafts[spec.uuid])
        #expect(actual.fields.comment == "내 코멘트")
        if explicit {
            #expect(actual.base.title == "최신 제목" && actual.fields.title == "최신 제목")
            let report = try RekordboxWriter.write(drafts: [], tags: [actual], to: fixture.database, dryRun: false,
                                                   backups: fixture.backups, shareRoot: fixture.shareRoot)
            #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        } else { #expect(actual == before) }
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 같은_칸_충돌과_그리드_초안은_파일까지_그대로_보존한다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        let row = try #require(store.rowsByUUID[spec.uuid])
        store.tags.setTag(.comment, "내 코멘트", rows: [row])
        writer.flush()
        var grid = GridDraft(trackUUID: spec.uuid, base: [.init(start: 0.2, bpm: 120, firstBeatNumber: 1)],
                             segments: [.init(start: 0.3, bpm: 120, firstBeatNumber: 1)])
        grid.shift(by: 0.01)
        try GridDraftStore.save(grid, directory: grids(fixture))
        let tagURL = tags(fixture).appending(path: "\(spec.uuid).json")
        let gridURL = grids(fixture).appending(path: "\(spec.uuid).json")
        let tagBefore = try Data(contentsOf: tagURL), gridBefore = try Data(contentsOf: gridURL)
        try fixture.execute("UPDATE djmdContent SET Commnt = '현재 코멘트' WHERE ID = ?", [.text(spec.id)])
        await store.load(snapshot: fixture.database, synchronizingDrafts: true)
        writer.flush()
        #expect(try Data(contentsOf: tagURL) == tagBefore && Data(contentsOf: gridURL) == gridBefore)
        #expect(store.tagDrafts[spec.uuid]?.fields.comment == "내 코멘트")
        #expect(store.toast?.kind == .warning)
        let report = try RekordboxWriter.write(drafts: [], tags: [try #require(store.tagDrafts[spec.uuid])],
                                               to: fixture.database, dryRun: false, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.tagWritten.isEmpty && report.tagBlocked.count == 1)
        #expect(try RekordboxLibrary.load(snapshot: fixture.database).tracks.first?.comment == "현재 코멘트")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 실패한_동기화는_기존_초안을_바꾸지_않는다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        store.tags.setTag(.comment, "내 코멘트", rows: [try #require(store.rowsByUUID[spec.uuid])])
        writer.flush()
        let before = try #require(TagDraftStore.load(trackUUID: spec.uuid, directory: tags(fixture)))
        await store.load(snapshot: fixture.root.appending(path: "없는.db"), quiet: true, synchronizingDrafts: true)
        #expect(store.lastError != nil && store.tagDrafts[spec.uuid] == before)
        #expect(TagDraftStore.load(trackUUID: spec.uuid, directory: tags(fixture)) == before)
    }
    @Test(.enabled(if: LiveDraftHome.isIsolated), arguments: [false, true])
    func 같은_칸_충돌은_그_칸만_명시적으로_선택한다(keepingDraft: Bool) async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        store.tags.setTag(.comment, "내 코멘트", rows: [try #require(store.rowsByUUID[spec.uuid])])
        writer.flush()
        try fixture.execute("UPDATE djmdContent SET Commnt = '현재 코멘트', Title = '최신 제목' WHERE ID = ?", [.text(spec.id)])
        await store.load(snapshot: fixture.database, synchronizingDrafts: true)
        let stale = try #require(store.tagDrafts[spec.uuid])
        let undo = UndoManager()
        store.undoManager = undo
        store.tags.resolveTagConflict(.comment, keepingDraft: keepingDraft, rows: [try #require(store.rowsByUUID[spec.uuid])])
        writer.flush()
        if keepingDraft {
            let resolved = try #require(TagDraftStore.load(trackUUID: spec.uuid, directory: tags(fixture)))
            #expect(resolved.base.comment == "현재 코멘트" && resolved.fields.comment == "내 코멘트")
            #expect(resolved.base.title == "최신 제목" && resolved.fields.title == "최신 제목")
            let report = try RekordboxWriter.write(drafts: [], tags: [resolved], to: fixture.database, dryRun: true,
                                                   backups: fixture.backups, shareRoot: fixture.shareRoot)
            #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        } else {
            #expect(store.tagDrafts[spec.uuid] == nil && TagDraftStore.load(trackUUID: spec.uuid, directory: tags(fixture)) == nil)
        }
        undo.undo()
        #expect(store.tagDrafts[spec.uuid] == stale)
    }

    @Test func 태그_저장_실패_후_새로_읽어도_입력을_잃지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let home = fixture.root.appending(path: "bad-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let directory = home.appending(path: "tag-drafts")
        // 권한을 바꾸는 대신 디렉터리 자리에 파일을 둬 저장 실패를 재현한다.
        try Data([0]).write(to: directory)
        // 권한을 바꾸는 대신 둔 파일을 손상 초안으로 옮기지 않게 한다(앱만 옮긴다).
        let store = LibraryStore.test(backupDirectory: fixture.backups, draftHome: home, movesDamagedDrafts: false, writer: writer)
        store.phase = .loaded
        let row = ReflectionPresenterTests.row(UUID().uuidString)
        store.rowsByUUID[row.track.uuid] = row
        store.tags.setTag(.comment, "저장할 코멘트", rows: [row])
        writer.flush()
        let before = try #require(store.tagDrafts[row.track.uuid])
        defer {
            var cleared = before
            cleared.fields = cleared.base
            writer.save([cleared], directory: directory)
            writer.flush()
        }
        #expect(TagDraftStore.load(trackUUID: row.track.uuid, directory: directory) == nil)
        await store.refreshExternalDrafts()
        #expect(store.tagDrafts[row.track.uuid] == before)
        #expect(store.lastError?.contains("태그 초안을 저장하지 못") == true)
        let otherHome = fixture.root.appending(path: "other-home")
        let otherDirectory = otherHome.appending(path: "tag-drafts")
        let other = LibraryStore.test(backupDirectory: fixture.backups, draftHome: otherHome, movesDamagedDrafts: false, writer: writer)
        other.phase = .loaded
        other.rowsByUUID[row.track.uuid] = row
        other.tags.setTag(.comment, "다른 홈 코멘트", rows: [row])
        writer.flush()
        await other.refreshExternalDrafts()
        #expect(other.lastError == nil && other.tagDrafts[row.track.uuid]?.fields.comment == "다른 홈 코멘트")
        #expect(writer.failedTagSaveUUIDs(in: directory) == [row.track.uuid])
        try FileManager.default.removeItem(at: directory)
        // 값은 그대로여도 명시적 동기화/쓰기 재시도는 실패한 저장만 다시 실행한다.
        store.retryFailedTagSaves()
        await store.refreshExternalDrafts()
        #expect(store.lastError == nil && writer.failedTagSaveUUIDs(in: directory).isEmpty)
        #expect(TagDraftStore.load(trackUUID: row.track.uuid, directory: directory)?.fields.comment == "저장할 코멘트")
        try FileManager.default.removeItem(at: directory)
        try Data([0]).write(to: directory)
        store.tags.setTag(.comment, "또 실패한 코멘트", rows: [row])
        // 실패한 버리기도 메모리의 삭제 의도를 되살리지 않는다.
        store.tags.revertTags(rows: [row])
        writer.flush()
        await store.refreshExternalDrafts()
        #expect(store.tagDrafts[row.track.uuid] == nil)
        try FileManager.default.removeItem(at: directory)
        store.tags.setTag(.comment, "재시도 코멘트", rows: [row])
        writer.flush()
        await store.refreshExternalDrafts()
        #expect(store.lastError == nil && writer.failedTagSaveUUIDs(in: directory).isEmpty)
        #expect(TagDraftStore.load(trackUUID: row.track.uuid, directory: directory)?.fields.comment == "재시도 코멘트")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated), arguments: [false, true])
    func 명시한_DB_모드는_그_사본만_동기화한다(environmentOverride: Bool) async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        let taken = ThreadRecorder(), source = fixture.database
        let take: @Sendable (Bool) throws -> URL = { _ in taken.record("take", main: false); return source }
        let args = environmentOverride ? ["test"] : ["test", "--db", fixture.database.path]
        let env = environmentOverride ? ["DJC_DB": fixture.database.path] : [:]
        let store = store(fixture, arguments: args, environment: env, takeLiveSnapshot: take)
        await store.load(snapshot: fixture.database)
        try fixture.execute("UPDATE djmdContent SET Title = '지정 사본 새 제목' WHERE ID = ?", [.text(spec.id)])
        await store.synchronizeLibrary()
        #expect(store.snapshotURL == fixture.database && store.rowsByUUID[spec.uuid]?.track.title == "지정 사본 새 제목")
        #expect(taken.calls.isEmpty)
        // 명시한 사본이 아니면(사본 rekordbox 폴더) 동기화는 스냅샷을 새로 뜬다(뜨기는 합성 DB만 돌려준다).
        let live = self.store(fixture, arguments: ["test"], environment: ["DJC_REKORDBOX_DIR": fixture.root.path], takeLiveSnapshot: take)
        await live.load(snapshot: fixture.database)
        await live.synchronizeLibrary()
        #expect(taken.calls.count == 1)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated), arguments: [false, true])
    func 쓰기나_미저장_드래그_중에는_동기화하지_않는다(writing: Bool) async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        try fixture.execute("UPDATE djmdContent SET Title = '다른 제목' WHERE ID = ?", [.text(spec.id)])
        store.isWritingRekordbox = writing
        store.allowsLibrarySync = { writing }
        await store.synchronizeLibrary()
        #expect(!store.canSynchronizeLibrary && store.rowsByUUID[spec.uuid]?.track.title == spec.title)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 동기화_도중_드래그가_시작하면_덱의_메모리를_덮지_않는다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        var loads: [TrackRow?] = []
        store.onLoadToDeck = { loads.append($0) }
        let row: TrackRow = try #require(store.rowsByUUID[spec.uuid])
        store.loadToDeck(row)
        var calls = 0
        store.allowsLibrarySync = { calls += 1; return calls == 1 }
        store.onRekordboxWritten = { _ in Issue.record("미저장 드래그를 다시 읽었습니다") }
        try fixture.execute("UPDATE djmdContent SET Title = '동기화한 제목' WHERE ID = ?", [.text(spec.id)])
        await store.synchronizeLibrary()
        #expect(store.rowsByUUID[spec.uuid]?.track.title == "동기화한 제목" && loads.count == 1)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 읽는_도중_쓰기가_시작하면_동기화_결과를_버린다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        store.tags.setTag(.comment, "보존할 코멘트", rows: [try #require(store.rowsByUUID[spec.uuid])])
        writer.flush()
        let before = try #require(TagDraftStore.load(trackUUID: spec.uuid, directory: tags(fixture)))
        try fixture.execute("UPDATE djmdContent SET Title = '쓰는 중 최신 제목' WHERE ID = ?", [.text(spec.id)])
        let resume = DispatchSemaphore(value: 0), started = Mutex(false)
        let loading = Task {
            await store.load(snapshot: fixture.database, quiet: true, refreshITunes: true, synchronizingDrafts: true, captureITunes: {
                                 started.withLock { $0 = true }
                                 resume.waitOffPool()
                                 return ITunesLibrarySnapshot()
                             })
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        store.isWritingRekordbox = true
        resume.signal()
        await loading.value
        writer.flush()
        #expect(store.rowsByUUID[spec.uuid]?.track.title == spec.title)
        #expect(store.tagDrafts[spec.uuid] == before && TagDraftStore.load(trackUUID: spec.uuid, directory: tags(fixture)) == before)
    }

    // MARK: - 라이브러리에 곡이 없는 초안은 충돌이 아니다(#197)

    /// 라이브러리 곡이 아닌 곡 UUID(추가 목록 곡, 넣은 뒤 연결이 끊긴 초안)의 태그 초안. 디스크에 저장해 다시 읽기가 읽게 한다.
    func writeOrphanTagDraft(_ uuid: String, comment: String, in fixture: RekordboxFixture) {
        var draft = TagDraft(trackUUID: uuid, base: TagFields())
        draft.fields.comment = comment
        writer.save([draft], directory: tags(fixture))
        writer.flush()
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 추가_목록_곡의_태그_초안은_동기화에서_충돌로_세지_않는다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        let staged = try JSONDecoder().decode(StagedTrack.self, from: Data("""
            {"uuid":"\(UUID().uuidString)","path":"/tmp/djc-synthetic.mp3","title":"합성 추가 곡","comment":"","duration":2,"addedOn":"2026-10-01"}
            """.utf8))
        store.staged = [staged]
        let unlinked = UUID().uuidString
        writeOrphanTagDraft(staged.uuid, comment: "추가 곡 코멘트", in: fixture)
        writeOrphanTagDraft(unlinked, comment: "연결이 끊긴 초안", in: fixture)
        let stagedBefore = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: tags(fixture)))
        let unlinkedBefore = try #require(TagDraftStore.load(trackUUID: unlinked, directory: tags(fixture)))
        await store.load(snapshot: fixture.database, quiet: true, synchronizingDrafts: true)
        writer.flush()
        #expect(store.toast?.kind != .warning, "라이브러리에 없는 곡의 초안은 비교할 rekordbox 값이 없어 충돌이 아니다: \(String(describing: store.toast))")
        // 초안은 그대로 보존한다(지우거나 기준을 바꾸지 않는다)
        #expect(store.tagDrafts[staged.uuid] == stagedBefore && TagDraftStore.load(trackUUID: staged.uuid, directory: tags(fixture)) == stagedBefore)
        #expect(store.tagDrafts[unlinked] == unlinkedBefore && TagDraftStore.load(trackUUID: unlinked, directory: tags(fixture)) == unlinkedBefore)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated)) func 곡이_없는_초안이_있어도_라이브러리_곡의_실제_충돌은_센다() async throws {
        let fixture = try RekordboxFixture(), spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        store.tags.setTag(.comment, "내 코멘트", rows: [try #require(store.rowsByUUID[spec.uuid])])
        let orphans = [UUID().uuidString, UUID().uuidString]
        for uuid in orphans { writeOrphanTagDraft(uuid, comment: "곡이 없는 초안", in: fixture) }
        writer.flush()
        try fixture.execute("UPDATE djmdContent SET Commnt = '현재 코멘트' WHERE ID = ?", [.text(spec.id)])
        await store.load(snapshot: fixture.database, quiet: true, synchronizingDrafts: true)
        #expect(store.toast?.kind == .warning)
        #expect(store.toast?.detail?.contains("1곡") == true, "충돌은 라이브러리 곡 1곡뿐이다: \(String(describing: store.toast?.detail))")
        #expect(store.tagDrafts[spec.uuid]?.fields.comment == "내 코멘트")
    }
}
