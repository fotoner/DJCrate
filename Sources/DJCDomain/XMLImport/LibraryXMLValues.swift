import Foundation

/// 라이브러리 XML 내보내기 결과의 수(곡·큐·재생 목록과 뺀 것). 쓰기는 RekordboxKit(`RekordboxLibraryXML`)이 한다.
public struct LibraryXMLSummary: Sendable, Equatable {
    /// 파일에 넣지 못해 뺀 것
    public struct Omitted: Sendable, Equatable {
        public var streamingTracks = 0
        public var intelligentPlaylists = 0
        /// XML로 옮길 수 없는 큐 종류(Kind 4 등)의 큐 수
        public var unknownCues = 0
        /// 컬렉션에 넣지 않은 곡(삭제·스트리밍)을 가리키던 재생 목록 항목 수
        public var playlistEntries = 0
        /// 없는 폴더를 가리켜 ROOT에서 닿지 않는 재생 목록·폴더 수(rekordbox 트리에 없으므로 지어 붙이지 않는다)
        public var orphanedPlaylists = 0
        public init() {}
    }

    public var tracks = 0
    public var marks = 0
    public var tracksWithGrid = 0
    public var tracksWithoutGrid = 0
    public var folders = 0
    public var playlists = 0
    public var playlistEntries = 0
    public var omitted = Omitted()
    public init() {}
}

/// 라이브러리 XML 내보내기 진행(읽기·그리드 읽기·쓰기)
public struct LibraryXMLProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case readingLibrary, readingGrids, writing }
    public var phase: Phase
    public var done: Int
    public var total: Int
    public init(phase: Phase, done: Int, total: Int) { self.phase = phase; self.done = done; self.total = total }
}

/// 내보낼 파일을 쓸 수 없는 이유. 무엇을 하면 되는지까지 한 문장이다.
public struct LibraryXMLOutputError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
    public var description: String { reason }
}

/// rekordbox XML을 읽지 못한 이유(문서가 깨졌거나 rekordbox XML이 아님)
public struct XMLReadError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
    public var description: String { reason }
}

/// rekordbox가 XML에 적는 표시 모양(#258). 라이브러리 XML 내보내기와 가져오기 비교가 같은 규칙을 쓴다.
/// rekordbox 7.2.18이 내보낸 XML과 견준 결과(2026-11-06)다.
public enum LibraryXMLDisplay {
    private static let tabs = CharacterSet(charactersIn: "\t")

    /// 글자 칸(`Name`·`Artist`·`Composer`·`Album`·`Genre`·`Comments`·`Remixer`·`Label`)의 앞뒤 **탭**을 뺀다. 스페이스와 가운데 글자는 그대로 둔다.
    /// - 확인: `Name`·`Genre`의 앞뒤 탭을 rekordbox는 빼고 내보냈다. 앞뒤 스페이스는 이름·장르·아티스트·앨범·코멘트 모두 그대로 내보냈다.
    /// - 추정: `Name`·`Genre` 밖의 글자 칸도 탭을 뺀다. 그런 값이 없어 견주지 못했다. 탭 아닌 다른 공백류(줄바꿈 등)도 견주지 못했다.
    public static func text(_ value: String) -> String {
        value.trimmingCharacters(in: tabs)
    }

    /// `Tonality`: DB에 옛 표기(`G`·`Em`)로 남은 키를 rekordbox 화면 표기(Camelot, `9B`·`9A`)로 바꾼다. 바꿀 수 없는 값은 그대로 둔다.
    /// - 확인: `G` → `9B`, `Em` → `9A`. 이 라이브러리의 화면 표기는 Camelot이다(`KeyNotation`).
    /// - 추정: 다른 옛 표기도 같은 규칙(Camelot 5도권)을 쓴다.
    public static func tonality(_ key: String) -> String {
        KeyNotation.camelot(from: key) ?? key
    }

    /// `Rating`: 별 수(0~5, DB 값) → XML 척도(0·51·102·153·204·255). 확인: rekordbox는 모든 곡에 적고 값이 DB 평점과 모두 맞았다.
    public static func rating(stars: Int) -> Int {
        min(max(stars, 0), 5) * 51
    }
}
