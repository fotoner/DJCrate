import DJCDomain
import Foundation

/// 쓰기·복원 대상 rekordbox 라이브러리: DB, 분석 파일 뿌리, 쓰기 전 백업 폴더.
/// 부르는 쪽이 정한다(라이브 DB를 기본값으로 두지 않는다, #182). 앱은 `LibraryStore.rekordboxDatabase`·`backupDirectory` 한 곳에서,
/// CLI는 `--live`·`--db`에서 만든다.
public struct RekordboxWriteTarget: Sendable, Equatable {
    public var database: URL
    /// 분석 파일 뿌리(nil이면 쓰기 관문이 정한다: 라이브는 rekordbox 폴더, 사본은 그 옆 share)
    public var shareRoot: URL?
    public var backups: URL

    public init(database: URL, shareRoot: URL?, backups: URL) {
        self.database = database
        self.shareRoot = shareRoot
        self.backups = backups
    }

    /// 사본 DB. 백업은 사본 옆 `backups/`에 둔다(사용자 백업 폴더를 밀어내지 않게).
    public static func copy(database: URL, shareRoot: URL?) -> Self {
        Self(database: database, shareRoot: shareRoot, backups: database.deletingLastPathComponent().appending(path: "backups"))
    }
}

/// 한 번에 rekordbox에 쓸 초안 묶음
public struct DraftWriteBatch: Sendable, Equatable {
    public var drafts: [CueDraft]
    public var grids: [GridDraft]
    /// 곡 UUID → 오토게인 초안(dB)
    public var gains: [String: Double]
    public var tags: [TagDraft]
    public var artworks: [ArtworkEdit]
    /// 함께 쓸 재생 목록 초안(없으면 nil). 결과(`playlistOutcomes`)가 편집 순서와 같다.
    public var playlists: PlaylistDraft?
    public var merges: [DuplicateMergeDraft]
    /// 함께 쓸 쓰기 대기 재생 기록(#43, 가져온 차례). 결과는 `historyOutcomes`(기록 ID로 맞춘다)
    public var histories: [HistoryImport]
    /// 초안마다 묶음을 읽은 때의 판(R22: 쓴 뒤 정리는 이 판만 지운다). 비어 있으면 판을 모른다(지금 동작)
    public var revisions: DraftBatchRevisions
    /// 정리 할 일을 적을 자리(앱의 쓰기). nil이면 미정리 목록을 적지 않는다(CLI·시험, 지금 동작)
    public var operation: DraftWriteOperation?
    /// 쓰기를 마치는 방식. 여러 곡 역편집은 `.allOrNothing`(R12). 미리 보기에서 관문까지 그대로 나른다
    public var commitPolicy: DraftCommitPolicy
    /// 자동 저장 묶음(#403). 관문은 쓰기 잠금을 기다리지 않고(잡지 못하면 `RekordboxWriteGate.LockBusy`, R9),
    /// 백업을 뜬 뒤의 실패를 백업 뒤 실패(`writeRolledBack`)로 알린다(R7: 엔진이 멈춘다)
    public var isAutoSave = false

    public init(drafts: [CueDraft] = [], grids: [GridDraft] = [], gains: [String: Double] = [:], tags: [TagDraft] = [],
                artworks: [ArtworkEdit] = [], playlists: PlaylistDraft? = nil, merges: [DuplicateMergeDraft] = [],
                histories: [HistoryImport] = [], revisions: DraftBatchRevisions = DraftBatchRevisions(),
                operation: DraftWriteOperation? = nil, commitPolicy: DraftCommitPolicy = .writable) {
        self.drafts = drafts
        self.grids = grids
        self.gains = gains
        self.tags = tags
        self.artworks = artworks
        self.playlists = playlists
        self.merges = merges
        self.histories = histories
        self.revisions = revisions
        self.operation = operation
        self.commitPolicy = commitPolicy
    }

