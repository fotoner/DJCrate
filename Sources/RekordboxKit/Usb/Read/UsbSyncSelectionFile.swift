import CryptoKit
import DJCDomain
import Foundation

/// USB의 Sync/Playlists 문서. 로컬 SYNC_ITUNES_PLAYLIST와 별개 형식이다.
public struct UsbSyncSelectionFile: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public let attributes: [String: String]
        public var libraryType: Int { Int(attributes["Lib_Type"]!)! }
        public var id: String { attributes["Id"]! }
        public var parentID: String { attributes["ParentId"]! }
        public var isFolder: Bool { attributes["Attribute"] == "1" }
        public var checkType: Int { Int(attributes["CheckType"]!)! }
        public var deviceID: String { attributes["Dev_ID"]! }
        public var timestamp: Int64 { Int64(attributes["Timestamp"]!)! }
        var key: String { "\(libraryType):\(Self.normalized(id))" }
        var parentKey: String { "\(libraryType):\(Self.normalized(parentID))" }
        var isRoot: Bool { Self.normalized(id) == "0" }
        // 표기만 정규화한다. 확인하지 않은 진법으로 정수를 변환하면 큰 10진수에서 넘칠 수 있다.
        static func normalized(_ id: String) -> String {
            let digits = id.drop(while: { $0 == "0" })
            return digits.isEmpty ? "0" : digits.uppercased()
        }
    }

    public enum ParseError: Error, LocalizedError, Equatable, Sendable {
        case invalidFile, changedDuringRead, unsafePath
        public var errorDescription: String? {
            switch self {
            case .invalidFile:
                String(ui: "USB 동기화 선택 파일을 읽을 수 없습니다. rekordbox에서 다시 동기화한 뒤 USB를 읽으세요")
            case .changedDuringRead:
                String(ui: "읽는 동안 USB 동기화 선택이 바뀌었습니다. 동기화가 끝난 뒤 다시 읽으세요")
            case .unsafePath:
                String(ui: "USB 동기화 선택 파일이 일반 파일이 아닙니다. USB 파일을 확인한 뒤 다시 읽으세요")
            }
        }
    }

    public let data: Data
    public let rootAttributes: [String: String]
    public let playlistAttributes: [String: String]
    /// 중복을 접은 행. 끝에 덧붙은 뿌리 행은 `trailingDuplicateRootNodes`에만 둔다.
    public let nodes: [Node]
    /// rekordbox가 SYNC 없이 다시 쓰며 끝에 덧붙인 뿌리 행(같은 라이브러리의 첫 뿌리 행과 칸마다 같다). 선택에는 넣지 않는다.
    let trailingDuplicateRootNodes: [Node]
    public var trailingDuplicateRoots: Int { trailingDuplicateRootNodes.count }

    public static func relativePath(for format: UsbFormat) -> String {
        "PIONEER/rekordbox/" + (format == .deviceLibrary ? "playlists3.sync" : "playlists3Plus.sync")
    }

    public static func parse(_ data: Data) throws -> Self {
        let document = try document(data)
        let root = document.rootElement()!
        let rootValues = try attributes(of: root)
        let flags = ["AllPlaylists", "AutomaticSync", "ForcedSync", "IncludeCue"]
        guard flags.allSatisfy({ rootValues[$0].map { decimal($0) != nil } ?? true }),
              let dbID = rootValues["DBID"], databaseID(dbID) != nil,
              let time = rootValues["Timestamp"], validTimestamp(time) else { throw ParseError.invalidFile }
        let playlists = root.elements(forName: "Playlists")[0]
        var parsed: [Node] = []
        for child in playlists.children ?? [] {
            if let element = child as? XMLElement {
                guard element.name == "NODE", element.elements(forName: "NODE").isEmpty,
                      (element.children ?? []).allSatisfy({ child in
                          child.kind == .comment || child.kind == .processingInstruction
                              || (child.kind == .text && (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                      }) else {
                    throw ParseError.invalidFile
                }
                let values = try attributes(of: element)
                guard let library = values["Lib_Type"], decimal(library) != nil,
                      let id = values["Id"], validNumber(id), let parent = values["ParentId"], validNumber(parent),
                      ["0", "1"].contains(values["Attribute"] ?? ""),
                      ["0", "1", "2"].contains(values["CheckType"] ?? ""),
                      let device = values["Dev_ID"], decimal(device) != nil,
                      let timestamp = values["Timestamp"], validTimestamp(timestamp) else { throw ParseError.invalidFile }
                parsed.append(Node(attributes: values))
            } else if child.kind == .text, !(child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ParseError.invalidFile
            }
        }
        // 2026-10-08 정상 USB 실험: rekordbox가 켜진 채 체크한 원본의 이름을 바꾸거나 옮기거나 지우면 SYNC 없이
        // playlists3Plus.sync만 다시 쓰며, 마지막 덩어리의 뿌리 행을 `</Playlists>` 바로 앞에 한 번 더 붙였다
        // (첫 뿌리 행과 바이트까지 같고, 빼면 앞 단계 파일과 같았다. 다음 SYNC는 이 행 없이 다시 쓴다).
        // 끝에 붙은, 같은 라이브러리의 첫 뿌리 행과 칸마다 같은 뿌리 행만 접는다. 다른 중복은 그대로 거부한다.
        var end = parsed.count
        while end > 1, parsed[end - 1].isRoot,
              let first = parsed[..<(end - 1)].first(where: { $0.key == parsed[end - 1].key }),
              first.attributes == parsed[end - 1].attributes {
            end -= 1
        }
        var nodes: [Node] = [], byKey: [String: Node] = [:]
        for node in parsed[..<end] {
            guard byKey[node.key] == nil, node.isFolder || node.checkType != 2 else { throw ParseError.invalidFile }
            byKey[node.key] = node
            nodes.append(node)
        }
        for node in nodes {
            if node.isRoot {
                guard node.parentKey == node.key, node.isFolder, Node.normalized(node.deviceID) == "0" else { throw ParseError.invalidFile }
            } else {
                var seen: Set<String> = [node.key], parent = node.parentKey
                while true {
                    guard seen.insert(parent).inserted, let ancestor = byKey[parent], ancestor.isFolder else { throw ParseError.invalidFile }
                    if ancestor.isRoot { break }
                    parent = ancestor.parentKey
                }
            }
        }
        return Self(data: data, rootAttributes: rootValues, playlistAttributes: try Self.attributes(of: playlists), nodes: nodes,
                    trailingDuplicateRootNodes: Array(parsed[end...]))
    }

    static func document(_ data: Data) throws -> XMLDocument {
        // UTF-8로만 읽어 DTD 검사가 UTF-16의 NUL 바이트 사이로 빠지지 않게 한다.
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ParseError.invalidFile
        }
        let document: XMLDocument
        do { document = try XMLDocument(data: data, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]) }
        catch { throw ParseError.invalidFile }
        guard document.dtd == nil, let root = document.rootElement(), root.name == "Sync",
              root.elements(forName: "Playlists").count == 1 else { throw ParseError.invalidFile }
        return document
    }

    static func attributes(of element: XMLElement) throws -> [String: String] {
        var result: [String: String] = [:]
        for attribute in element.attributes ?? [] {
            guard let key = attribute.name, let value = attribute.stringValue, result[key] == nil else { throw ParseError.invalidFile }
            result[key] = value
        }
        return result
    }

    /// 원본 Id·ParentId는 16진수다(rekordbox 목록 ID·iTunes 목록 ID, 2026-10-08 실험).
    static func validNumber(_ text: String) -> Bool { hexadecimal(text) != nil }
    static func hexadecimal(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.count <= 16, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return UInt64(text, radix: 16)
    }
    static func validTimestamp(_ text: String) -> Bool { decimal(text) != nil }
    static func decimal(_ text: String) -> Int64? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int64(text), value >= 0 else { return nil }
        return value
    }

    /// 루트 DBID는 로컬 djmdProperty.DBID를 부호 있는 32비트 10진수로 적은 값이다(음수일 수 있다, 2026-10-08 실험).
    static func databaseID(_ text: String) -> Int32? {
        let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int32(text)
    }

    /// 로컬 DBID와 같은 32비트 값인지. 로컬 값은 부호 없는 값으로 읽힐 수도 있어 비트 모양으로 견준다.
    static func databaseID(local: Int64) -> Int32? {
        guard local >= Int64(Int32.min), local <= Int64(UInt32.max) else { return nil }
        return Int32(truncatingIfNeeded: local)
    }

    /// rekordbox가 쓰는 모양(칸 순서·들여쓰기·CRLF)을 그대로 다시 만들 수 있는 원문인지.
    /// 바깥 요소·주석·모르는 칸이 있으면 거짓이라 고쳐 쓰지 않는다.
    public var isCanonical: Bool {
        guard playlistAttributes.isEmpty else { return false }
        return (try? UsbSyncSelectionXML.canonical(root: rootAttributes, nodes: nodes.map(\.attributes))) == data
    }

    /// rekordbox 모양에 끝 뿌리 행만 덧붙은 원문인지. 접은 행을 다시 붙인 모양이 원문 바이트와 같아야 한다.
    /// 다음 SYNC처럼 덧붙은 행 없이 다시 쓸 수 있다(켜짐만 바꾸는 쓰기는 막는다, `UsbSyncSelectionXML.render`).
    public var isCanonicalWithTrailingDuplicateRoots: Bool {
        guard !trailingDuplicateRootNodes.isEmpty, playlistAttributes.isEmpty else { return false }
        let all = (nodes + trailingDuplicateRootNodes).map(\.attributes)
        return (try? UsbSyncSelectionXML.canonical(root: rootAttributes, nodes: all)) == data
    }

    var selectionState: [String] {
        func encode(_ attributes: [String: String]) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return String(decoding: (try? encoder.encode(attributes)) ?? Data(), as: UTF8.self)
        }
        let root = encode(rootAttributes.filter { $0.key != "Timestamp" })
        return [root] + nodes.map { node in
            var fields = node.attributes.filter { ["Lib_Type", "Id", "ParentId", "Attribute", "CheckType"].contains($0.key) }
            fields["Id"] = Node.normalized(node.id)
            fields["ParentId"] = Node.normalized(node.parentID)
            fields["Lib_Type"] = String(node.libraryType)
            return encode(fields)
        }.sorted()
    }
}

