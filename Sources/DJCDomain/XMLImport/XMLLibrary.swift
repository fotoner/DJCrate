import Foundation

/// rekordbox XML(`DJ_PLAYLISTS`) 한 문서, 또는 같은 모양으로 읽은 지금 라이브러리(#72 가져오기).
/// 두 쪽을 같은 모델로 담아 `XMLLibraryDiff`가 비교한다. 시각은 rekordbox 시간축(초)이다.
public struct XMLLibrary: Sendable, Equatable {
    /// POSITION_MARK 하나. 큐(`Type` 0)와 루프(`Type` 4)만 담는다.
    public struct Mark: Sendable, Hashable {
        public var kind: EditableCue.Kind
        public var start: Double
        /// 루프 끝. 루프가 아니면 nil.
        public var end: Double?
        public var name: String

        public init(kind: EditableCue.Kind, start: Double, end: Double? = nil, name: String) {
            self.kind = kind; self.start = start; self.end = end; self.name = name
        }
    }

    public struct Track: Sendable, Equatable {
        /// XML `TrackID`, 라이브러리는 `ContentID`
        public var key: String
        /// 음원 파일 경로. 파일이 아닌 위치(스트리밍 등)는 nil.
        public var path: String?
        /// 문서에 있던 칸만 담는다(없는 칸은 비교하지 않는다). 값은 태그 초안 값 모양이다(평점 "1"~"5", 연도 "0"은 그대로).
        public var tags: [TagFields.Key: String]
        public var marks: [Mark]
        public var tempos: [GridSegment]
        /// 곡 길이(초). XML은 `TotalTime`, 라이브러리는 곡 길이. 모르면 nil.
        public var duration: Double?
        /// 큐·루프 POSITION_MARK 중 읽지 못한 것(값이 깨졌거나 A~H 밖 핫큐). 있으면 그 곡의 큐는 비교하지 않는다.
        public var unreadableMarks = 0

        public init(key: String, path: String?, tags: [TagFields.Key: String] = [:], marks: [Mark] = [], tempos: [GridSegment] = [],
                    duration: Double? = nil) {
            self.key = key; self.path = path; self.tags = tags; self.marks = marks; self.tempos = tempos; self.duration = duration
        }

        public var title: String { tags[.title] ?? "" }
    }

    /// PLAYLISTS의 NODE. `children`이 nil이면 재생 목록, 있으면 폴더다.
    public struct Node: Sendable, Equatable {
        public var name: String
        /// 라이브러리 쪽 목록 ID(XML 쪽은 nil)
        public var id: String?
        public var children: [Node]?
        /// 재생 목록의 곡(`Track.key`, 순서대로, 같은 곡이 여러 번 있을 수 있다)
        public var entries: [String]

        public init(name: String, id: String? = nil, entries: [String]) {
            self.name = name; self.id = id; children = nil; self.entries = entries
        }

        public init(name: String, id: String? = nil, children: [Node]) {
            self.name = name; self.id = id; self.children = children; entries = []
        }

        public var isFolder: Bool { children != nil }
    }

    /// 읽으면서 건너뛴 것. 막지 않고 개수만 알린다.
    public enum Skip: String, CaseIterable, Codable, Sendable, Comparable {
        /// 큐·루프가 아닌 POSITION_MARK(페이드·로드 등)
        case unknownMarkType
        /// 핫큐 번호가 A~H(0~7) 밖
        case hotCueOutOfRange
        /// 4/4가 아닌 TEMPO(그 곡의 그리드는 읽지 않는다)
        case unsupportedMeter
        /// 숫자여야 할 칸이 숫자가 아님
        case invalidValue
        /// 파일이 아닌 Location(스트리밍·다른 기계)
        case nonFileLocation
        /// 모르는 NODE 종류
        case unknownNodeType
        /// 모르는 요소
        case unknownElement
        /// 곡 색(`Colour`): rekordbox XML의 색 값과 곡 색 번호의 짝을 확인하지 못해 읽지 않는다
        case unverifiedColour
        /// 재생 목록 항목이 컬렉션에 없는 곡을 가리킴
        case missingTrackReference
        /// 앞 곡과 같은 `TrackID`(그 키의 곡은 모두 맞추지 않는다)
        case duplicateTrackID

        public static func < (lhs: Skip, rhs: Skip) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }

