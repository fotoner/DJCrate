import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import RekordboxFixtures
import RekordboxKit
import Foundation
import Testing

/// 태그 초안도 rekordbox 반영 대상이다(#1). 쓴 곡은 초안을 비우고(반영한 값이 새 base), 되돌리면 백업의 초안을 살린다.
@Suite("태그 반영") @MainActor
struct TagReflectionTests {
    static func row(_ uuid: String) -> TrackRow { ReflectionPresenterTests.row(uuid) }

    @Test func 태그_초안만_있는_곡도_반영_대기다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let row = Self.row("t")
        store.rowsByUUID[row.track.uuid] = row
        #expect(store.writeTargets([row]).isEmpty)
        store.tags.applyTagEdits([(row, .title, "새 제목")])
        #expect(store.pendingUUIDs == ["t"] && store.writeTargets([row]).map(\.track.uuid) == ["t"])
    }

    @Test func 쓴_태그_초안은_비우고_되돌리면_다시_살린다() throws {
        var saved: [[TagDraft]] = []
        let store = LibraryStore.test(saveTagDrafts: { saved.append($0) })
        let row = Self.row("t")
        store.rowsByUUID[row.track.uuid] = row
        store.tags.applyTagEdits([(row, .title, "새 제목"), (row, .comment, "코멘트")])
        let written: TagDraft = try #require(store.tagDrafts["t"])
        let revision = store.tagRevision

        // 쓰기 뒤: 쓴 초안의 fields를 base로 되돌려 넘긴다(저장소는 변경 없는 초안 파일을 지운다)
        var cleared = written
        cleared.fields = cleared.base
        store.replaceTagDraftsAfterWrite([cleared])
        #expect(store.tagDrafts.isEmpty && !store.pendingUUIDs.contains("t") && !store.editedUUIDs.contains("t"))
        #expect(saved.last == [cleared] && saved.last?.first?.hasChanges == false)
        #expect(store.tagRevision > revision, "시트가 다시 그린다")

        // 되돌린 뒤: 백업에 둔 초안을 그대로 살린다
        store.replaceTagDraftsAfterWrite([written])
        #expect(store.tagDrafts["t"] == written && store.pendingUUIDs.contains("t") && store.editedUUIDs.contains("t"))
        #expect(saved.last == [written])

        let count = saved.count
        store.replaceTagDraftsAfterWrite([])
        #expect(saved.count == count, "넘길 초안이 없으면 저장하지 않는다")
    }
    /// #159: 인스펙터(setTag)와 표 셀(applyTagEdits)의 공통 초안 저장·사본 쓰기를 확인한다.
    @Test(arguments: [false, true])
    func 코멘트는_초안에_영속하고_그리드없이_사본에_쓴다(tableCell: Bool) async throws {
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        // 초안은 이 시험의 폴더에 둔다(두 경우가 병렬로 돌고, 다른 시험이 같은 데이터 폴더의 초안을 읽는다).
        let drafts = fixture.root.appending(path: "drafts")
        let store = LibraryStore.test(
            settings: SettingsStore(defaults: TestDefaults.make("comment"), persist: false),
            resultHistory: WriteResultHistory(url: nil), backupDirectory: fixture.backups,
            playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in }, draftHome: drafts)
        await store.load(snapshot: fixture.database)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let comment = "합성 코멘트 日本語\n둘째 줄"
        if tableCell { store.tags.applyTagEdits([(row, .comment, comment)]) }
        else { store.tags.setTag(.comment, comment, rows: [row]) }
        store.testDrafts.flush()
        let saved = try #require(TagDraftStore.load(trackUUID: spec.uuid, directory: drafts.appending(path: "tag-drafts")))
        #expect(saved.changedKeys == [.comment] && saved.fields.comment == comment)
        #expect(store.writeTargets([row]).map(\.track.uuid) == [spec.uuid])
        let database = fixture.database, shareRoot = fixture.shareRoot
        let preview = try await Task.detached {
            try await WritePreviewSnapshot.withCopy(from: database, shareRoot: shareRoot) { copy, share in
                try RekordboxWriter.write(drafts: [], tags: [saved], to: copy, dryRun: true,
                                          backups: copy.deletingLastPathComponent().appending(path: "backups"), shareRoot: share)
            }
        }.value
        #expect(preview.tagWritten.count == 1 && preview.tagBlocked.isEmpty && preview.gridBlocked.isEmpty)
        #expect(try RekordboxLibrary.load(snapshot: fixture.database).tracks.first?.comment != comment)
        let report = try RekordboxWriter.write(drafts: [], tags: [saved], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty && report.gridBlocked.isEmpty)
        let library = try RekordboxLibrary.load(snapshot: fixture.database)
        #expect(library.tracks.first?.comment == comment)
    }

}
