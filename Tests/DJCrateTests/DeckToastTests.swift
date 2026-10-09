import DJCApplication
@testable import DJCrate
import Foundation
import Testing

/// 덱 파형 위 알림: 성공은 2.5초, 경고는 읽을 시간을 더 줘 5초 뒤 저절로 닫힌다(#146). VoiceOver가 켜져 있으면 남긴다.
@MainActor
@Suite("덱 — 알림")
struct DeckToastTests {
    private func deck(voiceOver: Bool) -> DeckModel {
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.feedback = AppFeedback(announce: { _ in }, isVoiceOverEnabled: { voiceOver })
        return deck
    }

    @Test func 경고도_잠시_뒤_저절로_닫힌다() async {
        #expect(DeckModel.toastDuration(.success) == .seconds(2.5))
        #expect(DeckModel.toastDuration(.warning) == .seconds(5))
        let deck = deck(voiceOver: false)
        deck.showToast("메모리 큐는 곡당 10개까지입니다")
        #expect(deck.toast?.kind == .warning)
        let task = deck.toastTask
        #expect(task != nil)
        await task?.value
        #expect(deck.toast == nil)
    }

    @Test func VoiceOver가_켜져_있으면_경고를_남긴다() {
        let deck = deck(voiceOver: true)
        deck.showToast("메모리 큐는 곡당 10개까지입니다")
        #expect(deck.toast?.kind == .warning && deck.toastTask == nil)
    }

    @Test func 새_알림은_앞_알림의_닫기를_취소한다() async {
        let deck = deck(voiceOver: false)
        deck.showToast("다시 분석합니다", kind: .success)
        let first = deck.toastTask
        // 뒤 알림은 닫히지 않는 종류로 띄워, 시험이 느려져도 앞 알림의 닫기만 본다.
        deck.showToast("오디오 출력 장치를 열지 못했습니다", kind: .failure)
        #expect(first?.isCancelled == true && deck.toastTask == nil)
        await first?.value
        #expect(deck.toast?.text == "오디오 출력 장치를 열지 못했습니다")
    }
}
