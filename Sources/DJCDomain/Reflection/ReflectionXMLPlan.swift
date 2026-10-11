import Foundation

/// rekordbox XML로 반영하는 계획의 값(이미 컬렉션에 있는 곡의 큐·그리드 초안). 계획·XML·검증 규칙은 RekordboxKit `Reflection`에 있다.
/// 시각은 모두 rekordbox 시간축(초)이다.

/// XML `POSITION_MARK` 하나(`Reflection.Mark`)
public struct ReflectionXMLMark: Codable, Hashable, Sendable {
    public var name: String
    /// 0 = 큐, 4 = 루프
    public var type: Int
    public var start: Double
    public var end: Double?
    /// -1 = 메모리 큐, 0…7 = 핫큐 A…H
    public var num: Int

    public init(name: String, type: Int, start: Double, end: Double?, num: Int) {
        self.name = name
        self.type = type
        self.start = start
        self.end = end
        self.num = num
    }
}

/// 보내기 전 rekordbox 곡 정보(가져온 뒤 바뀌면 안 되는 것, `Reflection.Metadata`)
public struct ReflectionXMLMetadata: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var composer: String
    public var comment: String
    public var key: String
    public var bpm: Double?
    public var year: Int?
    public var trackNumber: Int?
    public var lengthSeconds: Int
    public var importedOn: String

    public init(_ track: Track) {
        title = track.title; artist = track.artist ?? ""; album = track.album ?? ""; genre = track.genre ?? ""
        composer = track.composer ?? ""; comment = track.comment; key = track.key ?? ""; bpm = track.bpm
        year = track.releaseYear; trackNumber = track.trackNumber; lengthSeconds = track.lengthSeconds
        importedOn = track.importedOn ?? ""
    }
}

/// 곡 하나의 반영 계획(`Reflection.Plan`). 검증용으로 보내기 전 상태(메타데이터)도 함께 둔다.
public struct ReflectionXMLPlan: Codable, Hashable, Sendable {
    public var trackID: String
    public var uuid: String
    public var path: String
    public var title: String
    public var marks: [ReflectionXMLMark]
    /// nil이면 그리드를 건드리지 않는다(TEMPO를 쓰지 않는다).
    public var tempos: [GridSegment]?
    /// 반영하면 정보가 사라지거나 위험한 이유. 비어 있어야 내보낸다.
    public var blockers: [String]
    public var cueChanged: Bool
    public var gridChanged: Bool
    /// 보내기 전 rekordbox 값(가져온 뒤 바뀌면 안 되는 것)
    public var before: ReflectionXMLMetadata
    /// 보내기 전 rekordbox 큐(아직 가져오지 않았는지 판단용)
    public var beforeMarks: [ReflectionXMLMark]

    public init(trackID: String, uuid: String, path: String, title: String, marks: [ReflectionXMLMark], tempos: [GridSegment]?,
                blockers: [String], cueChanged: Bool, gridChanged: Bool, before: ReflectionXMLMetadata, beforeMarks: [ReflectionXMLMark]) {
        self.trackID = trackID
        self.uuid = uuid
        self.path = path
        self.title = title
        self.marks = marks
        self.tempos = tempos
        self.blockers = blockers
        self.cueChanged = cueChanged
        self.gridChanged = gridChanged
        self.before = before
        self.beforeMarks = beforeMarks
    }

    public var isEligible: Bool { blockers.isEmpty && (cueChanged || gridChanged) }
}

/// 가져온 뒤 검증 결과(`Reflection.Check`)
public struct ReflectionXMLCheck: Codable, Hashable, Sendable {
    public enum Result: String, Codable, Sendable {
        /// 의도한 큐·그리드가 들어갔고 곡 정보도 그대로다
        case matched
        /// 아직 반영되지 않았다(큐·그리드가 보내기 전 그대로)
        case notYet
        /// 일부만 맞거나 곡 정보가 바뀌었다
        case mismatched
    }
    public var result: Result
    public var problems: [String]

    public init(result: Result, problems: [String]) {
        self.result = result
        self.problems = problems
    }
}

/// 내보낸 반영 XML 하나의 계획 묶음(가져온 뒤 검증에 쓴다, `ReflectionStore.Batch`)
public struct ReflectionXMLBatch: Codable, Sendable, Equatable {
    public var createdAt: String
    public var xmlPath: String
    public var plans: [ReflectionXMLPlan]
    public var checks: [String: ReflectionXMLCheck]

    public init(createdAt: String, xmlPath: String, plans: [ReflectionXMLPlan], checks: [String: ReflectionXMLCheck]) {
        self.createdAt = createdAt
        self.xmlPath = xmlPath
        self.plans = plans
        self.checks = checks
    }
}
