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
        /// 빼기는 직전 목록의 모든 행(뺀 곡 + 번호를 다시 적는 남은 곡 전부), 옮기기는 자리(번호)가 바뀐 구간, 그 밖(만들기·이름·옮기기·순서·지우기)은 목록 행 하나.
        /// 직전·직후 목록을 모르면 편집만 보고 센다(`rows(of:playlistSize:)`)
        public static func rows(of edit: PlaylistEdit, before: [PlaylistEntry]?, after: [PlaylistEntry]?) -> Int {
            guard let before, let after else { return rows(of: edit, playlistSize: before?.count ?? 0) }
            switch edit {
            case let .addTracks(_, ids): return max(ids.count, 1)
            case .removeTracks:
                // 쓰기는 지운 행과 남은 행 전부(자리가 그대로인 곡까지)의 번호를 다시 적는다(RekordboxWriter+Playlist)
                return max(before.count, 1)
            case let .moveTracks(_, entries, to):
                // 쓰기처럼 고른 곡의 원래 번호로 순서를 다시 만들고, 원래 번호와 새 자리가 다른 줄을 센다(같은 곡이 여러 번 든 목록도 줄로 가린다)
                let picked = Set(entries.map(\.trackNo))
                var order = before.filter { !picked.contains($0.trackNo) }
                order.insert(contentsOf: before.filter { picked.contains($0.trackNo) }, at: min(max(to - 1, 0), order.count))
                return max(order.indices.filter { order[$0].trackNo != $0 + 1 }.count, 1)
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

    /// 대량 유예를 거칠지(R14): 자동으로 쓸 행이 M 이상이거나, 값을 지우는 편집이 여러 곡에 있다.
    /// 대기 중인 여러 곡 역편집 묶음의 행·곡도 합산한다(따로 보면 둘 다 M 아래여도, 컨실 2라운드 D·G7)
    public func isBulk(timing: AutoReflectionTiming, undoRows: Int = 0, undoTracks: Set<String> = []) -> Bool {
        autoRows(rowLimit: timing.rowLimit) + undoRows >= timing.bulkTracks || clearing.intersection(Set(tracks.keys).union(undoTracks)).count >= 2
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

// MARK: - 저장 뒤 ⌘Z의 역편집 묶음(R12)

/// 저장 뒤 ⌘Z가 대기열에 넣은 여러 곡 역편집(`ReflectionUndoEdit`의 초안 키). 한 번의 쓰기로 전부 쓰거나 전부 쓰지 않는다
public struct AutoReflectionUndoGroup: Equatable, Sendable {
    public var id: String
    public var keys: Set<DraftKey>
    /// 이 쓰기가 갱신할 곡 행 수(K와 견준다)
    public var rows: Int
    /// 처음 저장 대기에서 본 판. 그 뒤 판이 바뀌면(다시 고쳤다) 묶음을 풀어 보통 편집으로 쓴다
    public var revisions: [DraftKey: DraftRevision] = [:]

    public init(_ edit: ReflectionUndoEdit) {
        id = edit.id
        keys = edit.batch.draftKeys
        rows = edit.rowCount
    }
}

/// 대기 중인 여러 곡 역편집 묶음(R12). 자동 저장 엔진과 ⌘S가 같은 묶음을 본다(반영 포트 `ReflectionPorts.undoGroups`)
@MainActor
public final class ReflectionUndoGroups {
    public internal(set) var groups: [AutoReflectionUndoGroup] = []

    public init() {}

    /// 묶음을 넣는다. 키가 겹치는 묶음은 합친다(키 합집합, 행 수는 곡 수로 다시 세고 판은 다시 잡는다, 컨실 O2)
    public func enqueue(_ edit: ReflectionUndoEdit) {
        groups.removeAll { $0.id == edit.id }
        var group = AutoReflectionUndoGroup(edit)
        guard group.keys.count > 1 else { return }
        let overlapping = groups.filter { !$0.keys.isDisjoint(with: group.keys) }
        guard !overlapping.isEmpty else {
            groups.append(group)
            return
        }
        groups.removeAll { !$0.keys.isDisjoint(with: group.keys) }
        for other in overlapping { group.keys.formUnion(other.keys) }
        group.rows = Set(group.keys.map(\.id)).count
        group.revisions = [:]
        groups.append(group)
    }

    /// 그 곡들에 닿는 묶음(⌘S가 묶음 밖 편집과 섞지 않고 따로 쓴다)
    public func groups(touching uuids: Set<String>) -> [AutoReflectionUndoGroup] {
        groups.filter { group in group.keys.contains { uuids.contains($0.id) } }
    }

    /// 쓴 묶음을 뺀다(⌘S, 컨실 2라운드 B)
    public func remove(_ id: String) { groups.removeAll { $0.id == id } }
}

extension AutoReflectionInventory {
    /// 역편집 묶음을 반영한다(R12): 묶음의 곡 초안은 보통 자동 저장에서 빼고, 모두 자동으로 쓸 수 있으면 그 묶음만 따로 전부 아니면 전무로 쓴다(한 번에 하나).
    /// K행을 넘으면 `undoOverRowLimit`로, 한 곡이라도 자동으로 쓸 수 없거나 묶었을 때와 구성원·판이 다르면(빠짐·다시 고침) 묶음 전체를 `needsConfirmation`으로
    /// 남긴다(⌘S·저장 단추로 쓴다, 컨실 S2·G5). 저장 대기에서 모두 사라진 묶음(썼다·버렸다)은 버린다.
    /// - Returns: 남길 묶음, 이번에 쓸 묶음(없으면 nil), 쓸 수 있는 모든 묶음의 행 수·판·곡(대량 유예와 [취소] 판에 합산, 컨실 G7)
    public mutating func applyingUndo(_ groups: [AutoReflectionUndoGroup], rowLimit: Int)
        -> (groups: [AutoReflectionUndoGroup], chunk: AutoReflectionChunk?, pendingRows: Int, pendingRevisions: Set<DraftRevision>, pendingTracks: Set<String>) {
        var auto: [DraftKey: DraftRevision] = [:]
        for revisions in tracks.values { auto.merge(revisions) { first, _ in first } }
        var kept: [AutoReflectionUndoGroup] = [], chunk: AutoReflectionChunk?
        var pendingRows = 0, pendingRevisions: Set<DraftRevision> = [], pendingTracks: Set<String> = []
        for var group in groups {
            let present = group.keys.filter { auto[$0] != nil || leftoverKeys[$0] != nil }
            guard !present.isEmpty else { continue }
            var changed = false
            if group.revisions.isEmpty {
                // 처음 볼 때(합쳐 판을 비운 묶음 포함) 구성원이 모두 자동 저장 대기에 있을 때만 판을 잡는다: 빠진 구성원이 있으면
                // 판을 잡지 않고 묶음 전체를 보류한다(남은 곡만 묶음으로 쓰지 않는다, 컨실 2라운드 C·O11)
                if group.keys.allSatisfy({ auto[$0] != nil }) { group.revisions = auto.filter { group.keys.contains($0.key) } }
            } else {
                // 묶었을 때와 판이 다르거나(다시 고침) 구성원이 빠졌다(따로 쓰거나 버림)
                changed = group.revisions.contains { key, revision in auto[key].map { $0 != revision } ?? (leftoverKeys[key] == nil) }
            }
            kept.append(group)
            let members = present.filter { auto[$0] != nil }
            for key in members {
                tracks[key.id]?[key] = nil
                if tracks[key.id]?.isEmpty == true { tracks[key.id] = nil }
            }
            let held: ReflectionLeftover? = changed || members.count < group.keys.count ? .needsConfirmation
                : group.rows > rowLimit ? .undoOverRowLimit : nil
            if let held {
                for key in members { leftoverKeys[key] = held }
                continue
            }
            pendingRows += group.rows
            pendingRevisions.formUnion(members.compactMap { auto[$0] })
            pendingTracks.formUnion(members.map(\.id))
            if chunk == nil {
                var chosen: [String: [DraftKey: DraftRevision]] = [:]
                for key in members { chosen[key.id, default: [:]][key] = auto[key] }
                chunk = AutoReflectionChunk(tracks: chosen, playlistSteps: 0, stepRevisions: [], rows: group.rows, allOrNothing: true)
            }
        }
        return (kept, chunk, pendingRows, pendingRevisions, pendingTracks)
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
    /// 여러 곡 역편집 묶음(R12): 한 곡이라도 막히면 아무것도 쓰지 않는다
    public var allOrNothing: Bool

    public init(tracks: [String: [DraftKey: DraftRevision]], playlistSteps: Int, stepRevisions: [DraftRevision], rows: Int,
                allOrNothing: Bool = false) {
        self.tracks = tracks
        self.playlistSteps = playlistSteps
        self.stepRevisions = stepRevisions
        self.rows = rows
        self.allOrNothing = allOrNothing
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
