import DJCDomain
import Foundation

/// rekordbox XML(`DJ_PLAYLISTS`)을 읽어 가져오기 비교 모델(`XMLLibrary`)로 만든다(#72). 파일을 읽기만 한다.
///
/// 파일은 흘려 읽는다(`XMLParser` + 입력 흐름): 수만 곡짜리 파일도 문서 전체를 트리로 들고 있지 않고 곡 모델만 남긴다.
/// 모르는 요소·값은 막지 않고 건너뛰며 `XMLLibrary.skipped`에 센다. 문서가 깨졌거나 rekordbox XML이 아닐 때만 던진다.
public enum RekordboxXMLReader {
    public typealias ReadError = XMLReadError

    public static func read(url: URL) throws -> XMLLibrary {
        guard let stream = InputStream(url: url) else {
            throw ReadError(reason: String(ui: "XML 파일을 열지 못했습니다. 파일 위치와 권한을 확인하세요"))
        }
        return try read(parser: XMLParser(stream: stream))
    }

    public static func read(data: Data) throws -> XMLLibrary { try read(parser: XMLParser(data: data)) }

    static func read(parser: XMLParser) throws -> XMLLibrary {
        let reader = Reader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if reader.cancelled { throw CancellationError() }
        if let error = reader.error { throw error }
        guard ok else {
            throw ReadError(reason: String(ui: "XML 파일을 읽지 못했습니다(\(parser.lineNumber)번째 줄). 파일이 깨지지 않았는지 확인하세요"))
        }
        guard reader.sawRoot else {
            throw ReadError(reason: String(ui: "rekordbox XML(DJ_PLAYLISTS) 파일이 아닙니다. rekordbox 형식으로 내보낸 XML을 고르세요"))
        }
        return XMLLibrary(tracks: reader.tracks, lists: reader.lists, skipped: reader.skipped)
    }

    // MARK: - 값 읽기

    /// XML 평점(0·51·102·153·204·255) → 별 수("1"~"5", 0은 빈칸). 범위 밖이면 nil.
    static func stars(fromRating value: String) -> String? {
        guard let number = Int(value.trimmingCharacters(in: .whitespaces)), (0...255).contains(number) else { return nil }
        let stars = Int((Double(number) / 51).rounded())
        return stars == 0 ? "" : String(stars)
    }

    /// 태그로 읽는 TRACK 칸
    static let tagAttributes: [(String, TagFields.Key)] = [
        ("Name", .title), ("Artist", .artist), ("Composer", .composer), ("Album", .album), ("Genre", .genre),
        ("Comments", .comment), ("Tonality", .musicalKey),
    ]

    final class Reader: NSObject, XMLParserDelegate {
        final class NodeBuilder {
            let name: String
            let isFolder: Bool
            let keyType: Int
            var children: [NodeBuilder] = []
            var entries: [String] = []
            init(name: String, isFolder: Bool, keyType: Int) { self.name = name; self.isFolder = isFolder; self.keyType = keyType }
            var node: XMLLibrary.Node {
                isFolder ? XMLLibrary.Node(name: name, children: children.map(\.node)) : XMLLibrary.Node(name: name, entries: entries)
            }
        }

        enum Frame {
            case document, collection, track, playlists, root, node(NodeBuilder), entry, skip, leaf
        }

        var tracks: [XMLLibrary.Track] = []
        var lists: [XMLLibrary.Node] = []
        var skipped: [XMLLibrary.Skip: Int] = [:]
        var sawRoot = false
        var error: ReadError?
        var cancelled = false

        private var stack: [Frame] = []
        private var keys: Set<String> = []
        private var keyByLocation: [String: String] = [:]
        /// 이 곡의 TEMPO를 버렸는가(박자·값을 읽지 못함)
        private var dropTempos = false
        private var rootNodes: [NodeBuilder] = []

