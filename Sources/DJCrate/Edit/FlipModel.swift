import AVFoundation
import DJCApplication
import DJCDomain
import Foundation
import Observation

/// Flip 결과 창: 덱에서 기록한 Flip(`FlipRecording`)을 편집본으로 보여 주고 → 들어 보고 → 렌더해 추가한 곡에 넣는다.
///
/// 원곡의 그리드·큐·길이는 창을 열 때 덱에서 읽어 둔 값(`EditSource`)이다(덱과 같은 rekordbox 시간축). 결과 시간표는 `FlipEdit`(순수)이 정하고,
/// 재생은 곡 편집 창과 같은 창 전용 재생기(`EditAudio`, 덱과 따로)가 원곡을 메모리에 풀어 렌더하지 않고 바로 낸다.
/// 렌더·넣기는 `RenderEdit`가 메인 밖에서 한다. 원본 음원·rekordbox에는 쓰지 않는다.
@MainActor
@Observable
final class FlipModel {
    let row: TrackRow
    let source: URL
    let flip: FlipEdit
    /// 결과에 남은 점프 수(루프 되풀이 한 바퀴도 하나)
    let jumpCount: Int
    /// 출력 그리드. 원곡 그리드를 옮길 수 없으면 비어 있다(`gridNotice`).
    let grid: [GridSegment]
    let gridNotice: String?
    let carry: CueCarry
    let timelineOffset: Double
    let sourceDuration: Double
    let waveform: Waveform?
    @ObservationIgnored let deck: EditDeckControl
    @ObservationIgnored let audio: any EditAudio
    @ObservationIgnored let writer: RenderEdit

    /// 새 곡 제목(태그 초안)이자 파일 이름
    var title: String
    var message: AppMessage?

    // MARK: 재생

    private(set) var isAudioReady = false
    /// 멈춘 동안의 재생선. 재생 중 위치는 `position`으로 읽는다(매 프레임 바뀌어 관찰하지 않는다).
    private(set) var playhead: Double = 0
    private(set) var playing = false
    @ObservationIgnored private var playStart: Double = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// 재생선을 끄는 동안 멈춘 재생(손을 떼면 그 자리에서 잇는다)
    @ObservationIgnored private var scrubbing = false

    // MARK: 렌더

    /// 렌더 진행(0~1). nil이 아니면 렌더 중이다.
    private(set) var renderProgress: Double?
    private(set) var staged: StagedTrack?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored var onStaged: ((StagedTrack) -> Void)?

    /// - Parameters:
    ///   - deck: 창에서 재생할 때 덱을 멈추고 덱 음량을 따른다.
    ///   - writer: 렌더한 편집본을 쓰고 추가한 곡에 넣는다(앱은 음악 폴더의 DJCrate 편집본).
    /// - Throws: 결과를 만들 수 없을 때(점프가 없음·음원 없음) 이유와 할 일(`DJCError.editRefused`)
    init(source: EditSource, recording: FlipRecording, audio: any EditAudio,
         deck: EditDeckControl = .standalone, writer: RenderEdit) throws {
        if let reason = source.state.flipBlockedReason { throw DJCError.editRefused(reason) }
        let flip = try FlipEdit(recording, sourceDuration: source.duration)
        row = source.row
        self.source = source.url
        self.flip = flip
        self.deck = deck
        self.audio = audio
        self.writer = writer
        jumpCount = flip.pieces.count - 1
        timelineOffset = source.timelineOffset
        sourceDuration = source.duration
        waveform = source.waveform
        title = "\(row.title) (Flip)"
        // 옮긴 큐는 새 곡(편집본)의 큐라 새 ID를 붙인다
        carry = flip.carry(source.cues, newID: { UUID() })
        let moved = source.state.flipGrid(flip)
        grid = moved.grid
        gridNotice = moved.notice
        audio.prepare(url: self.source) { [weak self] ready in
            self?.isAudioReady = ready
            if !ready {
                self?.message = AppMessage(kind: .warning, text: String(ui: "원곡을 메모리에 풀지 못해 창에서 재생할 수 없습니다(20분 넘는 곡 등). 렌더한 뒤 덱에서 들어 보세요"))
            }
        }
    }

    var duration: Double { flip.duration }

    var canRender: Bool { renderProgress == nil }

    // MARK: - 재생·시킹

    /// 지금 재생선 위치(재생 중이면 들리는 자리)
    var position: Double {
        playing ? min(playStart + audio.elapsed, duration) : playhead
    }

    var canPlay: Bool { isAudioReady && duration > 0 }

    func togglePlay() {
        if playing { pause() } else { play() }
    }

    /// 재생선에서 재생한다. 끝에 있으면 처음부터.
    func play() {
        guard canPlay else { return }
        var from = position
        if from >= duration - 0.01 { from = 0 }
        start(at: from)
    }

