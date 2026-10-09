import Foundation

/// 원본 마디 구간(양 끝 포함). 마디는 첫 다운비트부터 1이고, 0마디는 첫 다운비트 앞(곡 머리)이다.
public struct BarRange: Codable, Hashable, Sendable, CustomStringConvertible {
    public var first: Int
    public var last: Int

    public init(_ first: Int, _ last: Int) {
        self.first = first
        self.last = last
    }

    public var count: Int { last - first + 1 }
    public var description: String { first == last ? "\(first)" : "\(first)-\(last)" }

    /// "1-16,1-16,17-64" → 구간 목록. 빈칸은 무시하고, "5"는 5마디 하나다.
    public static func list(_ text: String) throws -> [BarRange] {
        let parts = text.replacingOccurrences(of: " ", with: "").split(separator: ",", omittingEmptySubsequences: false)
        guard !(parts.count == 1 && parts[0].isEmpty) else {
            throw DJCError.editRefused(String(ui: "편집할 마디 구간이 없습니다. 1-16,1-16,17-64처럼 쓰세요"))
        }
        return try parts.map { part in
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...2).contains(ends.count), let first = ends.first ?? nil, let last = ends.last ?? nil, first >= 0 else {
                throw DJCError.editRefused(String(ui: "마디 구간 '\(part)'를 읽지 못했습니다. 1-16처럼 첫 마디-끝 마디로 쓰세요"))
            }
            let range = BarRange(first, last)
            try range.checkOrder()
            return range
        }
    }

    func checkOrder() throws {
        guard first >= 0 else { throw DJCError.editRefused(String(ui: "마디 \(first)는 없습니다. 0마디(곡 머리)나 1마디부터 고르세요")) }
        guard first <= last else { throw DJCError.editRefused(String(ui: "마디 구간 \(first)-\(last)이 거꾸로입니다. 앞 마디를 먼저 쓰세요")) }
    }
}

/// 템포 구간이 하나인 곡의 마디 배치(rekordbox 시간축, 초).
///
/// 1마디 = 0초 이상인 첫 다운비트부터(덱의 마디 번호 `BeatGrid.bar(at:)`와 같다). 0마디 = 곡 시작~첫 다운비트.
/// 마지막 마디는 곡 끝에서 잘릴 수 있다.
public struct BarLayout: Sendable, Equatable {
    public let segment: GridSegment
    public let duration: Double
    public let firstDownbeat: Double
    public let barLength: Double
    /// 마디 수(끝에서 잘린 마지막 마디 포함)
    public let count: Int

    /// 1ms 안쪽 차이는 같은 자리로 본다(rekordbox 큐·그리드는 ms 정수).
    static let tolerance = 0.001

    public init(grid: [GridSegment], duration: Double) throws {
        let segments = grid.filter { $0.bpm > 0 }
        guard let segment = segments.first else {
            throw DJCError.editRefused(String(ui: "그리드가 없습니다. rekordbox에서 트랙 분석을 먼저 한 뒤 편집하세요"))
        }
        guard segments.count == 1 else {
            throw DJCError.editRefused(String(ui: "템포가 바뀌는 곡(템포 구간 \(segments.count)개)은 아직 편집하지 않습니다. 템포 구간이 하나인 곡을 고르세요"))
        }
        let beat = 60 / segment.bpm
        barLength = 240 / segment.bpm
        // 구간 첫 박에서 다음 1박으로 간 뒤 곡 머리 쪽으로 마디 단위로 되돌린다(0초 이상인 첫 다운비트).
        let downbeat = segment.start + Double((5 - segment.firstBeatNumber % 4) % 4) * beat
        let back = ((downbeat + 1e-6) / barLength).rounded(.down)
        firstDownbeat = max(0, downbeat - back * barLength)
        self.segment = segment
        self.duration = duration
        count = max(0, Int(((duration - firstDownbeat - Self.tolerance) / barLength).rounded(.up)))
    }

    /// 첫 다운비트 앞에 소리가 있다(0마디).
    public var hasLeadIn: Bool { firstDownbeat > Self.tolerance }

    /// 마지막 마디가 곡 끝에서 잘렸다.
    public var lastBarIsPartial: Bool { count > 0 && start(ofBar: count + 1) > duration + Self.tolerance }

    /// 마디 시작 시각. 0마디는 곡 시작.
    public func start(ofBar bar: Int) -> Double {
        bar <= 0 ? 0 : firstDownbeat + Double(bar - 1) * barLength
    }

    /// 마디 끝 시각. 온전한 마디는 곡 끝을 1ms 안쪽으로 넘어도 다음 마디 시작이다(뒤 조각의 박이 밀리지 않게).
    public func end(ofBar bar: Int) -> Double {
        bar == count && lastBarIsPartial ? duration : start(ofBar: bar + 1)
    }

