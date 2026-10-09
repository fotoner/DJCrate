import CryptoKit
import Foundation

/// 두 USB 모델을 표·칸 단위로 비교한다(쓰기 뒤 확인·실험 비교).
/// 결과에는 칸 이름·ID·수만 넣는다. 글자 칸 값(제목·이름·경로)은 넣지 않는다.
public enum UsbLibraryDiff {
    public struct Options: Sendable {
        /// 곡은 path, artist·album·genre·key·label은 name(NFC), 목록은 (부모 이름 경로, 이름)으로 짝짓고
        /// 참조 칸은 짝지은 쪽 id로 바꿔 비교한다
        public var ignoreIDs = false
        /// analysisDataPath는 파일 이름(ANLZ000N.DAT)만 비교
        public var ignoreAnalysisFolder = false
        public var skipTables: Set<String> = []
        /// 이 형식이 담는 칸과 이 형식 몫(presentIn·항목·기기 칸·기록)만 비교한다
        public var formats: Set<UsbFormat> = UsbFormat.defaultSet

        public init(ignoreIDs: Bool = false, ignoreAnalysisFolder: Bool = false, skipTables: Set<String> = [],
                    formats: Set<UsbFormat> = UsbFormat.defaultSet) {
            self.ignoreIDs = ignoreIDs
            self.ignoreAnalysisFolder = ignoreAnalysisFolder
            self.skipTables = skipTables
            self.formats = formats
        }
    }

    public struct TableSummary: Sendable, Hashable {
        public var table: String
        /// 짝지은 행 중 모든 칸이 같은 행
        public var matchedRows: Int
        public var leftRows: Int
        public var rightRows: Int
        /// 칸 이름 → 다른 행 수. 한쪽에만 있는 행은 `onlyLeft`·`onlyRight`
        public var differingFields: [String: Int]

        public init(table: String, matchedRows: Int, leftRows: Int, rightRows: Int, differingFields: [String: Int]) {
            self.table = table
            self.matchedRows = matchedRows
            self.leftRows = leftRows
            self.rightRows = rightRows
            self.differingFields = differingFields
        }
    }

    public struct Difference: Sendable, Hashable {
        public var table: String
        /// id 또는 자연 키 해시(이름·경로는 드러내지 않는다)
        public var key: String
        public var field: String

        public init(table: String, key: String, field: String) {
            self.table = table
            self.key = key
            self.field = field
        }
    }

    /// 한쪽에만 있는 행의 칸 이름
    public static let onlyLeft = "onlyLeft"
    public static let onlyRight = "onlyRight"

