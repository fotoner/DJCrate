@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// R21(#401): 쓰는 동안 덱 재생이 멈추지 않고 창 덮개가 뜨지 않으며, 쓰는 묶음에 든 곡의 편집만 막는다.
/// 잠금은 쓰기 포트(`WriteLock.setTracks`·`set`)로 건다. 세션이 초안을 쓸 때 거는 순서와 같다.
/// 덱·태그·그림·덮개 값을 DB 없이 본다. 실제 관문으로 쓰는 흐름은 `WriteLockSplitTests`가 본다.
@Suite("쓰는 곡만 잠그기")
@MainActor
struct TrackWriteLockTests {
    let store = LibraryStore.test(saveTagDrafts: { _ in })

    /// 앱 조립 지점과 같은 연결로 만든 쓰기 잠금 포트
    var lock: WriteLock { store.reflection.session.ports.lock }

    /// 초안을 쓰는 동안의 잠금(세션 `lockDraftWrite`와 같다): 쓰는 곡과 초안 쓰기를 정하고 라이브러리를 쓰는 중으로 만든다. 덱은 잠그지 않는다.
    func beginDraftWrite(_ tracks: Set<String>) {
        let lock = lock
        lock.setTracks(tracks)
        lock.setDraftWriting(true)
        lock.set(true, false)
    }

    func endDraftWrite() {
        let lock = lock
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
    }

    // MARK: - 덱