        func count(_ skip: XMLLibrary.Skip) { skipped[skip, default: 0] += 1 }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            guard let parent = stack.last else {
                guard name == "DJ_PLAYLISTS" else {
                    error = ReadError(reason: String(ui: "rekordbox XML(DJ_PLAYLISTS) 파일이 아닙니다. rekordbox 형식으로 내보낸 XML을 고르세요"))
                    parser.abortParsing()
                    return
                }
                sawRoot = true
                stack.append(.document)
                return
            }
            let frame: Frame
            switch (parent, name) {
            case (.document, "PRODUCT"): frame = .leaf
            case (.document, "COLLECTION"): frame = .collection
            case (.document, "PLAYLISTS"): frame = .playlists
            case (.collection, "TRACK"):
                startTrack(attributes)
                if tracks.count % 500 == 0, Task.isCancelled { cancelled = true; parser.abortParsing() }
                frame = .track
            case (.track, "TEMPO"): readTempo(attributes); frame = .leaf
            case (.track, "POSITION_MARK"): readMark(attributes); frame = .leaf
            case (.playlists, "NODE"): frame = .root
            case (.root, "NODE"), (.node, "NODE"):
                frame = startNode(attributes, parent: parent)
            case let (.node(builder), "TRACK"):
                addEntry(attributes["Key"] ?? "", to: builder)
                frame = .entry
            case (.skip, _): frame = .skip
            default:
                count(.unknownElement)
                frame = .skip
            }
            stack.append(frame)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard let frame = stack.popLast() else { return }
            switch frame {
            case .track:
                if dropTempos { tracks[tracks.count - 1].tempos = [] }
            case .root:
                lists = rootNodes.map(\.node)
            default:
                break
            }
        }

        // MARK: 곡

        private func startTrack(_ attributes: [String: String]) {
            let key = attributes["TrackID"] ?? "#\(tracks.count + 1)"
            let location = attributes["Location"] ?? ""
            let path = XMLTrackMatching.path(fromLocation: location)
            if path == nil { count(.nonFileLocation) }
            var tags: [TagFields.Key: String] = [:]
            for (attribute, tag) in RekordboxXMLReader.tagAttributes {
                if let value = attributes[attribute] { tags[tag] = value }
            }
            for (attribute, tag) in [("Year", TagFields.Key.year), ("TrackNumber", .trackNumber)] {
                guard let value = attributes[attribute] else { continue }
                if Int(value.trimmingCharacters(in: .whitespaces)) != nil { tags[tag] = value } else { count(.invalidValue) }
            }
            if let value = attributes["Rating"] {
                if let stars = RekordboxXMLReader.stars(fromRating: value) { tags[.rating] = stars } else { count(.invalidValue) }
            }
            if let colour = attributes["Colour"], !colour.isEmpty { count(.unverifiedColour) }
            let duration = attributes["TotalTime"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            tracks.append(XMLLibrary.Track(key: key, path: path, tags: tags, duration: duration))
            // 같은 TrackID는 맞추지 않는다(`XMLTrackMatching`). 목록 항목도 그 키로는 곡을 정할 수 없다.
            if !keys.insert(key).inserted { count(.duplicateTrackID) }
            if !location.isEmpty, keyByLocation[location] == nil { keyByLocation[location] = key }
            dropTempos = false
        }

        private func readTempo(_ attributes: [String: String]) {
            guard !dropTempos else { return }
            if let meter = attributes["Metro"], meter != "4/4" {
                count(.unsupportedMeter)
                dropTempos = true
                return
            }
            guard let start = attributes["Inizio"].flatMap(Double.init), let bpm = attributes["Bpm"].flatMap(Double.init), bpm > 0,
                  start.isFinite, bpm.isFinite else {
                count(.invalidValue)
                dropTempos = true
                return
            }
            var beat = 1
            if let text = attributes["Battito"] {
                guard let value = Int(text), (1...4).contains(value) else {
                    count(.invalidValue)
                    dropTempos = true
                    return
                }
                beat = value
            }
            tracks[tracks.count - 1].tempos.append(GridSegment(start: start, bpm: bpm, firstBeatNumber: beat))
        }

        private func readMark(_ attributes: [String: String]) {
            guard let type = attributes["Type"].flatMap({ Int($0) }), type == 0 || type == 4 else {
                count(.unknownMarkType)
                return
            }
            let num = attributes["Num"].flatMap { Int($0) } ?? -1
            let kind: EditableCue.Kind
            switch num {
            case -1: kind = .memory
            case 0...7: kind = .hot(num)
            default:
                count(.hotCueOutOfRange)
                tracks[tracks.count - 1].unreadableMarks += 1
                return
            }
            guard let start = attributes["Start"].flatMap(Double.init), start.isFinite, start >= 0 else {
                count(.invalidValue)
                tracks[tracks.count - 1].unreadableMarks += 1
                return
            }
            var end: Double?
            if type == 4 {
                guard let value = attributes["End"].flatMap(Double.init), value.isFinite, value > start else {
                    count(.invalidValue)
                    tracks[tracks.count - 1].unreadableMarks += 1
                    return
                }
                end = value
            }
            tracks[tracks.count - 1].marks.append(XMLLibrary.Mark(kind: kind, start: start, end: end, name: attributes["Name"] ?? ""))
        }

        // MARK: 재생 목록

        private func startNode(_ attributes: [String: String], parent: Frame) -> Frame {
            let builder: NodeBuilder
            switch attributes["Type"] {
            case "0": builder = NodeBuilder(name: attributes["Name"] ?? "", isFolder: true, keyType: 0)
            case "1": builder = NodeBuilder(name: attributes["Name"] ?? "", isFolder: false, keyType: Int(attributes["KeyType"] ?? "0") ?? 0)
            default:
                count(.unknownNodeType)
                return .skip
            }
            switch parent {
            case let .node(folder) where folder.isFolder: folder.children.append(builder)
            case .root: rootNodes.append(builder)
            default:
                // 재생 목록 안의 NODE는 rekordbox 트리 모양이 아니다
                count(.unknownNodeType)
                return .skip
            }
            return .node(builder)
        }

        private func addEntry(_ key: String, to builder: NodeBuilder) {
            guard !builder.isFolder else { count(.unknownElement); return }
            switch builder.keyType {
            case 0 where keys.contains(key): builder.entries.append(key)
            case 1:
                if let trackKey = keyByLocation[key] { builder.entries.append(trackKey) } else { count(.missingTrackReference) }
            case 0: count(.missingTrackReference)
            default: count(.invalidValue)
            }
        }
    }
}

