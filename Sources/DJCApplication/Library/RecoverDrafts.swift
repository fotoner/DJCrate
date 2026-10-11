import DJCDomain
import Foundation

/// 막힌 초안 복구(#232)가 비교할 초안 하나(태그·큐·그리드)
public enum RecoveryDraft: Equatable, Sendable {
    case tags(TagDraft), cues(CueDraft), grid(GridDraft)
    public var uuid: String { switch self { case let .tags(d): d.trackUUID; case let .cues(d): d.trackUUID; case let .grid(d): d.trackUUID } }
    public var kind: DraftRecoveryKind { switch self { case .tags: .tags; case .cues: .cues; case .grid: .grid } }
    public var hasChanges: Bool { switch self { case let .tags(d): d.hasChanges; case let .cues(d): d.hasChanges; case let .grid(d): d.hasChanges } }
    public func resolved(onto current: Self, choice: DraftRecoveryChoice, sourceMappings: [String: String] = [:]) throws -> Self {
        switch (self, current) {
        case let (.tags(d), .tags(c)): .tags(TagDraftRecovery(draft: d, current: c.base).resolve(choice))
        case let (.cues(d), .cues(c)): .cues(try CueDraftRecovery(draft: d, current: c.base, sourceMappings: sourceMappings).resolve(choice))
        case let (.grid(d), .grid(c)): .grid(try GridDraftRecovery(draft: d, current: c.base).resolve(choice))
        default: throw DraftRecoveryError.ambiguousIdentity
        }
    }
}

/// 한 초안의 지금 rekordbox 값(새 사본으로 읽은 곡 줄·분석 그리드)
public struct RecoveryRead: Sendable {
    public var draft: RecoveryDraft
    public var row: TrackRow?
    public var grid: BeatGrid?

    public init(draft: RecoveryDraft, row: TrackRow?, grid: BeatGrid?) {
        self.draft = draft
        self.row = row
        self.grid = grid
    }
}

/// 복구 시트가 미리 읽어 둔 현재값(곡 줄 전체를 사본 하나로 읽는다)
public struct RecoveryPrefetch: Sendable {
    public var original: RecoveryDraft
    public var read: RecoveryRead

    public init(original: RecoveryDraft, read: RecoveryRead) {
        self.original = original
        self.read = read
    }
}

/// 곡 초안 하나의 비교(복구 시트 한 줄)
public struct DraftRecoveryReview: Sendable {
    public var original: RecoveryDraft
    public var current: RecoveryDraft
    public var title: String
    public var currentRow: TrackRow?
    public var currentGrid: BeatGrid?
    public var cueSourceMappings: [String: String] = [:]

    public init(original: RecoveryDraft, current: RecoveryDraft, title: String, currentRow: TrackRow?, currentGrid: BeatGrid?,
                cueSourceMappings: [String: String] = [:]) {
        self.original = original
        self.current = current
        self.title = title
        self.currentRow = currentRow
        self.currentGrid = currentGrid
        self.cueSourceMappings = cueSourceMappings
    }

    /// 비교 창에서 "내 편집 유지"를 고를 수 없는 이유(미리 알 수 있는 것만)
    public var keepRefusal: String? {
        guard let resolved = try? original.resolved(onto: current, choice: .keepEditing, sourceMappings: cueSourceMappings) else { return nil }
        return Self.gridKeepRefusal(original: original, resolved: resolved, currentGrid: currentGrid, lengthSeconds: currentRow?.track.lengthSeconds)
    }

    /// 구간으로 다시 만들 수 없는 현재 그리드에 승인 없는 구간 편집을 얹으면 rekordbox의 박을 통째로 덮으므로 막는다(덱 편집 제한과 같게).
    public static func gridKeepRefusal(original: RecoveryDraft, resolved: RecoveryDraft, currentGrid: BeatGrid?, lengthSeconds: Int?) -> String? {
        guard case let .grid(input) = original, input.replacementSource == nil,
              case let .grid(draft) = resolved, draft.hasChanges, let currentGrid,
              GridEditEligibility.reconstructionErrorMilliseconds(of: currentGrid, duration: Double(lengthSeconds ?? 0)) > 2 else { return nil }
        return String(ui: "rekordbox의 현재 그리드는 템포 구간으로 정확히 재현되지 않아 내 그리드 편집을 다시 적용할 수 없으니 현재값을 사용하세요.")
    }
}

