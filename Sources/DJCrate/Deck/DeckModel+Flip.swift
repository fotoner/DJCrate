import DJCApplication
import DJCDomain
import Foundation

/// Flip 기록(Serato Flip처럼): 재생하며 쓴 점프·루프만 모아 같은 소리로 재생되는 편집본을 만든다.
/// rekordbox에는 Flip 재생이 없어 결과는 새 곡 파일(추가한 곡)이다. 기록 규칙은 `FlipRecording`, 결과 창은 `FlipWindow`.
///
/// 들린 구간은 오디오가 재생 한 번이 끝날 때마다 샘플 단위로 알린다(`DeckAudioEngine.onPlayedRun`, 루프는 바퀴마다).
extension DeckModel {
    /// Flip 기록을 시작할 수 없는 이유와 할 일(기록 중이면 nil: 마치기는 언제든 된다)
    var flipUnavailableReason: String? {
        guard !isFlipRecording else { return nil }
        if isWriteLocked { return String(ui: "rekordbox 쓰기가 끝난 뒤 Flip을 기록하세요") }
        if row == nil || draft == nil { return String(ui: "곡을 덱에 불러오고 초안 읽기가 끝난 뒤 Flip을 기록하세요") }
        return playbackUnavailableReason
    }

    /// 기록을 시작한다. 이미 재생 중이면 지금부터 센다(그 전에 쓴 점프·루프는 넣지 않는다).
    func startFlipRecording() {
        guard !isFlipRecording else { return }
        if let reason = flipUnavailableReason {
            showToast(reason)
            return
        }
        flipRecording = FlipRecording()
        // 기록하는 동안만 들린 구간을 받는다(기록하지 않을 때 멈춤·점프마다 구간을 계산하지 않게).
        audio.onPlayedRun = { [weak self] run in self?.flipRecording?.record(run) }
        _ = audio.takePlayedRun()
        isFlipRecording = true
        showToast(String(ui: "Flip 기록 중: 재생하며 핫큐·루프를 쓴 뒤 Flip을 다시 누르면 편집본으로 만듭니다"), kind: .success)
    }

    /// 기록을 마치고 기록을 돌려준다. 재생은 그대로 둔다(지금까지 들린 곳까지 넣는다).
    func finishFlipRecording() -> FlipRecording? {
        guard isFlipRecording, var recording = flipRecording else { return nil }
        if let run = audio.takePlayedRun() { recording.record(run) }
        audio.onPlayedRun = nil
        flipRecording = nil
        isFlipRecording = false
        return recording
    }

    /// 기록을 버린다(곡을 바꿀 때).
    func cancelFlipRecording() {
        audio.onPlayedRun = nil
        flipRecording = nil
        isFlipRecording = false
    }

    /// 곡을 바꿔 기록을 버리기 전에 묻는다. 기록 중이 아니거나 점프·루프가 아직 없으면 묻지 않는다.
    /// - Returns: 버려도 되면 true(기록은 곡을 바꿀 때 `load`가 지운다). 취소하면 false이고 기록은 이어 간다.
    func confirmDiscardingFlip() -> Bool {
        if !isFlipRecording, let waiting = awaitingFlipResult {
            // 기록은 마쳤지만 결과 창이 아직 열리지 않았다(음원 확인을 기다리는 중). 곡을 바꾸면 결과 창을 열지 않는다.
            // 확인 창이 떠 있는 동안 음원 확인이 끝난 열기는 답을 기다린다(`finishAwaitingFlipResult`).
            flipDecisionWaiters = flipDecisionWaiters ?? []
            let discard = prompter.show(ReflectionPrompt(
                title: String(ui: "Flip 기록을 버릴까요?"),
                text: String(ui: "곡을 바꾸면 방금 마친 기록(점프·루프 \(waiting.jumpCount)개)으로 결과 창을 열지 않고 버립니다. 버린 기록은 다시 만들 수 없으니, 남기려면 취소하고 결과 창이 열릴 때까지 기다리세요"),
                confirm: String(ui: "기록 버리기"), destructive: true))
            // 버리면 차례를 넘겨 진행 중인 열기가 결과 창도 안내도 없이 끝나게 한다.
            if discard {
                flipResultTurn += 1
                awaitingFlipResult = nil
            }
            let waiters = flipDecisionWaiters ?? []
            flipDecisionWaiters = nil
            waiters.forEach { $0.resume() }
            return discard
        }
        guard isFlipRecording else { return true }
        // 지금 재생 안에서 아직 알리지 않은 점프도 센다.
        if let run = audio.takePlayedRun() { flipRecording?.record(run) }
        guard let recording = flipRecording, !recording.isEmpty else { return true }
        return prompter.show(ReflectionPrompt(
            title: String(ui: "Flip 기록을 버릴까요?"),
            text: String(ui: "곡을 바꾸면 지금까지 기록한 점프·루프 \(recording.jumpCount)개를 버립니다. 버린 기록은 다시 만들 수 없으니, 남기려면 취소하고 Flip을 눌러 기록을 마치세요"),
            confirm: String(ui: "기록 버리기"), destructive: true))
    }

    /// 마친 기록의 결과 창을 기다리기 시작한다(그동안 곡을 바꾸면 버릴지 묻는다). 돌려준 차례는 기다린 뒤 `finishAwaitingFlipResult`에 넘긴다.
    func beginAwaitingFlipResult(_ recording: FlipRecording) -> Int {
        flipResultTurn += 1
        awaitingFlipResult = recording
        return flipResultTurn
    }

    /// 기다리기를 마친다. 버릴지 묻는 창이 떠 있으면 답을 기다린다.
    /// - Returns: 그 사이 기록을 버렸으면 false(결과 창을 열지 않고 조용히 끝낸다).
    func finishAwaitingFlipResult(_ turn: Int) async -> Bool {
        if flipDecisionWaiters != nil {
            await withCheckedContinuation { flipDecisionWaiters?.append($0) }
        }
        guard turn == flipResultTurn else { return false }
        awaitingFlipResult = nil
        return true
    }

    /// 시험용: 결과 창 열기가 버릴지 묻는 창의 답을 기다리는 중인지
    var isAwaitingFlipDecision: Bool { !(flipDecisionWaiters?.isEmpty ?? true) }
}
