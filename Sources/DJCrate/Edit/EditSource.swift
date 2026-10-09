import DJCDomain
import Foundation

/// 편집 창(곡 편집·Flip)을 열 때 덱에서 읽어 둔 원곡(덱과 같은 rekordbox 시간축). 창 모델은 덱을 들고 있지 않는다.
struct EditSource {
    var row: TrackRow
    var cues: [EditableCue]
    var timelineOffset: Double
    var duration: Double
    var waveform: Waveform?
    /// 덱에서 듣던 자리(곡 편집 창은 여기부터 고른다)
    var currentTime: Double
    /// 편집할 수 있는지 정하는 값(`EditSourceState`)
    var state: EditSourceState

    var url: URL { URL(filePath: row.track.folderPath) }
}

/// 창 재생기가 덱과 겹쳐 들리지 않게 하는 덱 연결(창은 덱을 들고 있지 않는다)
@MainActor
struct EditDeckControl {
    /// 창에서 재생할 음량(덱 음량을 따른다)
    var volume: () -> Double
    /// 덱이 재생 중이면 멈춘다.
    var pause: () -> Void

    /// 덱 없이(시험)
    static let standalone = EditDeckControl(volume: { 0.9 }, pause: {})
}

extension DeckModel {
    /// 덱에 곡이 다 올라와(초안·그리드를 읽음) 곡 편집 창을 열 수 있는지
    var canOpenTrackEdit: Bool {
        row != nil && draft != nil && !isWriteLocked
    }

    var trackEditUnavailableReason: String? {
        if isWriteLocked { return String(ui: "rekordbox 쓰기가 끝난 뒤 곡 편집 창을 여세요") }
        if row == nil || draft == nil { return String(ui: "곡을 덱에 불러오고 초안 읽기가 끝난 뒤 곡 편집 창을 여세요") }
        return nil
    }

    /// 지금 덱의 곡. `audioFileExists`는 부르는 쪽이 메인 스레드 밖에서 확인한 값이다.
    func editSource(audioFileExists: Bool) -> EditSource? {
        guard let row else { return nil }
        // 스트리밍·파일 없음에서 먼저 막히면 덱의 재생 불가 이유(파일을 다시 본다)는 읽지 않는다.
        let playbackReason = canPlay || row.track.isStreaming || !audioFileExists ? nil : playbackUnavailableReason
        let state = EditSourceState(isStreaming: row.track.isStreaming, audioFileExists: audioFileExists,
                                    playbackUnavailableReason: playbackReason, segments: gridDraft?.segments ?? [],
                                    gridUnavailableReason: gridUnavailableReason, gridSourceNotice: gridSourceNotice,
                                    gridEditBlockedReason: gridEditBlockedReason)
        return EditSource(row: row, cues: draft?.cues ?? [], timelineOffset: timelineOffset, duration: duration,
                          waveform: waveform, currentTime: currentTime, state: state)
    }

    var editControl: EditDeckControl {
        EditDeckControl(volume: { [weak self] in self?.volume ?? 0.9 },
                        pause: { [weak self] in if let self, self.isPlaying { self.togglePlay() } })
    }
}