    /// 묶음이 건드리는 곡(합치기는 묶인 곡 모두)
    public var trackUUIDs: Set<String> {
        Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gains.keys).union(tags.map(\.trackUUID))
            .union(artworks.map(\.trackUUID)).union(merges.flatMap { $0.members.map(\.trackUUID) })
    }

    /// 묶음에 든 곡 초안(종류, 곡). 합치기는 합치기 초안 ID로 가리킨다. 재생 목록 단계·재생 기록은 들지 않는다
    public var draftKeys: Set<DraftKey> {
        Set(drafts.map { DraftKey(.cue, $0.trackUUID) }).union(grids.map { DraftKey(.grid, $0.trackUUID) })
            .union(gains.keys.map { DraftKey(.gain, $0) }).union(tags.map { DraftKey(.tag, $0.trackUUID) })
            .union(artworks.map { DraftKey(.artwork, $0.trackUUID) }).union(merges.map { DraftKey(.merge, $0.id) })
    }
}

/// 사본으로 끝까지 써 본 결과와 그때 읽은 초안 묶음
public struct WritePreview: Sendable {
    public var report: RekordboxWriteReport
    public var batch: DraftWriteBatch
    /// 미리 보기 전에 빠진 초안의 줄(읽지 못한 초안 파일 등)
    public var exclusions: [String]

    public init(report: RekordboxWriteReport, batch: DraftWriteBatch, exclusions: [String] = []) {
        self.report = report
        self.batch = batch
        self.exclusions = exclusions
    }

    /// 관문에 넘길 쓰기 요청. nil이면 쓰지 않는다.
    /// - `.writable`(지금 동작): 미리 보기에서 쓸 수 있다고 나온 것만(`writableBatch`). 쓸 것이 없으면 nil
    /// - `.allOrNothing`(여러 곡 역편집, R12): 하나라도 막혔거나 빠졌으면 nil, 모두 통과하면 원래 묶음 전체(판·작업 정보 포함)
    public var writeRequest: DraftWriteBatch? {
        switch batch.commitPolicy {
        case .writable: partialHasWritable ? partialBatch : nil
        case .allOrNothing: passesAll ? batch : nil
        }
    }

    /// 쓰기 요청의 묶음(세션이 관문에 넘긴다). 쓰기 요청이 없으면 아무것도 쓰지 않는 빈 묶음이다:
    /// `.allOrNothing` 묶음은 막힌 곡을 뺀 일부만 남기지 않는다(관문이 남은 곡만 커밋하지 않게)
    public var writableBatch: DraftWriteBatch {
        writeRequest ?? DraftWriteBatch(operation: batch.operation, commitPolicy: batch.commitPolicy)
    }

    /// 쓸 것이 하나라도 있는지(쓰기 요청이 있는지)
    public var hasWritable: Bool { writeRequest != nil }

    /// 미리 보기에서 쓸 수 있다고 나온 것만(분석을 붙이는 곡도 그리드 초안으로 쓴다). 재생 목록은 쓰는 편집이 있으면 초안 전체를 넘긴다.
    /// 재생 기록도 곡 초안처럼 미리 보기에서 쓸 수 있던 기록만 넘긴다(막힌 기록은 쓰기 대기에 남는다). 판·작업 정보·쓰기 방식은 나른다
    private var partialBatch: DraftWriteBatch {
        let cues = Set(report.written.map(\.trackUUID)), grids = Set((report.gridWritten + report.analysisWritten).map(\.trackUUID))
        let gains = Set(report.gainWritten.map(\.trackUUID)), tags = Set(report.tagWritten.map(\.trackUUID))
        let artworks = Set(report.artworkWritten.map(\.trackUUID)), histories = Set(report.historyWritten.map(\.id))
        var writable = DraftWriteBatch(drafts: batch.drafts.filter { cues.contains($0.trackUUID) },
                                       grids: batch.grids.filter { grids.contains($0.trackUUID) },
                                       gains: batch.gains.filter { gains.contains($0.key) },
                                       tags: batch.tags.filter { tags.contains($0.trackUUID) },
                                       artworks: batch.artworks.filter { artworks.contains($0.trackUUID) },
                                       playlists: report.playlistWritten.isEmpty ? nil : batch.playlists,
                                       merges: batch.merges.filter { draft in report.mergeWritten.contains { $0.trackUUID == draft.id } },
                                       histories: batch.histories.filter { histories.contains($0.id) },
                                       operation: batch.operation, commitPolicy: batch.commitPolicy)
        // 판은 남긴 초안의 것만 나른다(재생 목록 단계는 초안 전체를 넘기므로 그대로)
        writable.revisions = batch.revisions.restricted(to: writable.draftKeys)
        if writable.playlists == nil { writable.revisions.playlistSteps = [] }
        return writable
    }

