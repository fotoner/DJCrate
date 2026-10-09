// 곡 넣기·빼기 관문(`RekordboxTrackWriter`)의 결과·입력 값. 관문은 RekordboxKit에 그대로 있고 옛 이름(`RekordboxTrackWriter.Report` 등)은
// typealias로 남는다(#167). 백업 폴더의 보고서 JSON과 칸 이름이 같아야 하므로 저장 칸 이름·순서를 바꾸지 않는다.

/// 곡 하나를 넣거나 뺀 결과(`RekordboxTrackWriter.Outcome`)
public struct RekordboxTrackWriteOutcome: Codable, Hashable, Sendable {
    public var path: String
    public var contentID: String?
    public var title: String
    public var written: Bool
    public var reason: String?
    /// 넣은 곡의 UUID(초안을 새 곡으로 옮길 때 쓴다)
    public var uuid: String?
    /// 곡과 함께 넣은 큐 수(큐를 주지 않았거나 막혔으면 nil)
    public var cuesWritten: Int?
    /// 큐를 넣지 못한 이유(곡은 넣었다)
    public var cueReason: String?
    /// 곡과 함께 쓴 키 이름(Camelot, 키를 주지 않았거나 막혔으면 nil, #5). 옛 보고서에는 없다.
    public var keyWritten: String?
    /// 키를 쓰지 못한 이유(곡은 키 없이 넣었다). 옛 보고서에는 없다.
    public var keyReason: String?
    /// 키가 막혔을 때 넣은 곡의 태그 값(키는 빈칸). 앱이 고른 키를 새 곡의 키 초안으로 남길 때 기준(base)으로 쓴다: 쓰기 직후 다시 읽기가
    /// 실패해도 초안을 만들 수 있고, 곡 행에서 읽은 값이라 쓸 때 기준 어긋남으로 막히지 않는다(#197). 옛 보고서에는 없다.
    public var keyBase: TagFields?

    public init(path: String, contentID: String? = nil, title: String, written: Bool, reason: String? = nil, uuid: String? = nil,
                cuesWritten: Int? = nil, cueReason: String? = nil, keyWritten: String? = nil, keyReason: String? = nil,
                keyBase: TagFields? = nil) {
        self.path = path
        self.contentID = contentID
        self.title = title
        self.written = written
        self.reason = reason
        self.uuid = uuid
        self.cuesWritten = cuesWritten
        self.cueReason = cueReason
        self.keyWritten = keyWritten
        self.keyReason = keyReason
        self.keyBase = keyBase
    }
}

/// 곡 넣기·빼기 보고(`RekordboxTrackWriter.Report`). 쓰기 전 백업 폴더에 JSON으로 남는다.
public struct RekordboxTrackWriteReport: Codable, Sendable {
    public typealias Outcome = RekordboxTrackWriteOutcome

    public var added: [Outcome] = []
    public var deleted: [Outcome] = []
    public var backup: String?
    public var dryRun: Bool
    /// 지운 곡의 분석·아트워크 파일(백업 폴더 `anlz/`로 옮겨 두었다가 되돌릴 때 살린다)
    public var removedFiles: [String] = []
    /// 새로 만든 분석·아트워크 파일(되돌릴 때 지운다). 반환값은 절대 경로, 백업 JSON은 share 기준 상대 경로.
    public var createdFiles: [String] = []
    /// 쓴 직후 rekordbox 변경 카운터. 되돌리기 전에 그 뒤 rekordbox에서 바뀐 게 있는지 본다.
    public var finalUpdateCount: Int?

    public init(added: [Outcome] = [], deleted: [Outcome] = [], backup: String? = nil, dryRun: Bool, removedFiles: [String] = [],
                createdFiles: [String] = [], finalUpdateCount: Int? = nil) {
        self.added = added
        self.deleted = deleted
        self.backup = backup
        self.dryRun = dryRun
        self.removedFiles = removedFiles
        self.createdFiles = createdFiles
        self.finalUpdateCount = finalUpdateCount
    }

    /// 실제로 넣거나 뺀 곡 이름
    public var titles: [String] { (added + deleted).filter(\.written).map(\.title) }
}

/// 곡과 함께 붙일 분석(그리드·음량, `RekordboxTrackWriter.Analysis`). 파형·음원 정보는 쓰기 모듈이 음원에서 직접 만든다.
public struct RekordboxTrackAnalysis: Sendable {
    /// rekordbox 시간축 그리드 구간
    public var segments: [GridSegment]
    /// 통합 음량(LUFS). nil이면 오토게인 0dB.
    public var loudness: Double?
    /// 샘플 피크(선형, 0~1)
    public var peak: Double

    public init(segments: [GridSegment], loudness: Double?, peak: Double) {
        self.segments = segments
        self.loudness = loudness
        self.peak = peak
    }
}
