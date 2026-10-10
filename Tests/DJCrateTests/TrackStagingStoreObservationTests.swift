@testable import DJCrate
import DJCApplication
import DJCDomain
import Observation
import SwiftUI
import Synchronization
import Testing

/// 추가 목록 조각(`TrackStagingStore`, #252)과 목록 아래 막대의 관찰 범위. 핵심(`LibraryStore`)은 조각을 관찰하지 않는다.
/// 사이드바 줄은 각자 읽는 값에만 다시 계산하고(#141), 막대는 그 사이드바 항목일 때만 추가 목록·파일 확인 값을 읽는다.
/// 진행 줄을 넣고 빼는 값(`hasGridJob`·`hasXMLExportJob`)은 시작·끝에만 바뀌고, 같은 BPM은 다시 저장하지 않는다(R4). DB는 열지 않는다.
@MainActor
@Suite("추가 목록 조각 — 관찰 범위")
struct TrackStagingStoreObservationTests {
    private final class Flag: @unchecked Sendable { var fired = false }
    /// 추가 목록 저장 횟수
    private final class Saves: Sendable { let count = Mutex(0) }

    private func store(saves: Saves? = nil) -> LibraryStore {
        LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                          stagingSaver: { _ in saves?.count.withLock { $0 += 1 } })
    }

    /// `read`가 읽은 값 가운데 `change`가 바꾸는 것이 있는지
    private func observes(_ read: () -> Void, change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        change()
        return flag.fired
    }

    private func staged(_ name: String, bpm: Double? = nil) -> StagedTrack {
        var track = StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/synthetic/\(name).wav", title: "합성 \(name)", duration: 60,
                                addedOn: "2026-10-10")
        track.bpm = bpm
        return track
    }

    @Test(.tags(.perfContract)) func 핵심은_조각_속성을_관찰하지_않는다() {
        let store = store()
        #expect(!observes({ _ = store.staging }) { store.staging.staged = [staged("a")] })
        #expect(!observes({ _ = store.staging }) { store.staging.stagingMessage = AppMessage(text: "합성 안내") })
    }

    @Test(.tags(.perfContract)) func 사이드바_줄은_각자_읽는_값에만_다시_계산한다() {
        let store = store()
        let stagedRow = { _ = SidebarStagedRow(staging: store.staging).body }
        let gridRow = { _ = SidebarGridJobRow(staging: store.staging).body }
        let exportRow = { _ = SidebarXMLExportRow(staging: store.staging).body }
        #expect(observes(stagedRow) { store.staging.staged = [staged("a")] })
        #expect(!observes(stagedRow) { store.staging.gridJob = GridJob(done: 0, total: 1) })
        #expect(!observes(stagedRow) { store.staging.stagingMessage = AppMessage(text: "합성 안내") })
        #expect(observes(gridRow) { store.staging.gridJob = GridJob(done: 1, total: 1) })
        #expect(!observes(gridRow) { store.staging.xmlExportJob = LibraryXMLExportJob() })
        store.staging.xmlExportJob = LibraryXMLExportJob()
        #expect(observes(exportRow) { store.staging.xmlExportJob?.apply(LibraryXMLProgress(phase: .writing, done: 1, total: 2)) })
        #expect(!observes(exportRow) { store.staging.staged = [] })
    }

    @Test func XML_내보내기_중_표시는_시작과_끝에만_바뀐다() {
        let staging = store().staging
        #expect(!observes({ _ = staging.hasXMLExportJob }) { staging.xmlExportJob = nil })
        staging.xmlExportJob = LibraryXMLExportJob()
        #expect(staging.hasXMLExportJob)
        #expect(!observes({ _ = staging.hasXMLExportJob }) { staging.xmlExportJob?.apply(LibraryXMLProgress(phase: .writing, done: 1, total: 2)) })
        #expect(observes({ _ = staging.hasXMLExportJob }) { staging.xmlExportJob = nil })
        #expect(!staging.hasXMLExportJob)
    }

    @Test func 덱에서_같은_BPM으로_바꾸면_추가_목록을_다시_쓰지_않는다() {
        let saves = Saves()
        let store = store(saves: saves)
        let track = staged("a", bpm: 128)
        store.staging.staged = [track]
        store.staging.stagedGridChanged(uuid: track.uuid, bpm: 128)
        #expect(saves.count.withLock { $0 } == 0)
        #expect(!observes({ _ = store.staging.staged }) { store.staging.stagedGridChanged(uuid: track.uuid, bpm: 128) })
        store.staging.stagedGridChanged(uuid: track.uuid, bpm: 126)
        #expect(saves.count.withLock { $0 } == 1 && store.staging.staged.first?.bpm == 126)
        #expect(store.staging.stagedRows.first?.track.bpm == 126)
    }

    // MARK: - 수명

    /// 조각은 핵심을 붙들지 않는다(unowned). 조각이 시작한 일은 옛 저장소의 일처럼 도는 동안 핵심을 붙들어야 한다(리뷰 P1).
    @Test func 그리드_추정과_곡_추가는_도는_동안_핵심을_붙든다() async {
        weak var weakStore: LibraryStore?
        let started = TestSwitch()
        let (gate, release) = AsyncStream<Void>.makeStream()
        var grid: Task<Void, Never>?
        do {
            let path = "/synthetic/\(UUID().uuidString).wav"
            let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, stagingSaver: { _ in },
                                          ports: { ports in
                                              let exists = ports.files.exists
                                              ports.files.exists = { $0 == path || exists($0) }
                                              // 추정을 멈춰 두어 큐가 도는 동안 시험이 저장소를 놓게 한다
                                              ports.analysis.estimateGrid = { _, _ in
                                                  started.set(true)
                                                  for await _ in gate {}
                                                  return nil
                                              }
                                          })
            weakStore = store
            store.staging.enqueueGrid([GridJobItem(uuid: UUID().uuidString.lowercased(), path: path, staged: false)])
            grid = store.staging.gridTask
            #expect(await waitForState { started.isOn })
        }
        #expect(weakStore != nil, "추정 도중에는 핵심을 붙든다")
        release.finish()
        await grid?.value

        var adding: Task<Void, Never>?
        do {
            let store = store(saves: Saves())
            weakStore = store
            adding = store.staging.startAddingFiles([URL(filePath: "/nonexistent-djc-fixture/\(UUID()).mp3")])
        }
        #expect(weakStore != nil, "추가가 끝날 때까지 핵심을 붙든다")
        await adding?.value
    }

    // MARK: - 목록 아래 막대

    private func bar(_ store: LibraryStore) -> () -> Void {
        let model = ListActionBarModel(store: store)
        return { _ = ListActionBar(model: model).body }
    }

    @Test(.tags(.perfContract)) func 막대는_추가한_곡을_볼_때만_추가_목록_조각을_읽는다() {
        let store = store()
        let body = bar(store)
        #expect(!observes(body) { store.staging.staged = [staged("a")] })
        #expect(!observes(body) { store.staging.stagingMessage = AppMessage(text: "합성 안내") })
        #expect(!observes(body) { store.staging.gridJob = GridJob(done: 0, total: 1) })
        store.sidebar = .staged
        #expect(observes(body) { store.staging.staged = [staged("b")] })
        #expect(!observes(body) { store.staging.stagingMessage = AppMessage(text: "합성 안내 2") })
        #expect(!observes(body) { store.staging.gridJob = nil })
    }

    @Test(.tags(.perfContract)) func 막대는_파일_없음_필터에서만_파일_확인_진행을_읽는다() async {
        let store = store()
        let model = ListActionBarModel(store: store)
        let body = { _ = ListActionBar(model: model).body }
        #expect(!observes(body) { model.checkMissingFiles() })
        await model.missingFileTask?.value
        store.sidebar = .filter(.missingFile)
        #expect(observes(body) { model.checkMissingFiles() })
        await model.missingFileTask?.value
    }
}
