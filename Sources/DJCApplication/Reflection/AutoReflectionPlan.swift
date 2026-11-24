import DJCDomain
import Foundation

/// 자동 저장이 본 저장 대기(R4·R5·R6·R14·R23): 자동으로 쓸 곡 초안과 재생 목록 단계, 자동으로 쓰지 않고 남기는 것의 이유.
/// 반영 세션이 화면 상태·초안 저장소에서 만들고(`ReflectionSession.autoInventory`) 엔진이 이것으로 쓸 묶음(`chunk`)을 고른다.
/// 값만 다루는 판정이라 시험이 그대로 만든다.
public struct AutoReflectionInventory: Equatable, Sendable {
    /// 재생 목록 단계 하나(초안의 차례)
    public struct Step: Equatable, Sendable {
        /// 이 단계가 닿는 목록(`PlaylistRef.layoutID`, 만들기면 `new:키`)
        public var playlist: String
        /// 이 단계가 갱신할 곡 행 수(넣기·빼기·옮기기는 곡 수, 그 밖은 1)
        public var rows: Int
        public var revision: DraftRevision?
        /// 자동으로 쓰지 않는 이유. nil이면 자동으로 쓸 수 있다
        public var leftover: ReflectionLeftover?

        public init(playlist: String, rows: Int, revision: DraftRevision?, leftover: ReflectionLeftover? = nil) {
            self.playlist = playlist
            self.rows = rows
            self.revision = revision
            self.leftover = leftover
        }

        /// 단계 하나가 실제로 갱신할 곡 행 수(K와 견준다, R14). 단계 직전·직후 그 목록의 곡 줄로 센다: 넣기는 넣는 곡(끝에 붙는다),
        /// 빼기는 뺀 곡과 그 뒤 번호가 다시 매겨지는 남은 곡, 옮기기는 자리(번호)가 바뀐 곡, 그 밖(만들기·이름·옮기기·순서·지우기)은 목록 행 하나.
        /// 직전·직후 목록을 모르면 편집만 보고 센다(`rows(of:playlistSize:)`)
        public static func rows(of edit: PlaylistEdit, before: [PlaylistEntry]?, after: [PlaylistEntry]?) -> Int {
            guard let before, let after else { return rows(of: edit, playlistSize: before?.count ?? 0) }
            switch edit {
            case let .addTracks(_, ids): return max(ids.count, 1)
            case .removeTracks:
                // 앞에서부터 그대로인 줄 뒤는 지워졌거나 번호가 바뀌었다
                let kept = zip(before, after).prefix { $0 == $1 }.count
                return max(before.count - kept, 1)
            case .moveTracks: return max(zip(before, after).filter { $0 != $1 }.count, 1)
            case .create, .rename, .move, .reorder, .delete: return 1
            }
        }

        /// 편집이 갱신할 곡 행 수(K와 견준다). 넣기는 넣는 곡 수(끝에 붙는다), 빼기·옮기기는 그 목록의 남은 곡 번호를 다시 매기므로
        /// 목록의 곡 수(`playlistSize`)와 빼거나 옮기는 곡 수 중 큰 쪽, 목록 만들기·이름·옮기기·순서·지우기는 목록 행 하나
        public static func rows(of edit: PlaylistEdit, playlistSize: Int = 0) -> Int {
            switch edit {
            case let .addTracks(_, ids): max(ids.count, 1)
            case let .removeTracks(_, entries), let .moveTracks(_, entries, _): max(entries.count, playlistSize, 1)
            case .create, .rename, .move, .reorder, .delete: 1
            }
        }
    }

