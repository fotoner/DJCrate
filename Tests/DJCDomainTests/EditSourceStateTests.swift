@testable import DJCDomain
import Foundation
import Testing

/// 편집 창(곡 편집·Flip)을 열 때 덱에서 읽어 둔 원곡 상태로 정하는 것: 막힘 이유, 마디 눈금, Flip 그리드, 편집본 파일 이름, 이음새 듣기 구간.
@Suite("편집 창 열기·편집본 이름")
struct EditSourceStateTests {
    /// 120 BPM(1마디 2초), 첫 다운비트 0.5초
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    func state(segments: [GridSegment]? = nil) -> EditSourceState {
        EditSourceState(isStreaming: false, audioFileExists: true, playbackUnavailableReason: nil, segments: segments ?? grid,
                        gridUnavailableReason: nil, gridSourceNotice: nil, gridEditBlockedReason: nil)
    }

    @Test func 막힘_이유는_스트리밍·파일·재생·그리드_순서로_본다() {
        var state = state()
        state.isStreaming = true
        state.audioFileExists = false
        state.playbackUnavailableReason = "재생 불가"
        state.gridEditBlockedReason = "그리드 막힘"
        #expect(state.trackEditOpening(duration: 20.5) == .blocked(EditSourceState.streamingReason))
        state.isStreaming = false
        #expect(state.trackEditOpening(duration: 20.5) == .blocked(EditSourceState.missingFileReason))
        state.audioFileExists = true
        #expect(state.trackEditOpening(duration: 20.5) == .blocked("재생 불가"))
        state.playbackUnavailableReason = nil
        #expect(state.trackEditOpening(duration: 20.5) == .blocked("그리드 막힘"))
        state.gridEditBlockedReason = nil
        let opening = state.trackEditOpening(duration: 20.5)
        #expect(opening.blockedReason == nil && opening.layout?.count == 10 && opening.layout?.hasLeadIn == true)
    }

    @Test func 그리드가_없으면_그리드_이유·안내·기본_순서로_알린다() {
        var state = state(segments: [])
        state.gridUnavailableReason = "그리드 이유"
        state.gridSourceNotice = "분석 파일 안내"
        #expect(state.trackEditOpening(duration: 20.5).blockedReason == "그리드 이유")
        state.gridUnavailableReason = nil
        #expect(state.trackEditOpening(duration: 20.5).blockedReason == "분석 파일 안내")
        state.gridSourceNotice = nil
        #expect(state.trackEditOpening(duration: 20.5) == .blocked(EditSourceState.noGridReason))
    }

    @Test func 변속_곡은_마디_눈금을_만들지_못한_이유를_보인다() {
        let state = state(segments: grid + [GridSegment(start: 10.5, bpm: 124, firstBeatNumber: 1)])
        let opening = state.trackEditOpening(duration: 20.5)
        #expect(opening.layout == nil && opening.blockedReason?.contains("템포 구간 2개") == true)
    }

    @Test func Flip은_음원이_있어야_만들고_옮길_수_없는_그리드는_빼고_넣는다() throws {
        var state = state()
        state.isStreaming = true
        #expect(state.flipBlockedReason == EditSourceState.missingFileReason)
        state.isStreaming = false
        state.audioFileExists = false
        #expect(state.flipBlockedReason == EditSourceState.missingFileReason)
        state.audioFileExists = true
        // 재생·그리드 막힘은 Flip을 막지 않는다(그리드만 뺀다).
        state.playbackUnavailableReason = "재생 불가"
        #expect(state.flipBlockedReason == nil)

        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [PlayedSpan(start: 0, end: 8.5), PlayedSpan(start: 4.5, end: 12)], continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 20.5)
        let moved = state.flipGrid(flip)
        #expect(moved.grid == [GridSegment(start: 0, bpm: 120, firstBeatNumber: 4)] && moved.notice == nil)
        state.gridEditBlockedReason = "다이내믹 그리드"
        #expect(state.flipGrid(flip).grid.isEmpty && state.flipGrid(flip).notice == EditSourceState.flipGridBlockedNotice)
        let bare = self.state(segments: [])
        #expect(bare.flipGrid(flip).grid.isEmpty && bare.flipGrid(flip).notice == EditSourceState.flipNoGridNotice)
    }

    @Test func 파일_이름에_못_쓰는_글자는_바꾼다() {
        #expect(EditOutputName.fileName(for: "A/B: C (Edit)") == "A-B- C (Edit)")
        #expect(EditOutputName.fileName(for: "  ") == "Edit")
        #expect(EditOutputName.fileName(for: ".숨김") == "숨김")
        #expect(EditOutputName.fileName(for: String(repeating: "가", count: 200)).count == 120)
    }

    @Test func 있는_파일은_덮지_않고_번호를_붙인다() {
        let directory = URL(filePath: "/편집본")
        let existing: Set<String> = ["/편집본/곡 (Edit).wav", "/편집본/곡 (Edit) 2.wav"]
        var asked: [String] = []
        let url = EditOutputName.available(in: directory, name: "곡 (Edit)") { asked.append($0.lastPathComponent); return existing.contains($0.path) }
        #expect(url.path == "/편집본/곡 (Edit) 3.wav")
        #expect(asked == ["곡 (Edit).wav", "곡 (Edit) 2.wav", "곡 (Edit) 3.wav"])
        #expect(EditOutputName.available(in: directory, name: "새 곡") { existing.contains($0.path) }.path == "/편집본/새 곡.wav")
    }

    @Test func 이음새_듣기는_앞뒤_2마디를_이웃_조각_안에서() throws {
        // 1~4마디 두 번: 조각마다 8초, 이음새 8초 → 4초부터 12초까지
        let long = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(1, 4), BarRange(1, 4)])
        #expect(long.seamAudition(1) == 4...12)
        // 조각이 2마디보다 짧으면 그 조각 안에서(이음새 2초 → 0초부터 4초까지)
        let short = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(1, 1), BarRange(5, 5)])
        #expect(short.seamAudition(1) == 0...4)
        // 첫 조각 앞·없는 조각은 이음새가 아니다
        #expect(long.seamAudition(0) == nil && long.seamAudition(2) == nil)
    }
}
