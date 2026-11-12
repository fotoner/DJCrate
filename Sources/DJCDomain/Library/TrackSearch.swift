import Foundation

/// 곡 검색 규칙 하나(#350). 곡 목록·중복 후보 검색·CLI `djc search`가 같이 쓴다.
/// 검색 키는 곡 하나당 한 번 만들어 두고(`TrackRow`는 만들 때), 검색어 쪽만 입력마다 새로 계산한다.
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
    public static func key(for track: Track) -> String {
        let encrypted = track.title.hasPrefix("$A7:")
        let fields = [encrypted ? "" : track.title, encrypted ? "" : (track.artist ?? ""), encrypted ? "" : (track.album ?? ""),
                      encrypted ? "" : (track.albumArtist ?? ""), track.composer ?? "", track.comment, track.genre ?? "",
                      fileName(of: track)]
        return normalized(fields.joined(separator: fieldSeparator))
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

        private static let boundaries = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: TrackSearch.fieldSeparator))

        /// 공백·탭·줄바꿈·전각 공백과 칸 구분 글자가 낱말 경계다. 앞뒤와 사이의 빈 낱말은 버린다.
        private static func split(_ text: String) -> [String] {
            text.components(separatedBy: boundaries).filter { !$0.isEmpty }
        }
    }
}
