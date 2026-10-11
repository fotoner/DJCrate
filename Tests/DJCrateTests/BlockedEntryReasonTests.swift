@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

@MainActor
@Suite("편집·쓰기 진입 안내")
struct BlockedEntryReasonTests {
    @Test func 곡_편집_준비와_쓰기_잠금의_이유를_구분한다() async throws {
        let h = try DeckHarness()
        let notLoaded = try #require(h.deck.trackEditUnavailableReason)
        try await h.loaded()
        #expect(h.deck.trackEditUnavailableReason == nil && h.deck.canOpenTrackEdit)
        h.deck.isWriteLocked = true
        // 불러온 곡에서 막는 것은 쓰기 잠금뿐이고, 그 이유는 불러오기 전 이유와 다르다
        let locked = try #require(h.deck.trackEditUnavailableReason)
        #expect(locked != notLoaded)
        #expect(!h.deck.canOpenTrackEdit)
    }

    @Test func 소리_없는_곡도_그리드가_있으면_빈_핫큐를_만들_수_있다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.canPlay = false
        h.deck.grid = nil
        #expect(h.deck.hotCueCreationUnavailableReason != nil)
        h.deck.instantLoop = .init(start: 1, end: 3, beats: 4)
        #expect(h.deck.hotCueCreationUnavailableReason == nil)
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.hotCue(slot: 0)?.loop?.end == 3)
        h.deck.grid = BeatGrid(beats: [.init(number: 1, bpm: 120, time: 0)])
        #expect(h.deck.hotCueCreationUnavailableReason == nil)
        h.deck.isWriteLocked = true
        #expect(h.deck.hotCueCreationUnavailableReason != nil, "그리드가 있어도 쓰는 중에는 막는다")
    }

    @Test func 추정_초안은_분석_안내가_있어도_기존대로_편집한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        #expect(h.deck.canEditGrid)
        #expect(h.deck.gridUnavailableReason == nil)
    }

    @Test func 빈_구간_초안도_곡_편집의_기존_가드를_유지한다() async throws {
        let h = try EditHarness(grid: [])
        defer { h.remove() }
        let model = h.loaded()
        #expect(model.blockedReason != nil)
        #expect(!model.canRender)
    }

    @Test func 동기화_미확정_입력과_쓰기_대기_없음을_구분한다() throws {
        let folder = try TemporaryFolder()
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("entry"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), backupDirectory: folder.url.appending(path: "backups"),
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil,
                                 stagingSaver: { _ in }, draftHome: folder.url.appending(path: "drafts"),
                                 rekordboxDatabase: folder.url.appending(path: "master.db"), rekordboxShareRoot: folder.url.appending(path: "share"))
        let window = LibraryWindowModel(store: store)
        #expect(LibraryMenuAction.snapshot.disabledReason(in: window) == nil)
        store.phase = .loading("합성 읽기")
        let reading = try #require(LibraryMenuAction.snapshot.disabledReason(in: window))
        store.phase = .idle
        store.allowsLibrarySync = { false }
        let unconfirmed = try #require(LibraryMenuAction.snapshot.disabledReason(in: window))
        #expect(reading != unconfirmed, "읽는 중과 덱 입력 미확정을 다른 이유로 알린다")
        #expect(LibraryMenuAction.reflect.disabledReason(in: window)?.contains("초안") == true)
        #expect(LibraryMenuAction.exportXML.disabledReason(in: window)?.contains("큐·그리드") == true)
        #expect(LibraryMenuAction.restore.disabledReason(in: window)?.contains("백업") == true)
        #expect(LibraryMenuAction.removeTracks.disabledReason(in: window)?.contains("고르세요") == true)
        LibraryMenuAction.reflect.perform(in: window)
        #expect(store.staging.stagingMessage?.text == LibraryMenuAction.reflect.disabledReason(in: window))
        store.isWritingRekordbox = true
        #expect(LibraryMenuAction.snapshot.disabledReason(in: window)?.contains("쓰기") == true)
    }

    @Test func 루프_길이_한도와_곡_끝을_알리고_기존_값을_보존한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        for (size, direction) in [(0.25, -1), (32.0, 1)] {
            h.deck.loopSize = size
            h.deck.resizeLoop(direction)
            #expect(h.deck.loopSize == size)
            #expect(h.deck.toast?.text.contains("한도") == true)
        }
        #expect(h.deck.loopEnd(from: h.deck.duration, beats: 4) == nil)
        #expect(h.deck.toast?.text.contains("더 짧은 루프") == true)
        h.deck.canPlay = false
        h.deck.toggleLoop()
        #expect(h.deck.instantLoop == nil)
        #expect(h.deck.toast?.text == h.deck.playbackUnavailableReason)
    }

    @Test func 목록의_셀에도_읽기_전용_도움말이_남는다() throws {
        let folder = try TemporaryFolder()
        let stream = TrackListTagEditTests.row("1", streaming: true)
        let store = LibraryStore.test(saveTagDrafts: { _ in }, backupDirectory: folder.url.appending(path: "backups"),
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil,
                                 stagingSaver: { _ in }, draftHome: folder.url.appending(path: "drafts"),
                                 rekordboxDatabase: folder.url.appending(path: "master.db"), rekordboxShareRoot: folder.url.appending(path: "share"))
        let h = ListHarness(rows: [stream], selection: [stream.id], store: store)
        defer { h.close() }
        let reason = try #require(TrackListTagEditing.unavailableReason(stream, key: .title))
        #expect(try #require(h.cell(row: 0, column: "title")).toolTip == reason)
    }

    @Test func 렌더_대상_없음과_진행_중을_알린다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        #expect(model.renderUnavailableReason?.contains("결과에 넣") == true)
        model.select(from: 0, to: 4)
        model.addSelection()
        #expect(model.renderUnavailableReason == nil)
        #expect(model.canRender)
    }

    @Test func BPM_조정은_쓰기_범위를_넘기지_않고_이유를_보인다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.gridEditing = true
        h.deck.setGridBPM(655.35)
        #expect(h.deck.gridDraft?.segments.first?.bpm == 655.35)
        let before = h.deck.gridDraft
        h.deck.scaleGridBPM(2)
        #expect(h.deck.gridDraft == before)
        #expect(h.deck.toast?.text.contains("655.35") == true)
    }
}
