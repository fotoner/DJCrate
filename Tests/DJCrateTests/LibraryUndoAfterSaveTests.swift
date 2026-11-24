@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 저장 뒤 ⌘Z(R12, #405)의 목록 몫: 태그(평점·곡 색 포함) 편집 → 자동 저장 → ⌘Z → 자동 저장 → DB 값이 편집 전과 같다.
/// 자동 저장은 엔진이 고르는 길(`autoInventory` → `chunk` → `autoWrite`)로 실제 관문이 합성 사본에 쓴다. `DJC_HOME`이 있을 때만 돈다.
@MainActor
@Suite("목록 저장 뒤 ⌘Z", .serialized, .enabled(if: LiveDraftHome.isIsolated))
struct LibraryUndoAfterSaveTests {
    @MainActor
    final class Rig {
        let fixture: RekordboxFixture
        let tracks: [TrackSpec]
        let store: LibraryStore
        let undo = UndoManager()
        var edits: [ReflectionUndoEdit] = []

        init(_ tracks: [TrackSpec]) async throws {
            fixture = try RekordboxFixture()
            self.tracks = tracks
            try fixture.add(tracks: tracks)
            // 곡 색 표(rekordbox 기본 여덟 색)
            for (index, color) in TrackColor.rekordboxDefaults.enumerated() {
                try fixture.insert("djmdColor", ["ID": .text(color.id), "ColorCode": .null, "SortKey": .int(index + 1), "Commnt": .text(color.name),
                                                 "UUID": .text("c-\(color.id)"), "rb_data_status": .int(256), "rb_local_deleted": .int(0),
                                                 "rb_local_usn": .int(1_234)])
            }
            try fixture.execute("UPDATE djmdContent SET Rating = 0, ColorID = '0'")
            let database = fixture.database
            store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("library-undo"), persist: false),
                                      activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }),
                                      backupDirectory: fixture.backups, playlistDraftSaver: nil, mergeDraftSaver: { _ in },
                                      playlistImportURL: nil, stagingSaver: { _ in }, draftHome: fixture.root.appending(path: "drafts"),
                                      rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                      arguments: ["test"], environment: [:], takeLiveSnapshot: { _ in database }, draftOrigin: .human)
            await store.load(snapshot: fixture.database)
            store.undoManager = undo
            store.onUndoAfterSave = { [weak self] in self?.edits.append($0) }
        }

        func row(_ track: TrackSpec) throws -> TrackRow { try #require(store.rowsByUUID[track.uuid]) }

        /// 엔진이 고르는 길로 저장 대기를 자동으로 쓰고 다시 읽기까지 기다린다
        func autoSave() async throws {
            let session = store.session
            let inventory = await session.autoInventory(cancelled: [], needsConfirmation: [])
            let chunk = try #require(inventory.chunk(rowLimit: 200), "자동으로 쓸 편집이 없다: \(inventory)")
            guard case let .written(report, unwritten) = await session.autoWrite(chunk) else {
                Issue.record("자동 저장이 쓰지 못했다")
                return
            }
            #expect(unwritten.isEmpty && report.tagBlocked.isEmpty && report.playlistBlocked.isEmpty, "\(report.tagBlocked)")
            #expect(await waitForState(until: { !self.store.libraryBusy && self.store.writtenAwaitingReload.isEmpty }))
        }

        /// 곡 행의 태그 칸(제목·평점·곡 색·코멘트)
        func tagValues() throws -> [[String: String]] {
            try fixture.rows("SELECT ID, Title, Rating, ColorID, Commnt FROM djmdContent ORDER BY ID")
        }
    }

    @Test func 두_곡의_제목_평점_곡_색을_자동_저장_뒤_되돌리고_다시_저장하면_편집_전과_같다() async throws {
        let rig = try await Rig([TrackSpec(id: "500"), TrackSpec(id: "501")])
        let original = try rig.tagValues()
        let first = try rig.row(rig.tracks[0]), second = try rig.row(rig.tracks[1])
        rig.store.tags.applyTagEdits([(first, .title, "새 제목 1"), (second, .title, "새 제목 2"), (first, .rating, "4"), (second, .color, "3")])
        try await rig.autoSave()
        #expect(try rig.tagValues() != original)

        #expect(rig.undo.canUndo, "쓴 뒤 다시 읽어도 태그 ⌘Z가 남는다")
        rig.undo.undo()
        #expect(rig.store.tagDrafts.values.filter(\.hasChanges).count == 2)
        // 두 곡의 역편집은 한 번에 전부 쓰거나 전부 쓰지 않게 대기열에 든다
        #expect(rig.edits.count == 1 && rig.edits.first?.batch.commitPolicy == .allOrNothing && rig.edits.first?.rowCount == 2)
        try await rig.autoSave()
        #expect(try rig.tagValues() == original)
    }

    @Test func 저장_뒤에도_아티스트만_바꾼_편집은_되돌리지_않는다() async throws {
        let rig = try await Rig([TrackSpec(id: "500")])
        let row = try rig.row(rig.tracks[0])
        rig.store.tags.applyTagEdits([(row, .artist, "새 가수")])
        try await rig.autoSave()
        rig.undo.undo()
        #expect(rig.store.tagDrafts.values.allSatisfy { !$0.hasChanges }, "앨범·아티스트는 저장 뒤 되돌리지 않는다")
    }
    /// 그 곡을 쓰는 동안 누른 태그 ⌘Z는 미뤄 두었다가 잠금이 풀리면 차례를 지켜 다시 올린다(그 단계를 버리지 않는다)
    @Test func 쓰는_동안_누른_태그_실행_취소는_잠금이_풀린_뒤로_미룬다() async throws {
        let rig = try await Rig([TrackSpec(id: "500")])
        let row = try rig.row(rig.tracks[0])
        rig.store.tags.applyTagEdits([(row, .title, "첫 편집")])
        rig.store.tags.applyTagEdits([(row, .title, "둘째 편집")])
        rig.store.setLockedTracks([row.track.uuid])
        rig.undo.undo()
        #expect(rig.store.tagDrafts[row.track.uuid]?.fields.title == "둘째 편집", "쓰는 동안에는 되돌리지 않는다")
        rig.store.setLockedTracks([])
        #expect(rig.undo.canUndo)
        rig.undo.undo()
        #expect(rig.store.tagDrafts[row.track.uuid]?.fields.title == "첫 편집")
        rig.undo.undo()
        #expect(rig.store.tagDrafts[row.track.uuid]?.hasChanges != true)
    }
}
