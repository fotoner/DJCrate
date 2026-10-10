@testable import DJCrate
import DJCDomain
import Observation
import SwiftUI
import Testing

/// 배지·진행 값이 바뀌어도, 부모 뷰가 다시 계산돼도 사이드바 본문은 다시 계산되지 않는다(#141).
/// 본문이 다시 계산되면 List가 재생 목록 수백 개를 모두 다시 비교한다(덱에 곡을 올릴 때 50~120ms).
/// 값은 각자 작은 뷰가 읽고, 본문은 목록 구조만 읽는다.
@MainActor
@Suite("사이드바 — 본문이 읽는 값")
struct SidebarObservationTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    private func store() -> LibraryStore {
        LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
    }

    /// `body`를 한 번 계산하는 동안 읽은 값 중 `change`가 바꾸는 것이 있는지.
    private func reads<Content: View>(_ view: (LibraryStore) -> Content, before: (LibraryStore) -> Void = { _ in },
                                      change: (LibraryStore) -> Void) -> Bool {
        let store = store()
        before(store)
        let flag = Flag()
        withObservationTracking { _ = view(store).body } onChange: { flag.fired = true }
        change(store)
        return flag.fired
    }

    /// 같은 값을 다시 넣으면 알림이 나가지 않으므로, 시험은 값을 실제로 바꾼다.
    private func row(_ id: String) -> TrackRow {
        let track = Track(id: id, uuid: id, title: "합성 \(id)", artist: "시험", album: nil, albumArtist: nil,
                          genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: "8A", bpm: 120,
                          lengthSeconds: 180, folderPath: "/synthetic/\(id).wav", comment: "", importedOn: nil,
                          analysisDataPath: nil, imagePath: nil, isDeleted: false)
        return TrackRow(track: track, cues: [], playCount: 0)
    }

    private func sidebarReads(before: (LibraryStore) -> Void = { _ in }, _ change: (LibraryStore) -> Void) -> Bool {
        reads({ Sidebar(store: $0) }, before: before, change: change)
    }

    // MARK: - 사이드바 본문

    @Test(.tags(.perfContract)) func 그리드_추정_진행은_본문이_읽지_않는다() {
        #expect(!sidebarReads(before: { $0.gridJob = GridJob(done: 1, total: 5) }) { $0.gridJob = GridJob(done: 2, total: 5) })
    }

    @Test(.tags(.perfContract)) func 그리드_추정을_시작하고_끝내면_진행_줄을_넣고_빼려고_본문을_다시_계산한다() {
        #expect(sidebarReads { $0.gridJob = GridJob(done: 0, total: 5) })
        #expect(sidebarReads(before: { $0.gridJob = GridJob(done: 5, total: 5) }) { $0.gridJob = nil })
    }

    @Test(.tags(.perfContract)) func 추가한_곡_수는_본문이_읽지_않는다() {
        #expect(!sidebarReads { $0.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/synthetic/a.wav", title: "합성 곡", duration: 60,
                                                         addedOn: "2026-09-28")] })
    }

    @Test(.tags(.perfContract)) func 쓰기_대기_수는_본문이_읽지_않는다() {
        let other = row("y")
        #expect(!sidebarReads { $0.tagDrafts = ["x": TagDraft(track: other.track)] })
        #expect(!sidebarReads { $0.draftChanged(trackUUID: "x", kind: .cue, exists: true) })
        #expect(!sidebarReads { $0.draftChanged(trackUUID: "x", kind: .grid, exists: true) })
        #expect(!sidebarReads { $0.draftChanged(trackUUID: "x", kind: .gain, exists: true) })
        // 대기 곡이 있으면 곡 표에서 추가한 곡인지 걸러 낸다
        #expect(!sidebarReads(before: { $0.draftChanged(trackUUID: "y", kind: .cue, exists: true) }) { $0.rowsByUUID = ["y": other] })
    }

    @Test(.tags(.perfContract)) func 태그_편집_조각의_키_제안_무시는_본문이_읽지_않는다() {
        // 무시한 키 제안은 핵심에서 태그 편집 조각(`TagEditStore`)으로 옮겼다(#250). 덱 제안 줄만 읽는다.
        #expect(!sidebarReads { $0.tags.dismissKeySuggestion(rows: [row("x")]) })
    }

    @Test(.tags(.perfContract)) func 쓰기_중_표시는_본문이_읽지_않는다() {
        #expect(!sidebarReads { $0.isWritingRekordbox = true })
    }

    // MARK: - 줄 뷰

    @Test(.tags(.perfContract)) func 배지_값은_각자_줄이_읽어_값이_바뀌면_그_줄만_다시_계산한다() {
        #expect(reads({ SidebarStagedRow(store: $0) }) {
            $0.staged = [StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/synthetic/a.wav", title: "합성 곡", duration: 60,
                                     addedOn: "2026-09-28")]
        })
        #expect(reads({ SidebarPendingRow(store: $0) }) { $0.draftChanged(trackUUID: "x", kind: .cue, exists: true) })
        #expect(reads({ SidebarGridJobRow(store: $0) }, before: { $0.gridJob = GridJob(done: 1, total: 5) }) {
            $0.gridJob = GridJob(done: 2, total: 5)
        })
        #expect(reads({ SidebarLastWriteResultRow(store: $0) }) { $0.isWritingRekordbox = true })
    }

    @Test func 그리드_추정_중_표시는_시작과_끝에만_바뀐다() {
        let store = store()
        #expect(!store.hasGridJob)
        store.gridJob = GridJob(done: 0, total: 3)
        #expect(store.hasGridJob)
        store.gridJob?.total += 2
        store.gridJob?.done += 1
        #expect(store.hasGridJob)
        store.gridJob = nil
        #expect(!store.hasGridJob)
    }

    // MARK: - 재생 목록 구역

    @Test func 재생_목록_구역은_곡_수_배지와_선택을_읽지_않는다() {
        #expect(!reads({ PlaylistSection(store: $0) }) { $0.playlistCounts = ["x": 1] })
        #expect(!reads({ PlaylistSection(store: $0) }) { $0.selection = ["1"] })
        #expect(!reads({ PlaylistSection(store: $0) }) { $0.rowsByID = ["y": row("y")] })
    }

    // MARK: - 부모가 다시 계산될 때

    /// `@AppStorage`를 든 뷰는 부모가 다시 계산될 때마다 값이 바뀐 것으로 보여 본문이 다시 계산된다(#141: 덱에 곡을 올리면 ContentView가
    /// 다시 계산돼 사이드바 List 전체를 다시 비교했다). 설정값은 줄·구역 뷰가 들고 있어야 한다.
    @Test func 사이드바_본문은_부모가_다시_계산돼도_새로_계산되지_않도록_AppStorage를_들지_않는다() {
        let sidebar = Sidebar(store: store())
        let held = Mirror(reflecting: sidebar).children.map { String(describing: type(of: $0.value)) }
        #expect(!held.contains { $0.hasPrefix("AppStorage") }, "사이드바가 든 값: \(held)")
    }
}