    /// 자동으로 쓸 곡 초안(곡 → 종류별 판)
    public var tracks: [String: [DraftKey: DraftRevision]]
    /// 자동으로 쓰지 않는 곡 초안과 그 이유
    public var leftoverKeys: [DraftKey: ReflectionLeftover]
    /// 재생 목록 단계(초안 차례)
    public var steps: [Step]
    /// 값을 지우는 편집(태그 칸 비우기·큐 지우기)이 든 자동 저장 곡(R14: 여러 곡이면 대량 유예)
    public var clearing: Set<String>
    /// 쓰기 대기 재생 기록 수(대상 밖, R4)
    public var histories = 0
    /// 판정에서 본 판 전부(자동으로 쓸 것과 남긴 것). 여기 없는 [취소]·확인 필요 판은 새 판을 받았거나 쓰여 저절로 풀린다
    public var known: Set<DraftRevision> = []
    /// 재생 목록 초안을 판정하지 못했다(디스크와 아직 맞추지 못함·저장하지 못함). 단계는 확인 필요로 남고, 판이 사라졌는지 모르므로 솎지 않는다
    public var playlistUndetermined = false

    public init(tracks: [String: [DraftKey: DraftRevision]] = [:], leftoverKeys: [DraftKey: ReflectionLeftover] = [:], steps: [Step] = [],
                clearing: Set<String> = []) {
        self.tracks = tracks
        self.leftoverKeys = leftoverKeys
        self.steps = steps
        self.clearing = clearing
    }

    // MARK: - 재생 목록 단위(R4·R14)

    /// 같은 목록에 닿는 단계의 처음부터 끝까지를 한 단위로 묶는다. 사이에 낀 다른 목록의 단계도 그 단위에 든다(그 목록을 만드는 단계 포함).
    /// 단위끼리 겹치면 하나로 합친다. 반환은 단계 차례를 빠짐없이 나눈 연속 구간이다
    public static func units(_ playlists: [String]) -> [Range<Int>] {
        var last: [String: Int] = [:]
        for (index, playlist) in playlists.enumerated() { last[playlist] = index }
        var units: [Range<Int>] = []
        var start = 0, end = -1
        for (index, playlist) in playlists.enumerated() {
            end = max(end, last[playlist] ?? index)
            if index == end {
                units.append(start..<(end + 1))
                start = index + 1
            }
        }
        return units
    }

    /// 자동으로 쓸 수 있는 재생 목록 단위(앞에서부터)와, 멈춘 자리부터 남기는 이유.
    /// 단위 안의 단계가 하나라도 자동으로 쓸 수 없으면 그 단위부터 뒤는 자동으로 쓰지 않는다(AR-9, R4). 단위 하나가 K행을 넘어도 같다(R14)
    public func autoUnits(rowLimit: Int) -> (units: [Range<Int>], leftovers: Set<ReflectionLeftover>) {
        var accepted: [Range<Int>] = []
        for unit in Self.units(steps.map(\.playlist)) {
            let reasons = Set(steps[unit].compactMap(\.leftover))
            if !reasons.isEmpty { return (accepted, reasons) }
            if steps[unit].reduce(0, { $0 + $1.rows }) > rowLimit { return (accepted, [.overRowLimit]) }
            accepted.append(unit)
        }
        return (accepted, [])
    }

    // MARK: - 고르기

    /// 자동으로 쓸 판 전부(곡 초안과 자동으로 쓸 재생 목록 단계). 대량 유예의 [취소]가 이 판들에 묶인다(R14)
    public func autoRevisions(rowLimit: Int) -> Set<DraftRevision> {
        let steps = autoUnits(rowLimit: rowLimit).units.flatMap { Array($0) }.compactMap { self.steps[$0].revision }
        return Set(tracks.values.flatMap(\.values)).union(steps)
    }

    /// 자동으로 쓸 곡 행 수 전부(곡 수 + 자동으로 쓸 재생 목록 단계의 행)
    public func autoRows(rowLimit: Int) -> Int {
        tracks.count + autoUnits(rowLimit: rowLimit).units.flatMap { Array($0) }.reduce(0) { $0 + steps[$1].rows }
    }

    /// 대량 유예를 거칠지(R14): 자동으로 쓸 행이 M 이상이거나, 값을 지우는 편집이 여러 곡에 있다
    public func isBulk(timing: AutoReflectionTiming) -> Bool {
        autoRows(rowLimit: timing.rowLimit) >= timing.bulkTracks || clearing.intersection(tracks.keys).count >= 2
    }

