import Foundation

/// 재생 중 핫큐를 누르면 현재 박을 계속 재생하다 다음 비트그리드 선에서 저장 큐로 넘어간다.
/// 작은 박 조각에서 먼저 넘어가거나 큐 앞부분을 생략하지 않는다.
public struct PlayQuantize: Sendable, Equatable {
    /// 이전 설정을 읽기 위한 호환 값. 재생 경계는 값과 관계없이 한 박이다.
    public static let choices: [Double] = [0.25, 0.5, 1]
    /// 이전 설정의 기본값(재생 경계 단위가 아님).
    public static let defaultBeats = 0.25

    public let grid: BeatGrid
    /// 이전 호출부·저장값과의 호환용이며 경계 계산에는 쓰지 않는다.
    public let beats: Double

    /// 그리드가 없거나 단위가 잘못되면 nil(퀀타이즈하지 않고 바로 넘어간다).
    public init?(grid: BeatGrid?, beats: Double) {
        guard let grid, !grid.beats.isEmpty, beats.isFinite, beats > 0 else { return nil }
        self.grid = grid
        self.beats = beats
    }

    /// 넘어가는 곡 위치(경계)와 착지 곡 위치(rekordbox 시간축)
    public struct Jump: Equatable, Sendable {
        public var at: Double
        public var to: Double

        public init(at: Double, to: Double) {
            self.at = at
            self.to = to
        }
    }

    /// `time` 이상인 첫 정수 박 경계. phase는 이전 호출부 호환용이며 항상 0이다.
    public func boundary(atOrAfter time: Double) -> (time: Double, phase: Double) {
        let coordinate = grid.beatCoordinate(at: time)
        // 경계 위(부동소수 오차 안)는 그 경계로 본다.
        let target = (coordinate - 1e-9).rounded(.up)
        return (grid.time(atBeatCoordinate: target), 0)
    }

    /// 저장 큐의 첫 샘플부터 재생한다. phase·loopEnd는 이전 호출부 호환용이다.
    public func landing(cue: Double, phase: Double, loopEnd: Double? = nil) -> Double {
        cue
    }

    /// `earliest`(예약할 수 있는 가장 이른 곡 위치) 뒤 첫 경계에서 `cue` 쪽으로 넘어가는 점프
    public func jump(earliest: Double, to cue: Double, loopEnd: Double? = nil) -> Jump {
        let boundary = boundary(atOrAfter: earliest)
        return Jump(at: boundary.time, to: landing(cue: cue, phase: boundary.phase, loopEnd: loopEnd))
    }
}
