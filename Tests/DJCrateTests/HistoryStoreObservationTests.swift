@testable import DJCrate
import DJCDomain
import Observation
import SwiftUI
import Testing

/// 재생 기록 조각(`HistoryStore`, #251)의 관찰 범위. 핵심(`LibraryStore`)은 조각을 관찰하지 않는다.
/// 사이드바 기록 구역 본문은 트리 구조만 읽고, 곡 수·USB 보존·쓰기 대기 표시는 기록 줄만 읽는다(#141).
/// 트리·숨김·쓰기 대기·펼침은 같은 값이면 다시 쓰지 않는다(R4). DB 없이 기록 값을 직접 넣는다.
@MainActor
@Suite("재생 기록 조각 — 관찰 범위")
struct HistoryStoreObservationTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    private func store() -> LibraryStore {
        LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
    }

    /// `read`가 읽은 값 가운데 `change`가 바꾸는 것이 있는지
    private func observes(_ read: () -> Void, change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        change()
        return flag.fired
    }

    /// rekordbox 기록(2025년 `month`월)
    static func history(_ id: String, month: Int = 2, contentIDs: [String] = ["1"]) -> RekordboxHistory {
        RekordboxHistory(id: id, name: "합성 \(id)", dateCreated: "2025-0\(month)-03 21:00:00", folderNames: ["2025", "\(month)"], seq: 1,
                         entries: contentIDs.enumerated().map { .init(id: "\(id)-\($0.offset)", contentID: $0.element, trackNumber: $0.offset + 1) })
    }

    private func row(_ id: String) -> TrackRow {
        let track = Track(id: id, uuid: id, title: "합성 \(id)", artist: "시험", album: nil, albumArtist: nil, genre: nil, composer: nil,
                          releaseYear: nil, trackNumber: nil, key: "8A", bpm: 120, lengthSeconds: 180, folderPath: "/synthetic/\(id).wav",
                          comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        return TrackRow(track: track, cues: [], playCount: 0)
    }

    private func item(_ id: String, in tree: HistoryTree) -> HistoryTree.Item? {
        (tree.years.flatMap { $0.months.flatMap(\.items) } + tree.undated).first { $0.id == id }
    }

    @Test(.tags(.perfContract)) func 핵심은_조각_속성을_관찰하지_않는다() {
        let store = store()
        #expect(!observes({ _ = store.history }) { store.history.histories = [Self.history("a")] })
    }

    @Test(.tags(.perfContract)) func 기록_구역_본문은_트리만_읽어_펼침과_곡_수에는_다시_계산하지_않는다() {
        let store = store()
        store.history.histories = [Self.history("a")]
        let body = { _ = SidebarHistorySection(history: store.history).body }
        #expect(observes(body) { store.history.histories.append(Self.history("b", month: 1)) })
        #expect(!observes(body) { store.history.setHistoryFolder(HistoryTree.yearID(2025), expanded: true) })
        #expect(!observes(body) { store.rowsByID = ["1": row("1")] })
    }

    @Test(.tags(.perfContract)) func 보존본의_쓰기_대기_상태만_바뀌면_구역_본문은_그대로이고_그_기록_줄만_다시_계산한다() throws {
        let store = store()
        let archived = UsbHistoryWriteTests.archived("row", ["1"], sequence: 1)
        store.history.archivedHistories = [archived]
        let item = try #require(item(archived.id, in: store.history.historyTree))
        var excluded = archived
        excluded.excludedFromRekordbox = true
        #expect(!observes({ _ = SidebarHistorySection(history: store.history).body }) { store.history.archivedHistories = [excluded] })
        #expect(observes({ _ = SidebarHistoryRow(history: store.history, item: item).body }) { store.history.archivedHistories = [archived] })
        // 곡 수는 컬렉션 짝을 읽는 기록 줄이 센다
        #expect(observes({ _ = SidebarHistoryRow(history: store.history, item: item).body }) { store.rowsByID = ["1": row("1")] })
    }

    @Test(.tags(.perfContract)) func 같은_기록을_다시_넣거나_결과가_같은_다시_계산은_트리·숨김·쓰기_대기를_다시_쓰지_않는다() {
        let store = store()
        let histories = [Self.history("a")]
        store.history.histories = histories
        let read = {
            _ = store.history.historyTree
            _ = store.history.shadowedArchiveIDs
            _ = store.history.pendingHistories
            _ = store.history.pendingHistoryIDs
        }
        #expect(!observes(read) { store.history.histories = histories })
        // 라이브러리를 읽기 전에는 쓰기 대기를 고르지 않으므로 관문을 열어도 결과가 같다
        #expect(!observes(read) { store.history.writesHistories = true })
        #expect(!observes(read) { store.history.refreshHistoryTree() })
        #expect(observes(read) { store.history.histories = [] })
    }

    @Test(.tags(.perfContract)) func 이미_펼친_폴더의_기록을_고르면_펼침을_다시_쓰지_않는다() {
        let store = store()
        store.history.histories = [Self.history("a")]
        store.history.revealHistory("a")
        let folders = store.history.expandedHistoryFolders
        #expect(folders == [HistoryTree.yearID(2025), HistoryTree.monthID(year: 2025, month: 2)])
        #expect(!observes({ _ = store.history.expandedHistoryFolders }) { store.sidebar = .history("a") })
        #expect(store.history.expandedHistoryFolders == folders)
    }
}
