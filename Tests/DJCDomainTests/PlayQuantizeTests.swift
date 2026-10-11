@testable import DJCDomain
import Testing

/// 재생 퀀타이즈: 기존 설정값과 관계없이 다음 큰 박선에서 저장 큐로 넘어간다.
@Suite("재생 퀀타이즈")
struct PlayQuantizeTests {
    /// 120 BPM(0.5초 간격), 0.5초에서 시작하는 100박(마지막 박 50초)
    let grid = BeatGrid(beats: (0..<100).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5) })

    func quantize(_ beats: Double, grid: BeatGrid? = nil) throws -> PlayQuantize {
        try #require(PlayQuantize(grid: grid ?? self.grid, beats: beats))
    }

    @Test func 이전_설정값과_기본값을_호환한다() {
        #expect(PlayQuantize.defaultBeats == 0.25)
        #expect(PlayQuantize.choices == [0.25, 0.5, 1])
    }

    @Test func 그리드가_없거나_단위가_잘못되면_퀀타이즈하지_않는다() {
        #expect(PlayQuantize(grid: nil, beats: 0.25) == nil)
        #expect(PlayQuantize(grid: BeatGrid(beats: []), beats: 0.25) == nil)
        #expect(PlayQuantize(grid: grid, beats: 0) == nil)
        #expect(PlayQuantize(grid: grid, beats: .nan) == nil)
    }

    @Test func 이전_단위값과_관계없이_다음_큰_박이_경계다() throws {
        // 1.1초 = 1.2박째(박 0 = 0.5초)
        let quarter = try quantize(0.25).boundary(atOrAfter: 1.1)
        #expect(abs(quarter.time - 1.5) < 1e-9)
        #expect(quarter.phase == 0)
        let half = try quantize(0.5).boundary(atOrAfter: 1.1)
        #expect(abs(half.time - 1.5) < 1e-9)
        #expect(half.phase == 0)
        let beat = try quantize(1).boundary(atOrAfter: 1.1)
        #expect(abs(beat.time - 1.5) < 1e-9)
        #expect(beat.phase == 0)
    }

    @Test func 경계_위에서는_그_경계다() throws {
        let q = try quantize(0.25)
        #expect(abs(q.boundary(atOrAfter: 1.125).time - 1.5) < 1e-9)
        #expect(abs(q.boundary(atOrAfter: 1.5).time - 1.5) < 1e-9)
        #expect(q.boundary(atOrAfter: 1.5).phase == 0)
    }

    @Test func 박_끝_바로_앞이면_다음_박이_경계다() throws {
        let b = try quantize(0.25).boundary(atOrAfter: 1.49)
        #expect(abs(b.time - 1.5) < 1e-9)
        #expect(b.phase == 0)
    }

    @Test func 첫_박_앞과_마지막_박_뒤는_그_박_길이로_늘려_센다() throws {
        let q = try quantize(0.25)
        // 0.2초 = -0.6박 → 다음 정수 박은 0.5초
        let before = q.boundary(atOrAfter: 0.2)
        #expect(abs(before.time - 0.5) < 1e-9)
        #expect(before.phase == 0)
        // 50.3초 = 마지막 박(50초) + 0.6박 → 50.5초
        let after = q.boundary(atOrAfter: 50.3)
        #expect(abs(after.time - 50.5) < 1e-9)
        #expect(after.phase == 0)
    }

    @Test func 변속_그리드는_다음_실제_박선을_쓴다() throws {
        // 0~2초 1초 간격(60BPM), 그 뒤 0.5초 간격(120BPM)
        let times = [0.0, 1, 2, 2.5, 3, 3.5]
        let variable = BeatGrid(beats: times.enumerated().map { BeatGrid.Beat(number: $0.offset % 4 + 1, bpm: $0.element < 2 ? 60 : 120, time: $0.element) })
        let q = try quantize(0.25, grid: variable)
        #expect(abs(q.boundary(atOrAfter: 1.1).time - 2) < 1e-9)
        #expect(abs(q.boundary(atOrAfter: 2.1).time - 2.5) < 1e-9)
    }

    @Test func 다음_큰_박에서_저장큐_첫_샘플로_간다() throws {
        // 1.1초에 눌러도 현재 박을 계속 재생한 뒤 1.5초에서 10초 큐로 간다
        let jump = try quantize(0.25).jump(earliest: 1.1, to: 10)
        #expect(abs(jump.at - 1.5) < 1e-9)
        #expect(abs(jump.to - 10) < 1e-9)
    }

    @Test func 한_박_단위면_다음_박에서_정확히_큐로() throws {
        let jump = try quantize(1).jump(earliest: 1.1, to: 10)
        #expect(abs(jump.at - 1.5) < 1e-9)
        #expect(jump.to == 10)
    }

    @Test func 박에서_벗어난_큐는_그_어긋남을_그대로_둔다() throws {
        // 저장 큐가 박선에서 벗어나도 큐 앞부분을 생략하지 않는다
        let jump = try quantize(0.25).jump(earliest: 1.1, to: 10.1)
        #expect(abs(jump.to - 10.1) < 1e-9)
    }

    @Test func 루프_길이와_관계없이_저장큐로_내린다() throws {
        let q = try quantize(0.5)
        #expect(q.jump(earliest: 1.1, to: 10, loopEnd: 10.2).to == 10)
        #expect(abs(q.jump(earliest: 1.1, to: 10, loopEnd: 12).to - 10) < 1e-9)
    }
}

