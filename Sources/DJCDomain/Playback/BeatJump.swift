import Foundation

/// 박·마디 단위로 재생 위치를 옮긴다(←→·⇧←→, VoiceOver 조절).
///
/// 멈춰 있으면 박에 붙인다: 박 위(±5ms)면 그 박부터, 박 사이면 가는 쪽 가까운 박을 첫 박으로 센다(그 자리에 큐를 찍을 수 있게).
/// 재생 중이면(`keepsPhase`) 박 안의 위치를 지켜 정확히 n박만큼 옮긴다(CDJ 비트 점프처럼 박자가 끊기지 않게).
/// 그리드가 없으면 박당 0.5초(큐 밀기와 같다). 결과는 곡 안(0~`duration`)이다.
public enum BeatJump {
    public static let beatsPerBar = 4
    /// 이만큼 가까우면 박 위로 본다(다음 메모리 큐 세기와 같은 ±5ms)
    static let tolerance = 0.005

    public static func target(from time: Double, beats steps: Int, grid: BeatGrid?, duration: Double, keepsPhase: Bool) -> Double {
        guard steps != 0 else { return time }
        let result: Double
        if let beats = grid?.beats, !beats.isEmpty, let grid {
            result = keepsPhase ? grid.time(atBeatCoordinate: grid.beatCoordinate(at: time) + Double(steps))
                : snapped(from: time, steps: steps, grid: grid)
        } else {
            result = time + Double(steps) * 0.5
        }
        return min(max(result, 0), max(duration, 0))
    }

    private static func snapped(from time: Double, steps: Int, grid: BeatGrid) -> Double {
        let beats = grid.beats
        let after = grid.firstIndex(atOrAfter: time - tolerance)
        let onBeat = after < beats.count && abs(beats[after].time - time) <= tolerance
        // 박 사이면 가는 쪽 가까운 박이 1박째다.
        let index = onBeat || steps < 0 ? after + steps : after + steps - 1
        if index < 0 {
            // 첫 박을 넘으면 첫 박에서 멈추고, 이미 첫 박이거나 그 앞이면 곡 처음(인트로)으로
            return beats[0].time < time - tolerance ? beats[0].time : 0
        }
        if index >= beats.count {
            let last = beats[beats.count - 1].time
            return last > time + tolerance ? last : time
        }
        return beats[index].time
    }
}