/// 재생 목록 복구가 비교할 지금 rekordbox 라이브러리
public struct PlaylistRecoveryCurrent: Equatable, Sendable {
    public var layout: PlaylistLayout
    public var contentIDs: Set<String>
    public var titles: [String: String]
    public var rows: [String: TrackRow]

    public init(layout: PlaylistLayout, contentIDs: Set<String>, titles: [String: String], rows: [String: TrackRow]) {
        self.layout = layout
        self.contentIDs = contentIDs
        self.titles = titles
        self.rows = rows
    }
}

/// 재생 목록 하나의 비교(복구 시트 한 줄)
public struct PlaylistRecoveryReview: Sendable {
    public var original: PlaylistDraft
    public var current: PlaylistRecoveryCurrent
    public var playlistID: String
    public var recovery: PlaylistDraft.Recovery

    public init(original: PlaylistDraft, current: PlaylistRecoveryCurrent, playlistID: String, recovery: PlaylistDraft.Recovery) {
        self.original = original
        self.current = current
        self.playlistID = playlistID
        self.recovery = recovery
    }

    public var blockedOffsets: [Int] {
        let blocked = original.project(onto: current.layout, contentIDs: current.contentIDs).blocked
        return original.steps.indices.filter { original.steps[$0].edit.playlist.layoutID == playlistID && blocked[$0] != nil }
    }
}

/// 복구 비교에 쓸 지금 rekordbox 값(포트): 원본 DB·분석 파일을 임시 사본으로 떠서 읽는다(원본은 읽기만 한다).
/// 실제 구현은 DJCAdapters(`RecoveryReader.live`).
public struct RecoveryReader: Sendable {
    /// 원본 DB(`source`)와 분석 파일 뿌리(`share`)를 사본으로 떠서 라이브러리를 읽는다. `grids` 초안의 곡은 사본의 분석 그리드도 읽는다
    /// (곡 UUID별: 그 곡을 하나로 찾지 못했거나 분석 파일 경로가 없으면 nil, 읽지 못하면 실패). 부른 작업을 취소하면 멈춘다
    public var read: @Sendable (_ source: URL, _ share: URL, _ grids: [GridDraft]) async throws
        -> (library: RekordboxLibrary, grids: [String: Result<BeatGrid?, any Error>])

    public init(read: @escaping @Sendable (_ source: URL, _ share: URL, _ grids: [GridDraft]) async throws
                    -> (library: RekordboxLibrary, grids: [String: Result<BeatGrid?, any Error>])) {
        self.read = read
    }
}

/// 막힌 초안 복구(유스케이스, #232): 막힌 곡 초안·재생 목록 초안을 지금 rekordbox 값과 견주고, 고른 대로(내 편집 유지·다시 적용 / 현재값 사용)
/// 새 기준의 초안을 저장한다. 화면 모델(`LibraryStore`)은 시트가 열린 동안 쓰기를 막고, 비교 사이 입력·화면 상태가 바뀌었는지 보고, 결과를 메모리에 얹는다.
public struct RecoverDrafts: Sendable {
    let reader: RecoveryReader
    let drafts: DraftStore

    public init(reader: RecoveryReader, drafts: DraftStore) {
        self.reader = reader
        self.drafts = drafts
    }

    /// 비교 사이 입력이나 현재값이 바뀌었다
    public static var changedError: DJCError {
        .writeRefused(String(ui: "비교 중 입력이나 현재값이 바뀌어 초안을 그대로 남겼으니 현재값을 다시 가져오세요."))
    }

    /// 곡 초안을 비교할 원본: 명시한 사본으로 열었으면 연 사본, 아니면 라이브 DB와 라이브 share
    public static func draftSource(location: LibraryLocation, opened: URL?) throws -> (database: URL, share: URL) {
        if location.opensExplicitCopy {
            guard let opened else { throw changedError }
            return (opened, location.liveShare)
        }
        return (location.liveDatabase, location.liveShare)
    }

    /// 재생 목록 초안을 비교할 원본: 명시한 사본으로 열었으면 연 사본, 아니면 쓰기 대상 DB와 그 share
    public static func playlistSource(location: LibraryLocation, opened: URL?) -> (database: URL, share: URL) {
        let source = location.opensExplicitCopy ? opened ?? location.database : location.database
        return (source, location.shareRoot ?? source.deletingLastPathComponent().appending(path: "share"))
    }

    // MARK: - 곡 초안

    /// 걸린 초안 저장을 끝낸다(비교하기 전·저장하기 전)
    public func flush() { drafts.flush() }