    private var partialHasWritable: Bool {
        !report.written.isEmpty || !report.gridWritten.isEmpty || !report.analysisWritten.isEmpty || !report.gainWritten.isEmpty
            || !report.tagWritten.isEmpty || !report.artworkWritten.isEmpty || !report.playlistWritten.isEmpty || !report.mergeWritten.isEmpty
            || !report.historyWritten.isEmpty
    }

    /// 묶음 전체가 막힘 없이 통과했는지: 빠진 초안·막힌 결과가 없고, 묶음의 초안마다 결과(쓰기·바뀐 것 없음)가 있다.
    /// 결과가 없는 초안은 쓰였는지 모르므로 통과로 보지 않는다
    private var passesAll: Bool {
        guard exclusions.isEmpty else { return false }
        let blocked = !report.blocked.isEmpty || !report.gridBlocked.isEmpty || !report.analysisBlocked.isEmpty || !report.gainBlocked.isEmpty
            || !report.tagBlocked.isEmpty || !report.artworkBlocked.isEmpty || !report.playlistBlocked.isEmpty || !report.mergeBlocked.isEmpty
            || !report.historyBlocked.isEmpty
        guard !blocked else { return false }
        let cues = Set(report.outcomes.map(\.trackUUID))
        let grids = Set(((report.gridOutcomes ?? []) + (report.analysisOutcomes ?? [])).map(\.trackUUID))
        let gains = Set((report.gainOutcomes ?? []).map(\.trackUUID)), tags = Set((report.tagOutcomes ?? []).map(\.trackUUID))
        let artworks = Set((report.artworkOutcomes ?? []).map(\.trackUUID)), merges = Set((report.mergeOutcomes ?? []).map(\.trackUUID))
        let histories = Set((report.historyOutcomes ?? []).map(\.id))
        let playlistsDone = batch.playlists.map { (report.playlistOutcomes ?? []).count == $0.steps.count } ?? true
        return batch.drafts.allSatisfy { cues.contains($0.trackUUID) } && batch.grids.allSatisfy { grids.contains($0.trackUUID) }
            && batch.gains.keys.allSatisfy(gains.contains) && batch.tags.allSatisfy { tags.contains($0.trackUUID) }
            && batch.artworks.allSatisfy { artworks.contains($0.trackUUID) } && batch.merges.allSatisfy { merges.contains($0.id) }
            && batch.histories.allSatisfy { histories.contains($0.id) } && playlistsDone
    }
}

/// 넣을 추가한 곡(앱의 목록 행이 아니라 계획을 만드는 데 필요한 값만)
public struct StagedTrackRequest: Sendable, Equatable {
    public var uuid: String
    public var path: String
    public var title: String

    public init(uuid: String, path: String, title: String) {
        self.uuid = uuid
        self.path = path
        self.title = title
    }
}

/// 추가한 곡 하나의 넣기 계획(파일 태그 + 태그 초안)과 함께 넣을 것
public struct TrackAddCandidate: Sendable {
    public var plan: TrackAddPlan
    /// 함께 넣을 큐(추가한 곡의 큐 초안, 없으면 nil)
    public var cues: [EditableCue]?
    /// 함께 쓸 키(사용자가 고른 Camelot 이름, #5)
    public var key: String?
    /// 분석을 붙이지 못하는 이유(곡은 분석 전 상태로 넣는다)
    public var withoutAnalysis: String?
    /// 계획을 만들 때 읽은 옛 UUID 초안(큐·그리드·태그)의 판과 그때 읽은 내용의 해시(R22: 넣기에 쓴 판으로 싣는다)
    public var revisions: [DraftKey: DraftBatchEntry] = [:]