/// 허용된 두 파일만 읽는다. 두 형식이 다른 선택을 가리키면 합집합으로 추측하지 않는다.
public struct UsbSyncSelectionBundle: Sendable {
    public let files: [UsbFormat: UsbSyncSelectionFile]
    private let expectedFormats: Set<UsbFormat>
    public var baseFiles: [UsbFormat: Data] { files.mapValues(\.data) }
    public var semanticFingerprint: String? {
        guard let state = files.values.first?.selectionState else { return nil }
        guard files.values.allSatisfy({ $0.selectionState == state }) else { return nil }
        let data = (try? JSONEncoder().encode(state)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public init(files: [UsbFormat: UsbSyncSelectionFile]) {
        self.files = files
        expectedFormats = Set(files.keys)
    }
    private init(files: [UsbFormat: UsbSyncSelectionFile], formats: Set<UsbFormat>) {
        self.files = files
        expectedFormats = formats
    }

    /// stage·검증·CLI에서 쓸 안전 읽기 입구. 허용된 두 이름만 열고 없으면 nil을 반환한다.
    public static func readFile(root: UsbRoot, format: UsbFormat,
                                fileSystem: any UsbFileSystem = PosixUsbFileSystem()) throws -> Data? {
        try snapshot(root: root, format: format, fileSystem: fileSystem)?.data
    }

    private static func snapshot(root: UsbRoot, format: UsbFormat, fileSystem: any UsbFileSystem) throws -> UsbFileRead? {
        let maximum = 16 * 1024 * 1024
        guard let file = try fileSystem.readFile(root: root, relativePath: UsbSyncSelectionFile.relativePath(for: format),
                                                maxBytes: maximum) else { return nil }
        guard file.stat.kind == .file, file.stat.size > 0, file.stat.size <= Int64(maximum),
              file.data.count == Int(file.stat.size) else { throw UsbSyncSelectionFile.ParseError.unsafePath }
        return file
    }

    public static func read(root: UsbRoot, formats: Set<UsbFormat>,
                            fileSystem: any UsbFileSystem = PosixUsbFileSystem()) throws -> Self {
        var files: [UsbFormat: UsbSyncSelectionFile] = [:]
        var originals: [UsbFormat: UsbFileRead] = [:]
        for format in UsbFormat.allCases where formats.contains(format) {
            guard let file = try snapshot(root: root, format: format, fileSystem: fileSystem) else { continue }
            originals[format] = file
            files[format] = try .parse(file.data)
        }
        // 두 번째 파일을 읽는 동안의 변경·삭제·새 파일 생성도 fd를 다시 열어 확인한다.
        for format in UsbFormat.allCases where formats.contains(format) {
            guard try snapshot(root: root, format: format, fileSystem: fileSystem) == originals[format] else {
                throw UsbSyncSelectionFile.ParseError.changedDuringRead
            }
        }
        return Self(files: files, formats: formats)
    }

    /// 형식마다 그 형식 DB에 있는 목록 번호. Dev_ID는 그 형식의 번호와 견준다.
    public static func playlistIDs(of library: UsbLibrary) -> [UsbFormat: Set<Int>] {
        representatives(of: library).mapValues { Set($0.keys) }
    }

    /// 형식마다 그 형식 DB의 목록 번호 → 합친 모델의 대표 번호(#233: 같은 목록의 두 형식 번호가 다를 수 있다)
    public static func representatives(of library: UsbLibrary) -> [UsbFormat: [Int: Int]] {
        Dictionary(uniqueKeysWithValues: library.formats.map { format in
            (format, Dictionary(library.playlists.filter { $0.presentIn.contains(format) }.map { ($0.id(in: format), $0.id) },
                                uniquingKeysWith: { first, _ in first }))
        })
    }

    /// - masterNodeIDs: 로컬 `masterPlaylists6.xml`의 rekordbox NODE Id(16진). 원본 목록에도 이 파일에도 없는 rekordbox 행은
    ///   로컬에서 지운 원본으로 본다(rekordbox는 종료할 때 지운 목록을 이 파일에서 뺀다, 2026-10-08 실험). nil이면 막는다.
    /// - representatives: 형식 번호 → 대표 번호(`representatives(of:)`). 형식마다 Dev_ID를 대표 번호로 바꿔 같은 목록인지 본다.
    ///   nil이면 두 형식 번호가 같을 때만 잇는다
    public func resolution(sourceNodes: [UsbSyncSourceNode], localDBID: Int64,
                           usbPlaylistIDs: [UsbFormat: Set<Int>]? = nil,
                           representatives: [UsbFormat: [Int: Int]]? = nil,
                           masterNodeIDs: Set<String>? = nil) -> UsbSyncSelectionResolution {
        var issues: [UsbSyncSelectionIssue] = []
        func issue(_ value: UsbSyncSelectionIssue) { if !issues.contains(value) { issues.append(value) } }
        let enabledStates = files.values.compactMap { file -> Bool? in
            switch file.rootAttributes["AutomaticSync"] {
            case "1": true
            case "0": false
            default: nil
            }
        }
        let enabled = enabledStates.count == files.count && Set(enabledStates).count == 1 ? enabledStates.first : nil
        func result(_ selected: Set<String> = [], _ ids: [String: Int] = [:],
                    _ formatIDs: [UsbFormat: [String: Int]] = [:], _ removed: Set<Int> = []) -> UsbSyncSelectionResolution {
            if enabledStates.count != files.count { issue(.enabledStateUnknown) }
            return .init(selection: .init(selectedIDs: selected), enabled: enabled, playlistIDs: ids,
                         formatPlaylistIDs: formatIDs, removedSourcePlaylistIDs: removed, issues: issues)
        }
        guard !files.isEmpty else { return result() }
        guard semanticFingerprint != nil else { issue(.formatConflict); return result() }
        if Set(files.keys) != expectedFormats { issue(.missingFormatFile) }
        guard let local = UsbSyncSelectionFile.databaseID(local: localDBID) else { issue(.databaseMismatch); return result() }
        for file in files.values {
            guard UsbSyncSelectionFile.databaseID(file.rootAttributes["DBID"]!) == local else { issue(.databaseMismatch); return result() }
        }
        let groups = [UsbSyncSourceNode.rekordboxSelectionID, UsbSyncSourceNode.iTunesSelectionID]
        let actual = sourceNodes.filter { !groups.contains($0.id) }
        let grouped = Dictionary(grouping: actual, by: \.id)
        guard grouped.values.allSatisfy({ $0.count == 1 }), actual.allSatisfy({ $0.id != "0" }) else { issue(.sourceStructure); return result() }
        let catalog = grouped.mapValues { $0[0] }
        func group(_ id: String) -> String { id.hasPrefix("itunes:") ? groups[1] : groups[0] }
        func parent(_ source: UsbSyncSourceNode) -> String {
            if let parent = source.parentID, parent != "0", !groups.contains(parent) { return parent }
            return group(source.id)
        }
        for source in actual {
            if let suppliedParent = source.parentID, groups.contains(suppliedParent), suppliedParent != group(source.id) {
                issue(.sourceStructure)
                return result()
            }
            var visited: Set<String> = [source.id], next = parent(source)
            while !groups.contains(next) {
                guard visited.insert(next).inserted, let ancestor = catalog[next], ancestor.isFolder,
                      group(ancestor.id) == group(source.id) else { issue(.sourceStructure); return result() }
                next = parent(ancestor)
            }
        }
        let file = files[.deviceLibrary] ?? files[.oneLibrary]!
        let master = masterNodeIDs.map { Set($0.map(UsbSyncSelectionFile.Node.normalized)) }
        var mappings: [String: String] = [:], reverseMappings: [String: String] = [:], removedKeys = Set<String>()
        for node in file.nodes {
            guard [0, 1].contains(node.libraryType) else {
                if node.checkType > 0 { issue(.unsupportedSource) }
                continue
            }
            if node.isRoot { mappings[node.key] = groups[node.libraryType]; continue }
            let candidates: [String]
            if node.libraryType == 1 {
                let id = "itunes:" + UsbSyncSelectionFile.Node.normalized(node.id)
                candidates = catalog[id] == nil ? [] : [id]
            } else {
                // rekordbox 원본 Id는 djmdPlaylist.ID의 16진수 대문자다.
                let value = UsbSyncSelectionFile.hexadecimal(node.id)
                candidates = actual.filter { !$0.id.hasPrefix("itunes:") && value != nil && UInt64($0.id) == value }.map(\.id)
            }
            if candidates.isEmpty, node.libraryType == 0, let master, !master.contains(UsbSyncSelectionFile.Node.normalized(node.id)) {
                removedKeys.insert(node.key)
                continue
            }
            guard candidates.count == 1, let id = candidates.first else { issue(candidates.isEmpty ? .sourceMissing : .sourceAmbiguous); continue }
            guard catalog[id]?.isFolder == node.isFolder else { issue(.sourceStructure); continue }
            if let previous = reverseMappings[id], previous != node.key { issue(.sourceAmbiguous); continue }
            mappings[node.key] = id
            reverseMappings[id] = node.key
        }
        // 일부만 복원하면 누락된 선택이 다음 동기화에서 빠질 수 있어 전체 연결이 맞아야 한다.
        guard issues.isEmpty else { return result() }
        var selected = Set<String>(), ids: [String: Int] = [:], formatIDs: [UsbFormat: [String: Int]] = [:], removed = Set<Int>()
        /// - report: 거짓이면 문제를 막힘으로 올리지 않는다(지운 원본의 행은 USB 목록이 이미 없어도 막을 일이 아니다)
        func deviceIDs(_ node: UsbSyncSelectionFile.Node, report: Bool = true) -> [UsbFormat: Int] {
            var result: [UsbFormat: Int] = [:]
            for (format, other) in files {
                guard let corresponding = other.nodes.first(where: { $0.key == node.key }) else {
                    if report { issue(.formatConflict) }
                    continue
                }
                // Dev_ID는 그 형식 DB의 목록 번호(10진수)다.
                guard let value = UsbSyncSelectionFile.decimal(corresponding.deviceID).flatMap({ Int(exactly: $0) }), value > 0,
                      usbPlaylistIDs.map({ $0[format]?.contains(value) == true }) ?? true,
                      representatives.map({ $0[format]?[value] != nil }) ?? true else {
                    if report { issue(.deviceIDAmbiguous) }
                    continue
                }
                result[format] = value
            }
            return result
        }
        /// 형식 번호 → 대표 번호(모르면 그 번호 그대로: 두 형식 번호가 같을 때만 한 목록으로 본다)
        func linked(_ found: [UsbFormat: Int]) -> [UsbFormat: Int] {
            Dictionary(uniqueKeysWithValues: found.map { format, value in (format, representatives?[format]?[value] ?? value) })
        }
        for node in file.nodes where [0, 1].contains(node.libraryType) {
            if removedKeys.contains(node.key) {
                // 지운 원본의 USB 목록은 두 형식이 같은 목록을 가리킬 때만 지울 대상으로 둔다. 다르면 지우지 않고 남긴다.
                let found = linked(deviceIDs(node, report: false))
                let values = Set(found.values)
                if found.count == files.count, values.count == 1, let value = values.first { removed.insert(value) }
                continue
            }
            guard let id = mappings[node.key] else { issue(.sourceMissing); continue }
            // 행의 부모가 지금 원본의 부모와 달라도 막지 않는다. rekordbox는 옮긴 원본의 체크를 그대로 두고
            // SYNC 때 새 자리로 옮긴다(2026-10-08 실험).
            guard node.isRoot || catalog[id] != nil else { issue(.sourceStructure); continue }
            if node.checkType == 1 { selected.insert(id) }
            guard !node.isRoot else { continue }
            let values = deviceIDs(node)
            for (format, value) in values { formatIDs[format, default: [:]][id] = value }
            // 두 형식이 같은 USB 목록(대표 번호)을 가리킬 때만 잇는다. 형식 번호는 다를 수 있다(#233).
            let linkedValues = linked(values)
            if Set(linkedValues.values).count == 1, let usbID = linkedValues.values.first { ids[id] = usbID }
        }
        for map in formatIDs.values where Dictionary(grouping: map.keys, by: { map[$0]! }).values.contains(where: { $0.count > 1 }) {
            issue(.deviceIDAmbiguous)
        }
        if issues.contains(.sourceMissing) || issues.contains(.sourceAmbiguous) || issues.contains(.sourceStructure) { return result() }
        return result(selected, ids, formatIDs, removed.subtracting(ids.values))
    }
}
