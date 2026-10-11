import DJCApplication
import DJCDomain
import AppKit
import Foundation

/// 루프: 즉석 루프·루프 큐·활성 루프(길이 규칙은 `LoopRules`)
extension DeckModel {
    // MARK: 루프 재생

    /// 즉석 루프(큐에 저장하지 않은 루프). CDJ의 오토 비트 루프와 같다. 이 상태로 빈 핫큐 칸을 누르면 루프 핫큐로 저장된다.
    struct InstantLoop: Equatable {
        var start: Double
        var end: Double
        /// 박 수(루프 큐로 저장할 때 rekordbox BeatLoopSize로 적는다)
        var beats: Double?
    }


    var loopSizeText: String { LoopRules.text(loopSize) }

    /// 지금 반복 중인 구간(즉석 루프 또는 루프 큐)
    var engagedLoopRange: InstantLoop? {
        if let instantLoop { return instantLoop }
        guard let cue = cue(engagedLoopID), let loop = cue.loop else { return nil }
        return InstantLoop(start: cue.time, end: loop.end, beats: loop.beats)
    }

    var isLooping: Bool { engagedLoopRange != nil }

    /// 걸린 루프를 오디오에 알린다. 오디오가 곡을 메모리에 풀어 두었으면 샘플 단위로 이어 붙여 끊김 없이 되풀이한다.
    func syncAudioLoop() {
        audio.setLoop(engagedLoopRange.map { $0.start...$0.end })
    }

    /// 재생 중 루프 처리. 반복으로 되돌렸으면 true.
    func handleLoops(previous: Double) -> Bool {
        let cues = draft?.cues ?? []
        // 활성 루프: 재생이 그 시작을 지나가면 자동으로 건다.
        if engagedLoopID == nil, instantLoop == nil,
           let active = cues.first(where: { $0.loop?.active == true && previous < $0.time && playhead >= $0.time }) {
            engagedLoopID = active.id
        }
        if engagedLoopID != nil, cue(engagedLoopID)?.loop == nil { engagedLoopID = nil }
        syncAudioLoop()
        guard let range = engagedLoopRange else { return false }
        // 오디오가 샘플 단위로 되풀이하고 있으면 화면은 따라가기만 한다.
        if audio.handlesLoop { return false }
        // 곡을 아직 메모리에 풀지 못했으면(막 불러온 직후) 예전처럼 끝에서 되돌린다.
        if playhead >= range.end - 0.004 {
            startPlayback(from: range.start)
            playhead = range.start
            return true
        }
        return false
    }

    /// 루프에서 빠져나온다(재생 중이면 지금 바퀴 끝에서 그대로 이어 간다).
    func exitLoop() {
        prepareLoopChange()
        engagedLoopID = nil
        instantLoop = nil
        syncAudioLoop()
    }

    /// LOOP 버튼·L: 반복 중이면 빠져나오고, 아니면 플레이헤드(퀀타이즈면 가까운 박)에서 `loopSize`박 루프를 건다.
    func toggleLoop() {
        let wasLooping = isLooping
        prepareLoopChange()
        if wasLooping {
            exitLoop()
            return
        }
        guard canPlay else {
            if let reason = playbackUnavailableReason { showToast(reason) }
            return
        }
        let start = snapped(currentTime)
        guard let end = loopEnd(from: start, beats: loopSize) else { return }
        instantLoop = InstantLoop(start: start, end: end, beats: loopSize)
        syncAudioLoop()
    }

    /// 루프 길이를 반으로(-1) · 두 배로(+1). 반복 중이면 시작점은 두고 끝만 바꾼다(루프 큐는 그대로 두고 즉석 루프로 바뀐다).
    func resizeLoop(_ direction: Int) {
        prepareLoopChange()
        let current = engagedLoopRange
        var size = loopSize
        if instantLoop == nil, let cue = cue(engagedLoopID) {
            if let beats = cue.loop?.beats { size = beats } else if let beats = loopBeats(cue), beats > 0 { size = Double(beats) }
        }
        guard let next = LoopRules.resized(size, direction: direction) else {
            showToast(String(ui: "루프 길이 한도에 도달했으니 반대 방향으로 길이를 바꾸세요"))
            return
        }
        if let current {
            guard let end = loopEnd(from: current.start, beats: next) else { return }
            engagedLoopID = nil
            instantLoop = InstantLoop(start: current.start, end: end, beats: next)
            if playhead >= end {
                // 줄어든 루프 밖에 있으면 바로 시작점으로(새 루프로 다시 예약된다)
                audio.setLoop(current.start...end, reschedule: false)
                jump(to: current.start)
            } else {
                syncAudioLoop()
            }
        }
        loopSize = next
    }

    /// `start`에서 `beats`박 뒤(규칙은 `LoopRules.end`). 곡 끝을 넘으면 알리고 nil.
    func loopEnd(from start: Double, beats: Double) -> Double? {
        guard let end = LoopRules.end(from: start, beats: beats, grid: grid, fallbackBPM: gridBPM, duration: duration) else {
            showToast(String(ui: "루프를 만들 박 정보나 남은 길이가 부족하니 그리드를 확인하고 더 짧은 루프나 앞쪽 위치를 고르세요"))
            return nil
        }
        return end
    }
}
