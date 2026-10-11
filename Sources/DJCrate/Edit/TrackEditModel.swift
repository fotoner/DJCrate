import AVFoundation
import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 곡 편집 창(#80·#128): 덱에 올린 곡을 컷 편집기처럼 다룬다.
/// 원곡 줄에서 마디 구간을 끌어 고르고 → 결과 타임라인에 넣고 → 자르기·지우기·복제·끌어 옮기기(실행 취소) → 어디서든 들어 보고 → 렌더해 추가한 곡에 넣는다.
///
/// 원곡의 그리드·큐·길이는 창을 열 때 덱에서 읽어 둔 값(`EditSource`)이다(덱과 같은 rekordbox 시간축). 규칙은 `TrackEdit`·`EditTimeline`·
/// `EditPointer`(순수)가 정하고, 재생은 창 전용 재생기(`EditAudio`, 덱과 따로)가 원곡을 메모리에 풀어 결과를 렌더하지 않고 바로 낸다
/// (이음새 섞는 소리까지 결과물과 같다). 렌더·넣기는 `RenderEdit`가 메인 밖에서 한다. 원본 음원·rekordbox에는 쓰지 않는다.
/// 편집 명령은 `+Editing`, 재생·보기는 `+Playback`, 렌더는 `+Render`에 있다.
@MainActor
@Observable
final class TrackEditModel {
    typealias Entry = EditEntry
    typealias Lane = EditLane

    let row: TrackRow
    let source: URL
    let segments: [GridSegment]
    /// 편집할 수 없는 곡이면 nil(`blockedReason`)
    let layout: BarLayout?
    let blockedReason: String?
    let cues: [EditableCue]
    let timelineOffset: Double
    let duration: Double
    let waveform: Waveform?
    @ObservationIgnored let deck: EditDeckControl
    @ObservationIgnored let audio: any EditAudio
    @ObservationIgnored let writer: RenderEdit

    /// 결과 타임라인의 클립(목록 순서 = 출력 순서)
    var entries: [Entry] = [] { didSet { if entries != oldValue { rebuild() } } }
    /// 원곡 줄에서 끌어 고른 마디 구간
    var selection: BarRange?
    /// 결과 타임라인에서 고른 클립
    var selectedClip: Entry.ID?
    /// 원곡에서 고른 구간을 결과로 끄는 동안 놓을 자리(결과 줄에 표시한다)
    var insertPreview: EditInsertion?
    /// 새 곡 제목(태그 초안)이자 파일 이름
    var title: String
    private(set) var edit: TrackEdit?
    /// 목록이 규칙에 맞지 않을 때 이유와 할 일(렌더를 막는다)
    private(set) var planError: String?
    private(set) var carry: CueCarry?
    /// 결과의 마디 눈금(출력 그리드)
    private(set) var outputLayout: BarLayout?
    /// 결과 타임라인에 그릴 클립 자리(목록 순서). 규칙에 맞지 않는 목록도 고칠 수 있게 그린다.
    private(set) var clipLayout: [TrackEdit.Piece] = []
    var message: AppMessage?

    // MARK: 재생

    /// 스페이스바·←→가 움직이는 줄(마지막으로 누른 줄)
    var focus: Lane = .source
    /// 멈춘 동안의 재생선. 재생 중 위치는 `position(_:)`으로 읽는다(매 프레임 바뀌어 관찰하지 않는다).
    private(set) var sourcePlayhead: Double = 0
    private(set) var outputPlayhead: Double = 0
    private(set) var playing: Lane?
    /// 듣고 있는 이음새(`edit.pieces`의 순서)
    private(set) var auditioning: Int?
    private(set) var isAudioReady = false
    @ObservationIgnored private(set) var playStart: Double = 0
    @ObservationIgnored private(set) var playLimit: Double = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// 재생선을 끄는 동안 멈춘 재생(손을 떼면 그 자리에서 잇는다)
    @ObservationIgnored private(set) var scrubbing: Lane?

    // MARK: 보기(확대·가로 스크롤)

    /// 줄마다 보이는 자리(#134). 두 줄은 길이가 달라 따로 확대한다.
    private(set) var sourceView = EditViewport()
    private(set) var outputView = EditViewport()

    // MARK: 실행 취소

    /// 편집 창의 실행 취소(편집 › 실행 취소 ⌘Z). 창이 준다.
    @ObservationIgnored weak var undoManager: UndoManager? { didSet { observeUndo() } }
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []

    // MARK: 렌더

    /// 렌더 진행(0~1). nil이 아니면 렌더 중이다.
    private(set) var renderProgress: Double?
    private(set) var staged: StagedTrack?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored var onStaged: ((StagedTrack) -> Void)?

    /// - Parameters:
    ///   - deck: 창에서 재생할 때 덱을 멈추고 덱 음량을 따른다.
    ///   - writer: 렌더한 편집본을 쓰고 추가한 곡에 넣는다(앱은 음악 폴더의 DJCrate 편집본).
    init(source: EditSource, entries: [BarRange] = [], audio: any EditAudio,
         deck: EditDeckControl = .standalone, writer: RenderEdit) {
        row = source.row
        self.source = source.url
        self.deck = deck
        self.audio = audio
        self.writer = writer
        segments = source.state.segments
        cues = source.cues
        timelineOffset = source.timelineOffset
        duration = source.duration
        waveform = source.waveform
        title = "\(row.title) (Edit)"
        let opening = source.state.trackEditOpening(duration: duration)
        layout = opening.layout
        blockedReason = opening.blockedReason
        // 덱에서 듣던 자리부터 이어 고른다.
        sourcePlayhead = min(max(source.currentTime, 0), duration)
        self.entries = entries.map { Entry(id: UUID(), range: $0) }
        rebuild()
        if blockedReason == nil {
            audio.prepare(url: self.source) { [weak self] ready in
                self?.isAudioReady = ready
                if !ready {
                    self?.message = AppMessage(kind: .warning, text: String(ui: "원곡을 메모리에 풀지 못해 창에서 재생할 수 없습니다(20분 넘는 곡 등). 렌더한 뒤 덱에서 들어 보세요"))
                }
            }
        }
    }

    var canRender: Bool { blockedReason == nil && edit != nil && renderProgress == nil }

    var renderUnavailableReason: String? {
        if let blockedReason { return blockedReason }
        if renderProgress != nil { return String(ui: "렌더가 끝나거나 취소한 뒤 다시 렌더하세요") }
        if let planError { return planError }
        return edit == nil ? String(ui: "렌더할 구간이 없으니 원곡에서 마디 구간을 고른 뒤 결과에 넣으세요") : nil
    }

    var selectedIndex: Int? { selectedClip.flatMap { id in entries.firstIndex { $0.id == id } } }

    private func rebuild() {
        let bars = entries.map(\.range)
        // 재생 중인 결과가 바뀌면 멈춘다(바뀐 결과를 이어 들으려면 다시 재생).
        if playing == .output { pause() }
        if let selectedClip, !entries.contains(where: { $0.id == selectedClip }) { self.selectedClip = nil }
        defer {
            clipLayout = edit?.clips ?? layout.map { TrackEdit.place(bars, in: $0) } ?? []
            outputPlayhead = min(outputPlayhead, edit?.duration ?? 0)
        }
        guard layout != nil, !bars.isEmpty else { edit = nil; carry = nil; planError = nil; outputLayout = nil; return }
        do {
            let edit = try TrackEdit(grid: segments, sourceDuration: duration, bars: bars)
            self.edit = edit
            // 옮긴 큐는 새 곡(편집본)의 큐라 새 ID를 붙인다
            carry = edit.carry(cues, newID: { UUID() })
            outputLayout = try? BarLayout(grid: [edit.outputGrid], duration: edit.duration)
            planError = nil
        } catch {
            edit = nil
            carry = nil
            outputLayout = nil
            planError = Self.reason(error)
        }
    }

    static func reason(_ error: any Error) -> String {
        if case let DJCError.editRefused(reason) = error { return reason }
        return AppErrorMessage.message(for: error)
    }

    /// 창을 닫을 때: 재생·렌더를 멈추고 메모리에 푼 원곡을 놓는다.
    func close() {
        stopAudio()
        audio.close()
        renderTask?.cancel()
        undoManager?.removeAllActions(withTarget: self)
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
    }

    // MARK: - 상태 바꾸기
    // 재생·보기·실행 취소·렌더 상태는 이 파일에서만 바꾼다. 확장(+Playback·+Editing·+Render)은 아래 메서드로 고쳐
    // 뷰가 소리 멈추기 같은 짝 동작을 건너뛰고 상태만 바꾸지 못하게 한다.

    /// 재생을 시작한 상태로 둔다. `watch`는 끝·화면 넘김을 지켜보는 작업.
    func markPlaying(_ lane: Lane, from time: Double, limit: Double, watch: Task<Void, Never>) {
        playStart = time
        playLimit = limit
        playing = lane
        playTask = watch
    }

    /// 듣고 있는 이음새를 적는다(결과를 재생 중일 때만).
    func markAuditioning(_ piece: Int) {
        if playing == .output { auditioning = piece }
    }

    func stopAudio() {
        playTask?.cancel()
        playTask = nil
        if playing != nil || audio.isPlaying { audio.stop() }
        playing = nil
        auditioning = nil
    }

    /// 재생선을 줄 길이 안으로 옮긴다.
    func setPlayhead(_ lane: Lane, _ time: Double) {
        let time = min(max(time, 0), length(lane))
        if lane == .source { sourcePlayhead = time } else { outputPlayhead = time }
    }

    /// 자른 뒤 결과 재생선을 자른 자리에 둔다(결과를 다시 만든 뒤라 길이로 자르지 않는다).
    func placeOutputPlayhead(_ time: Double) {
        outputPlayhead = time
    }

    /// 재생선을 끄는 동안 멈춘 줄을 적거나(`lane`) 꺼낸다(nil).
    func holdScrub(_ lane: Lane?) {
        scrubbing = lane
    }

    func setViewport(_ view: EditViewport, for lane: Lane) {
        if lane == .source { sourceView = view } else { outputView = view }
    }

    func observeUndo() {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup,
                         .NSUndoManagerDidOpenUndoGroup].map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndo() }
            }
        }
        refreshUndo()
    }

    func refreshUndo() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    /// 렌더를 시작한 상태로 둔다(진행 0).
    func markRendering(_ task: Task<Void, Never>) {
        renderProgress = 0
        renderTask = task
    }

    /// 렌더 진행. 끝난 뒤 늦게 온 진행은 버린다.
    func updateRenderProgress(_ value: Double) {
        if renderProgress != nil { renderProgress = value }
    }

    func markStaged(_ track: StagedTrack) {
        staged = track
    }

    /// 렌더가 끝났다(성공·실패·취소).
    func finishRendering() {
        renderTask = nil
        renderProgress = nil
    }

    func cancelRender() {
        renderTask?.cancel()
    }
}