    /// 자동으로 쓸 것이 있는지
    public func hasAuto(rowLimit: Int) -> Bool { !tracks.isEmpty || !autoUnits(rowLimit: rowLimit).units.isEmpty }

    /// 이번 자동 저장 한 번에 쓸 것(K행까지). 재생 목록 단위를 앞에서부터 나누지 않고 넣고, 남은 행만큼 곡을 채운다.
    /// 넘는 것은 다음 저장이 차례로 쓴다(쓴 단계는 정리로 빠지므로 다음 판정이 다시 앞에서부터 고른다). 쓸 것이 없으면 nil
    public func chunk(rowLimit: Int) -> AutoReflectionChunk? {
        var rows = 0, stepCount = 0
        for unit in autoUnits(rowLimit: rowLimit).units {
            let unitRows = steps[unit].reduce(0) { $0 + $1.rows }
            guard rows + unitRows <= rowLimit else { break }
            rows += unitRows
            stepCount = unit.upperBound
        }
        var chosen: [String: [DraftKey: DraftRevision]] = [:]
        for uuid in tracks.keys.sorted() where rows < rowLimit {
            chosen[uuid] = tracks[uuid]
            rows += 1
        }
        guard stepCount > 0 || !chosen.isEmpty else { return nil }
        return AutoReflectionChunk(tracks: chosen, playlistSteps: stepCount,
                                   stepRevisions: steps.prefix(stepCount).compactMap(\.revision), rows: rows)
    }

    // MARK: - 남은 편집(R3 8번 줄)

    /// 자동으로 쓰지 않고 남기는 이유 전부
    public func leftovers(rowLimit: Int) -> Set<ReflectionLeftover> {
        Set(leftoverKeys.values).union(autoUnits(rowLimit: rowLimit).leftovers).union(histories > 0 ? [.outsideScope] : [])
    }

    /// 남은 편집 수: 자동으로 쓰지 않는 초안이 있는 곡 수 + 자동으로 쓰지 않는 재생 목록 단계 수
    public func leftoverCount(rowLimit: Int) -> Int {
        let autoSteps = autoUnits(rowLimit: rowLimit).units.reduce(0) { $0 + $1.count }
        return Set(leftoverKeys.keys.map(\.id)).count + (steps.count - autoSteps) + histories
    }
}

/// 자동 저장 한 번에 쓸 것(K행까지)
public struct AutoReflectionChunk: Equatable, Sendable {
    /// 쓸 곡 초안(곡 → 종류별 판). 같은 곡의 대상 밖 초안은 들지 않는다(R4)
    public var tracks: [String: [DraftKey: DraftRevision]]
    /// 묶음에 넣을 재생 목록 단계 수(초안 앞에서부터)
    public var playlistSteps: Int
    /// 그 단계들의 판(초안 차례)
    public var stepRevisions: [DraftRevision]
    /// 갱신할 곡 행 수
    public var rows: Int

    public init(tracks: [String: [DraftKey: DraftRevision]], playlistSteps: Int, stepRevisions: [DraftRevision], rows: Int) {
        self.tracks = tracks
        self.playlistSteps = playlistSteps
        self.stepRevisions = stepRevisions
        self.rows = rows
    }

    /// 묶음에 든 판 전부
    public var revisions: Set<DraftRevision> { Set(tracks.values.flatMap(\.values)).union(stepRevisions) }
}

extension TagDraft {
    /// 값을 지우는 편집이 있는지(기준에 값이 있던 칸을 비움, R14)
    var clearsValues: Bool { TagFields.Key.allCases.contains { !base[$0].isEmpty && fields[$0].isEmpty } }
}

extension CueDraft {
    /// 큐를 지우는 편집인지(기준보다 큐가 줄었다, R14)
    var clearsValues: Bool { cues.count < base.count }
}