        public var label: String {
            switch self {
            case .unknownMarkType: String(ui: "큐·루프가 아닌 위치 표시")
            case .hotCueOutOfRange: String(ui: "A~H 밖의 핫큐")
            case .unsupportedMeter: String(ui: "4/4가 아닌 박자의 그리드")
            case .invalidValue: String(ui: "읽지 못한 값")
            case .nonFileLocation: String(ui: "파일이 아닌 위치의 곡")
            case .unknownNodeType: String(ui: "모르는 재생 목록 종류")
            case .unknownElement: String(ui: "모르는 요소")
            case .unverifiedColour: String(ui: "곡 색(확인 전이라 읽지 않음)")
            case .missingTrackReference: String(ui: "컬렉션에 없는 곡을 가리킨 목록 항목")
            case .duplicateTrackID: String(ui: "TrackID가 겹친 곡")
            }
        }
    }

    public var tracks: [Track]
    public var lists: [Node]
    /// 라이브러리 쪽: 분석 파일에서 그리드를 읽었는가. 읽지 않았으면 그리드를 비교하지 않는다.
    public var hasGrids: Bool
    public var skipped: [Skip: Int]

    public init(tracks: [Track], lists: [Node] = [], hasGrids: Bool = true, skipped: [Skip: Int] = [:]) {
        self.tracks = tracks; self.lists = lists; self.hasGrids = hasGrids; self.skipped = skipped
    }
}

/// XML 곡을 라이브러리 곡과 파일 경로로 맞춘다.
public enum XMLTrackMatching {
    public struct Result: Sendable, Equatable {
        /// XML 키 → 라이브러리 키
        public var matched: [String: String] = [:]
        /// 라이브러리에 없는 곡(파일이 아닌 위치 포함), XML 순서
        public var unmatched: [String] = []
        /// 여러 라이브러리 곡에 맞거나 XML 안에서 같은 곡을 여러 번 적은 곡, TrackID가 겹친 곡(키는 한 번만), XML 순서
        public var ambiguous: [String] = []
    }

    /// `Location`(`file://localhost/…` 퍼센트 인코딩) → 파일 경로. 파일이 아니거나 다른 기계의 위치면 nil.
    public static func path(fromLocation location: String) -> String? {
        var rest: Substring
        if location.hasPrefix("file://localhost/") {
            rest = location.dropFirst("file://localhost".count)
        } else if location.hasPrefix("file:///") {
            rest = location.dropFirst("file://".count)
        } else {
            return nil
        }
        // 인코딩하지 않은 `%`가 섞여 풀 수 없으면 적힌 그대로 쓴다.
        let decoded = String(rest).removingPercentEncoding ?? String(rest)
        rest = Substring(decoded)
        return rest.isEmpty ? nil : String(rest)
    }

    /// 경로 비교 키: NFC(macOS 파일 이름은 NFD로 올 때가 있다)
    public static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    /// 정확히 같은 경로(NFC)를 먼저 보고, 없으면 대소문자만 다른 경로가 하나뿐일 때 맞춘다(macOS 기본 볼륨은 대소문자를 가리지 않는다).
    public static func match(xml: [XMLLibrary.Track], library: [XMLLibrary.Track]) -> Result {
        var exact: [String: [String]] = [:], folded: [String: [String]] = [:]
        for track in library {
            guard let path = track.path else { continue }
            let nfc = key(path)
            exact[nfc, default: []].append(track.key)
            folded[nfc.lowercased(), default: []].append(track.key)
        }
        var result = Result()
        var tentative: [(xml: String, library: String)] = []
        // 같은 TrackID가 여럿이면 목록 항목이 어느 곡을 가리키는지 모르고, 맞춤이 서로를 덮는다.
        let keyCounts = Dictionary(xml.map { ($0.key, 1) }, uniquingKeysWith: +)
        var duplicated: Set<String> = []
        for track in xml {
            if keyCounts[track.key, default: 0] > 1 { duplicated.insert(track.key); continue }
            guard let path = track.path else { result.unmatched.append(track.key); continue }
            let nfc = key(path)
            let candidates = exact[nfc] ?? folded[nfc.lowercased()] ?? []
            switch candidates.count {
            case 0: result.unmatched.append(track.key)
            case 1: tentative.append((track.key, candidates[0]))
            default: result.ambiguous.append(track.key)
            }
        }
        let uses = Dictionary(grouping: tentative, by: \.library)
        var ambiguous = Set(result.ambiguous).union(duplicated)
        for pair in tentative {
            if uses[pair.library]?.count == 1 { result.matched[pair.xml] = pair.library } else { ambiguous.insert(pair.xml) }
        }
        var listed: Set<String> = []
        result.ambiguous = xml.map(\.key).filter { ambiguous.contains($0) && listed.insert($0).inserted }
        return result
    }
}
