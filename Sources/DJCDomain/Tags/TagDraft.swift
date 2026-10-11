import Foundation

/// 태그 편집기에서 다루는 곡 정보. 반영하면 rekordbox 라이브러리에 쓴다(음원 파일 태그는 그대로 둔다).
public struct TagFields: Codable, Hashable, Sendable {
    public enum Key: String, CaseIterable, Codable, Sendable, Identifiable {
        case title, artist, album, albumArtist, genre, composer, year, trackNumber, comment
        /// 곡의 키(rekordbox `ScaleName`, 예 "8A"). 초안 저장 이름은 musicalKey, 목록의 기존 칸 이름은 "key"로 유지한다.
        /// 옛 칸 순서를 지키려고 맨 뒤에 둔다.
        case musicalKey
        /// 평점(rekordbox `Rating`, 별 수). 값은 "1"~"5", 없으면 빈칸(#65). 옛 칸 순서를 지키려고 키 뒤에 둔다.
        case rating
        /// 곡 색(rekordbox `ColorID` = `djmdColor.ID`, '1'~'8'). 값은 그 번호, 없으면 빈칸(#65).
        case color

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .title: String(ui: "제목")
            case .artist: String(ui: "아티스트")
            case .album: String(ui: "앨범")
            case .albumArtist: String(ui: "앨범 아티스트")
            case .genre: String(ui: "장르")
            case .composer: String(ui: "작곡가")
            case .year: String(ui: "연도")
            case .trackNumber: String(ui: "트랙 번호")
            case .comment: String(ui: "코멘트")
            case .musicalKey: String(ui: "키")
            case .rating: String(ui: "평점")
            case .color: String(ui: "곡 색")
            }
        }

        /// 초안이 고칠 때만 기준과 비교하는 칸. 다른 칸(앨범 관계 등)과 얽히지 않고, 칸이 생기기 전의 초안 파일에는 없어 빈칸으로 읽힌다.
        /// 고치지 않은 초안은 이 칸을 지금 rekordbox 값으로 맞춘다(`TagDraft.adoptingIndependentKeys`, 쓰기의 기준·다시 읽기 비교).
        public static let independent: Set<Key> = [.musicalKey, .rating, .color]
    }

    public var title = ""
    public var artist = ""
    public var album = ""
    public var albumArtist = ""
    public var genre = ""
    public var composer = ""
    public var year = ""
    public var trackNumber = ""
    public var comment = ""
    /// 키가 없는 곡은 빈칸. 쓰기는 Camelot 이름(1A~12B)만 받는다(`KeyNotation.camelotNames`).
    public var musicalKey = ""
    /// 평점 별 수("1"~"5"). 없으면 빈칸(쓰면 `Rating` 0).
    public var rating = ""
    /// 곡 색 번호(`djmdColor.ID`). 없으면 빈칸(쓰면 `ColorID` '0').
    public var color = ""

    public init() {}

    /// 키·평점·곡 색 칸이 없는 옛 초안 파일도 읽는다(없으면 빈칸). 나머지 칸은 예전처럼 모두 있어야 읽는다.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        albumArtist = try c.decode(String.self, forKey: .albumArtist)
        genre = try c.decode(String.self, forKey: .genre)
        composer = try c.decode(String.self, forKey: .composer)
        year = try c.decode(String.self, forKey: .year)
        trackNumber = try c.decode(String.self, forKey: .trackNumber)
        comment = try c.decode(String.self, forKey: .comment)
        musicalKey = try c.decodeIfPresent(String.self, forKey: .musicalKey) ?? ""
        rating = try c.decodeIfPresent(String.self, forKey: .rating) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
    }

    /// rekordbox DB 값에서 시작한다. 파일 태그 대조는 writer 단계에서 한다.
    public init(track: Track) {
        title = track.title
        artist = track.artist ?? ""
        album = track.album ?? ""
        albumArtist = track.albumArtist ?? ""
        genre = track.genre ?? ""
        composer = track.composer ?? ""
        year = track.releaseYear.map(String.init) ?? ""
        trackNumber = track.trackNumber.map(String.init) ?? ""
        comment = track.comment
        musicalKey = track.key ?? ""
        rating = track.rating > 0 ? String(track.rating) : ""
        color = track.colorID ?? ""
    }

    public subscript(key: Key) -> String {
        get {
            switch key {
            case .title: title
            case .artist: artist
            case .album: album
            case .albumArtist: albumArtist
            case .genre: genre
            case .composer: composer
            case .year: year
            case .trackNumber: trackNumber
            case .comment: comment
            case .musicalKey: musicalKey
            case .rating: rating
            case .color: color
            }
        }
        set {
            switch key {
            case .title: title = newValue
            case .artist: artist = newValue
            case .album: album = newValue
            case .albumArtist: albumArtist = newValue
            case .genre: genre = newValue
            case .composer: composer = newValue
            case .year: year = newValue
            case .trackNumber: trackNumber = newValue
            case .comment: comment = newValue
            case .musicalKey: musicalKey = newValue
            case .rating: rating = newValue
            case .color: color = newValue
            }
        }
    }
}

public struct TagDraft: Codable, Equatable, Sendable {
    public var trackUUID: String
    public var base: TagFields
    public var fields: TagFields

