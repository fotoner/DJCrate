@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import Synchronization
import SwiftUI
import Testing

/// 주 창(`ContentView`)의 단추·끌어 놓기·수명 일(#244). 뷰는 동기 입구나 `.task { await 받는쪽.메서드() }` 한 줄만 부르고,
/// 일의 시작과 순서는 저장소·조립 지점·도우미가 맡는다(MVVM-4).
@MainActor
@Suite("주 창의 단추와 수명 일")
struct MainWindowActionTests {
    /// 인스펙터 내용 표시(그리기 상태)를 든 칸
    final class Shown {
        var value: Bool
        init(_ value: Bool) { self.value = value }
        var binding: Binding<Bool> { Binding(get: { self.value }, set: { self.value = $0 }) }
    }

    @Test func 인스펙터를_열면_내용을_바로_그린다() async {
        let shown = Shown(false)
        await InspectorReveal.follow(true, shown: shown.binding, after: .seconds(60))
        #expect(shown.value)
    }

    @Test func 인스펙터를_닫으면_접힌_뒤에_내용을_지운다() async {
        let shown = Shown(true)
        await InspectorReveal.follow(false, shown: shown.binding, after: .zero)
        #expect(!shown.value)
    }

    @Test func 접히기_전에_다시_열면_작업이_취소되어_내용을_지우지_않는다() async {
        let shown = Shown(true)
        let hiding = Task { await InspectorReveal.follow(false, shown: shown.binding, after: .seconds(60)) }
        hiding.cancel()
        await hiding.value
        #expect(shown.value)
    }

    struct SnapshotRefused: Error {}

    @Test func 스냅샷_단추는_강제_여부를_그대로_넘긴다() async {
        let forces = Mutex<[Bool]>([])
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), takeLiveSnapshot: { force in
            forces.withLock { $0.append(force) }
            throw SnapshotRefused()
        })
        await store.startTakeSnapshot(force: true).value
        await store.startTakeSnapshot().value
        #expect(forces.withLock { $0 } == [true, false])
    }

    @Test func 놓은_파일을_읽어_곡_추가로_넘긴다() async throws {
        let folder = try TemporaryFolder()
        let text = folder.url.appending(path: "메모.txt")
        try Data("음원이 아님".utf8).write(to: text)
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), stagingSaver: { _ in })
        await store.addDroppedFiles([NSItemProvider(object: text as NSURL)]).value
        // 음원이 아니라 추가하지 않고 이유를 알린다(곡 추가까지 왔다는 뜻)
        #expect(store.stagingMessage?.text.contains("추가할 음원이 없습니다") == true, "\(store.stagingMessage?.text ?? "")")
    }

    @Test func 재생_목록에_놓은_파일도_그_목록으로_곡_추가에_넘긴다() async throws {
        let folder = try TemporaryFolder()
        let text = folder.url.appending(path: "메모.txt")
        try Data("음원이 아님".utf8).write(to: text)
        let store = TrackListDragTests.playlistStore(count: 1)
        await store.startAddingFiles([text], toPlaylist: "A").value
        #expect(store.stagingMessage?.text.contains("추가할 음원이 없습니다") == true, "\(store.stagingMessage?.text ?? "")")
        // 고칠 수 없는 목록이면 곡 추가 전에 멈춘다
        store.stagingMessage = nil
        await store.startAddingFiles([text], toPlaylist: "없는 목록").value
        #expect(store.stagingMessage == nil)
    }

    @Test func rekordbox에_쓰는_중에_놓은_파일은_넣지_않는다() async throws {
        let folder = try TemporaryFolder()
        let text = folder.url.appending(path: "메모.txt")
        try Data("음원이 아님".utf8).write(to: text)
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), stagingSaver: { _ in })
        store.isWritingRekordbox = true
        await store.addDroppedFiles([NSItemProvider(object: text as NSURL)]).value
        #expect(store.stagingMessage == nil)
    }

    @Test func 주_창이_떠_있는_동안_바깥_초안을_다시_읽고_사라지면_멈춘다() async throws {
        let fixture = try RekordboxFixture()
        let track = TrackSpec(id: "101")
        try fixture.add(track)
        let home = fixture.root.appending(path: "drafts")
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), backupDirectory: fixture.backups, draftHome: home)
        await store.load(snapshot: fixture.database)
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let app = AppComposition(store: store, deck: deck)
        let watching = Task { await app.watchExternalDrafts(every: .milliseconds(10)) }
        // 다른 프로세스(djc)가 그리드 초안을 만든다
        try GridDraftStore.save(GridDraft(trackUUID: track.uuid, base: [], segments: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)]),
                                directory: home.appending(path: "grid-drafts"))
        #expect(await waitForState { store.hasDraft(.grid, trackUUID: track.uuid) })
        watching.cancel()
        await watching.value
    }
}
