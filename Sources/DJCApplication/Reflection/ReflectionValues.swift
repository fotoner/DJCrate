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

    public init(drafts: [CueDraft] = [], grids: [GridDraft] = [], gains: [String: Double] = [:], tags: [TagDraft] = [],
                artworks: [ArtworkEdit] = [], playlists: PlaylistDraft? = nil, merges: [DuplicateMergeDraft] = []) {
        self.drafts = drafts
        self.grids = grids
        self.gains = gains
        self.tags = tags
        self.artworks = artworks
        self.playlists = playlists
        self.merges = merges
    }

    /// 묶음이 건드리는 곡(합치기는 묶인 곡 모두)
    public var trackUUIDs: Set<String> {
        Set(drafts.map(\.trackUUID)).union(grids.map(\.trackUUID)).union(gains.keys).union(tags.map(\.trackUUID))
            .union(artworks.map(\.trackUUID)).union(merges.flatMap { $0.members.map(\.trackUUID) })
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

    /// 미리 보기에서 쓸 수 있다고 나온 것만(분석을 붙이는 곡도 그리드 초안으로 쓴다). 재생 목록은 쓰는 편집이 있으면 초안 전체를 넘긴다.
    public var writableBatch: DraftWriteBatch {
        let cues = Set(report.written.map(\.trackUUID)), grids = Set((report.gridWritten + report.analysisWritten).map(\.trackUUID))
        let gains = Set(report.gainWritten.map(\.trackUUID)), tags = Set(report.tagWritten.map(\.trackUUID))
        let artworks = Set(report.artworkWritten.map(\.trackUUID))
        return DraftWriteBatch(drafts: batch.drafts.filter { cues.contains($0.trackUUID) },
                               grids: batch.grids.filter { grids.contains($0.trackUUID) },
                               gains: batch.gains.filter { gains.contains($0.key) },
                               tags: batch.tags.filter { tags.contains($0.trackUUID) },
                               artworks: batch.artworks.filter { artworks.contains($0.trackUUID) },
                               playlists: report.playlistWritten.isEmpty ? nil : batch.playlists,
                               merges: batch.merges.filter { draft in report.mergeWritten.contains { $0.trackUUID == draft.id } })
    }

    /// 쓸 것이 하나라도 있는지
    public var hasWritable: Bool {
        !report.written.isEmpty || !report.gridWritten.isEmpty || !report.analysisWritten.isEmpty || !report.gainWritten.isEmpty
            || !report.tagWritten.isEmpty || !report.artworkWritten.isEmpty || !report.playlistWritten.isEmpty || !report.mergeWritten.isEmpty
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

    public init(plans: [TrackAddPlan], analyses: [String: RekordboxTrackAnalysis] = [:], cues: [String: [EditableCue]] = [:],
                keys: [String: String] = [:]) {
        self.plans = plans
        self.analyses = analyses
        self.cues = cues
        self.keys = keys
    }
}