/// 지금 라이브러리를 가져오기 비교 모델로 읽는다(#72). 전체 내보내기(`RekordboxLibraryXML.load`)와 같은 값을 쓰므로
/// 내보낸 XML을 그대로 가져오면 차이가 없다.
public enum RekordboxXMLImport {
    /// 스냅샷(읽기용 사본)과 분석 파일을 읽는다. `shareRoot`가 nil이면 그리드를 읽지 않고 비교하지도 않는다.
    /// - Parameter xml: 주면 이 XML에 TEMPO가 있는 곡(경로가 맞을 수 있는 곡)의 분석 파일만 읽는다. 나머지 곡은 그리드를 비교하지 않으니 읽지 않는다.
    public static func library(snapshot: URL, shareRoot: URL?, gridsFor xml: XMLLibrary? = nil) throws -> XMLLibrary {
        // 대소문자만 다른 경로도 맞추므로(`XMLTrackMatching`) 접은 키로 고른다.
        let wanted = xml.map { Set($0.tracks.filter { !$0.tempos.isEmpty }.compactMap(\.path).map { XMLTrackMatching.key($0).lowercased() }) }
        let collection = try RekordboxLibraryXML.load(snapshot: snapshot, shareRoot: shareRoot, gridPaths: wanted)
        return library(from: collection, hasGrids: shareRoot != nil)
    }

    public static func library(from collection: RekordboxLibraryXML.Collection, hasGrids: Bool) -> XMLLibrary {
        var contentIDs: [Int: String] = [:]
        let tracks = collection.entries.map { entry -> XMLLibrary.Track in
            contentIDs[entry.trackKey] = entry.track.id
            let fields = TagFields(track: entry.track)
            var tags: [TagFields.Key: String] = [:]
            for key in TagFields.Key.allCases { tags[key] = fields[key] }
            let marks = entry.marks.map { mark in
                XMLLibrary.Mark(kind: mark.num < 0 ? .memory : .hot(mark.num), start: mark.start,
                                end: mark.type == 4 ? mark.end : nil, name: mark.name)
            }
            return XMLLibrary.Track(key: entry.track.id, path: entry.track.folderPath, tags: tags, marks: marks, tempos: entry.tempos,
                                    duration: entry.track.lengthSeconds > 0 ? Double(entry.track.lengthSeconds) : nil)
        }
        func node(_ list: RekordboxLibraryXML.ListNode) -> XMLLibrary.Node {
            if let children = list.children { return XMLLibrary.Node(name: list.name, id: list.id, children: children.map(node)) }
            return XMLLibrary.Node(name: list.name, id: list.id, entries: list.keys.compactMap { contentIDs[$0] })
        }
        return XMLLibrary(tracks: tracks, lists: collection.lists.map(node), hasGrids: hasGrids)
    }
}
