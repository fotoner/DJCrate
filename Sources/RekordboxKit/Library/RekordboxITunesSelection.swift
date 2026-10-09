import DJCDomain
import Foundation

/// rekordbox의 playlists3.sync. 목록 본문이 아니라 iTunes 동기화 선택과 부모 ID만 담는다.
public struct RekordboxITunesSelection: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public let id: String
        public let parentID: String
        public let isFolder: Bool
        public let isSelected: Bool
    }

    public let nodes: [Node]
    public var selectedIDs: Set<String> { Set(nodes.filter { $0.isSelected && $0.id != "0" }.map(\.id)) }

    /// 동기화 파일을 읽지 못함(목록 사본 값이 던지는 오류와 같다)
    public typealias ParseError = ITunesSelectionError

    public static func parse(_ data: Data) throws -> Self {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, reader.hasRoot, reader.hasPlaylists else { throw ParseError.invalidFile }
        return Self(nodes: reader.nodes)
    }

    /// Apple API는 UInt64, rekordbox는 앞의 0을 생략한 16진수로 같은 ID를 나타낸다.
    public static func normalizedID(_ text: String) -> String? { ITunesLibrarySnapshot.normalizedID(text) }

    private final class Reader: NSObject, XMLParserDelegate {
        var nodes: [Node] = []
        var ids = Set<String>()
        var stack: [String] = []
        var hasRoot = false
        var hasPlaylists = false
        var invalid = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            defer { stack.append(name) }
            // 모양이 다른 목록을 '선택 없음'으로 삼키지 않는다. PRODUCT 같은 루트 메타데이터는 허용한다.
            if name == "NODE", stack != ["SYNC_ITUNES_PLAYLIST", "PLAYLISTS"] { invalid = true }
            if stack == ["SYNC_ITUNES_PLAYLIST", "PLAYLISTS"], name != "NODE" { invalid = true }
            if stack.contains("NODE") { invalid = true }
            if stack.isEmpty {
                hasRoot = name == "SYNC_ITUNES_PLAYLIST"
            } else if stack == ["SYNC_ITUNES_PLAYLIST"], name == "PLAYLISTS" {
                if hasPlaylists { invalid = true }
                hasPlaylists = true
            } else if stack == ["SYNC_ITUNES_PLAYLIST", "PLAYLISTS"], name == "NODE" {
                guard let library = attributes["Lib_Type"], Int(library) != nil else { invalid = true; return }
                guard library == "1" else { return }
                guard let id = attributes["Id"].flatMap(RekordboxITunesSelection.normalizedID),
                      let parent = attributes["ParentId"].flatMap(RekordboxITunesSelection.normalizedID),
                      let kind = attributes["Attribute"], ["0", "1"].contains(kind),
                      let check = attributes["CheckType"], ["0", "1", "2"].contains(check), ids.insert(id).inserted else {
                    invalid = true
                    return
                }
                nodes.append(Node(id: id, parentID: parent, isFolder: kind == "1", isSelected: check == "1"))
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }
    }
}
