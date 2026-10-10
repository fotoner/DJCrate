@testable import DJCrate
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// Flip 결과 창 열기: 기록을 마친 뒤 음원 파일 확인(메인 밖)을 기다리는 사이에 덱의 곡이 바뀌는 경우(r3 P1-1).
@MainActor
@Suite("Flip 결과 창 열기")
struct FlipWindowTests {
    /// 음원 확인을 시험이 풀어 줄 때까지 붙잡는 편집본 쓰기
    final class SourceCheckGate: Sendable {
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)

        var writer: RenderEdit {
            RenderEdit(files: EditFiles(
                outputDirectory: { URL(filePath: "/편집본") },
                fileExists: { [self] _ in
                    started.withLock { $0 = true }
                    release.waitOffPool()
                    return true
                },
                createDirectory: { _ in }, removeFile: { _ in }, render: { _, _, _ in }),
                stager: RenderEdit.fake(StagingProbe()).stager)
        }
    }

    /// 점프 하나를 기록한 덱과, 기록을 마쳐 결과 창이 음원 확인을 기다리는 중인 Flip 창
    func finishedRecording() async throws -> (h: DeckHarness, window: FlipWindow, gate: SourceCheckGate, prompter: ScriptedPrompter) {
        let h = try DeckHarness()
        try await h.loaded()
        let prompter = ScriptedPrompter()
        h.deck.prompter = prompter
        let gate = SourceCheckGate(), window = FlipWindow()
        window.attach(EditWindowLinks(deck: h.deck, store: nil, writer: gate.writer, makeAudio: { EditAudioPlayer() }, showStaged: { _, _ in }))
        window.toggleRecording()
        #expect(h.deck.isFlipRecording)
        h.deck.flipRecording?.record(PlayedRun(spans: [PlayedSpan(start: 0, end: 8.5), PlayedSpan(start: 4.5, end: 12)], continuing: false))
        window.toggleRecording()
        try await until { gate.started.withLock { $0 } }
        h.deck.toast = nil
        return (h, window, gate, prompter)
    }

    func row(_ row: TrackRow, folderPath: String) -> TrackRow {
        let t = row.track
        return TrackRow(track: Track(id: t.id, uuid: t.uuid, title: t.title, artist: t.artist, album: t.album, albumArtist: t.albumArtist,
                                     genre: t.genre, composer: t.composer, releaseYear: t.releaseYear, trackNumber: t.trackNumber,
                                     key: t.key, bpm: t.bpm, lengthSeconds: t.lengthSeconds, folderPath: folderPath, comment: t.comment,
                                     importedOn: t.importedOn, analysisDataPath: t.analysisDataPath, imagePath: t.imagePath,
                                     isDeleted: t.isDeleted),
                        cues: row.cues, playCount: row.playCount)
    }

    @Test func 마친_직후_결과_창_열기가_돌기_전에_곡을_바꿔도_묻고_기록한_곡으로만_비교한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let prompter = ScriptedPrompter()
        prompter.answer = false
        h.deck.prompter = prompter
        let gate = SourceCheckGate(), window = FlipWindow()
        window.attach(EditWindowLinks(deck: h.deck, store: nil, writer: gate.writer, makeAudio: { EditAudioPlayer() }, showStaged: { _, _ in }))
        window.toggleRecording()
        h.deck.flipRecording?.record(PlayedRun(spans: [PlayedSpan(start: 0, end: 8.5), PlayedSpan(start: 4.5, end: 12)], continuing: false))
        // 마치고 같은 메인 차례에서(결과 창 열기 Task가 돌기 전) 곡을 바꾸려 한다: 이미 기다리는 중이라 묻는다
        window.toggleRecording()
        #expect(!h.deck.confirmDiscardingFlip())
        #expect(prompter.shown.count == 1)
        // 묻지 않고 곡이 바뀌어도(직접 불러오기) 비교 기준은 기록한 곡이다
        let current = try #require(h.deck.row)
        h.deck.load(row(current, folderPath: current.track.folderPath + ".other.wav"))
        h.deck.toast = nil
        gate.release.signal()
        try await until { h.deck.toast != nil }
        #expect(h.deck.toast?.text == FlipWindow.trackChangedReason)
        #expect(window.model == nil && !h.deck.hasPendingFlipResult)
    }

    /// 확인 창(`NSAlert.runModal`)이 떠 있는 동안 메인 큐가 돌아 음원 확인을 마친 열기가 이어지는 경우.
    /// 시험 본문 안에서는 메인 큐를 다시 돌릴 수 없어, 창이 떠 있는 상태(`flipDecisionWaiters`)를 먼저 만들고 열기가 답을 기다리게 한 뒤 묻는다.
    func decidedWhileOpening(answer: Bool) async throws -> (h: DeckHarness, window: FlipWindow, prompter: ScriptedPrompter) {
        let (h, window, gate, prompter) = try await finishedRecording()
        h.deck.flipDecisionWaiters = []
        gate.release.signal()
        try await until { h.deck.isAwaitingFlipDecision }
        #expect(window.model == nil, "답이 나기 전에는 결과 창을 열지 않는다")
        prompter.answer = answer
        #expect(h.deck.confirmDiscardingFlip() == answer)
        #expect(prompter.shown.count == 1 && h.deck.flipDecisionWaiters == nil)
        return (h, window, prompter)
    }

    @Test func 확인_창이_떠_있는_사이_음원_확인이_끝나도_버리면_결과_창을_열지_않는다() async throws {
        let (h, window, _) = try await decidedWhileOpening(answer: true)
        let current = try #require(h.deck.row)
        h.deck.load(row(current, folderPath: current.track.folderPath + ".other.wav"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.model == nil && !h.deck.hasPendingFlipResult && h.deck.awaitingFlipResult == nil)
        #expect(h.deck.toast == nil, "방금 직접 버린 기록을 실패처럼 알리지 않는다")
    }

    @Test func 확인_창이_떠_있는_사이_음원_확인이_끝나고_남기면_결과_창을_연다() async throws {
        let (h, window, _) = try await decidedWhileOpening(answer: false)
        try await until { window.model != nil }
        #expect(h.deck.hasPendingFlipResult && h.deck.awaitingFlipResult == nil)
        window.window?.close()
        #expect(window.model == nil && !h.deck.hasPendingFlipResult)
    }

    @Test func 기다리는_사이_곡을_바꾸려_해_묻고_버리면_결과_창도_안내도_없다() async throws {
        let (h, window, gate, prompter) = try await finishedRecording()
        // 기록은 끝났지만 결과 창이 아직 없다: 곡을 바꾸기 전에 버릴지 묻는다
        #expect(!h.deck.isFlipRecording)
        prompter.answer = true
        #expect(h.deck.confirmDiscardingFlip())
        #expect(prompter.shown.count == 1)
        // 버리자마자 기다림이 끝나 다시 Flip을 기록할 수 있다
        #expect(h.deck.awaitingFlipResult == nil)
        let current = try #require(h.deck.row)
        h.deck.load(row(current, folderPath: current.track.folderPath + ".other.wav"))
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.model == nil && !h.deck.hasPendingFlipResult)
        #expect(h.deck.toast == nil, "방금 직접 버린 기록을 실패처럼 알리지 않는다")
    }

    @Test func 결과_창을_기다리는_사이_덱이_비면_곡이_없다고_알린다() async throws {
        let (h, window, gate, _) = try await finishedRecording()
        h.deck.load(nil)
        gate.release.signal()
        try await until { h.deck.toast != nil }
        #expect(h.deck.toast?.text == FlipWindow.noTrackReason)
        #expect(window.model == nil)
    }
}

/// 곡 편집 창 열기: 음원 파일 확인을 기다리는 사이 덱의 곡이 바뀌면 Flip과 같이 알린다(f3 P3-1).
@MainActor
@Suite("곡 편집 창 열기")
struct TrackEditWindowOpenTests {
    @Test func 창을_여는_사이_곡이_바뀌면_열지_않고_알린다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let gate = FlipWindowTests.SourceCheckGate(), window = TrackEditWindow()
        window.attach(EditWindowLinks(deck: h.deck, store: nil, writer: gate.writer, makeAudio: { EditAudioPlayer() }, showStaged: { _, _ in }))
        let opening = Task { await window.open() }
        try await until { gate.started.withLock { $0 } }
        let current = try #require(h.deck.row)
        h.deck.load(FlipWindowTests().row(current, folderPath: current.track.folderPath + ".other.wav"))
        try await h.loaded()
        h.deck.toast = nil
        gate.release.signal()
        await opening.value
        #expect(h.deck.toast?.text == TrackEditWindow.trackChangedReason)
        #expect(window.model == nil)
    }
}
