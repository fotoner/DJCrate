import Foundation

// 초안 쓰기 관문(`RekordboxWriter`)의 결과 값. 관문은 RekordboxKit에 그대로 있고, 유스케이스·화면이 RekordboxKit 없이
// 보고를 읽도록 값만 여기 둔다(#167). RekordboxKit은 옛 이름(`RekordboxWriter.Report` 등)을 typealias로 남긴다.
// 백업 폴더의 보고서 JSON과 칸 이름이 같아야 하므로 저장 칸 이름·순서를 바꾸지 않는다.

/// 초안 쓰기 한 곡(또는 한 묶음)의 결과(`RekordboxWriter.Outcome`)
public struct RekordboxWriteOutcome: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case written
        case blocked
        case unchanged
    }

    public var trackUUID: String
    public var title: String
    public var status: Status
    public var reason: String?
    public var removed: Int
    public var added: Int
    /// 태그 쓰기에서 바꾼 칸(`TagFields.Key` 이름). 다른 쓰기와 옛 보고서에는 없다.
    public var fields: [String]? = nil
    /// 그림 쓰기에서 한 일(넣기·바꾸기·지우기). 다른 쓰기와 옛 보고서에는 없다.
    public var artwork: ArtworkWriteKind? = nil

    public init(trackUUID: String, title: String, status: Status, reason: String? = nil, removed: Int, added: Int,
                fields: [String]? = nil, artwork: ArtworkWriteKind? = nil) {
        self.trackUUID = trackUUID
        self.title = title
        self.status = status
        self.reason = reason
        self.removed = removed
        self.added = added
        self.fields = fields
        self.artwork = artwork
    }
}

/// 초안 쓰기 보고(`RekordboxWriter.Report`). 쓰기 전 백업 폴더에 JSON으로 남는다.
public struct RekordboxWriteReport: Codable, Sendable {
    public typealias Outcome = RekordboxWriteOutcome

    public var outcomes: [Outcome]
    /// 쓰기 전 백업 폴더(시험 실행이면 nil)
    public var backup: String?
    public var dryRun: Bool
    public var createdAt: String
    /// 쓴 직후 rekordbox 변경 카운터. 되돌리기 전에 지금 값과 비교해 그 뒤 rekordbox에서 바뀐 게 있는지 본다.
    public var finalUpdateCount: Int?
    /// 그리드(분석 파일) 쓰기 결과. 옛 보고서에는 없다.
    public var gridOutcomes: [Outcome]?
    /// 오토게인 쓰기 결과(added = 새 게인 ×100 dB). 옛 보고서에는 없다.
    public var gainOutcomes: [Outcome]?
    /// 분석 전 곡에 분석 파일을 붙인 결과(added = 박 수). 옛 보고서에는 없다.
    public var analysisOutcomes: [Outcome]?
    /// 새로 만든 분석·아트워크 파일(되돌릴 때 지운다). 반환값은 절대 경로, 백업 JSON은 share 기준 상대 경로. 옛 보고서에는 없다.
    public var createdFiles: [String]?
    /// 재생 목록 편집 결과(편집 순서대로). 옛 보고서에는 없다.
    public var playlistOutcomes: [PlaylistOutcome]?
    /// 분석을 붙이며 음원 내장 그림으로 아트워크도 넣은(시험 실행이면 넣을) 곡 UUID. 옛 보고서에는 없다.
    public var artworkAdded: [String]?
    /// 태그(곡 정보) 쓰기 결과(added = 바꾼 칸 수). 옛 보고서에는 없다.
    public var tagOutcomes: [Outcome]?
    /// 중복 묶음 합치기 결과(removed = 컬렉션에서 뺀 곡 수).
    public var mergeOutcomes: [Outcome]?
    /// 곡 정보 그림 쓰기 결과(`Outcome.artwork` = 넣기·바꾸기·지우기). 옛 보고서에는 없다.
    public var artworkOutcomes: [Outcome]?
    /// 쓰기는 끝났지만 알릴 것(보고서를 백업에 저장하지 못함 등). 옛 보고서에는 없다.
    public var warnings: [String]?
    public var iTunesSyncWritten: Bool?

    public init(outcomes: [Outcome], backup: String? = nil, dryRun: Bool, createdAt: String, finalUpdateCount: Int? = nil,
                gridOutcomes: [Outcome]? = nil, gainOutcomes: [Outcome]? = nil, analysisOutcomes: [Outcome]? = nil,
                createdFiles: [String]? = nil, playlistOutcomes: [PlaylistOutcome]? = nil, artworkAdded: [String]? = nil,
                tagOutcomes: [Outcome]? = nil, mergeOutcomes: [Outcome]? = nil, artworkOutcomes: [Outcome]? = nil,
                warnings: [String]? = nil, iTunesSyncWritten: Bool? = nil) {
        self.outcomes = outcomes
        self.backup = backup
        self.dryRun = dryRun
        self.createdAt = createdAt
        self.finalUpdateCount = finalUpdateCount
        self.gridOutcomes = gridOutcomes
        self.gainOutcomes = gainOutcomes
        self.analysisOutcomes = analysisOutcomes
        self.createdFiles = createdFiles
        self.playlistOutcomes = playlistOutcomes
        self.artworkAdded = artworkAdded
        self.tagOutcomes = tagOutcomes
        self.mergeOutcomes = mergeOutcomes
        self.artworkOutcomes = artworkOutcomes
        self.warnings = warnings
        self.iTunesSyncWritten = iTunesSyncWritten
    }

