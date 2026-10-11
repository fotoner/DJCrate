@testable import DJCDomain
import Foundation
import Testing

@Suite("Flip: 들린 구간 → 점프 경로 → 출력 시간표")
struct FlipEditTests {
    func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) < tolerance }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let DJCError.editRefused(reason) { return reason } catch { return "다른 오류: \(error)" }
    }

    func span(_ start: Double, _ end: Double) -> PlayedSpan { PlayedSpan(start: start, end: end) }

    func ranges(_ recording: FlipRecording) -> [String] {
        recording.path.map { segment in
            let end = segment.end.map { String(format: "%.3f", $0) } ?? "끝"
            return String(format: "%.3f", segment.start) + "~" + end
        }
    }

    // MARK: - 재생 조각 → 들린 구간

    @Test func 루프가_없으면_한_구간() {
        // 1000Hz, 시간축 차이 0. 10초에서 재생 시작, 노드 2000프레임(2초)까지 들렸다.
        let schedule = PlaybackSchedule(sampleRate: 1000, timelineOffset: 0, startLinear: 10,
                                        pieces: [PlaybackPiece(node: 0, frame: 10_000, loop: nil)])
        #expect(schedule.playedSpans(from: -.infinity, to: 2000) == [span(10, 12)])
        // 이미 알린 앞부분은 빼고 센다
        #expect(schedule.playedSpans(from: 500, to: 2000) == [span(10.5, 12)])
        #expect(schedule.playedSpans(from: 2000, to: 2000).isEmpty)
    }

    @Test func 루프는_바퀴마다_나눈다() {
        // 10초에서 재생 → 11초(노드 1000)에 루프 10.5~11초를 건다 → 노드 2250까지(2바퀴 반)
        let schedule = PlaybackSchedule(sampleRate: 1000, timelineOffset: 0, startLinear: 10, pieces: [
            PlaybackPiece(node: 0, frame: 10_000, loop: nil),
            PlaybackPiece(node: 1000, frame: 10_500, loop: 500),
        ])
        #expect(schedule.playedSpans(from: -.infinity, to: 2250) == [span(10, 11), span(10.5, 11), span(10.5, 11), span(10.5, 10.75)])
    }

    @Test func 아직_닿지_않은_점프는_빠지고_곡_앞_지연_구간도_센다() {
        // 0.05초 지연 곡을 0초에서 재생(노드는 50프레임 늦게 시작), 노드 1000에 30초로 넘어가게 예약했다.
        let schedule = PlaybackSchedule(sampleRate: 1000, timelineOffset: 0.05, startLinear: 0, leadInFrames: 50, pieces: [
            PlaybackPiece(node: 0, frame: 0, loop: nil),
            PlaybackPiece(node: 1000, frame: 29_950, loop: nil),
        ])
        #expect(schedule.playedSpans(from: -.infinity, to: 500) == [span(0, 0.55)])
        #expect(schedule.playedSpans(from: -.infinity, to: 1500) == [span(0, 1.05), span(30, 30.5)])
    }

    // MARK: - 점프 경로

    @Test func 어디서_재생했든_곡_처음부터_점프_출발점까지_이어진다() {
        // 60초에서 재생을 시작해 70초에서 핫큐(10초)로 → 결과는 0~70초 + 10초~끝
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70), span(10, 30)], continuing: false))
        #expect(ranges(recording) == ["0.000~70.000", "10.000~끝"])
        #expect(recording.jumpCount == 1)
    }

    @Test func 탐색_이동은_다시_재생으로_이어진_점프다() {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70)], continuing: true))
        recording.record(PlayedRun(spans: [span(10, 30)], continuing: false))
        #expect(ranges(recording) == ["0.000~70.000", "10.000~끝"])
    }

    @Test func 멈췄다가_다른_자리에서_재생한_것은_점프가_아니다() {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70)], continuing: false))
        recording.record(PlayedRun(spans: [span(100, 110), span(20, 25)], continuing: false))
        #expect(ranges(recording) == ["0.000~110.000", "20.000~끝"])
        // 같은 자리에서 다시 재생(µs 어긋남)도 점프가 아니다
        var resumed = FlipRecording()
        resumed.record(PlayedRun(spans: [span(60, 70)], continuing: true))
        resumed.record(PlayedRun(spans: [span(70.0004, 80)], continuing: false))
        #expect(resumed.isEmpty)
    }

    @Test func 끌기로_멈췄다가_이어_재생하면_점프다() {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70)], continuing: false))
        recording.linkNextRun()
        recording.record(PlayedRun(spans: [span(90, 95)], continuing: false))
        #expect(ranges(recording) == ["0.000~70.000", "90.000~끝"])
        // 다시 재생하지 못했으면 이어지지 않는다
        var broken = FlipRecording()
        broken.record(PlayedRun(spans: [span(60, 70)], continuing: true))
        broken.breakLink()
        broken.record(PlayedRun(spans: [span(90, 95)], continuing: false))
        #expect(broken.isEmpty)
    }

    @Test func 루프_되풀이는_바퀴마다_점프다() {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(8, 11), span(10.5, 11), span(10.5, 11), span(10.5, 14)], continuing: false))
        #expect(ranges(recording) == ["0.000~11.000", "10.500~11.000", "10.500~11.000", "10.500~끝"])
        #expect(recording.jumpCount == 3)
    }

    @Test func 같은_핫큐를_연달아_누른_스터터() {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(20, 32.3), span(32, 32.2), span(32, 40)], continuing: false))
        #expect(ranges(recording) == ["0.000~32.300", "32.000~32.200", "32.000~끝"])
    }

    @Test func 마지막_착지보다_앞에서_다시_재생해_점프하면_그_뒤를_다시_쓴다() {
        // 70초 → 10초로 점프한 뒤 멈추고 5초로 돌아가 8초에서 100초로 점프: 앞 점프는 버리고 0~8초 + 100초~끝
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70), span(10, 20)], continuing: false))
        recording.record(PlayedRun(spans: [span(5, 8), span(100, 110)], continuing: false))
        #expect(ranges(recording) == ["0.000~8.000", "100.000~끝"])
    }

    @Test func 착지_뒤에서_다시_재생하면_앞_점프를_지킨다() {
        // 70초 → 10초 점프, 20초에서 멈춤, 15초로 돌아가 25초에서 100초로: 0~70 + 10~25 + 100~끝
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70), span(10, 20)], continuing: false))
        recording.record(PlayedRun(spans: [span(15, 25), span(100, 110)], continuing: false))
        #expect(ranges(recording) == ["0.000~70.000", "10.000~25.000", "100.000~끝"])
    }

    // MARK: - 출력 시간표

    @Test func 경로를_이어_붙인_출력() throws {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70), span(10, 30)], continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 180)
        #expect(flip.pieces.count == 2)
        #expect(near(flip.pieces[0].sourceStart, 0) && near(flip.pieces[0].sourceEnd, 70) && near(flip.pieces[0].outputEnd, 70))
        #expect(near(flip.pieces[1].sourceStart, 10) && near(flip.pieces[1].outputStart, 70) && near(flip.pieces[1].outputEnd, 240))
        #expect(near(flip.duration, 240))
        #expect(flip.seams.count == 1 && near(flip.seams[0], 70))
        #expect(near(flip.sourceTime(atOutput: 75) ?? -1, 15))
    }

    @Test func 점프가_없으면_만들지_않는다() {
        #expect(refusal { _ = try FlipEdit(FlipRecording(), sourceDuration: 180) }?.contains("점프") == true)
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70), span(10, 30)], continuing: false))
        #expect(refusal { _ = try FlipEdit(recording, sourceDuration: 0) } != nil)
    }

    @Test func 곡_끝을_넘는_기록은_곡_끝에서_자르고_짧은_조각은_버린다() throws {
        var recording = FlipRecording()
        // 끝 너머(181초)에서 10초로, 곧바로(0.5ms 뒤) 다시 20초로
        recording.record(PlayedRun(spans: [span(170, 181), span(10, 10.0005), span(20, 30)], continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 180)
        #expect(flip.pieces.count == 2)
        #expect(near(flip.pieces[0].sourceEnd, 180) && near(flip.pieces[1].sourceStart, 20))
    }

    @Test func 프레임이_빈틈없이_이어진다() throws {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(8, 11), span(10.5, 11), span(10.5, 11), span(10.5, 14)], continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 20)
        let spans = flip.frames(sampleRate: 44_100, sourceOffset: 0)
        for (before, after) in zip(spans, spans.dropFirst()) {
            #expect(before.outputFrame + before.frameCount == after.outputFrame)
            #expect(after.crossfadeFrames == 176)
        }
        #expect(spans.first?.crossfadeFrames == 0)
        #expect(spans[1].sourceFrame == 463_050)  // 10.5초
    }

    @Test func 큐는_처음_나오는_자리로_옮긴다() throws {
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(60, 70), span(10, 30)], continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 180)
        let hot = EditableCue(kind: .hot(0), time: 20)
        let late = EditableCue(kind: .memory, time: 100)
        let carried = flip.carry([hot, late])
        // 20초는 첫 조각(0~70초)에서 먼저 나온다. 100초는 두 번째 조각의 출력 160초.
        #expect(carried.placed.map(\.time) == [20, 160])
        #expect(carried.dropped.isEmpty)
    }

    // MARK: - 출력 그리드

    /// 120 BPM(1박 0.5초), 첫 박 0.5초 = 1박
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    @Test func 박_줄과_박_번호가_이어지는_점프는_그리드_한_구간() throws {
        // 16.5초(1박)에서 8.5초(1박)로: 박 간격·번호가 그대로 이어진다
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(10, 16.5), span(8.5, 12)], continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 60)
        let output = flip.outputGrid(grid)
        #expect(output.count == 1)
        #expect(near(output[0].start, 0) && output[0].firstBeatNumber == 4 && output[0].bpm == 120)
    }

    @Test func 박_번호가_어긋나는_점프는_새_구간() throws {
        // 17.5초(3박)에서 8.5초(1박)로: 박 줄은 맞지만 번호가 3→1로 바뀐다
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(10, 17.5), span(8.5, 12)], continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 60)
        let output = flip.outputGrid(grid)
        #expect(output.count == 2)
        #expect(near(output[1].start, 17.5) && output[1].firstBeatNumber == 1)
    }

    @Test func 박_줄을_벗어난_점프는_새_구간() throws {
        // 16.7초에서 8.5초로(박 0.2초 앞에서 끊음): 다음 박이 0.3초 뒤에 온다
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(10, 16.7), span(8.5, 12)], continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 60)
        let output = flip.outputGrid(grid)
        #expect(output.count == 2)
        #expect(near(output[1].start, 16.7) && output[1].firstBeatNumber == 1)
        #expect(flip.outputGrid([]).isEmpty)
    }

    // MARK: - 짧은 루프의 출력 그리드(GridDraft로 박을 만들어 본다)

    /// 출력 그리드를 rekordbox에 쓸 박으로 만든다(추가한 곡의 그리드 초안과 같은 길).
    func outputBeats(_ flip: FlipEdit) -> (segments: [GridSegment], beats: [BeatGrid.Beat]) {
        let segments = flip.outputGrid(grid)
        return (segments, GridDraft(trackUUID: "flip", base: [], segments: segments).grid(duration: flip.duration).beats)
    }

    /// `length`초 루프(10.5초 = 1박에서 시작)를 8바퀴 돌고 이어서 14초까지 재생한 기록
    func loopRecording(length: Double) -> FlipRecording {
        var recording = FlipRecording()
        let end = 10.5 + length
        let turns = Array(repeating: span(10.5, end), count: 6)
        recording.record(PlayedRun(spans: [span(8, end)] + turns + [span(10.5, 14)], continuing: false))
        return recording
    }

    /// 모든 구간에 박이 하나 이상 남고, 박이 반 박보다 가깝게 붙거나 같은 번호가 이어지지 않는다.
    func expectReadableGrid(_ result: (segments: [GridSegment], beats: [BeatGrid.Beat]), _ comment: Comment) {
        for segment in result.segments {
            #expect(result.beats.contains { abs($0.time - segment.start) < 0.0015 }, "박이 없는 구간 \(segment.start)초: \(comment)")
        }
        for (a, b) in zip(result.beats, result.beats.dropFirst()) {
            #expect(b.time - a.time >= 0.25 - 0.0015, "박이 붙음 \(a.time)→\(b.time)초: \(comment)")
            #expect(b.time - a.time <= 0.75 + 0.0015, "박이 빠짐 \(a.time)→\(b.time)초: \(comment)")
            #expect(a.number != b.number, "같은 번호가 이어짐 \(a.time)→\(b.time)초(\(a.number)): \(comment)")
        }
    }

    @Test func 반_박_루프도_박이_사라지지_않는다() throws {
        // ½박(0.25초) 루프 8바퀴: 바퀴마다 새 구간을 열면 GridDraft가 구간마다 "다음 시작 − 반 박"에서 잘라 박이 0개였다.
        let flip = try FlipEdit(loopRecording(length: 0.25), sourceDuration: 60)
        let result = outputBeats(flip)
        // 루프가 나온 출력 10.5~12.25초(첫 바퀴는 첫 조각 안)에 박이 남는다
        #expect(result.beats.filter { $0.time >= 10.5 - 0.001 && $0.time < 12.25 }.count >= 3)
        expectReadableGrid(result, "½박 루프")
    }

    @Test func 한_박_루프는_박_번호를_이어_센다() throws {
        // 1박 루프 8바퀴: 바퀴마다 원곡 번호(1)로 새 구간을 열면 모든 박이 1이었다. 한 마디보다 짧은 조각은 번호를 이어 센다.
        let flip = try FlipEdit(loopRecording(length: 0.5), sourceDuration: 60)
        let result = outputBeats(flip)
        expectReadableGrid(result, "1박 루프")
        // 첫 바퀴는 첫 조각 안(출력 10.5초), 이어지는 여섯 바퀴는 출력 11~14초
        let loopBeats = result.beats.filter { $0.time >= 10.5 - 0.001 && $0.time < 14 - 0.001 }
        #expect(loopBeats.map(\.number) == [1, 2, 3, 4, 1, 2, 3])
        // 루프 뒤 곡이 이어지는 조각(한 마디 넘게 김)은 원곡 번호로: 마지막 바퀴의 출력 14초가 원곡 10.5초(1박)
        #expect(result.beats.first { abs($0.time - 14) < 0.001 }?.number == 1)
        // 박 간격은 끝까지 0.5초
        for (a, b) in zip(result.beats, result.beats.dropFirst()) { #expect(near(b.time - a.time, 0.5, 0.0015)) }
    }

    @Test func 박_줄을_벗어난_짧은_루프도_박이_남는다() throws {
        // 박 사이(10.6초)에서 시작한 0.2초 루프 8바퀴: 바퀴마다 박 줄이 어긋나도 박 없는 구간·붙은 박이 생기지 않는다.
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [span(8, 10.8)] + Array(repeating: span(10.6, 10.8), count: 6) + [span(10.6, 14)],
                                   continuing: false))
        let flip = try FlipEdit(recording, sourceDuration: 60)
        expectReadableGrid(outputBeats(flip), "박 사이 0.2초 루프")
    }
}
