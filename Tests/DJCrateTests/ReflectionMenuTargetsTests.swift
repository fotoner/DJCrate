@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 곡 목록 오른쪽 클릭 메뉴의 쓰기·넣기·빼기 항목은 반영 세션과 같은 대상 규칙(`ReflectionTargets`)으로 보인다(adv2 N9:
/// 메뉴가 조건을 다시 적어, 저장이 끝나지 않은 초안의 곡은 메뉴에 쓰기 항목이 없었고 세션은 그 곡을 썼다).
@MainActor
@Suite("목록 메뉴의 반영 대상", .serialized)
struct ReflectionMenuTargetsTests {
    private final class MenuTable: NSTableView {
        override var clickedRow: Int { -1 }
    }

    let writer = DraftWriter()

    private func menu(_ store: LibraryStore, rows: [TrackRow]) -> [String] {
        _ = NSApplication.shared
        store.rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.track.id, $0) })
        store.rowsByUUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.track.uuid, $0) })
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store)), table = MenuTable()
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        coordinator.table = table
        coordinator.update(rows: rows, edited: [], selection: Set(rows.map(\.id)), sortOrder: [], snapshotURL: nil, previewRevision: 0)
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        return withExtendedLifetime(table) { menu.items.map(\.title) }
    }

    @Test func 저장이_끝나지_않은_초안만_있는_곡도_메뉴에_쓰기_항목이_보이고_세션과_같은_곡을_고른다() throws {
        let home = try TemporaryFolder(prefix: "djc-menu-targets")
        let store = LibraryStore.test(saveTagDrafts: { _ in }, draftHome: home.url, writer: writer)
        let row = MusicalKeyEditingTests.row("1")
        var cue = CueDraft(trackUUID: row.track.uuid)
        cue.place(EditableCue(kind: .hot(0), time: 4))
        // 저장이 실패해 아직 디스크에 없는 입력(표시는 아직 바뀌지 않았다)
        writer.save(cue, directory: store.draftLocations.cue, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        #expect(!store.pendingUUIDs.contains(row.track.uuid) && store.testDrafts.unsavedUUIDs().contains(row.track.uuid))
        #expect(store.writeTargets([row]).map(\.id) == [row.id])
        #expect(menu(store, rows: [row]).contains("선택한 곡 rekordbox에 쓰기 (1곡)"))
    }

    @Test func 빼기_항목은_세션의_빼기_대상과_같은_곡_수를_보인다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let local = MusicalKeyEditingTests.row("1"), stream = ReflectionPresenterTests.row("2")
        let streaming = TrackRow(track: Track(id: "3", uuid: "3", title: "스트림", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                                              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "spotify:3",
                                              comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false),
                                 cues: [], playCount: 0)
        let rows = [local, stream, streaming]
        let expected = store.deleteTargets(rows).count
        #expect(expected == 2)
        #expect(menu(store, rows: rows).contains("rekordbox 컬렉션에서 빼기 (\(expected)곡)…"))
    }
}