    @Test func 쓰는_곡이_덱의_곡이어도_재생은_멈추지_않고_재생_전환_호출이_없다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        store.connectWriteLocks(to: h.deck)
        h.deck.togglePlay()
        #expect(h.deck.isPlaying && h.audio.isPlaying)
        let calls = h.audio.log
        beginDraftWrite(["track-1"])
        #expect(store.libraryBusy && store.lockedTracks == ["track-1"])
        #expect(h.deck.isPlaying && h.audio.isPlaying, "쓰는 동안에도 재생이 이어진다")
        endDraftWrite()
        #expect(h.deck.isPlaying && h.audio.isPlaying)
        #expect(h.audio.log == calls, "재생·멈춤·되감기 호출이 하나도 없다")
        #expect(store.lockedTracks.isEmpty && !store.libraryBusy)
    }

    @Test func 쓰는_곡이_덱의_곡이면_덱_편집만_막고_다른_곡이면_편집된다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        store.connectWriteLocks(to: h.deck)

        beginDraftWrite(["track-1"])
        #expect(h.deck.isEditLocked && !h.deck.editsFrozen, "덱의 곡이 쓰는 곡이라 편집만 막는다")
        h.deck.addMemoryCue(at: 40.5)
        #expect(h.deck.draft?.cues.isEmpty == true, "쓰는 곡의 큐는 바뀌지 않는다")
        endDraftWrite()
        #expect(!h.deck.isEditLocked)

        beginDraftWrite(["other-track"])
        #expect(!h.deck.isEditLocked, "쓰는 곡이 덱의 곡이 아니다")
        h.deck.addMemoryCue(at: 40.5)
        #expect(h.deck.draft?.cues.count == 1, "다른 곡 편집은 쓰는 동안에도 된다")
        endDraftWrite()
    }

    @Test func 쓰는_곡이_덱의_곡이면_게인_버리기와_저장_다시_시도도_막는다() async throws {
        let h = try DeckHarness(autoGain: RekordboxAutoGain(gain: 1, peak: 0.9))
        try await h.loaded()
        store.connectWriteLocks(to: h.deck)
        h.deck.setTrackGain(-2)
        #expect(h.deck.gainDraft == -2)
        beginDraftWrite(["track-1"])
        h.deck.clearGainDraft()
        #expect(h.deck.gainDraft == -2 && h.drafts.gain("track-1") == -2, "쓰는 곡의 게인 초안은 쓰는 도중 지우지 않는다")
        h.deck.setTrackGain(-4)
        #expect(h.deck.gainDraft == -2)
        endDraftWrite()
        h.deck.clearGainDraft()
        #expect(h.deck.gainDraft == nil, "쓰기가 끝나면 다시 고친다")
    }

    @Test func 통째_잠금은_그대로_덱을_멈추고_편집을_막는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        store.connectWriteLocks(to: h.deck)
        h.deck.togglePlay()
        lock.set(true, true)
        #expect(!h.deck.isPlaying && h.deck.editsFrozen && h.deck.isEditLocked)
        store.writeStage = WriteStage("rekordbox를 복원하는 중…")
        #expect(store.editsFrozen && store.lockedTracks.isEmpty && store.showsWriteOverlay)
        store.writeStage = nil
        lock.set(false, true)
        #expect(h.deck.isPlaying && !h.deck.editsFrozen)
    }

    // MARK: - 태그·그림

    @Test func 쓰는_곡의_태그_편집만_막고_다른_곡은_된다() {
        let writing = TagInspectorModelTests.row("a"), other = TagInspectorModelTests.row("b")
        beginDraftWrite([writing.track.uuid])
        #expect(store.isEditLocked(writing.track.uuid) && !store.isEditLocked(other.track.uuid))
        store.tags.setTag(.title, "새 제목", rows: [writing, other])
        #expect(Set(store.tagDrafts.keys) == [other.track.uuid], "쓰는 곡은 빼고 다른 곡만 초안이 생긴다")
        store.tags.setTag(.title, "또 새 제목", rows: [writing])
        #expect(store.tagDrafts[writing.track.uuid] == nil)
        endDraftWrite()
        store.tags.setTag(.title, "새 제목", rows: [writing])
        #expect(store.tagDrafts[writing.track.uuid] != nil, "쓰기가 끝나면 다시 고친다")
    }

    @Test func 쓰는_곡의_태그_되돌리기와_충돌_해결도_막는다() {
        let writing = TagInspectorModelTests.row("a"), other = TagInspectorModelTests.row("b")
        store.tags.setTag(.title, "새 제목", rows: [writing, other])
        #expect(Set(store.tagDrafts.keys) == [writing.track.uuid, other.track.uuid])
        beginDraftWrite([writing.track.uuid])
        store.tags.revertTags(rows: [writing, other])
        #expect(Set(store.tagDrafts.keys) == [writing.track.uuid], "쓰는 곡의 초안은 그대로, 다른 곡만 버려진다")
        endDraftWrite()
    }

    @Test func 쓰는_곡의_그림_편집만_막고_다른_곡은_된다() {
        let model = ArtworkInspectorModel(store: store)
        let writing = ArtworkInspectorModelTests.row("a"), other = ArtworkInspectorModelTests.row("b")
        let image = ImageFixture.image(width: 8, height: 8)
        beginDraftWrite([writing.track.uuid])
        model.setArtwork(image, name: nil, rows: [writing, other])
        #expect(Set(store.artworkDrafts.keys) == [other.track.uuid], "쓰는 곡의 그림 초안은 만들지 않는다")
        #expect(model.isLocked(rows: [writing]) && !model.isLocked(rows: [other]))
        endDraftWrite()
    }

    @Test func 목록_칸_편집은_쓰는_곡의_줄만_막는다() {
        let writing = MusicalKeyEditingTests.row("1"), other = MusicalKeyEditingTests.row("2")
        let h = ListHarness(rows: [writing, other], selection: [writing.id], showKey: true)
        defer { h.close() }
        h.coordinator.presentKeyMenu = { _, _, _ in }
        let lock = h.store.reflection.session.ports.lock
        lock.setTracks([writing.track.uuid])
        lock.set(true, false)
        #expect(h.coordinator.keyMenu(row: 0) == nil && !h.coordinator.beginEditing(row: 0, column: "key"), "쓰는 곡의 줄은 고르기 메뉴도 열지 않는다")
        #expect(h.coordinator.keyMenu(row: 1) != nil && h.coordinator.beginEditing(row: 1, column: "key"), "다른 곡의 줄은 쓰는 동안에도 고른다")
        lock.set(false, false)
        lock.setTracks([])
        #expect(h.coordinator.keyMenu(row: 0) != nil)
    }

    // MARK: - 덮개와 쓰는 중 값

    @Test func 곡_단위로_쓰는_동안에는_창_덮개를_띄우지_않고_통째_잠금은_띄운다() {
        #expect(!store.showsWriteOverlay, "진행 단계가 없으면 덮개도 없다")
        beginDraftWrite(["uuid-a"])
        store.writeStage = WriteStage("rekordbox에 저장하는 중…")
        #expect(store.writeStage != nil && !store.showsWriteOverlay, "진행 단계는 있지만 창 덮개는 없다")
        store.writeStage = nil
        endDraftWrite()
        lock.set(true, true)
        store.writeStage = WriteStage("rekordbox를 복원하는 중…")
        #expect(store.showsWriteOverlay, "복원·곡 넣기·빼기는 창 전체를 덮는다")
        store.writeStage = nil
        lock.set(false, true)
    }

    @Test func 곡_단위로_쓰는_동안에도_라이브러리_배타와_종료_판단은_그대로다() {
        beginDraftWrite(["uuid-a"])
        #expect(store.libraryBusy && store.quitBlocked && store.isWritingRekordbox)
        #expect(lock.isLocked(), "다른 쓰기는 바쁨으로 거절한다")
        #expect(!store.editsFrozen, "편집 잠금은 곡 단위다")
        #expect(lock.lockedTracks() == ["uuid-a"])
        endDraftWrite()
        #expect(!store.libraryBusy && !store.quitBlocked && !lock.isLocked() && lock.lockedTracks().isEmpty)
    }

    /// S3: 재생 목록·재생 기록만 쓰는 묶음은 곡 집합이 비어도 초안 쓰기라 통째 편집 잠금도 덮개도 없다(R21).
    @Test func 재생_목록만_쓰는_동안에도_덮개가_없고_곡_태그_편집은_되고_재생_목록_편집은_막힌다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        store.connectWriteLocks(to: h.deck)
        h.deck.togglePlay()
        let row = TagInspectorModelTests.row("b")
        beginDraftWrite([])
        store.writeStage = WriteStage("rekordbox에 저장하는 중…")
        #expect(store.libraryBusy && store.lockedTracks.isEmpty)
        #expect(!store.editsFrozen && !store.showsWriteOverlay && !h.deck.editsFrozen && h.deck.isPlaying, "덮개도 통째 잠금도 없고 덱은 멈추지 않는다")
        #expect(!store.isEditLocked(row.track.uuid))
        store.tags.setTag(.title, "새 제목", rows: [row])
        #expect(store.tagDrafts[row.track.uuid] != nil, "곡 태그 편집은 된다")
        store.playlists.openPlaylistPicker(tracks: [row])
        #expect(store.playlists.playlistPicker == nil, "재생 목록 편집은 libraryBusy로 막는다(얼리기는 #402)")
        store.writeStage = nil
        endDraftWrite()
        #expect(!store.libraryBusy && !store.isEditLocked(row.track.uuid) && h.deck.isPlaying)
    }

    @Test func 초안_쓰기_표시만_있어도_곡_단위_쓰기이고_복원은_통째_잠금이다() {
        lock.setDraftWriting(true)
        lock.set(true, false)
        store.writeStage = WriteStage("rekordbox에 저장하는 중…")
        #expect(!store.editsFrozen && !store.showsWriteOverlay)
        store.writeStage = nil
        lock.set(false, false)
        lock.setDraftWriting(false)
        // 복원·곡 넣기·빼기·iTunes 동기화는 초안 쓰기 표시가 없어 그대로 통째로 잠근다
        lock.set(true, true)
        store.writeStage = WriteStage("rekordbox를 복원하는 중…")
        #expect(store.editsFrozen && store.showsWriteOverlay)
        store.writeStage = nil
        lock.set(false, true)
    }

    // MARK: - 재생 목록은 아직 쓰는 동안 통째로 막는다

    @Test func 곡_단위로_쓰는_동안에는_재생_목록_초안을_버리지_못한다() {
        let created = store.playlists.applyPlaylistRequests(
            [.create(name: "새 목록", isFolder: false, parent: .ref(PlaylistRef(PlaylistLayout.root)), position: nil, alias: nil, tracks: [])],
            actionName: "새 목록")
        #expect(created != nil && !store.playlists.playlistDraft.isEmpty)
        let draft = store.playlists.playlistDraft
        beginDraftWrite(["uuid-a"])
        store.playlists.discardPlaylistDraft()
        store.playlists.discardBlockedPlaylistEdits()
        #expect(store.playlists.playlistDraft == draft, "쓰는 동안 재생 목록 초안은 그대로다(사이드바 우클릭 메뉴가 막아 주던 길)")
        endDraftWrite()
        store.playlists.discardPlaylistDraft()
        #expect(store.playlists.playlistDraft.isEmpty)
    }

    @Test func 곡_단위로_쓰는_동안에도_재생_목록_편집은_쓰는_중으로_막는다() {
        let row = TagInspectorModelTests.row("b")
        beginDraftWrite(["uuid-a"])
        store.playlists.openPlaylistPicker(tracks: [row])
        #expect(store.playlists.playlistPicker == nil, "재생 목록 얼리기는 W2-G2 몫이라 쓰는 동안에는 재생 목록을 편집하지 않는다")
        endDraftWrite()
        store.playlists.openPlaylistPicker(tracks: [row])
        #expect(store.playlists.playlistPicker != nil)
    }
}