    private func start(at time: Double) {
        stopAudio()
        // 덱과 겹쳐 들리지 않게 덱을 멈춘다.
        deck.pause()
        let rate = audio.sampleRate
        let items = TrackEdit.playbackItems(flip.frames(sampleRate: rate, sourceOffset: timelineOffset))
        playhead = min(max(time, 0), duration)
        guard audio.play(items, from: Int64((playhead * rate).rounded()), volume: Float(deck.volume())) else {
            message = AppMessage(kind: .failure, text: String(ui: "재생하지 못했습니다. 소리 출력 장치를 확인하세요"))
            return
        }
        playStart = playhead
        playing = true
        // 끝에 닿으면 멈춘다.
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.playing else { return }
                if !self.audio.isPlaying || self.playStart + self.audio.elapsed >= self.duration {
                    self.pause()
                    return
                }
            }
        }
    }

    /// 멈추고 들리던 자리에 재생선을 둔다.
    func pause() {
        guard playing else { return }
        let time = position
        stopAudio()
        playhead = min(max(time, 0), duration)
    }

    private func stopAudio() {
        playTask?.cancel()
        playTask = nil
        if playing || audio.isPlaying { audio.stop() }
        playing = false
    }

    /// 재생선을 옮긴다(누른 자리·Home·End). 재생 중이면 그 자리에서 잇는다.
    func seek(to time: Double) {
        if playing { start(at: time) } else { playhead = min(max(time, 0), duration) }
    }

    /// 재생선을 끄는 동안: 소리를 멈췄다가 `endScrub`에서 그 자리부터 잇는다.
    func scrub(to time: Double) {
        if playing {
            stopAudio()
            scrubbing = true
        }
        playhead = min(max(time, 0), duration)
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        play()
    }

    /// 출력 시각이 든 조각(`flip.pieces`의 순서)
    func pieceIndex(atOutput time: Double) -> Int? {
        flip.pieces.firstIndex { time < $0.outputEnd } ?? (flip.pieces.isEmpty ? nil : flip.pieces.count - 1)
    }

    // MARK: - 렌더 → 추가한 곡

    /// 백그라운드에서 렌더하고(진행·취소) 추가한 곡에 넣는다. 파일 이름 고르기·렌더·넣기는 `RenderEdit`가 메인 밖에서 한다.
    func render() {
        guard canRender else { return }
        pause()
        message = nil
        let request = EditOutputRequest(job: EditRenderJob(plan: .flip(flip), source: source, sourceOffset: timelineOffset),
                                        title: title, grid: grid, cues: carry.placed, sourceTrack: row.track)
        let writer = writer, duration = flip.duration
        renderProgress = 0
        renderTask = Task { [self] in
            defer {
                renderTask = nil
                renderProgress = nil
            }
            do {
                let staged = try await writer.write(request) { [weak self] value in
                    Task { @MainActor in
                        // 끝난 뒤 늦게 온 진행은 버린다.
                        if self?.renderProgress != nil { self?.renderProgress = value }
                    }
                }
                self.staged = staged
                message = AppMessage(kind: .success, text: String(ui: "Flip 편집본을 추가한 곡에 넣었습니다: \(request.title) · \(duration.clockText) · 큐 \(request.cues.count)개"))
                onStaged?(staged)
            } catch is CancellationError {
                message = AppMessage(kind: .warning, text: String(ui: "렌더를 취소했습니다. 만들던 파일은 지웠습니다."))
            } catch {
                message = AppMessage(kind: .failure, text: String(ui: "렌더하지 못했습니다. \(TrackEditModel.reason(error))"))
            }
        }
    }

    /// 결과를 버리기 전에(창 닫기·다시 기록) 묻는다. 기록은 다시 만들 수 없다. 이미 추가한 곡에 넣었으면 묻지 않는다.
    /// - Returns: 버려도 되면 true
    func confirmDiscard(_ prompter: any ReflectionPrompter) -> Bool {
        guard staged == nil else { return true }
        return prompter.show(ReflectionPrompt(
            title: String(ui: "Flip 결과를 버릴까요?"),
            text: String(ui: "아직 추가한 곡에 넣지 않은 Flip(점프·루프 \(jumpCount)개)을 버립니다. 버린 기록은 다시 만들 수 없으니, 남기려면 취소하고 렌더해서 넣으세요"),
            confirm: String(ui: "Flip 버리기"), destructive: true))
    }

    func cancelRender() {
        renderTask?.cancel()
    }

    /// 창을 닫을 때: 재생·렌더를 멈추고 메모리에 푼 원곡을 놓는다.
    func close() {
        stopAudio()
        audio.close()
        renderTask?.cancel()
    }
}