    public static func compare(_ a: UsbLibrary, _ b: UsbLibrary, options: Options) -> (summaries: [TableSummary], differences: [Difference]) {
        let formats = options.formats
        let inFormats: (Set<UsbFormat>) -> Bool = { !$0.isDisjoint(with: formats) }
        // 비교하지 않는 형식의 곡·목록·연결·기록은 뺀다
        func restricted(_ library: UsbLibrary) -> UsbLibrary {
            var library = library
            library.tracks = library.tracks.filter { inFormats($0.presentIn) }
            library.playlists = library.playlists.filter { inFormats($0.presentIn) }
            library.myTagLinks = library.myTagLinks.filter { inFormats($0.presentIn) }
            library.histories = library.histories.filter { formats.contains($0.format) }
            library.unknownRows = library.unknownRows.filter { formats.contains($0.format) }
            if options.ignoreAnalysisFolder {
                for index in library.tracks.indices { library.tracks[index].analysisDataPath = fileName(library.tracks[index].analysisDataPath) }
            }
            return library
        }
        let natural = options.ignoreIDs
        let remapped = natural ? remap(b, onto: a, formats: formats) : b
        let left = restricted(a), right = restricted(remapped)
        let ordered = UsbFormat.allCases.filter(formats.contains)
        var comparer = Comparer(skipTables: options.skipTables)

        func fields<Row>(_ rules: [UsbFieldRule<Row>]) -> [Field<Row>] {
            rules.filter { !$0.formats.isDisjoint(with: formats) }.map { Field(name: $0.name, same: $0.same) }
        }
        func named(_ table: String, _ left: [UsbNamedRow], _ right: [UsbNamedRow]) {
            comparer.table(table, left, right, key: { natural ? NaturalKeys.hash("name", $0.name) : String($0.id) },
                           fields: fields(UsbFieldFormats.namedRow))
        }

        var trackFields = fields(UsbFieldFormats.track)
        trackFields.append(Field(name: "presentIn") { $0.presentIn.intersection(formats) == $1.presentIn.intersection(formats) })
        for format in ordered {
            trackFields.append(Field(name: "deviceFields.\(format.rawValue)") { $0.deviceFields[format] == $1.deviceFields[format] })
        }
        comparer.table("content", left.tracks, right.tracks,
                       key: { natural ? NaturalKeys.hash("path", $0.path) : String($0.id) }, fields: trackFields)
        named("artist", left.artists, right.artists)
        comparer.table("album", left.albums, right.albums, key: { natural ? NaturalKeys.hash("name", $0.name) : String($0.id) },
                       fields: fields(UsbFieldFormats.album))
        named("genre", left.genres, right.genres)
        named("key", left.keys, right.keys)
        named("label", left.labels, right.labels)
        comparer.table("color", left.colors, right.colors, key: { String($0.id) }, fields: fields(UsbFieldFormats.namedRow))
        comparer.table("image", left.images, right.images, key: { String($0.id) }, fields: fields(UsbFieldFormats.image))

        var playlistFields = fields(UsbFieldFormats.playlist)
        playlistFields.append(Field(name: "presentIn") { $0.presentIn.intersection(formats) == $1.presentIn.intersection(formats) })
        for format in ordered {
            playlistFields.append(Field(name: "sortOrder.\(format.rawValue)") { $0.sortOrder[format] == $1.sortOrder[format] })
            // 항목이 없는 것과 빈 항목은 같다(형식 리더마다 폴더를 다르게 둘 수 있다)
            playlistFields.append(Field(name: "entries.\(format.rawValue)") { ($0.entries[format] ?? []) == ($1.entries[format] ?? []) })
            // 합친 모델은 대표 번호로 짝짓고 형식 번호도 견준다(#233). ID를 무시할 때는 번호를 보지 않는다
            if !natural { playlistFields.append(Field(name: "id.\(format.rawValue)") { $0.id(in: format) == $1.id(in: format) }) }
        }
        // 오른쪽 id는 이미 왼쪽 id로 옮겼다(짝이 없으면 음수). 그래서 두 쪽 경로 표를 합쳐도 id가 겹치지 않는다.
        // 경로는 형식으로 거르기 전 목록에서 구한다(짝지을 때와 같은 키라야 짝과 비교 순서가 맞는다).
        let playlistPaths = natural
            ? NaturalKeys.playlistPaths(a.playlists).merging(NaturalKeys.playlistPaths(remapped.playlists)) { first, _ in first } : [:]
        comparer.table("playlist", left.playlists, right.playlists,
                       key: { natural ? NaturalKeys.hash("playlist", playlistPaths[$0.id] ?? $0.name) : String($0.id) },
                       fields: playlistFields)
        comparer.table("myTag", left.myTags, right.myTags, key: { String($0.id) }, fields: fields(UsbFieldFormats.myTag))
        comparer.table("myTag_content", left.myTagLinks, right.myTagLinks,
                       key: { "\($0.myTagID):\($0.contentID)" },
                       fields: [Field(name: "presentIn") { $0.presentIn.intersection(formats) == $1.presentIn.intersection(formats) }])
        comparer.table("menuItem", left.menuItems, right.menuItems, key: { String($0.id) }, fields: fields(UsbFieldFormats.menuItem))
        comparer.table("category", left.categories, right.categories, key: { String($0.id) }, fields: fields(UsbFieldFormats.category))
        comparer.table("sort", left.sorts, right.sorts, key: { String($0.id) }, fields: fields(UsbFieldFormats.sort))
        comparer.table("property", [left.property], [right.property], key: { _ in "property" }, fields: fields(UsbFieldFormats.property))
        comparer.table("history", left.histories, right.histories,
                       key: { "\($0.format.rawValue):\($0.id)" },
                       fields: [Field(name: "name") { $0.name == $1.name }, Field(name: "entries") { $0.entries == $1.entries }])
        comparer.table("unknownRows", left.unknownRows, right.unknownRows,
                       key: { "\($0.format.rawValue):\($0.file):\($0.tableType)" }, fields: [Field(name: "liveRows") { $0.liveRows == $1.liveRows }])
        // pdb에만 있는 표. 죽은 행 ID는 ID 자체라 ID를 무시할 때는 보지 않는다.
        if formats.contains(.deviceLibrary) {
            if !options.ignoreIDs {
                comparer.table("deadIDs", left.deadIDs.sorted { $0.key < $1.key }, right.deadIDs.sorted { $0.key < $1.key },
                               key: { $0.key }, fields: [Field(name: "ids") { $0.value == $1.value }])
            }
            comparer.table("trackRowExtras", left.trackRowExtras.sorted { $0.key < $1.key }, right.trackRowExtras.sorted { $0.key < $1.key },
                           key: { String($0.key) }, fields: [Field(name: "extras") { $0.value == $1.value }])
        }
        return (comparer.summaries, comparer.differences)
    }

