import Foundation

/// 파일을 찾지 못한 곡 하나(#62). 곡 행에서 맞추는 데 쓰는 값만 든다.
public struct RelocateTarget: Sendable, Equatable, Identifiable {
    /// ContentID
    public let id: String
    public let title: String
    public let artist: String?
    /// 곡 행이 가리키는 옛 경로(파일 이름까지)
    public let oldPath: String
    /// 곡 행의 길이(초). 0이거나 nil이면 모르는 값이다.
    public let lengthSeconds: Int?
    /// 곡 행의 파일 크기(바이트). 0이거나 nil이면 모르는 값이다.
    public let fileSize: Int64?

    public init(id: String, title: String, artist: String?, oldPath: String, lengthSeconds: Int?, fileSize: Int64?) {
        self.id = id; self.title = title; self.artist = artist; self.oldPath = oldPath
        self.lengthSeconds = lengthSeconds; self.fileSize = fileSize
    }

    public init(track: Track, fileSize: Int64?) {
        self.init(id: track.id, title: track.title, artist: track.artist, oldPath: track.folderPath,
                  lengthSeconds: track.lengthSeconds, fileSize: fileSize)
    }

    public var fileName: String { (oldPath as NSString).lastPathComponent }
}

/// 사용자가 고른 폴더 아래에서 찾은 음원 파일 하나. 길이·태그는 읽지 못했거나 읽지 않았으면 nil이다.
public struct RelocateFile: Sendable, Equatable, Identifiable {
    public let path: String
    public let size: Int64
    public var durationSeconds: Double?
    public var title: String?
    public var artist: String?

    public init(path: String, size: Int64, durationSeconds: Double? = nil, title: String? = nil, artist: String? = nil) {
        self.path = path; self.size = size; self.durationSeconds = durationSeconds; self.title = title; self.artist = artist
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

/// 곡과 파일 한 쌍이 어디까지 맞는지.
public struct RelocateEvidence: Sendable, Equatable {
    public enum Name: Sendable, Equatable {
        /// NFC로 맞춰 글자까지 같음
        case exact
        /// 대소문자만 다름
        case caseInsensitive
        /// 이름은 같고 확장자만 다름
        case stemOnly
        case different
    }

    public enum Check: Sendable, Equatable {
        case equal, different
        /// 어느 한쪽을 모름(점수도 감점도 없음)
        case unknown
    }

    public var name: Name
    public var sameExtension: Bool
    public var size: Check
    public var duration: Check
    public var title: Check
    public var artist: Check

    public init(name: Name, sameExtension: Bool, size: Check, duration: Check, title: Check, artist: Check) {
        self.name = name; self.sameExtension = sameExtension; self.size = size; self.duration = duration
        self.title = title; self.artist = artist
    }

    public var score: Int {
        var total = switch name {
        case .exact: RelocateRules.exactNamePoints
        case .caseInsensitive: RelocateRules.foldedNamePoints
        case .stemOnly: RelocateRules.stemOnlyPoints
        case .different: 0
        }
        if size == .equal { total += RelocateRules.sizePoints }
        if duration == .equal { total += RelocateRules.durationPoints }
        if title == .equal { total += RelocateRules.titlePoints }
        if artist == .equal { total += RelocateRules.artistPoints }
        return total
    }

    /// 양쪽 길이를 알고 허용 오차를 넘으면 다른 파일이다.
    public var isDisqualified: Bool { duration == .different }
}

public struct RelocateCandidate: Sendable, Equatable, Identifiable {
    public let file: RelocateFile
    public let score: Int
    public let evidence: RelocateEvidence

    public init(file: RelocateFile, score: Int, evidence: RelocateEvidence) {
        self.file = file; self.score = score; self.evidence = evidence
    }

    public var id: String { file.path }
}

public enum RelocateOutcome: Sendable, Equatable {
    /// 하나뿐이고 근거가 충분하다. 그래도 사람이 미리 보기에서 확인한다.
    case confident(RelocateCandidate)
    /// 후보가 있지만 사람이 골라야 한다(점수 높은 순).
    case ambiguous(AmbiguityReason, [RelocateCandidate])
    case none

    public enum Kind: Sendable, Equatable { case confident, ambiguous, none }

    public enum AmbiguityReason: Sendable, Equatable, Hashable {
        /// 같은 급의 후보가 둘 이상
        case severalCandidates
        /// 다른 곡도 같은 파일을 주 후보로 삼음
        case sharedFile
        /// 근거는 충분하지만 확장자가 다름
        case differentExtension
        /// 후보가 하나지만 근거가 모자람(이름만 맞고 길이·크기를 모르는 경우 등)
        case weakEvidence
    }

    public var kind: Kind {
        switch self {
        case .confident: .confident
        case .ambiguous: .ambiguous
        case .none: .none
        }
    }
}

public struct RelocateResult: Sendable, Equatable, Identifiable {
    public let target: RelocateTarget
    public let outcome: RelocateOutcome

    public init(target: RelocateTarget, outcome: RelocateOutcome) {
        self.target = target; self.outcome = outcome
    }

    public var id: String { target.id }

    /// 사람이 고를 수 있는 후보(확실이면 그 하나)
    public var candidates: [RelocateCandidate] {
        switch outcome {
        case let .confident(candidate): [candidate]
        case let .ambiguous(_, options): options
        case .none: []
        }
    }
}

public struct RelocateReport: Sendable, Equatable {
    /// 넘겨받은 곡 순서 그대로
    public let results: [RelocateResult]

    public init(results: [RelocateResult]) { self.results = results }

    public func count(_ kind: RelocateOutcome.Kind) -> Int { results.lazy.filter { $0.outcome.kind == kind }.count }
    public var confidentCount: Int { count(.confident) }
    public var ambiguousCount: Int { count(.ambiguous) }
    public var noneCount: Int { count(.none) }
}
