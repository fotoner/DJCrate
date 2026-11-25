import Foundation

/// 곡 검색 규칙 하나(#350). 곡 목록·중복 후보 검색·CLI `djc search`가 같이 쓴다.
/// 검색 키는 곡 하나당 한 번 만들어 두고(`TrackRow`는 만들 때), 검색어 쪽만 입력마다 새로 계산한다.
/// 저장 대기 중인 태그 편집이 있는 곡만 편집 값을 얹은 키를 검색 때 만든다(#376).
public enum TrackSearch {
    /// 키에서 칸을 가르는 글자. 검색어에서는 낱말 경계로 쳐서 낱말 하나가 칸 사이에 걸쳐 맞지 않는다.
    private static let fieldSeparator = "\u{1F}"

    /// 같은 모양으로 맞춘다: 소문자, NFC. 키와 검색어에 똑같이 쓴다.
    /// 한글 파일 이름은 macOS 파일 시스템에서 NFD로 들어오고 IME는 NFC로 친다. Swift의 `String.contains`는 이 둘을 같게 보지만,
    /// 글자를 같은 조각으로 고정해 두면 비교 방식(바이트 검색 등)이 바뀌어도 맞는다. 시험은 이 변환을 글자 조각으로 본다.
    static func normalized(_ text: String) -> String {
        text.lowercased().precomposedStringWithCanonicalMapping
    }

    /// 검색 키: 제목·아티스트·앨범·앨범 아티스트·작곡가·코멘트·장르·파일 이름.
    /// rekordbox가 암호화해 둔 Spotify 곡의 제목·아티스트·앨범·앨범 아티스트는 뺀다(`TrackRow`가 화면에 비우는 칸과 같다).
    /// 파일 이름은 폴더를 뺀 이름이다. 스트리밍 곡은 파일이 없어 뺀다.
    public static func key(for track: Track) -> String { key(for: track, edits: [:]) }

    /// 저장 대기 중인 태그 편집(`DraftEdits`)을 얹은 검색 키(#376). 고친 칸만 편집 값으로 바꾸고 나머지(고치지 않은 칸·파일 이름)는 곡의 값이다.
    public static func key(for track: Track, edits: DraftEdits) -> String {
        let encrypted = track.title.hasPrefix("$A7:")
        func field(_ key: TagFields.Key, _ stored: String?) -> String { edits[key] ?? stored ?? "" }
        let fields = [encrypted ? "" : field(.title, track.title), encrypted ? "" : field(.artist, track.artist),
                      encrypted ? "" : field(.album, track.album), encrypted ? "" : field(.albumArtist, track.albumArtist),
                      field(.composer, track.composer), field(.comment, track.comment), field(.genre, track.genre),
                      fileName(of: track)]
        return normalized(fields.joined(separator: fieldSeparator))
    }

    /// 검색 키에 드는 태그 칸. 초안이 이 칸을 고쳤을 때만 검색 키가 달라진다.
    static let searchedDraftKeys: [TagFields.Key] = [.title, .artist, .album, .albumArtist, .composer, .comment, .genre]

    /// 초안이 고친 검색 칸의 값(저장 대기 값). 고친 칸이 없으면 빈 사전이다.
    public typealias DraftEdits = [TagFields.Key: String]

    public static func edits(of draft: TagDraft) -> DraftEdits {
        var edits: DraftEdits = [:]
        for key in searchedDraftKeys where draft.base[key] != draft.fields[key] { edits[key] = draft.fields[key] }
        return edits
    }

    /// 곡 UUID별 저장 대기 검색 값. 검색 칸을 고친 초안만 든다(그 곡만 검색 키를 다시 만든다).
    public static func edits(of drafts: [String: TagDraft]) -> [String: DraftEdits] {
        drafts.compactMapValues { draft in
            let edits = edits(of: draft)
            return edits.isEmpty ? nil : edits
        }
    }

    /// 폴더를 뺀 파일 이름(확장자 포함). 스트리밍 곡은 빈 글자.
    static func fileName(of track: Track) -> String {
        guard !track.isStreaming else { return "" }
        let path = track.folderPath
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return path }
        return String(path[path.utf8.index(after: slash)...])
    }

    /// 입력한 검색어. 띄어 쓴 낱말로 쪼개 두고, 키에 낱말이 모두 들어 있어야 맞는다(AND).
    public struct Query: Sendable, Equatable {
        public let terms: [String]

        public init(_ text: String) {
            terms = Self.split(normalized(text))
        }

        /// 낱말이 없으면(빈 검색어·공백뿐) 모든 곡이 맞는다.
        public var isEmpty: Bool { terms.isEmpty }

        public func matches(key: String) -> Bool {
            terms.allSatisfy { key.contains($0) }
        }

        public func matches(_ track: Track) -> Bool {
            isEmpty || matches(key: TrackSearch.key(for: track))
        }

        /// 표의 줄이 맞는지(#376). 저장된 값 전체로 맞거나, 저장 대기 중인 편집을 얹은 값 전체로 맞으면 맞는다(둘의 낱말을 섞지 않는다).
        /// 편집으로 곡이 목록에서 빠지지 않게 저장된 값도 계속 본다: 목록 구성은 정렬·필터처럼 rekordbox 값이 정한다.
        public func matches(row: TrackRow, edits: DraftEdits?) -> Bool {
            isEmpty || matches(key: row.searchKey) || edits.map { matches(key: TrackSearch.key(for: row.track, edits: $0)) } == true
        }

        private static let boundaries = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: TrackSearch.fieldSeparator))

        /// 공백·탭·줄바꿈·전각 공백과 칸 구분 글자가 낱말 경계다. 앞뒤와 사이의 빈 낱말은 버린다.
        private static func split(_ text: String) -> [String] {
            text.components(separatedBy: boundaries).filter { !$0.isEmpty }
        }
    }
}