    static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// 오른쪽 모델의 id와 참조를 자연 키로 짝지은 왼쪽 id로 옮긴다. 짝이 없는 id는 왼쪽에 없는 음수로 옮겨 우연히 같아지지 않게 한다.
    /// 곡·목록은 `formats`에 드는 행(비교하는 행)끼리 먼저 짝짓고, 나머지는 참조를 옮기려고 따로 짝짓는다.
    static func remap(_ right: UsbLibrary, onto left: UsbLibrary, formats: Set<UsbFormat> = UsbFormat.defaultSet) -> UsbLibrary {
        /// 같은 키가 여럿이면 나온 순서대로 짝짓는다(오른쪽 n번째 ↔ 왼쪽 n번째). `Comparer.unique`의 "#n"과 같은 규칙이라야
        /// 이름이 같은 앨범·아티스트·폴더가 있어도 같은 라이브러리끼리 차이가 나지 않는다.
        func pairs(_ right: [(id: Int, key: String)], _ left: [(id: Int, key: String)]) -> [Int: Int] {
            var leftByKey: [String: [Int]] = [:]
            for row in left { leftByKey[row.key, default: []].append(row.id) }
            var seen: [String: Int] = [:], map: [Int: Int] = [:]
            for row in right {
                let occurrence = seen[row.key, default: 0]
                seen[row.key] = occurrence + 1
                if map[row.id] == nil, let ids = leftByKey[row.key], occurrence < ids.count { map[row.id] = ids[occurrence] }
            }
            return map
        }
        typealias Keyed = (id: Int, key: String, compared: Bool)
        func splitPairs(_ right: [Keyed], _ left: [Keyed]) -> [Int: Int] {
            func part(_ rows: [Keyed], _ wanted: Bool) -> [(id: Int, key: String)] {
                rows.filter { $0.compared == wanted }.map { ($0.id, $0.key) }
            }
            return pairs(part(right, true), part(left, true)).merging(pairs(part(right, false), part(left, false))) { first, _ in first }
        }
        func namedPairs(_ right: [UsbNamedRow], _ left: [UsbNamedRow]) -> [Int: Int] {
            pairs(right.map { ($0.id, UsbLayout.nfc($0.name)) }, left.map { ($0.id, UsbLayout.nfc($0.name)) })
        }
        let compared: (Set<UsbFormat>) -> Bool = { !$0.isDisjoint(with: formats) }
        let tracks = splitPairs(right.tracks.map { ($0.id, UsbLayout.nfc($0.path), compared($0.presentIn)) },
                                left.tracks.map { ($0.id, UsbLayout.nfc($0.path), compared($0.presentIn)) })
        let artists = namedPairs(right.artists, left.artists)
        let albums = pairs(right.albums.map { ($0.id, UsbLayout.nfc($0.name)) }, left.albums.map { ($0.id, UsbLayout.nfc($0.name)) })
        let genres = namedPairs(right.genres, left.genres)
        let keys = namedPairs(right.keys, left.keys)
        let labels = namedPairs(right.labels, left.labels)
        let rightPaths = NaturalKeys.playlistPaths(right.playlists), leftPaths = NaturalKeys.playlistPaths(left.playlists)
        let playlists = splitPairs(right.playlists.map { ($0.id, rightPaths[$0.id] ?? "", compared($0.presentIn)) },
                                   left.playlists.map { ($0.id, leftPaths[$0.id] ?? "", compared($0.presentIn)) })

        func move(_ id: Int, _ map: [Int: Int]) -> Int { map[id] ?? (-1 - id) }
        // 참조 칸의 0은 "없음"이라 그대로 둔다(목록 parentID·작사가 artist 등)
        func move(_ id: Int?, _ map: [Int: Int]) -> Int? { id.map { $0 == 0 ? 0 : move($0, map) } }

        var result = right
        result.tracks = right.tracks.map { track in
            var track = track
            track.id = move(track.id, tracks)
            track.artistID = move(track.artistID, artists)
            track.remixerID = move(track.remixerID, artists)
            track.originalArtistID = move(track.originalArtistID, artists)
            track.composerID = move(track.composerID, artists)
            track.lyricistArtistID = move(track.lyricistArtistID, artists)
            track.albumID = move(track.albumID, albums)
            track.genreID = move(track.genreID, genres)
            track.labelID = move(track.labelID, labels)
            track.keyID = move(track.keyID, keys)
            return track
        }
        func moved(_ rows: [UsbNamedRow], _ map: [Int: Int]) -> [UsbNamedRow] {
            rows.map { UsbNamedRow(id: move($0.id, map), name: $0.name, nameForSearch: $0.nameForSearch) }
        }
        result.artists = moved(right.artists, artists)
        result.genres = moved(right.genres, genres)
        result.keys = moved(right.keys, keys)
        result.labels = moved(right.labels, labels)
        result.albums = right.albums.map { album in
            var album = album
            album.id = move(album.id, albums)
            album.artistID = move(album.artistID, artists)
            return album
        }
        result.playlists = right.playlists.map { playlist in
            var playlist = playlist
            playlist.id = move(playlist.id, playlists)
            playlist.parentID = move(Optional(playlist.parentID), playlists) ?? 0
            playlist.entries = playlist.entries.mapValues { $0.map { move($0, tracks) } }
            return playlist
        }
        result.myTagLinks = right.myTagLinks.map { link in
            var link = link
            link.contentID = move(link.contentID, tracks)
            return link
        }
        result.histories = right.histories.map { history in
            var history = history
            history.entries = history.entries.map { move($0, tracks) }
            return history
        }
        result.trackRowExtras = Dictionary(right.trackRowExtras.map { (move($0.key, tracks), $0.value) }) { first, _ in first }
        return result
    }