    /// 몇 번째 마디인지. 첫 다운비트 앞은 0.
    public func bar(at time: Double) -> Int {
        time + Self.tolerance < firstDownbeat ? 0 : Int(((time - firstDownbeat + Self.tolerance) / barLength).rounded(.down)) + 1
    }
}

/// 마디 단위 곡 편집: 원본 마디 구간을 차례로 이어 붙인 출력 시간표와, 그리드·큐를 출력 위치로 옮기는 규칙.
///
/// 원본 시각은 rekordbox 시간축이다. 출력은 PCM(WAV·AIFF)이라 인코더 지연이 없어 출력 시간축 = 음원 시간축이다.
/// 조각은 모두 온전한 마디라 출력 그리드는 원본 BPM의 한 구간으로 이어진다.
/// 곡 머리(0마디)는 맨 앞에만, 끝에서 잘린 마지막 마디는 맨 뒤에만 둘 수 있다(가운데 두면 박이 어긋난다).
public struct TrackEdit: Sendable, Equatable {
    public struct Piece: Sendable, Hashable, EditPieceTiming {
        /// 원본 마디(이어지는 구간은 하나로 합쳤다)
        public var bars: BarRange
        public var sourceStart: Double
        public var sourceEnd: Double
        public var outputStart: Double
        public var outputEnd: Double
    }

    public let layout: BarLayout
    public let pieces: [Piece]
    /// 목록 구간마다 하나(원본에서 이어져도 합치지 않는다). 편집 화면의 클립이다.
    public let clips: [Piece]

    public init(grid: [GridSegment], sourceDuration: Double, bars: [BarRange]) throws {
        let layout = try BarLayout(grid: grid, duration: sourceDuration)
        guard !bars.isEmpty else { throw DJCError.editRefused(String(ui: "편집할 마디 구간이 없습니다. 1-16,1-16,17-64처럼 쓰세요")) }
        for (index, range) in bars.enumerated() {
            try range.checkOrder()
            guard range.last <= layout.count else {
                throw DJCError.editRefused(String(ui: "마디 \(range.last)은 곡 끝을 넘습니다. 마지막 마디 \(layout.count) 이하로 고르세요"))
            }
            if range.first == 0 {
                guard layout.hasLeadIn else { throw DJCError.editRefused(String(ui: "이 곡은 첫 다운비트가 곡 시작이라 0마디가 없습니다. 1마디부터 고르세요")) }
                guard index == 0 else { throw DJCError.editRefused(String(ui: "0마디(첫 다운비트 앞)는 맨 앞 구간의 시작에만 둘 수 있습니다")) }
            }
            if layout.lastBarIsPartial, range.last == layout.count, index != bars.count - 1 {
                throw DJCError.editRefused(String(ui: "마지막 마디 \(layout.count)은 곡 끝에서 잘려 있어 맨 뒤 구간의 끝에만 둘 수 있습니다"))
            }
        }
        // 원본에서 이어지는 구간은 합친다(이음새가 아니다).
        var merged: [BarRange] = []
        for range in bars {
            if let last = merged.last, last.last + 1 == range.first { merged[merged.count - 1].last = range.last } else { merged.append(range) }
        }
        pieces = Self.place(merged, in: layout)
        clips = Self.place(bars, in: layout)
        self.layout = layout
    }

    /// 구간을 차례로 출력에 놓는다. 출력 시각은 앞 구간 마디 수 × 마디 길이로 바로 구한다(더해 가면 오차가 쌓인다).
    /// 규칙은 보지 않는다: 규칙에 맞지 않는 목록(가운데 곡 머리 등)도 편집 화면이 그려 고칠 수 있게 한다.
    public static func place(_ ranges: [BarRange], in layout: BarLayout) -> [Piece] {
        guard let head = ranges.first else { return [] }
        let leadIn = head.first == 0 ? layout.firstDownbeat : 0
        var barsBefore = 0
        return ranges.enumerated().map { index, range in
            let wholeBars = range.last - max(range.first, 1) + 1
            let start = index == 0 ? 0 : leadIn + Double(barsBefore) * layout.barLength
            barsBefore += wholeBars
            let sourceStart = layout.start(ofBar: range.first), sourceEnd = layout.end(ofBar: range.last)
            let partial = layout.lastBarIsPartial && range.last == layout.count
            let end = partial ? start + (sourceEnd - sourceStart) : leadIn + Double(barsBefore) * layout.barLength
            return Piece(bars: range, sourceStart: sourceStart, sourceEnd: sourceEnd, outputStart: start, outputEnd: end)
        }
    }

    /// 출력 길이(초)
    public var duration: Double { pieces.last?.outputEnd ?? 0 }

