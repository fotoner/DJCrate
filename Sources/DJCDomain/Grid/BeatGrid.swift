import Foundation

/// rekordbox 분석 파일(ANLZ)에서 비트 그리드(PQTZ)를 읽는다. 읽기 전용.
///
/// 형식(빅엔디언, Deep Symmetry 문서 기준): 파일 헤더 `PMAI` 뒤에 태그가 이어지고,
/// 각 태그는 `fourcc, len_header(u32), len_tag(u32)`로 시작한다.
/// PQTZ 항목은 8바이트: 박 번호(u16, 1~4) · 템포(u16, BPM×100) · 시각(u32, ms).
public struct BeatGrid: Sendable, Hashable {
    public struct Beat: Sendable, Hashable {
        public var number: Int
        public var bpm: Double
        public var time: Double
        public var isDownbeat: Bool { number == 1 }

        public init(number: Int, bpm: Double, time: Double) {
            self.number = number
            self.bpm = bpm
            self.time = time
        }
    }

    public let beats: [Beat]
    /// 다운비트 시각(미리 계산). 마디 번호 계산에 쓴다.
    public let downbeats: [Double]

    public init(beats: [Beat]) {
        self.beats = beats
        downbeats = beats.filter(\.isDownbeat).map(\.time)
    }

    /// `time` 이상인 첫 박의 인덱스.
    public func firstIndex(atOrAfter time: Double) -> Int {
        var lo = 0, hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 가장 가까운 박.
    public func snap(_ time: Double) -> Double {
        guard !beats.isEmpty else { return time }
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { beats.indices.contains($0) }
        return candidates.map { beats[$0].time }.min { abs($0 - time) < abs($1 - time) } ?? time
    }

    /// 박 좌표: 박 번호를 소수(박 안의 비율 포함)로 본 위치(첫 박 = 0). 첫 박 앞·마지막 박 뒤는 그 박 길이로 늘려 센다.
    /// 비어 있으면 0.
    public func beatCoordinate(at time: Double) -> Double {
        guard !beats.isEmpty else { return 0 }
        if time < beats[0].time { return (time - beats[0].time) / beatLength(0) }
        let index = max(firstIndex(atOrAfter: time + 1e-12) - 1, 0)
        return Double(index) + (time - beats[index].time) / beatLength(index)
    }

    /// 박 좌표 → 곡 위치(`beatCoordinate`의 반대)
    public func time(atBeatCoordinate coordinate: Double) -> Double {
        guard !beats.isEmpty else { return 0 }
        if coordinate < 0 { return beats[0].time + coordinate * beatLength(0) }
        let index = min(Int(coordinate.rounded(.down)), beats.count - 1)
        return beats[index].time + (coordinate - Double(index)) * beatLength(index)
    }

    /// `index` 박에서 다음 박까지(마지막 박은 그 BPM으로)
    private func beatLength(_ index: Int) -> Double {
        index + 1 < beats.count ? beats[index + 1].time - beats[index].time : 60 / max(beats[index].bpm, 1)
    }

    /// 박 단위로 옮긴다(`steps`가 음수면 앞으로).
    public func nudge(_ time: Double, beats steps: Int) -> Double {
        guard let index = beats.firstIndex(where: { $0.time >= time - 0.001 }) else { return time }
        let target = min(max(index + steps, 0), beats.count - 1)
        return beats[target].time
    }

    /// 몇 번째 마디인지(1부터). 첫 다운비트 이전은 0.
    public func bar(at time: Double) -> Int {
        var lo = 0, hi = downbeats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if downbeats[mid] <= time + 0.001 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 변속 흐름: 정수로 반올림한 BPM이 8박 넘게 이어지는 구간만 센 BPM 순서(2 BPM 이내 차이는 합친다).
    /// 한 가지면 빈 배열(변속 없음).
    public var tempoChanges: [Double] {
        var runs: [(bpm: Double, count: Int)] = []
        for beat in beats {
            let bpm = beat.bpm.rounded()
            if let last = runs.last, last.bpm == bpm { runs[runs.count - 1].count += 1 } else { runs.append((bpm, 1)) }
        }
        // rekordbox 가변 그리드의 ±1~2 BPM 흔들림은 같은 템포로 본다.
        let kept = runs.filter { $0.count > 8 }
        var sequence: [Double] = []
        for run in kept {
            if let last = sequence.last, abs(last - run.bpm) <= 2 { continue }
            sequence.append(run.bpm)
        }
        return sequence.count > 1 ? sequence : []
    }

    /// 마디.박 위치. 덱 눈금(`BeatRulerLabel`)과 같이 rekordbox처럼 박은 1부터 센다(14.1 → 14.2 → 14.3 → 14.4 → 15.1).
    /// 첫 박 이전은 nil.
    public func position(at time: Double) -> (bar: Int, beat: Int)? {
        let index = firstIndex(atOrAfter: time + 0.001) - 1
        guard beats.indices.contains(index) else { return nil }
        return (bar(at: beats[index].time), max(beats[index].number, 1))
    }

    public func positionText(at time: Double) -> String? {
        position(at: time).map { "\($0.bar).\($0.beat)" }
    }
}
