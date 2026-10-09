import DJCDomain
import Foundation

/// rekordbox 폴더의 `masterPlaylists6.xml`. 재생 목록·폴더마다 NODE 한 줄이 있고, rekordbox가 DB와 함께 고친다.
///
/// 2026-09-26 라이브러리 조사(읽기 전용): 살아 있는 목록 505개 모두 NODE가 있고 `ParentId`·`Attribute`가 DB와 같다.
/// `Id`·`ParentId`는 목록 ID의 16진수 대문자(맨 위는 `0`), 줄 끝은 CRLF. 지운 목록의 NODE는 남아 있다.
/// 고친 줄 말고는 바이트 그대로 둔다.
public struct MasterPlaylistsXML: Sendable, Equatable {
    public typealias Node = MasterPlaylistNode

    public private(set) var text: String

    public init(text: String) { self.text = text }

    public init(contentsOf url: URL) throws {
        text = try String(contentsOf: url, encoding: .utf8)
    }

    public var data: Data { Data(text.utf8) }

    /// DB 목록 ID("root" 포함) → NODE의 Id 글자
    public static func hex(_ id: String) -> String? { MasterPlaylistNode.hex(id) }

    public var nodes: [Node] { lines.compactMap(\.node) }

    public func node(id: String) -> Node? {
        guard let hex = Self.hex(id) else { return nil }
        return nodes.first { $0.id == hex }
    }

    /// 새 NODE를 목록 끝(`</PLAYLISTS>` 앞)에 붙인다.
    public mutating func append(id: String, parentID: String, isFolder: Bool, timestamp: Int64) throws {
        guard let hex = Self.hex(id), let parent = Self.hex(parentID) else { throw DJCError.writeVerificationFailed(String(ui: "재생 목록 ID가 숫자가 아닙니다")) }
        guard let end = text.range(of: "  </PLAYLISTS>") else { throw DJCError.writeVerificationFailed(String(ui: "masterPlaylists6.xml 모양이 다릅니다")) }
        let line = #"    <NODE Id="\#(hex)" ParentId="\#(parent)" Attribute="\#(isFolder ? 1 : 0)" Timestamp="\#(timestamp)" Lib_Type="0" CheckType="0"/>"#
        text.insert(contentsOf: line + newline, at: end.lowerBound)
    }

    /// 있는 NODE의 칸을 고친다(없는 칸은 그대로). NODE가 없으면 false.
    @discardableResult
    public mutating func update(id: String, parentID: String? = nil, timestamp: Int64? = nil) throws -> Bool {
        guard let hex = Self.hex(id) else { return false }
        var lines = self.lines
        guard let index = lines.firstIndex(where: { $0.node?.id == hex }) else { return false }
        var line = lines[index].text
        if let parentID {
            guard let parent = Self.hex(parentID) else { throw DJCError.writeVerificationFailed(String(ui: "재생 목록 ID가 숫자가 아닙니다")) }
            line = Self.replacing("ParentId", with: parent, in: line)
        }
        if let timestamp { line = Self.replacing("Timestamp", with: String(timestamp), in: line) }
        lines[index].text = line
        text = lines.map(\.text).joined()
        return true
    }

    /// 여러 NODE의 Timestamp를 한 값으로 고친다(줄을 한 번만 훑는다). 없는 NODE는 건너뛴다.
    /// - Parameter ids: DB 목록 ID
    /// - Returns: 고친 NODE 수
    @discardableResult
    public mutating func touch(ids: Set<String>, timestamp: Int64) -> Int {
        let hexes = Set(ids.compactMap(Self.hex))
        guard !hexes.isEmpty else { return 0 }
        var lines = self.lines
        var touched = 0
        for index in lines.indices {
            guard let node = lines[index].node, hexes.contains(node.id) else { continue }
            lines[index].text = Self.replacing("Timestamp", with: String(timestamp), in: lines[index].text)
            touched += 1
        }
        if touched > 0 { text = lines.map(\.text).joined() }
        return touched
    }

    // MARK: - 줄

    private struct Line {
        var text: String
        var node: Node? {
            guard text.contains("<NODE ") else { return nil }
            func value(_ name: String) -> String? {
                guard let start = text.range(of: " \(name)=\"") else { return nil }
                return text[start.upperBound...].split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            }
            guard let id = value("Id"), let parent = value("ParentId") else { return nil }
            return Node(id: id, parentID: parent, attribute: Int(value("Attribute") ?? "") ?? 0, timestamp: Int64(value("Timestamp") ?? "") ?? 0,
                        libType: Int(value("Lib_Type") ?? "") ?? 0, checkType: Int(value("CheckType") ?? "") ?? 0)
        }
    }

    /// 줄 끝까지 포함한 줄들(합치면 원문 그대로)
    private var lines: [Line] {
        var result: [Line] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" || character == "\r\n" { result.append(Line(text: current)); current = "" }
        }
        if !current.isEmpty { result.append(Line(text: current)) }
        return result
    }

    private var newline: String { text.contains("\r\n") ? "\r\n" : "\n" }

    private static func replacing(_ name: String, with value: String, in line: String) -> String {
        guard let start = line.range(of: " \(name)=\""), let end = line[start.upperBound...].firstIndex(of: "\"") else { return line }
        return line.replacingCharacters(in: start.upperBound..<end, with: value)
    }
}
