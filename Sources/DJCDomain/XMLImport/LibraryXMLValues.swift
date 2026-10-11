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
