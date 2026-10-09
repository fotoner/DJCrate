@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 덱의 Flip 기록: 가짜 오디오가 재생 한 번마다 [시작, 시험이 옮긴 위치]를 알린다. 곡 180초(`DeckHarness`).
@MainActor
@Suite("덱 — Flip 기록")
struct DeckFlipRecordingTests {
    func ranges(_ recording: FlipRecording?) -> [String] {
        (recording?.path ?? []).map { segment in
            "\(Int(segment.start))~" + (segment.end.map { "\(Int($0))" } ?? "끝")
        }
    }

    @Test func 재생_중_이동만_점프로_남고_멈춘_뒤_자리_옮기기는_남지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.startFlipRecording()
        #expect(h.deck.isFlipRecording)
        h.deck.seek(60)
        h.deck.togglePlay()
        h.audio.position = 70
        h.deck.seek(10)  // 재생 중 이동 = 점프
        h.audio.position = 30
        h.deck.togglePlay()
        h.deck.seek(100)  // 멈춘 뒤 자리 옮기기 = 점프가 아니다
        h.deck.togglePlay()
        h.audio.position = 110
        let recording = h.deck.finishFlipRecording()
        #expect(!h.deck.isFlipRecording)
        #expect(ranges(recording) == ["0~70", "10~끝"])
        #expect(h.deck.isPlaying, "기록을 마쳐도 재생은 그대로")
    }

    @Test func 기록_전에_쓴_점프는_넣지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(50)
        h.deck.togglePlay()
        h.audio.position = 55
        h.deck.seek(20)
        h.audio.position = 25
        h.deck.startFlipRecording()
        h.audio.position = 30
        h.deck.togglePlay()
        #expect(h.deck.finishFlipRecording()?.isEmpty == true)
    }

    @Test func 재생_중_끌어_옮기면_점프다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.startFlipRecording()
        h.deck.seek(40)
        h.deck.togglePlay()
        // 화면 틱이 없으니 덱 재생선도 들리는 자리로 옮겨 둔다.
        h.audio.position = 48
        h.deck.playhead = 48
        h.deck.beginScrubDrag()
        h.deck.dragScrub(by: 42)  // 48 → 90
        h.deck.endScrub()
        h.audio.position = 95
        h.deck.togglePlay()
        #expect(ranges(h.deck.finishFlipRecording()) == ["0~48", "90~끝"])
    }

    @Test func 쓰기_중에는_기록을_시작하지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.isWriteLocked = true
        #expect(h.deck.flipUnavailableReason != nil)
        h.deck.startFlipRecording()
        #expect(!h.deck.isFlipRecording)
    }

    @Test func 기록_중에만_들린_구간을_받는다() async throws {
        // 기록하지 않을 때 멈춤·점프마다 들린 구간을 계산하지 않게 오디오에 받을 곳을 걸지 않는다.
        let h = try DeckHarness()
        try await h.loaded()
        #expect(h.audio.onPlayedRun == nil)
        h.deck.startFlipRecording()
        #expect(h.audio.onPlayedRun != nil)
        _ = h.deck.finishFlipRecording()
        #expect(h.audio.onPlayedRun == nil)
        h.deck.startFlipRecording()
        h.deck.cancelFlipRecording()
        #expect(h.audio.onPlayedRun == nil)
    }

    @Test func 출력_장치가_빠져_멈춘_뒤_자리를_옮겨_재생해도_점프가_아니다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.startFlipRecording()
        h.deck.seek(40)
        h.deck.togglePlay()
        h.audio.position = 50
        // 오디오가 이어진 재생으로 알렸더라도(옛 엔진) 이어 재생에 실패해 멈췄으면 잇지 않는다.
        h.audio.simulateOutputLost(continuing: true)
        #expect(!h.deck.isPlaying)
        h.deck.seek(100)
        h.deck.togglePlay()
        h.audio.position = 110
        #expect(ranges(h.deck.finishFlipRecording()) == ["0~끝"])
    }

    // MARK: - 기록 버리기 전 확인

    @Test func 점프가_있는_기록은_곡을_바꾸기_전에_묻는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let prompter = ScriptedPrompter()
        h.deck.prompter = prompter
        // 점프가 없으면 묻지 않는다
        h.deck.startFlipRecording()
        #expect(h.deck.confirmDiscardingFlip())
        #expect(prompter.shown.isEmpty)
        // 아직 알리지 않은 지금 재생 안의 점프도 센다(재생 중 이동 한 번)
        h.deck.seek(60)
        h.deck.togglePlay()
        h.audio.position = 70
        h.deck.seek(10)
        h.audio.position = 20
        prompter.answer = false
        #expect(!h.deck.confirmDiscardingFlip())
        #expect(prompter.shown.count == 1)
        #expect(prompter.shown.last?.destructive == true)
        #expect(prompter.shown.last?.confirm?.hasSuffix("…") == false, "최종 버튼에는 말줄임표를 붙이지 않는다")
        #expect(h.deck.isFlipRecording, "취소하면 기록을 이어 간다")
        prompter.answer = true
        #expect(h.deck.confirmDiscardingFlip())
        #expect(ranges(h.deck.finishFlipRecording()) == ["0~70", "10~끝"], "확인만으로는 기록을 지우지 않는다(곡을 바꿀 때 지운다)")
    }
}