    /// 저장해 둔 큐·그리드 입력: 저장 대기 입력이 있으면 그것(지우기 입력이면 빈 초안), 없으면 초안 파일. 태그는 화면 메모리가 원본이라 nil
    public func savedInput(uuid: String, kind: DraftRecoveryKind) -> RecoveryDraft? {
        switch kind {
        case .tags: nil
        case .cues: (drafts.pendingCue(uuid) ?? drafts.cueDraft(uuid)).map(RecoveryDraft.cues)
        case .grid: (drafts.pendingGrid(uuid) ?? drafts.gridDraft(uuid)).map(RecoveryDraft.grid)
        }
    }

    /// 곡 줄 여럿의 현재값을 사본 하나로 읽는다(줄마다 사본을 뜨고 라이브러리 전체를 읽지 않게). 곡을 찾지 못하는 등 초안마다의 실패는 그 결과로 남긴다
    public func readCurrent(_ originals: [RecoveryDraft], source: URL, share: URL) async throws -> [Result<RecoveryRead, any Error>] {
        let grids = originals.compactMap { original -> GridDraft? in if case let .grid(draft) = original { draft } else { nil } }
        let read = try await reader.read(source, share, grids)
        return originals.map { original in
            Result { try Self.current(of: original, library: read.library, grid: read.grids[original.uuid], newID: drafts.newCueID) }
        }
    }

    /// 읽어 둔 라이브러리에서 초안 하나의 현재값을 만든다(현재 큐의 ID는 `newID`로 받는다)
    public static func current(of original: RecoveryDraft, library: RekordboxLibrary, grid: Result<BeatGrid?, any Error>?,
                               newID: () -> UUID) throws -> RecoveryRead {
        let tracks = library.tracks.filter { $0.uuid == original.uuid }
        guard tracks.count == 1, let track = tracks.first, !track.isStreaming else {
            throw DJCError.writeRefused(String(ui: "현재 라이브러리에서 이 곡을 확인하지 못했으니 곡을 다시 선택하세요. 초안은 그대로 남겼습니다."))
        }
        let row = TrackRow(track: track, cues: library.cues(for: track), playCount: library.playCounts[track.id] ?? 0)
        switch original {
        case .tags:
            return RecoveryRead(draft: .tags(TagDraft(track: track)), row: row, grid: nil)
        case let .cues(draft):
            let cues = CueDraft(trackUUID: track.uuid, rekordboxCues: row.cues, newID: newID)
            return RecoveryRead(draft: .cues(try CueDraftRecovery(draft: draft, current: cues.base).resolve(.useCurrent)), row: row, grid: nil)
        case .grid:
            let current = try grid?.get()
            let segments = current.map(GridDraft.segments(from:)) ?? []
            return RecoveryRead(draft: .grid(GridDraft(trackUUID: track.uuid, base: segments, segments: segments)), row: row, grid: current)
        }
    }