    /// 출력 그리드: 원본 BPM 한 구간. 출력의 첫 다운비트(곡 머리를 살렸으면 그 길이, 아니면 0초)에서 곡 머리 쪽 첫 박으로 되돌린다.
    public var outputGrid: GridSegment {
        let downbeat = pieces.first?.bars.first == 0 ? layout.firstDownbeat : 0
        let beat = 60 / layout.segment.bpm
        let back = Int(((downbeat + 1e-6) / beat).rounded(.down))
        return GridSegment(start: max(0, downbeat - Double(back) * beat), bpm: layout.segment.bpm,
                           firstBeatNumber: ((-back) % 4 + 4) % 4 + 1)
    }

    /// 원본 시각이 출력에서 나오는 시각들(나오는 순서). 편집에서 빠진 시각이면 빈 배열.
    public func outputTimes(of sourceTime: Double) -> [Double] { pieces.outputTimes(of: sourceTime) }

    /// 출력 시각 → 원본 시각(미리 듣기용). 출력 끝을 넘으면 nil.
    public func sourceTime(atOutput time: Double) -> Double? { pieces.sourceTime(atOutput: time) }
}

// MARK: - 큐 옮기기

public struct CueCarry: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// 편집에서 빠진 구간에 있었다
        case cut
        /// 루프가 조각 끝을 넘어 이음새에 걸린다(출력에서는 다른 소리를 되풀이하게 된다)
        case loopAcrossSeam

        public var label: String {
            switch self {
            case .cut: String(ui: "빠진 구간")
            case .loopAcrossSeam: String(ui: "루프가 이음새에 걸림")
            }
        }
    }

    public struct Dropped: Sendable, Equatable {
        public var cue: EditableCue
        public var reason: Reason
    }

    /// 새 곡에 놓을 큐(새 ID, rekordbox ID 없음)
    public var placed: [EditableCue]
    public var dropped: [Dropped]
}

public extension TrackEdit {
    /// 큐(핫큐·메모리 큐·루프)를 출력 위치로 옮긴다. 같은 소리가 여러 번 나오면 처음 나오는 자리 하나에만 둔다
    /// (핫큐 슬롯이 겹치지 않고, 인트로를 늘려도 뒤 인트로에 같은 메모리 큐가 또 생기지 않는다).
    /// 루프는 끝까지 한 조각 안에 드는 첫 자리로 옮긴다.
    func carry(_ cues: [EditableCue], newID: () -> UUID) -> CueCarry { pieces.carry(cues, newID: newID) }
}

// MARK: - 프레임 계획

/// 렌더할 조각 하나(프레임 단위). 렌더러는 이대로 읽고 쓴다.
public struct EditFrameSpan: Sendable, Hashable {
    /// 원본 음원(AVFoundation 시간축) 첫 프레임. 음수·길이 밖은 무음으로 채운다.
    public var sourceFrame: Int64
    public var frameCount: Int64
    public var outputFrame: Int64
    /// 이 조각 앞 이음새에서 섞는 프레임 수. 앞 조각 끝을 줄이고 이 조각 바로 앞 원본 소리를 키워 이음새에서 끝난다
    /// (다운비트 어택은 그대로 둔다). 0이면 이음새가 없다(첫 조각).
    public var crossfadeFrames: Int64

    public init(sourceFrame: Int64, frameCount: Int64, outputFrame: Int64, crossfadeFrames: Int64) {
        self.sourceFrame = sourceFrame
        self.frameCount = frameCount
        self.outputFrame = outputFrame
        self.crossfadeFrames = crossfadeFrames
    }
}

public extension TrackEdit {
    /// 이음새에서 섞는 길이(초). 클릭만 없앨 만큼 짧게.
    static let crossfadeSeconds = 0.004

    /// 조각마다 읽고 쓸 프레임. 경계는 각각 반올림해 조각이 많아도 어긋남이 쌓이지 않는다.
    /// - Parameter sourceOffset: 원본의 rekordbox 시간축 − 음원 시간축(초). MP3·AAC 인코더 지연(`RekordboxTimeline.predictedOffset`).
    func frames(sampleRate: Double, sourceOffset: Double, crossfade: Double = crossfadeSeconds) -> [EditFrameSpan] {
        pieces.frames(sampleRate: sampleRate, sourceOffset: sourceOffset, crossfade: crossfade)
    }
}

// MARK: - 구간 후보

public extension BarLayout {
    /// 마디마다 값(`values[i]` = i+1마디, 예: 보컬 활동 평균)이 `threshold` 미만인 마디가 `minimum`개 이상 이어지는 구간.
    /// 인트로 연장·짧은 버전을 고를 때 보컬 없는 구간 후보로 보여 준다.
    static func runs(_ values: [Double], below threshold: Double, minimum: Int) -> [BarRange] {
        var result: [BarRange] = []
        var start: Int?
        for (index, value) in (values + [threshold]).enumerated() {
            if value < threshold {
                if start == nil { start = index + 1 }
            } else if let first = start {
                if index - first + 1 >= minimum { result.append(BarRange(first, index)) }
                start = nil
            }
        }
        return result
    }
}
