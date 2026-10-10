@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 목록 아래 막대 화면 모델(`ListActionBarModel`, #252): 사이드바 항목마다 보일 단추의 대상·막힘 이유와 파일 없음 확인.
/// 값은 공유 핵심(`LibraryStore`)과 기능 조각(추가 목록·재생 목록·재생 기록)에서 읽는다. DB는 열지 않는다.
@MainActor
@Suite("목록 아래 막대 화면 모델")
struct ListActionBarModelTests {
    private func store() -> LibraryStore {
        LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, stagingSaver: { _ in })
    }

    private func staged(_ name: String, imported: StagedTrack.ImportCheck.Result? = nil) -> StagedTrack {
        var track = StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/synthetic/\(name).wav", title: "합성 \(name)", duration: 60,
                                addedOn: "2026-10-10")
        track.importCheck = imported.map { StagedTrack.ImportCheck(result: $0, checkedOn: "2026-10-10") }
        return track
    }

    private func track(_ id: String, path: String? = nil) -> Track {
        Track(id: id, uuid: id, title: "합성 \(id)", artist: "시험", album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: "8A", bpm: 120, lengthSeconds: 180, folderPath: path ?? "/synthetic/\(id).wav",
              comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    /// 추가 목록을 보는 저장소와 그 막대 모델
    private func stagedBar(_ tracks: [StagedTrack]) -> (LibraryStore, ListActionBarModel) {
        let store = store()
        store.sidebar = .staged
        store.staging.staged = tracks
        store.staging.rebuildStagedRows()
        return (store, ListActionBarModel(store: store))
    }

    /// 막힌 초안 비교 창을 띄운다(쓰기 입구가 막힌다)
    private func openRecoverySheet(_ store: LibraryStore) {
        store.recoverySheet = RecoverySheetModel(host: store, requests: [])
    }

    // MARK: - 추가한 곡

    @Test func 바로_넣기는_고른_추가한_곡만_넣고_고른_곡이_없으면_추가_목록_전체를_넣는다() {
        let a = staged("a"), b = staged("b")
        let (store, model) = stagedBar([a, b])
        #expect(model.stagedAddTargets.map(\.id) == [a.id, b.id])
        store.selection = [b.id]
        #expect(model.stagedAddTargets.map(\.id) == [b.id])
    }

    @Test func 바로_넣기는_대상이_없거나_쓰는_중이거나_비교_창이_열려_있으면_막고_이유를_알린다() {
        let (empty, emptyModel) = stagedBar([])
        #expect(emptyModel.isAddBlocked(emptyModel.stagedAddTargets))
        #expect(!empty.writesBlockedBySheet)

        let (store, model) = stagedBar([staged("a")])
        let targets = model.stagedAddTargets
        #expect(!model.isAddBlocked(targets))
        #expect(model.addHelp == String(ui: "고른 곡(없으면 추가 목록 전체)을 확인한 뒤 rekordbox 컬렉션에 넣습니다."))
        store.isWritingRekordbox = true
        #expect(model.isAddBlocked(targets) && model.isWritingRekordbox)
        store.isWritingRekordbox = false
        openRecoverySheet(store)
        #expect(model.isAddBlocked(targets))
        #expect(model.addHelp == LibraryStore.writesBlockedBySheetReason)
    }

    @Test func 빼기는_추가한_곡을_골랐을_때만_XML은_목록이_있을_때만_가져온_곡_정리는_확인된_곡이_있을_때만_보인다() {
        let a = staged("a"), pending = staged("p", imported: .pending)
        let (store, model) = stagedBar([a, pending])
        #expect(!model.canRemoveStaged && model.canExportStaged && !model.hasImportedStaged)
        store.selection = [a.id]
        #expect(model.canRemoveStaged)
        let (_, empty) = stagedBar([])
        #expect(!empty.canExportStaged)
        let (_, imported) = stagedBar([staged("m", imported: .matched)])
        #expect(imported.hasImportedStaged)
    }

    @Test func 고른_곡_빼기와_가져온_곡_정리는_추가_목록_조각에_넘긴다() {
        let a = staged("a"), b = staged("b"), done = staged("d", imported: .reanalyzed)
        let (store, model) = stagedBar([a, b, done])
        store.selection = [a.id]
        model.removeSelectedStaged()
        #expect(store.staging.staged.map(\.uuid) == [b.uuid, done.uuid])
        #expect(store.selection.isEmpty)
        model.removeImportedStaged()
        #expect(store.staging.staged.map(\.uuid) == [b.uuid])
    }

    // MARK: - rekordbox 쓰기 대기

    @Test func 쓰기는_쓸_것이_없거나_쓰는_중이거나_비교_창이_열려_있으면_막는다() {
        let store = store()
        store.sidebar = .pending
        let model = ListActionBarModel(store: store)
        #expect(model.pendingTargets.isEmpty && model.pendingPlaylistEdits == 0 && model.pendingHistories.isEmpty)
        #expect(model.isWriteBlocked(targets: [], playlistEdits: 0, histories: 0))
        // 곡이 없어도 재생 목록 초안·재생 기록만으로 쓸 수 있다
        #expect(!model.isWriteBlocked(targets: [], playlistEdits: 1, histories: 0))
        #expect(!model.isWriteBlocked(targets: [], playlistEdits: 0, histories: 1))
        #expect(model.writeHelp == String(ui: "고른 곡(없으면 목록 전체)과 재생 목록 초안·USB 재생 기록을 rekordbox에 씁니다."))
        store.isWritingRekordbox = true
        #expect(model.isWriteBlocked(targets: [], playlistEdits: 1, histories: 0))
        store.isWritingRekordbox = false
        openRecoverySheet(store)
        #expect(model.isWriteBlocked(targets: [], playlistEdits: 1, histories: 0))
        #expect(model.writeHelp == LibraryStore.writesBlockedBySheetReason)
    }

    @Test func 쓰기_전으로_복원은_백업이_없으면_막고_백업이_없다고_알린다() {
        let store = store()
        store.sidebar = .pending
        let model = ListActionBarModel(store: store)
        #expect(!store.hasWriteBackup)
        #expect(model.isRestoreBlocked)
        #expect(model.restoreHelp == String(ui: "복원할 백업이 없습니다. rekordbox에 쓰면 쓰기 전 백업이 생깁니다."))
        openRecoverySheet(store)
        #expect(model.restoreHelp == LibraryStore.writesBlockedBySheetReason)
    }

    // MARK: - 재생 목록·그리드 추정·USB

    @Test func 재생_목록_초안_비교는_쓰는_중이나_복구_중에는_막는다() {
        let store = store()
        let model = ListActionBarModel(store: store)
        #expect(!model.isPlaylistRecoveryBlocked)
        store.isRecoveringDraft = true
        #expect(model.isPlaylistRecoveryBlocked)
        store.isRecoveringDraft = false
        store.isWritingRekordbox = true
        #expect(model.isPlaylistRecoveryBlocked)
    }

    @Test func 그리드_추정은_보이는_곡이_없거나_추정이_도는_중이면_막는다() {
        let (store, model) = stagedBar([staged("a")])
        #expect(model.displayedCount == 1 && !model.isGridEstimateBlocked)
        store.staging.gridJob = GridJob(done: 0, total: 1)
        #expect(model.isGridEstimateBlocked)
        store.staging.gridJob = nil
        store.sidebar = .filter(.noBPM)
        #expect(model.displayedCount == 0 && model.isGridEstimateBlocked)
    }

    @Test func USB를_붙이지_않았으면_USB_편집_단추를_보이지_않는다() {
        let model = ListActionBarModel(store: store())
        #expect(model.usbEditing(volumeKey: "합성") == nil)
        #expect(!model.hasUsbPlaylistMismatch(volumeKey: "합성"))
    }

    // MARK: - 파일 없음 확인(#126)

    /// 곡 둘(하나는 연결되지 않은 외장 디스크)을 DB 없이 읽는 저장소. `present`가 켜지면 파일이 모두 있다
    private func missingFileStore(_ folder: TemporaryFolder, present: TestSwitch) -> LibraryStore {
        let volume = "/Volumes/DJC 시험 디스크 \(UUID().uuidString)"
        let tracks = [track("1"), track("2", path: "\(volume)/Music/b.wav")]
        return LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, stagingSaver: { _ in },
                                 draftHome: folder.url.appending(path: "drafts"), ports: { ports in
                                     var source = LibrarySource.withoutDatabase
                                     source.library = { _ in RekordboxLibrary(allTracks: tracks, cues: [], playCounts: [:]) }
                                     ports.source = source
                                     ports.files.exists = { _ in present.isOn }
                                 })
    }

    @Test func 읽은_뒤_핵심이_막대_모델의_파일_확인을_시작하고_결과를_행과_막대에_넣는다() async throws {
        let present = TestSwitch(), folder = try TemporaryFolder.withEmptyDatabase()
        let store = missingFileStore(folder, present: present)
        let model = ListActionBarModel(store: store)
        await store.load(snapshot: folder.database)
        let task = try #require(model.missingFileTask, "읽은 뒤 확인을 시작한다")
        await task.value
        #expect(!model.isCheckingFiles)
        #expect(model.missingFiles.trackIDs == ["1", "2"])
        #expect(model.missingFiles.unmountedVolumes.map(\.trackCount) == [1])
        #expect(store.count(.missingFile) == 2 && store.rowsByID["1"]?.fileMissing == true)

        // 디스크를 연결하면(AppDelegate) 핵심 입구로 다시 확인한다
        present.set(true)
        store.checkMissingFiles()
        #expect(model.isCheckingFiles)
        await model.missingFileTask?.value
        #expect(!model.isCheckingFiles && model.missingFiles.trackIDs.isEmpty)
        #expect(store.count(.missingFile) == 0 && store.rowsByID["1"]?.fileMissing == false)
        withExtendedLifetime(folder) {}
    }

    @Test func 다시_읽기_시작한_뒤_끝난_확인은_버리고_진행_표시만_끈다() async throws {
        let present = TestSwitch(), folder = try TemporaryFolder.withEmptyDatabase()
        let store = missingFileStore(folder, present: present)
        let model = ListActionBarModel(store: store)
        await store.load(snapshot: folder.database)
        await model.missingFileTask?.value
        present.set(true)
        model.checkMissingFiles()
        let stale = model.missingFileTask
        store.invalidatePendingLoads()
        await stale?.value
        #expect(!model.isCheckingFiles)
        #expect(model.missingFiles.trackIDs == ["1", "2"], "지난 결과를 그대로 둔다")
        #expect(store.count(.missingFile) == 2)
        withExtendedLifetime(folder) {}
    }
}
