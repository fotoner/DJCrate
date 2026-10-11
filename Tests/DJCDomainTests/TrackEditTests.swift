@testable import DJCDomain
import Foundation
import Testing

@Suite("곡 편집: 마디 구간 → 출력 시간표")
struct TrackEditTests {
    /// 120 BPM(1박 0.5초, 1마디 2초), 첫 다운비트 0.5초 → 0마디(곡 머리) 0.5초, 1마디 = 0.5~2.5초.
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) < tolerance }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let DJCError.editRefused(reason) { return reason } catch { return "다른 오류: \(error)" }
    }

    // MARK: - 마디 구간 글

    @Test func 마디_구간_글을_읽는다() throws {
        #expect(try BarRange.list("1-16, 1-16,17-64") == [BarRange(1, 16), BarRange(1, 16), BarRange(17, 64)])
        #expect(try BarRange.list("5") == [BarRange(5, 5)])
        #expect(try BarRange.list("0-8") == [BarRange(0, 8)])
        #expect(BarRange(1, 16).description == "1-16" && BarRange(5, 5).description == "5")
        for bad in ["", "1-", "a-b", "1-2-3", "-3", "1,,2"] {
            #expect(refusal { _ = try BarRange.list(bad) } != nil, "\(bad)")
        }
        #expect(refusal { _ = try BarRange.list("16-1") }?.contains("거꾸로") == true)
    }

    // MARK: - 원본 마디

    @Test func 원본_마디_배치() throws {
        let bars = try BarLayout(grid: grid, duration: 100.5)
        #expect(near(bars.firstDownbeat, 0.5) && near(bars.barLength, 2))
        #expect(bars.count == 50 && !bars.lastBarIsPartial && bars.hasLeadIn)
        #expect(near(bars.start(ofBar: 1), 0.5) && near(bars.start(ofBar: 0), 0) && near(bars.end(ofBar: 50), 100.5))
        #expect(bars.bar(at: 0.2) == 0 && bars.bar(at: 0.5) == 1 && bars.bar(at: 2.49) == 1 && bars.bar(at: 2.5) == 2)

        // 끝에서 잘린 마디: 101.5초면 51마디는 1초뿐
        let cut = try BarLayout(grid: grid, duration: 101.5)
        #expect(cut.count == 51 && cut.lastBarIsPartial && near(cut.end(ofBar: 51), 101.5))
    }

    @Test func 그리드_시작이_곡_중간이어도_곡_머리_쪽으로_센다() throws {
        // 3박에서 시작한 구간(10.0초 = 3박) → 다운비트 11.0초, 거기서 마디 단위로 곡 머리 쪽 첫 다운비트 1.0초
        let bars = try BarLayout(grid: [GridSegment(start: 10.0, bpm: 120, firstBeatNumber: 3)], duration: 60)
        #expect(near(bars.firstDownbeat, 1.0))
        // 첫 다운비트가 곡 시작이면 0마디가 없다
        let flush = try BarLayout(grid: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)], duration: 60)
        #expect(!flush.hasLeadIn && near(flush.firstDownbeat, 0))
    }

    @Test func 변속곡과_그리드_없는_곡은_막는다() {
        let two = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1), GridSegment(start: 60.5, bpm: 125, firstBeatNumber: 1)]
        #expect(refusal { _ = try BarLayout(grid: two, duration: 120) }?.contains("템포") == true)
        #expect(refusal { _ = try BarLayout(grid: [], duration: 120) }?.contains("분석") == true)
        #expect(refusal { _ = try BarLayout(grid: [GridSegment(start: 0, bpm: 0, firstBeatNumber: 1)], duration: 120) } != nil)
    }

    // MARK: - 시간표

    @Test func 인트로_연장_시간표() throws {
        // 1-16을 두 번, 이어서 17-50. 이어지는 구간(두 번째 1-16과 17-50)은 한 조각으로 합친다(이음새 없음).
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-16,1-16,17-50"))
        #expect(edit.pieces.map(\.bars) == [BarRange(1, 16), BarRange(1, 50)])
        #expect(near(edit.pieces[0].sourceStart, 0.5) && near(edit.pieces[0].sourceEnd, 32.5) && near(edit.pieces[0].outputStart, 0))
        #expect(near(edit.pieces[1].sourceStart, 0.5) && near(edit.pieces[1].sourceEnd, 100.5) && near(edit.pieces[1].outputStart, 32))
        #expect(near(edit.duration, 132))
        // 출력은 다운비트로 시작: 그리드 0초 1박, BPM 그대로
        #expect(edit.outputGrid == GridSegment(start: 0, bpm: 120, firstBeatNumber: 1))
    }

    @Test func 곡_머리를_살리면_그리드_위상도_그대로() throws {
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("0-16,1-50"))
        #expect(edit.pieces.map(\.bars) == [BarRange(0, 16), BarRange(1, 50)])
        #expect(near(edit.pieces[0].sourceStart, 0) && near(edit.pieces[0].sourceEnd, 32.5))
        #expect(near(edit.pieces[1].outputStart, 32.5) && near(edit.duration, 132.5))
        // 첫 다운비트 0.5초 → 곡 머리 쪽으로 0.0초 4박(원본과 같은 위상)
        #expect(near(edit.outputGrid.start, 0) && edit.outputGrid.bpm == 120 && edit.outputGrid.firstBeatNumber == 4)
    }

    @Test func 짧은_버전과_잘린_마지막_마디() throws {
        // 101.5초 → 51마디는 끝에서 잘린 1초. 맨 뒤에만 둘 수 있다.
        let edit = try TrackEdit(grid: grid, sourceDuration: 101.5, bars: BarRange.list("1-16,49-51"))
        #expect(edit.pieces.count == 2)
        #expect(near(edit.pieces[1].sourceStart, 96.5) && near(edit.pieces[1].sourceEnd, 101.5))
        #expect(near(edit.pieces[1].outputStart, 32) && near(edit.duration, 37))
        #expect(refusal { _ = try TrackEdit(grid: grid, sourceDuration: 101.5, bars: BarRange.list("51,1-16")) }?.contains("맨 뒤") == true)
        #expect(refusal { _ = try TrackEdit(grid: grid, sourceDuration: 101.5, bars: BarRange.list("49-51,1-4")) }?.contains("맨 뒤") == true)
    }

    @Test func 막는_구간() throws {
        func refused(_ text: String, duration: Double = 100.5, grid: [GridSegment]? = nil) -> String? {
            refusal { _ = try TrackEdit(grid: grid ?? self.grid, sourceDuration: duration, bars: BarRange.list(text)) }
        }
        #expect(refused("1-51")?.contains("50") == true)
        #expect(refused("1-16,0-4")?.contains("맨 앞") == true)
        #expect(refused("0-4", grid: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)])?.contains("0마디") == true)
        #expect(refusal { _ = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: []) } != nil)
    }

    @Test func 출력_시각과_원본_시각() throws {
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-16,1-16,17-50"))
        // 원본 10.5초(6마디)는 두 번 나온다
        let times = edit.outputTimes(of: 10.5)
        #expect(times.count == 2 && near(times[0], 10) && near(times[1], 42))
        #expect(edit.outputTimes(of: 0.2).isEmpty)  // 0마디는 빠졌다
        #expect(near(edit.sourceTime(atOutput: 40) ?? -1, 8.5))
        #expect(edit.sourceTime(atOutput: 132.5) == nil)
    }

    // MARK: - 큐 옮기기

    @Test func 큐는_처음_나오는_자리로_옮긴다() throws {
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-16,1-16,17-50"))
        let memory = EditableCue(kind: .memory, time: 0.5, name: "인")
        let drop = EditableCue(kind: .hot(0), time: 32.5, name: "드롭")
        let loop = EditableCue(kind: .hot(1), time: 16.5, loop: .init(end: 32.5, active: true, beats: 32))
        let carried = edit.carry([memory, drop, loop])
        #expect(carried.dropped.isEmpty)
        let byName = Dictionary(uniqueKeysWithValues: carried.placed.map { ($0.name, $0) })
        #expect(near(byName["인"]!.time, 0) && byName["인"]!.kind == .memory)
        // 드롭(17마디)은 두 번째 조각에서 나온다: 32 + (32.5 − 0.5)
        #expect(near(byName["드롭"]!.time, 64) && byName["드롭"]!.kind == .hot(0))
        // 루프는 끝(17마디 다운비트 = 첫 조각 끝)까지 첫 조각 안에 있다
        let movedLoop = try #require(carried.placed.first { $0.kind == .hot(1) })
        #expect(near(movedLoop.time, 16) && near(movedLoop.loop!.end, 32) && movedLoop.loop!.active && movedLoop.loop!.beats == 32)
        // 새 곡의 큐라 rekordbox ID도 원본 id도 물려받지 않는다
        #expect(carried.placed.allSatisfy { $0.sourceID == nil } && !carried.placed.contains { $0.id == drop.id })
    }

    @Test func 빠진_구간과_이음새에_걸친_루프는_버린다() throws {
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-16,33-50"))
        let cut = EditableCue(kind: .hot(2), time: 40.5)
        let across = EditableCue(kind: .memory, time: 30.5, loop: .init(end: 34.5))
        let kept = EditableCue(kind: .memory, time: 70.5)
        let carried = edit.carry([cut, across, kept])
        #expect(carried.placed.count == 1 && near(carried.placed[0].time, 32 + (70.5 - 64.5)))
        #expect(carried.dropped.map(\.reason) == [.cut, .loopAcrossSeam])
        #expect(carried.dropped.map(\.cue.id) == [cut.id, across.id])
    }

    @Test func ms로_잘린_다운비트_큐도_그_조각에_든다() throws {
        // rekordbox 큐는 ms 정수: 17마디 다운비트 32.5초가 32.4997초로 적혀 있어도 17마디 조각의 시작이다.
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("17-50"))
        let carried = edit.carry([EditableCue(kind: .hot(0), time: 32.4997)])
        #expect(carried.placed.count == 1 && near(carried.placed[0].time, 0))
    }

    // MARK: - 프레임 계획

    @Test func 프레임_계획은_이음새마다_섞고_어긋남이_쌓이지_않는다() throws {
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-16,1-16,17-50"))
        let spans = edit.frames(sampleRate: 44_100, sourceOffset: 0)
        #expect(spans.count == 2)
        #expect(spans[0] == EditFrameSpan(sourceFrame: 22_050, frameCount: 32 * 44_100, outputFrame: 0, crossfadeFrames: 0))
        #expect(spans[1] == EditFrameSpan(sourceFrame: 22_050, frameCount: 100 * 44_100, outputFrame: 32 * 44_100, crossfadeFrames: 176))

        // 127.3 BPM 1마디를 200번 이어도 k번째 조각 출력 위치는 k × 마디 길이를 반올림한 자리(누적 오차 없음)
        let odd = [GridSegment(start: 0, bpm: 127.3, firstBeatNumber: 1)]
        let many = try TrackEdit(grid: odd, sourceDuration: 300, bars: Array(repeating: BarRange(3, 3), count: 200))
        let rate = 44_100.0, bar = 4 * 60 / 127.3
        let frames = many.frames(sampleRate: rate, sourceOffset: 0)
        for (k, span) in frames.enumerated() {
            #expect(span.outputFrame == Int64((Double(k) * bar * rate).rounded()))
        }
        #expect(frames.last.map { $0.outputFrame + $0.frameCount } == Int64((200 * bar * rate).rounded()))
    }

    @Test func MP3_원본은_인코더_지연만큼_앞에서_읽는다() throws {
        // rekordbox 시각 = 음원 시각 + 0.05초. 곡 머리(0초)는 음원 −0.05초라 음수 프레임(무음)부터 읽는다.
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("0-16,1-50"))
        let spans = edit.frames(sampleRate: 44_100, sourceOffset: 0.05)
        #expect(spans[0].sourceFrame == -2_205 && spans[0].outputFrame == 0)
        #expect(spans[1].sourceFrame == 22_050 - 2_205)
        // 이음새 앞 조각이 섞을 길이보다 짧으면 그 길이까지만 섞는다
        let tiny = try TrackEdit(grid: [GridSegment(start: 0.002, bpm: 120, firstBeatNumber: 1)], sourceDuration: 60, bars: BarRange.list("0,5-8"))
        #expect(tiny.frames(sampleRate: 44_100, sourceOffset: 0)[1].crossfadeFrames == 88)
    }
}

@Suite("곡 편집: 구간 후보")
struct EditCandidateTests {
    @Test func 값이_낮은_마디가_이어지는_구간() {
        let vocal = [0.1, 0.1, 0.1, 0.1, 0.5, 0.1, 0.1, 0.3, 0.0]
        #expect(BarLayout.runs(vocal, below: 0.25, minimum: 4) == [BarRange(1, 4)])
        #expect(BarLayout.runs(vocal, below: 0.25, minimum: 1) == [BarRange(1, 4), BarRange(6, 7), BarRange(9, 9)])
        #expect(BarLayout.runs([], below: 0.25, minimum: 1).isEmpty)
    }
}