    public init(plan: TrackAddPlan, cues: [EditableCue]? = nil, key: String? = nil, withoutAnalysis: String? = nil) {
        self.plan = plan
        self.cues = cues
        self.key = key
        self.withoutAnalysis = withoutAnalysis
    }
}

/// 곡 넣기 미리 보기
public struct TrackAddPreview: Sendable {
    /// 사본에서 DB만 시험해 본 결과(분석 없이)
    public var report: RekordboxTrackWriteReport
    public var plans: [TrackAddPlan]
    /// 경로 → 추가한 곡 UUID
    public var stagedUUIDs: [String: String]
    /// 경로 → 분석을 붙이지 못하는 이유(곡은 분석 전 상태로 넣는다)
    public var withoutAnalysis: [String: String]
    /// 경로 → 함께 넣을 큐(추가한 곡의 큐 초안)
    public var cues: [String: [EditableCue]]
    /// 경로 → 함께 쓸 키(사용자가 고른 Camelot 이름, #5)
    public var keys: [String: String]
    /// 계획을 만들지 못한 곡(이름: 이유)
    public var unreadable: [String]
    /// 미리 볼 때 읽은 옛 UUID 초안의 판과 그때 읽은 내용의 해시(넣기 묶음에 그대로 싣는다. 쓰기 직전 디스크를 다시 읽지 않는다)
    public var revisions: [DraftKey: DraftBatchEntry] = [:]

    public init(report: RekordboxTrackWriteReport, plans: [TrackAddPlan], stagedUUIDs: [String: String], withoutAnalysis: [String: String],
                cues: [String: [EditableCue]] = [:], keys: [String: String] = [:], unreadable: [String]) {
        self.report = report
        self.plans = plans
        self.stagedUUIDs = stagedUUIDs
        self.withoutAnalysis = withoutAnalysis
        self.cues = cues
        self.keys = keys
        self.unreadable = unreadable
    }
}

/// 곡 빼기 미리 보기
public struct TrackDeletePreview: Sendable {
    /// 사본에서 시험해 본 결과
    public var report: RekordboxTrackWriteReport
    public var contentIDs: [String]

    public init(report: RekordboxTrackWriteReport, contentIDs: [String]) {
        self.report = report
        self.contentIDs = contentIDs
    }
}

/// 곡 넣기 관문에 넘기는 것
public struct TrackAddBatch: Sendable {
    public var plans: [TrackAddPlan]
    /// 경로 → 함께 붙일 분석(그리드·음량)
    public var analyses: [String: RekordboxTrackAnalysis]
    public var cues: [String: [EditableCue]]
    public var keys: [String: String]
    /// 경로 → 추가 목록 UUID(옛 UUID). 미정리 목록이 옛·새 UUID를 잇는다(R22). 비어 있으면 모른다(지금 동작)
    public var stagedUUIDs: [String: String]
    /// 넣기에 실은 초안(키의 곡은 옛 UUID, 큐·그리드·태그). 정리는 이 판만 백업으로 옮기고 지운다.
    /// 넣는 동안 생긴 새 판은 새 곡으로 옮겨 제안으로 둔다(R22)
    public var revisions: DraftBatchRevisions
    /// 정리 할 일을 적을 자리(앱의 곡 넣기). nil이면 미정리 목록을 적지 않는다(CLI·시험, 지금 동작)
    public var operation: DraftWriteOperation?

    public init(plans: [TrackAddPlan], analyses: [String: RekordboxTrackAnalysis] = [:], cues: [String: [EditableCue]] = [:],
                keys: [String: String] = [:], stagedUUIDs: [String: String] = [:], revisions: DraftBatchRevisions = DraftBatchRevisions(),
                operation: DraftWriteOperation? = nil) {
        self.plans = plans
        self.analyses = analyses
        self.cues = cues
        self.keys = keys
        self.stagedUUIDs = stagedUUIDs
        self.revisions = revisions
        self.operation = operation
    }
}