    public init(track: Track) {
        self.init(trackUUID: track.uuid, base: TagFields(track: track))
    }

    /// base(초안을 만들 때의 rekordbox 값)에서 시작한다.
    public init(trackUUID: String, base: TagFields) {
        self.trackUUID = trackUUID
        self.base = base
        fields = base
    }

    public var changedKeys: [TagFields.Key] { TagFields.Key.allCases.filter { base[$0] != fields[$0] } }
    public var hasChanges: Bool { base != fields }

    /// 쓰는 칸과 그 칸의 앨범 관계만 충돌을 본다. 코멘트 초안은 다른 정보 변경을 덮지 않는다.
    public func conflictingKeys(with current: TagFields) -> [TagFields.Key] {
        var protected = Set(changedKeys)
        let albumKeys: Set<TagFields.Key> = [.artist, .album, .albumArtist]
        if !protected.isDisjoint(with: albumKeys) { protected.formUnion(albumKeys) }
        return TagFields.Key.allCases.filter {
            protected.contains($0) && current[$0] != base[$0] && current[$0] != fields[$0]
        }
    }

    /// 키를 안 고친 초안의 키 칸(기준·내용)을 지금 rekordbox 값으로 맞춘다. 키 칸이 없던 때의 초안(읽으면 빈칸)이나 그 뒤 rekordbox에서
    /// 키가 바뀐 초안이 키를 "고친" 것처럼 보이거나 기준이 어긋난 것으로 막히지 않게 한다. 키를 고친 초안은 그대로 돌려준다.
    public func adoptingMusicalKey(of current: TagFields) -> TagDraft { adopting([.musicalKey], of: current) }

    /// 고치지 않은 독립 칸(키·평점·곡 색, `TagFields.Key.independent`)의 기준·내용을 지금 rekordbox 값으로 맞춘다. 그 칸이 없던 때의 초안
    /// (읽으면 빈칸)이나 그 뒤 rekordbox에서 그 칸만 바뀐 초안이 그 칸을 "고친" 것처럼 보이거나 기준이 어긋난 것으로 막히지 않게 한다.
    public func adoptingIndependentKeys(of current: TagFields) -> TagDraft { adopting(TagFields.Key.independent, of: current) }

    private func adopting(_ keys: Set<TagFields.Key>, of current: TagFields) -> TagDraft {
        var adopted = self
        for key in TagFields.Key.allCases where keys.contains(key) && base[key] == fields[key] && base[key] != current[key] {
            adopted.base[key] = current[key]
            adopted.fields[key] = current[key]
        }
        return adopted
    }

    /// 같은 칸의 실제 충돌은 보존하고, 안 고친 칸만 최신값으로 맞춘다.
    public func rebased(onto current: TagFields) -> TagDraft? {
        guard conflictingKeys(with: current).isEmpty else { return nil }
        var rebased = TagDraft(trackUUID: trackUUID, base: current)
        for key in changedKeys { rebased.fields[key] = fields[key] }
        return rebased
    }

    /// 쓰기 전 확인할 문제.
    public var issues: [String] {
        var issues: [String] = []
        if !fields.year.isEmpty, Int(fields.year) == nil { issues.append(String(ui: "연도를 숫자로 고친 뒤 rekordbox에 쓰세요")) }
        if !fields.trackNumber.isEmpty, Int(fields.trackNumber) == nil { issues.append(String(ui: "트랙 번호를 숫자로 고친 뒤 rekordbox에 쓰세요")) }
        if fields.title.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(String(ui: "제목을 입력한 뒤 rekordbox에 쓰세요")) }
        for key in [TagFields.Key.year, .trackNumber] where changedKeys.contains(key) {
            if let value = Int(fields[key]), value < 0 {
                issues.append(String(ui: "\(key.label)를 0 이상으로 고친 뒤 rekordbox에 쓰세요"))
            }
        }
        // 키는 고쳤을 때만 이름을 본다: 읽은 키가 옛 표기(Em)나 삭제 표시 줄의 이름이어도 다른 칸은 쓸 수 있어야 한다.
        if changedKeys.contains(.musicalKey), !fields.musicalKey.isEmpty, !KeyNotation.camelotNames.contains(fields.musicalKey) {
            issues.append(String(ui: "키는 1A~12B 중에서 고르거나 비운 뒤 rekordbox에 쓰세요"))
        }
        if changedKeys.contains(.rating), TrackRating.accepted(fields.rating) != fields.rating {
            issues.append(String(ui: "평점은 별 1~5개 중에서 고르거나 비운 뒤 rekordbox에 쓰세요"))
        }
        if changedKeys.contains(.color), !fields.color.isEmpty, !TrackColor.ids.contains(fields.color) {
            issues.append(String(ui: "곡 색은 rekordbox의 여덟 색 중에서 고르거나 비운 뒤 rekordbox에 쓰세요"))
        }
        if changedKeys.contains(.albumArtist), fields.album.isEmpty, !fields.albumArtist.isEmpty {
            issues.append(String(ui: "앨범이 없는 곡에는 앨범 아티스트를 쓸 수 없으니 앨범을 입력하거나 앨범 아티스트 초안을 되돌리세요"))
        }
        return issues
    }
}