    public var mergeWritten: [Outcome] { (mergeOutcomes ?? []).filter { $0.status == .written } }
    public var mergeBlocked: [Outcome] { (mergeOutcomes ?? []).filter { $0.status == .blocked } }

    public var written: [Outcome] { outcomes.filter { $0.status == .written } }
    public var blocked: [Outcome] { outcomes.filter { $0.status == .blocked } }
    public var gridWritten: [Outcome] { (gridOutcomes ?? []).filter { $0.status == .written } }
    public var gridBlocked: [Outcome] { (gridOutcomes ?? []).filter { $0.status == .blocked } }
    public var gainWritten: [Outcome] { (gainOutcomes ?? []).filter { $0.status == .written } }
    public var gainBlocked: [Outcome] { (gainOutcomes ?? []).filter { $0.status == .blocked } }
    public var analysisWritten: [Outcome] { (analysisOutcomes ?? []).filter { $0.status == .written } }
    public var analysisBlocked: [Outcome] { (analysisOutcomes ?? []).filter { $0.status == .blocked } }
    public var tagWritten: [Outcome] { (tagOutcomes ?? []).filter { $0.status == .written } }
    public var tagBlocked: [Outcome] { (tagOutcomes ?? []).filter { $0.status == .blocked } }
    public var artworkWritten: [Outcome] { (artworkOutcomes ?? []).filter { $0.status == .written } }
    public var artworkBlocked: [Outcome] { (artworkOutcomes ?? []).filter { $0.status == .blocked } }
    public var playlistWritten: [PlaylistOutcome] { (playlistOutcomes ?? []).filter { $0.status == .written } }
    public var playlistBlocked: [PlaylistOutcome] { (playlistOutcomes ?? []).filter { $0.status == .blocked } }
}

/// 쓰기 전 백업 하나(`RekordboxWriter.Backup`). 백업 폴더 읽기·이름 규칙은 RekordboxKit에 있다.
public struct RekordboxWriteBackup: Sendable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var createdAt: Date
    /// DJCrate가 쓰기 직전에 뜬 백업이면 true(큐·그리드·게인 쓰기, 곡 추가·삭제). 되돌리기 직전 상태를 떠 둔 백업은 false.
    public var isWrite: Bool
    public var report: RekordboxWriteReport?
    /// 곡 추가·삭제 보고서
    public var trackReport: RekordboxTrackWriteReport?

    public init(url: URL, createdAt: Date, isWrite: Bool, report: RekordboxWriteReport? = nil, trackReport: RekordboxTrackWriteReport? = nil) {
        self.url = url
        self.createdAt = createdAt
        self.isWrite = isWrite
        self.report = report
        self.trackReport = trackReport
    }

    public var titles: [String] {
        // 한 곡에 큐·태그를 함께 썼으면 한 번만
        var seen: Set<String> = []
        let written = report.map { $0.written + $0.analysisWritten + $0.tagWritten + $0.artworkWritten + $0.mergeWritten } ?? []
        return written.filter { seen.insert($0.trackUUID).inserted }.map(\.title) + (report?.playlistWritten.map(\.name) ?? [])
            + (trackReport?.titles ?? [])
            + (report?.iTunesSyncWritten == true ? [String(ui: "iTunes 동기화 목록")] : [])
    }
    /// 쓴 직후 rekordbox 변경 카운터(옛 백업에는 없다)
    public var finalUpdateCount: Int? { report?.finalUpdateCount ?? trackReport?.finalUpdateCount }
}

/// 분석을 붙일 곡의 음원 길이·음량(`RekordboxWriter.AnalysisInput`, 앱이 AVFoundation·음량 분석으로 잰다)
public struct RekordboxAnalysisInput: Sendable, Equatable {
    /// AVFoundation 길이(초). 곡 넣기처럼 버림해 `Length`에 적는다.
    public var duration: Double
    /// 통합 음량(LUFS). nil이면 오토게인 0dB.
    public var loudness: Double?
    /// 샘플 피크(선형, 0~1)
    public var peak: Double
    /// 음원 내장 그림(`AudioTags.artwork`). 있으면 아트워크 파일 셋도 넣는다.
    public var artwork: Data?

    public init(duration: Double, loudness: Double?, peak: Double, artwork: Data? = nil) {
        self.duration = duration
        self.loudness = loudness
        self.peak = peak
        self.artwork = artwork
    }
}