/// 재생 퀀타이즈 점프를 재생 노드에 예약하는 계획. 48kHz(1박 = 24000프레임, 기존 ¼ 설정도 한 박 경계), 120BPM 그리드.
/// 나중에 예약한 interrupts 버퍼가 그 시각에 앞서 예약한 미래 버퍼(루프 몸통 포함)를 모두 지운다(2026-09-27 오프라인 렌더 실험).
@Suite("재생 퀀타이즈 점프 계획")
struct JumpPlannerTests {
    let sr: Int64 = 48_000
    let grid = BeatGrid(beats: (0..<100).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5) })
    /// 곡 1초(프레임 48000)에서 재생 시작
    var straight: PlaybackSchedule {
        PlaybackSchedule(sampleRate: 48_000, timelineOffset: 0, startLinear: 1, pieces: [PlaybackPiece(node: 0, frame: sr, loop: nil)])
    }
    let songFrames: Int64 = 48_000 * 60

    func quantize(_ beats: Double) throws -> PlayQuantize { try #require(PlayQuantize(grid: grid, beats: beats)) }

    @Test func 빠른_곡도_렌더_여유_밖의_다음_큰_박에_예약한다() throws {
        let fastGrid = BeatGrid(beats: (0..<100).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 180, time: Double($0) / 3) })
        let q = try #require(PlayQuantize(grid: fastGrid, beats: 0.25))
        let flow = PlaybackSchedule(sampleRate: 48_000, timelineOffset: 0, startLinear: 0,
                                    pieces: [.init(node: 0, frame: 0, loop: nil)])
        // 180 BPM의 한 박 = 16000프레임. 렌더 여유를 지키며 큰 박까지 기다린다.
        let lead = JumpPlanner.renderLeadFrames(bufferFrames: 512, outputSampleRate: 48_000, sampleRate: 48_000, rate: 1)
        let plan = try #require(JumpPlanner.plan(schedule: flow, ahead: 1000 + lead, quantize: q, cue: 10, loop: nil, frameCount: songFrames))
        #expect(plan.buffers.first?.at == 16000)
    }

    @Test func 렌더_여유는_출력과_곡의_샘플레이트_및_재생속도를_따른다() {
        #expect(JumpPlanner.renderLeadFrames(bufferFrames: 512, outputSampleRate: 48_000, sampleRate: 44_100, rate: 2) == 1882)
    }

    @Test func 흐름_중에는_다음_경계_샘플에서_큐_쪽으로_넘어간다() throws {
        // 노드 4800 = 곡 1.1초 → 1.5초(노드 24000)에 10초(프레임 480000)로
        let plan = try #require(JumpPlanner.plan(schedule: straight, ahead: 4_800, quantize: quantize(0.25), cue: 10, loop: nil, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 480_000, to: nil, at: 24_000, interrupts: true, loops: false)])
        #expect(plan.pieces == [PlaybackPiece(node: 0, frame: sr, loop: nil), PlaybackPiece(node: 24_000, frame: 480_000, loop: nil)])
        #expect(abs(plan.jump.at - 1.5) < 1e-9)
        #expect(abs(plan.jump.to - 10) < 1e-9)
    }

    @Test func 인코더_지연만큼_곡_위치가_밀린_곡도_같은_경계에서() throws {
        // rekordbox 시간축 = 음원 + 0.024초. 노드 0 = 프레임 48000 = 곡 1.024초
        let shifted = PlaybackSchedule(sampleRate: 48_000, timelineOffset: 0.024, startLinear: 1.024, pieces: [PlaybackPiece(node: 0, frame: sr, loop: nil)])
        let plan = try #require(JumpPlanner.plan(schedule: shifted, ahead: 100, quantize: quantize(1), cue: 10, loop: nil, frameCount: songFrames))
        // 다음 박 1.5초 = 프레임 (1.5 − 0.024) × 48000 = 70848 → 노드 22848, 착지 10초 = 프레임 478848
        #expect(plan.buffers == [.init(from: 478_848, to: nil, at: 22_848, interrupts: true, loops: false)])
    }

    @Test func 이전_분수단위의_루프핫큐도_저장큐에서_되풀이한다() throws {
        let plan = try #require(JumpPlanner.plan(schedule: straight, ahead: 4_800, quantize: quantize(0.25), cue: 10, loop: 10...12, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 480_000, to: 576_000, at: 24_000, interrupts: true, loops: true)])
        #expect(plan.pieces.last == PlaybackPiece(node: 24_000, frame: 480_000, loop: 96_000))
    }

    @Test func 루프_시작에_내리면_바로_되풀이_버퍼_하나() throws {
        let plan = try #require(JumpPlanner.plan(schedule: straight, ahead: 4_800, quantize: quantize(1), cue: 10, loop: 10...12, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 480_000, to: 576_000, at: 24_000, interrupts: true, loops: true)])
        #expect(plan.pieces.last == PlaybackPiece(node: 24_000, frame: 480_000, loop: 96_000))
    }

    @Test func 되풀이_중이면_이번_바퀴_안의_다음_경계에서_끊고_넘어간다() throws {
        // 2~3초 루프(48000프레임)가 노드 48000부터 도는 중, 셋째 바퀴 0.3초째(곡 2.3초)
        var looping = straight
        looping.pieces.append(PlaybackPiece(node: sr, frame: 2 * sr, loop: sr))
        let ahead = sr + 2 * sr + 14_400
        let plan = try #require(JumpPlanner.plan(schedule: looping, ahead: ahead, quantize: quantize(0.25), cue: 20, loop: nil, frameCount: songFrames))
        // 2.3초 → 다음 큰 박 2.5초(노드 +24000)에서 저장큐 20초로
        #expect(plan.buffers == [.init(from: 960_000, to: nil, at: sr + 2 * sr + 24_000, interrupts: true, loops: false)])
        #expect(plan.pieces.count == 3)
    }

    @Test func 이번_바퀴에_경계가_없으면_다음_바퀴에서_찾는다() throws {
        // 2.0~2.1초 루프(한 박보다 짧다), 첫 바퀴 0.05초째 → 다음 바퀴 시작(2.0초 = 박 위)에서
        var looping = straight
        looping.pieces.append(PlaybackPiece(node: sr, frame: 2 * sr, loop: 4_800))
        let plan = try #require(JumpPlanner.plan(schedule: looping, ahead: sr + 2_400, quantize: quantize(0.25), cue: 20, loop: nil, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 960_000, to: nil, at: sr + 4_800, interrupts: true, loops: false)])
    }

    @Test func 박_경계가_없는_루프면_바퀴가_끝날_때_큐로() throws {
        // 2.01~2.1초 루프: 안에 큰 박선이 없다 → 바퀴 끝에서 큐 그대로
        var looping = straight
        looping.pieces.append(PlaybackPiece(node: sr, frame: 96_480, loop: 4_320))
        let plan = try #require(JumpPlanner.plan(schedule: looping, ahead: sr + 100, quantize: quantize(0.25), cue: 20, loop: nil, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 960_000, to: nil, at: sr + 4_320, interrupts: true, loops: false)])
    }

    @Test func 아직_넘어가지_않은_점프가_있으면_새_점프가_그_자리를_대신한다() throws {
        // 노드 24000의 점프 전 다른 핫큐를 누르면 같은 큰 박 경계에서 새 큐로
        var pending = straight
        pending.pieces.append(PlaybackPiece(node: 24_000, frame: 480_000, loop: nil))
        let plan = try #require(JumpPlanner.plan(schedule: pending, ahead: 5_000, quantize: quantize(0.25), cue: 30, loop: nil, frameCount: songFrames))
        #expect(plan.buffers == [.init(from: 1_440_000, to: nil, at: 24_000, interrupts: true, loops: false)])
        #expect(plan.pieces == [PlaybackPiece(node: 0, frame: sr, loop: nil), PlaybackPiece(node: 24_000, frame: 1_440_000, loop: nil)])
    }

    @Test func 곡_끝_직전의_유효한_큐도_앞부분을_생략하지_않는다() throws {
        #expect(try JumpPlanner.plan(schedule: straight, ahead: 4_800, quantize: quantize(0.25), cue: 59.99, loop: nil, frameCount: songFrames)?.buffers.first?.from == 2_879_520)
    }

    @Test func 경계가_곡_끝_뒤면_계획하지_않는다() throws {
        var near = straight
        near.pieces = [PlaybackPiece(node: 0, frame: songFrames - 100, loop: nil)]
        #expect(try JumpPlanner.plan(schedule: near, ahead: 0, quantize: quantize(1), cue: 10, loop: nil, frameCount: songFrames) == nil)
    }

    @Test func 조각이_없으면_계획하지_않는다() throws {
        var empty = straight
        empty.pieces = []
        #expect(try JumpPlanner.plan(schedule: empty, ahead: 0, quantize: quantize(1), cue: 10, loop: nil, frameCount: songFrames) == nil)
    }

    // MARK: #107 큰 박선(QuantizeBoundaryRegressionTests를 합침)

    /// 렌더 여유 안의 경계는 소급 예약하지 않고 다음 큰 박으로 미룬다. 기대는 제품의 boundary 계산 없이 그리드 선과 저장 큐로 정한다.
    @Test(arguments: [120.0, 180.0])
    func 경계_전후와_렌더_여유를_구분한다(bpm: Double) throws {
        let rate = 48_000.0
        let beatFrames = Int64(rate * 60 / bpm)
        let grid = BeatGrid(beats: (0..<100).map {
            .init(number: $0 % 4 + 1, bpm: bpm, time: Double($0) * 60 / bpm)
        })
        let q = try #require(PlayQuantize(grid: grid, beats: 0.25))
        let flow = PlaybackSchedule(sampleRate: rate, timelineOffset: 0, startLinear: 0,
                                    pieces: [.init(node: 0, frame: 0, loop: nil)])
        for (ahead, expected) in [(beatFrames - 48, beatFrames), (beatFrames, beatFrames),
                                  (beatFrames + 48, 2 * beatFrames), (beatFrames - 48 + 1024, 2 * beatFrames)] {
            let plan = try #require(JumpPlanner.plan(schedule: flow, ahead: ahead, quantize: q,
                                                     cue: 10.1, loop: nil, frameCount: 2_880_000))
            #expect(plan.buffers.first?.at == expected)
            #expect(plan.buffers.first?.from == 484_800)
            #expect(plan.buffers[0].at >= ahead, "이미 렌더한 경계를 소급 예약하지 않는다")
        }
    }

    @Test func 변속과_인코더_지연에서도_큰_박선과_저장큐를_쓴다() throws {
        let grid = BeatGrid(beats: [0.0, 1, 2, 2.5, 3].enumerated().map {
            .init(number: $0.offset % 4 + 1, bpm: $0.element < 2 ? 60 : 120, time: $0.element)
        })
        let q = try #require(PlayQuantize(grid: grid, beats: 0.25))
        #expect(q.jump(earliest: 1.1, to: 2.1) == .init(at: 2, to: 2.1))
        #expect(q.jump(earliest: 2.1, to: 1.1) == .init(at: 2.5, to: 1.1))
        let flow = PlaybackSchedule(sampleRate: 48_000, timelineOffset: 0.024, startLinear: 1.024,
                                    pieces: [.init(node: 0, frame: 48_000, loop: nil)])
        let plan = try #require(JumpPlanner.plan(schedule: flow, ahead: 4_000, quantize: q,
                                                 cue: 2.1, loop: nil, frameCount: 480_000))
        #expect(plan.buffers.first?.at == 46_848)
        #expect(plan.buffers.first?.from == 99_648)
    }

    /// 곡 샘플레이트와 재생 속도가 렌더 여유와 예약 샘플을 함께 바꾼다(느린·빠른 쪽 하나씩).
    @Test(arguments: zip([44_100.0, 48_000.0], [2.0, 0.5]))
    func 샘플레이트와_재생속도를_바꿔도_큰_박의_샘플에_예약한다(sampleRate: Double, rate: Double) throws {
        let grid = BeatGrid(beats: (0..<100).map {
            .init(number: $0 % 4 + 1, bpm: 120, time: Double($0) * 0.5)
        })
        let q = try #require(PlayQuantize(grid: grid, beats: 0.25))
        let flow = PlaybackSchedule(sampleRate: sampleRate, timelineOffset: 0.024, startLinear: 1.024,
                                    pieces: [.init(node: 0, frame: Int64(sampleRate), loop: nil)])
        let lead = JumpPlanner.renderLeadFrames(bufferFrames: 512, outputSampleRate: 48_000, sampleRate: sampleRate, rate: rate)
        let rendered = Int64((0.076 * sampleRate).rounded()) // 곡 위치 1.100초
        let plan = try #require(JumpPlanner.plan(schedule: flow, ahead: rendered + lead, quantize: q,
                                                 cue: 10, loop: nil, frameCount: Int64(sampleRate * 60)))
        #expect(plan.buffers.first?.at == Int64((0.476 * sampleRate).rounded()))
        #expect(plan.buffers.first?.from == Int64((9.976 * sampleRate).rounded()))
    }
}