    struct Field<Row> {
        let name: String
        let same: (Row, Row) -> Bool
    }

    /// ID를 무시할 때 쓰는 자연 키. 이름·경로는 해시로만 키에 넣는다.
    enum NaturalKeys {
        /// 목록 id → 맨 위부터 이름을 이은 경로
        static func playlistPaths(_ playlists: [UsbPlaylist]) -> [Int: String] {
            var byID: [Int: UsbPlaylist] = [:]
            for playlist in playlists where byID[playlist.id] == nil { byID[playlist.id] = playlist }
            var paths: [Int: String] = [:]
            for playlist in playlists {
                var names = [UsbLayout.nfc(playlist.name)], current = playlist, seen: Set<Int> = [playlist.id]
                // 부모를 따라 올라간다(고리가 있으면 멈춘다)
                while current.parentID != 0, let parent = byID[current.parentID], seen.insert(parent.id).inserted {
                    names.insert(UsbLayout.nfc(parent.name), at: 0)
                    current = parent
                }
                paths[playlist.id] = names.joined(separator: "\u{1F}")
            }
            return paths
        }

        static func hash(_ kind: String, _ text: String) -> String {
            let digest = SHA256.hash(data: Data((kind + "\u{1F}" + UsbLayout.nfc(text)).utf8))
            return kind + ":" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Comparer {
        let skipTables: Set<String>
        var summaries: [TableSummary] = []
        var differences: [Difference] = []

        init(skipTables: Set<String>) {
            self.skipTables = skipTables
        }

        mutating func table<Row>(_ name: String, _ left: [Row], _ right: [Row], key: (Row) -> String, fields: [Field<Row>]) {
            guard !skipTables.contains(name) else { return }
            let leftKeys = Self.unique(left.map(key)), rightKeys = Self.unique(right.map(key))
            let rightByKey = Dictionary(zip(rightKeys, right)) { first, _ in first }
            var summary = TableSummary(table: name, matchedRows: 0, leftRows: left.count, rightRows: right.count, differingFields: [:])
            func record(_ key: String, _ field: String) {
                differences.append(Difference(table: name, key: key, field: field))
                summary.differingFields[field, default: 0] += 1
            }
            for (rowKey, row) in zip(leftKeys, left) {
                guard let other = rightByKey[rowKey] else { record(rowKey, UsbLibraryDiff.onlyLeft); continue }
                let differing = fields.filter { !$0.same(row, other) }
                if differing.isEmpty { summary.matchedRows += 1 }
                for field in differing { record(rowKey, field.name) }
            }
            let leftSet = Set(leftKeys)
            for rowKey in rightKeys where !leftSet.contains(rowKey) { record(rowKey, UsbLibraryDiff.onlyRight) }
            summaries.append(summary)
        }

        /// 같은 키가 여럿이면 둘째부터 "#2"…를 붙인다
        static func unique(_ keys: [String]) -> [String] {
            var counts: [String: Int] = [:]
            return keys.map { key in
                counts[key, default: 0] += 1
                return counts[key]! == 1 ? key : "\(key)#\(counts[key]!)"
            }
        }
    }
}