    /// 비교했을 때와 지금 현재값의 기준이 같은지(큐는 원래 큐 ID 순서로 견준다)
    public static func sameCurrent(_ a: RecoveryDraft, _ b: RecoveryDraft) -> Bool {
        switch (a, b) {
        case let (.tags(a), .tags(b)): return a.base == b.base
        case let (.grid(a), .grid(b)): return a.base == b.base
        case let (.cues(a), .cues(b)):
            let lhs = a.base.sorted { ($0.sourceID ?? "") < ($1.sourceID ?? "") }
            let rhs = b.base.sorted { ($0.sourceID ?? "") < ($1.sourceID ?? "") }
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                $0.sourceID == $1.sourceID && $0.kind == $1.kind && $0.time == $1.time && $0.name == $1.name && $0.loop == $1.loop
            }
        default: return false
        }
    }

    /// 고른 대로 새 기준의 초안을 만든다. 비교 뒤 현재값이 바뀌었거나 다시 적용할 수 없으면 던진다(초안은 그대로 남는다)
    public static func resolve(_ review: DraftRecoveryReview, latest: RecoveryRead, choice: DraftRecoveryChoice) throws -> RecoveryDraft {
        guard sameCurrent(latest.draft, review.current), latest.grid == review.currentGrid else { throw changedError }
        var resolved = try review.original.resolved(onto: latest.draft, choice: choice, sourceMappings: review.cueSourceMappings)
        if case .keepEditing = choice, let refusal = DraftRecoveryReview.gridKeepRefusal(
            original: review.original, resolved: resolved, currentGrid: latest.grid, lengthSeconds: latest.row?.track.lengthSeconds) {
            throw DJCError.writeRefused(refusal)
        }
        if case .keepEditing = choice, case let .grid(original) = review.original, original.replacementSource != nil {
            guard case let .grid(draft) = resolved, let currentGrid = latest.grid,
                  let duration = latest.row?.track.lengthSeconds else { throw changedError }
            // 구간의 실측 BPM이 달라도 전체 저장 박이 이미 원하는 결과면 다시 쓰지 않는다.
            if draft.grid(duration: Double(duration)) == currentGrid {
                resolved = .grid(GridDraft(trackUUID: draft.trackUUID, base: draft.base, segments: draft.base))
            } else if let approved = draft.approvingReplacement(of: currentGrid, duration: Double(duration)) {
                resolved = .grid(approved)
            } else {
                throw DJCError.writeRefused(String(ui: "현재 원본에 대체 그리드를 재적용할 수 없으니 초안을 남기고 그리드 구간을 다시 지정하세요."))
            }
        }
        return resolved
    }

    /// 새 기준의 초안을 저장한다. 저장하지 못하면 기존 입력을 저장 큐에 돌려놓고 던진다(실패한 새 기준이 저장 대기로 남지 않게)
    @MainActor
    public func save(_ resolved: RecoveryDraft, restoring original: RecoveryDraft) throws {
        do { try save(resolved) }
        catch {
            switch original {
            case .tags: break
            case let .cues(d): drafts.saveCue(d)
            case let .grid(d): drafts.saveGrid(d)
            }
            drafts.flush()
            throw error
        }
    }

    @MainActor
    private func save(_ draft: RecoveryDraft) throws {
        switch draft {
        case let .tags(d):
            drafts.saveTags([d])
            drafts.flush()
            guard !drafts.failedTagSaves().contains(d.trackUUID) else {
                throw DJCError.writeRefused(DraftSaveFailure.tagSaveMessage)
            }
        case let .cues(d): drafts.saveCue(d)
        case let .grid(d): drafts.saveGrid(d)
        }
        drafts.flush()
        let kind: DraftSaveKind?
        switch draft { case .tags: kind = nil; case .cues: kind = .cue; case .grid: kind = .grid }
        if let kind, let failure = drafts.failures().first(where: { $0.kind == kind && $0.trackUUID == draft.uuid }) {
            throw DJCError.writeRefused(failure.message)
        }
    }

    // MARK: - 재생 목록 초안

    /// 재생 목록 줄 전체를 위해 현재 라이브러리를 한 번 읽는다(줄마다 사본을 뜨지 않게)
    public func readPlaylistCurrent(source: URL, share: URL) async throws -> PlaylistRecoveryCurrent {
        let library = try await reader.read(source, share, []).library
        return PlaylistRecoveryCurrent(layout: PlaylistLayout(rekordbox: library.playlists),
                                       contentIDs: Set(library.tracks.map(\.id)),
                                       titles: Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0.title) }),
                                       rows: Dictionary(uniqueKeysWithValues: library.tracks.map { track in
                                           (track.id, TrackRow(track: track, cues: library.cues(for: track), playCount: library.playCounts[track.id] ?? 0))
                                       }))
    }

    /// 재생 목록 하나를 비교한다. 다시 적용할 막힌 편집이 없으면 던진다
    public static func review(playlist id: String, draft: PlaylistDraft, current: PlaylistRecoveryCurrent) throws -> PlaylistRecoveryReview {
        let review = PlaylistRecoveryReview(original: draft, current: current, playlistID: id,
                                            recovery: draft.recovering(playlist: id, rekordbox: current.layout, contentIDs: current.contentIDs))
        guard !review.blockedOffsets.isEmpty else { throw changedError }
        return review
    }

    /// 고른 대로 새 재생 목록 초안을 만든다: 다시 적용하거나 그 목록의 막힌 편집을 버린다. 비교 뒤 현재값이 바뀌었으면 던진다
    public static func resolvePlaylist(_ review: PlaylistRecoveryReview, reapply: Bool, latest: PlaylistRecoveryCurrent) throws -> PlaylistDraft {
        guard latest == review.current else { throw changedError }
        if reapply {
            guard !review.recovery.reapplied.isEmpty else { throw changedError }
            return review.recovery.draft
        }
        var resolved = review.original
        resolved.removeSteps(at: review.blockedOffsets)
        return resolved
    }
}
