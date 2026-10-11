import DJCDomain
import Foundation

/// 확인한 칸 규칙의 판. 저널의 기대값에 함께 남겨 다른 판으로 만든 준비 파일과 섞지 않는다.
///
/// 2026-10-08 rekordbox 7.2.x 실험(동기화 관리자에서 선택을 바꿔 SYNC → USB 사본 전후 비교, 값은 적지 않음):
/// rekordbox는 매번 파일 전체를 같은 모양으로 다시 쓴다. 그래서 원문을 고쳐 쓰지 않고 칸 규칙대로 새로 만든다.
extension UsbSyncXMLWriteContract {
    public static let confirmed = Self(revision: 1)

    /// 비상 스위치. nil이면 선택 파일 쓰기를 백업·USB 쓰기 전에 막는다.
    public static var production: Self? { confirmed }
}

/// 파일 준비는 UsbWriter가 맡고, 여기서는 입력 값으로 XML 칸만 만든다.
public enum UsbSyncSelectionXML {
    public enum RenderError: Error, LocalizedError, Equatable, Sendable {
        case invalidSource, missingPlaylist, missingSourceNode, contractMismatch, verificationFailed
        /// 원문 끝에 rekordbox가 SYNC 없이 덧붙인 뿌리 행이 있는데 켜짐만 바꾸려 한다
        case pendingRekordboxSync
        public var errorDescription: String? {
            switch self {
            case .invalidSource:
                String(ui: "USB 동기화 선택의 원본을 확인할 수 없습니다. 목록을 다시 읽은 뒤 동기화하세요")
            case .missingPlaylist:
                String(ui: "USB 동기화 목록의 최종 번호를 찾지 못했습니다. 쓰기 결과를 다시 읽은 뒤 동기화하세요")
            case .missingSourceNode:
                String(ui: "masterPlaylists6.xml에서 동기화할 목록을 찾지 못했습니다. rekordbox를 한 번 켰다가 종료하고 새 스냅샷을 읽은 뒤 동기화하세요")
            case .contractMismatch:
                String(ui: "USB 동기화 파일이 확인한 형식과 다릅니다. rekordbox에서 다시 동기화한 뒤 읽으세요")
            case .verificationFailed:
                String(ui: "USB 동기화 선택을 다시 읽으니 쓴 내용과 다릅니다. USB를 다시 읽은 뒤 동기화하세요")
            case .pendingRekordboxSync:
                UsbSyncSelectionStage.pendingRekordboxSyncBlock.message
            }
        }
    }

    static let rootFields = ["DBID", "AutomaticSync", "AllPlaylists", "IncludeCue", "ForcedSync", "Timestamp"]
    static let nodeFields = ["Id", "ParentId", "Attribute", "Lib_Type", "Dev_ID", "Timestamp", "CheckType"]
    static let newline = "\r\n"

    /// 원문이 없을 때(새 파일)의 루트 칸. 2026-10-08 빈 USB 실험: rekordbox가 처음 만든 두 파일(첫 SYNC 뒤)의 루트가
    /// 모두 이 값이었다(`AutomaticSync`는 체크 값, `DBID`는 로컬 DBID).
    static let newFileRootDefaults = ["AllPlaylists": "0", "IncludeCue": "1", "ForcedSync": "0", "Timestamp": "0"]

    /// 선언·빈 줄·`<Sync …>`·2칸 `<Playlists>`·4칸 `<NODE …/>`, 줄 끝은 모두 CRLF(마지막 줄 포함).
    /// 행이 없으면 `  <Playlists/>` 한 줄이다(빈 USB에서 동기화를 켜면 rekordbox가 만든 173바이트 파일, 길이로 확인).
    static func canonical(root: [String: String], nodes: [[String: String]]) throws -> Data {
        func line(_ name: String, _ fields: [String], _ values: [String: String], close: String) throws -> String {
            guard Set(values.keys) == Set(fields) else { throw RenderError.contractMismatch }
            let attributes = try fields.map { field -> String in
                let value = values[field]!
                // 칸 값은 숫자뿐이다. 이스케이프가 필요한 값은 확인한 모양이 아니다.
                guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") }) else {
                    throw RenderError.contractMismatch
                }
                return "\(field)=\"\(value)\""
            }
            return "<\(name) " + attributes.joined(separator: " ") + close
        }
        var lines = [#"<?xml version="1.0" encoding="UTF-8"?>"#, "", try line("Sync", rootFields, root, close: ">")]
        if nodes.isEmpty {
            lines.append("  <Playlists/>")
        } else {
            lines.append("  <Playlists>")
            for node in nodes { lines.append("    " + (try line("NODE", nodeFields, node, close: "/>"))) }
            lines.append("  </Playlists>")
        }
        lines.append("</Sync>")
        return Data((lines.joined(separator: newline) + newline).utf8)
    }

    /// 로컬 DBID를 루트 DBID 표기(부호 있는 32비트 10진수)로
    public static func databaseID(_ localDBID: Int64) -> String? {
        UsbSyncSelectionFile.databaseID(local: localDBID).map(String.init)
    }

    /// - playlistIDs: 원본 ID → 이 형식 DB의 USB 목록 번호(Dev_ID). 두 형식의 번호가 다르면 형식마다 다르게 준다.
    public static func render(draft: UsbSyncSelectionDraft, format: UsbFormat, playlistIDs: [String: Int],
                              contract: UsbSyncXMLWriteContract) throws -> Data {
        guard contract == .confirmed else { throw RenderError.contractMismatch }
        guard let databaseID = databaseID(draft.localDBID) else { throw RenderError.invalidSource }
        var root: [String: String]
        var original: UsbSyncSelectionFile?
        if let base = draft.baseFiles[format] {
            let file = try UsbSyncSelectionFile.parse(base)
            // 끝에 덧붙은 뿌리 행만 있는 원문(rekordbox가 SYNC 없이 다시 쓴 파일)은 다음 SYNC처럼 그 행 없이 새로 쓴다.
            // 켜짐만 바꾸는 쓰기는 rekordbox처럼 다른 칸·NODE를 그대로 둘 수 없어 막는다.
            if file.isCanonicalWithTrailingDuplicateRoots, draft.enabledOnly { throw RenderError.pendingRekordboxSync }
            // 모르는 칸·요소·주석이 있는 원문은 뜻을 추측하지 않는다.
            guard file.isCanonical || file.isCanonicalWithTrailingDuplicateRoots, file.rootAttributes["DBID"] == databaseID,
                  ["0", "1"].contains(file.rootAttributes["AutomaticSync"] ?? "") else { throw RenderError.contractMismatch }
            root = file.rootAttributes
            original = file
        } else {
            root = newFileRootDefaults
            root["DBID"] = databaseID
        }
        // 동기화 켜짐 말고 루트 칸(AllPlaylists·IncludeCue·ForcedSync·Timestamp)은 SYNC로 바뀌지 않았다.
        root["AutomaticSync"] = draft.enabled ? "1" : "0"
        if draft.enabledOnly {
            // 켜짐만 바꿀 때는 rekordbox처럼 다른 칸·NODE를 그대로 둔다. 파일이 없는 USB에서 켜면 rekordbox처럼
            // 행 없는 파일을 만들고, 끄는 것은 만들 파일이 없다(`UsbSyncSelectionStage.writesNothing`).
            guard let original else {
                guard draft.enabled else { throw RenderError.invalidSource }
                return try canonical(root: root, nodes: [])
            }
            return try canonical(root: root, nodes: original.nodes.map(\.attributes))
        }
        if original?.nodes.contains(where: { ![0, 1].contains($0.libraryType) }) == true { throw RenderError.contractMismatch }

        let groups = [UsbSyncSourceNode.rekordboxSelectionID, UsbSyncSourceNode.iTunesSelectionID]
        let actual = draft.sourceNodes.filter { !groups.contains($0.id) }
        let grouped = Dictionary(grouping: actual, by: \.id)
        guard grouped.values.allSatisfy({ $0.count == 1 }), actual.allSatisfy({ $0.id != "0" }),
              draft.selection.selectedIDs.isSubset(of: Set(grouped.keys).union(groups).union(["0"])) else { throw RenderError.invalidSource }
        let byID = grouped.mapValues { $0[0] }
        func group(_ id: String) -> String { id.hasPrefix("itunes:") ? groups[1] : groups[0] }
        func parent(_ source: UsbSyncSourceNode) -> String {
            guard let parent = source.parentID, parent != "0", !groups.contains(parent) else { return group(source.id) }
            return parent
        }
        for source in actual {
            if let suppliedParent = source.parentID, groups.contains(suppliedParent), suppliedParent != group(source.id) {
                throw RenderError.invalidSource
            }
            var visited: Set<String> = [source.id], ancestor = parent(source)
            while !groups.contains(ancestor) {
                guard visited.insert(ancestor).inserted, let next = byID[ancestor], next.isFolder,
                      group(next.id) == group(source.id) else { throw RenderError.invalidSource }
                ancestor = parent(next)
            }
        }
        // masterPlaylists6.xml의 Id 표기: rekordbox 목록은 djmdPlaylist.ID의 16진수 대문자, iTunes는 그 목록 ID 그대로.
        func encodedID(_ id: String) throws -> String {
            if groups.contains(id) { return "0" }
            if id.hasPrefix("itunes:") {
                guard let value = UInt64(id.dropFirst("itunes:".count), radix: 16), value > 0 else { throw RenderError.invalidSource }
                return String(value, radix: 16, uppercase: true)
            }
            guard let value = UInt64(id, radix: 10), value > 0 else { throw RenderError.invalidSource }
            return String(value, radix: 16, uppercase: true)
        }
        var encoded = [String: String](), uniqueEncoded = Set<String>()
        for source in actual {
            let value = try encodedID(source.id)
            guard uniqueEncoded.insert("\(source.id.hasPrefix("itunes:") ? 1 : 0):\(value)").inserted else { throw RenderError.invalidSource }
            encoded[source.id] = value
        }
        let selectionNodes: [ITunesSyncSelection.Node] = groups.map { .init(id: $0, parentID: "0", isFolder: true) }
            + actual.map { .init(id: $0.id, parentID: parent($0), isFolder: $0.isFolder) }
        let included = draft.selection.expandedIDs(in: selectionNodes)
        // 원본 순서(트리 전위 순회, 형제는 rekordbox 순서)를 그대로 따른다.
        let children = Dictionary(grouping: actual, by: parent)
        var states: [String: Int] = [:]
        func state(_ id: String) -> Int {
            let childStates = (children[id] ?? []).map { state($0.id) }
            let check = included.contains(id) ? 1 : childStates.contains(where: { $0 > 0 }) ? 2 : 0
            states[id] = check
            return check
        }
        groups.forEach { _ = state($0) }

        var nodes: [[String: String]] = []
        func append(_ source: UsbSyncSourceNode, library: Int) throws {
            let check = states[source.id, default: 0]
            // 해제한 목록은 행이 빠진다. 그 행이 가리키던 USB 목록은 두 형식이 맞는 USB면 rekordbox도 SYNC 때 지운다
            // (2026-10-08 정상 USB 실험). 지우는 것은 동기화 계획(`UsbSyncPlan`)이 맡는다.
            guard check > 0 else { return }
            guard let timestamp = source.timestamp, timestamp >= 0 else { throw RenderError.missingSourceNode }
            guard let ref = draft.playlistRefs[source.id], ref != .root else { throw RenderError.missingPlaylist }
            let value: Int?
            if let resolved = playlistIDs[source.id] { value = resolved }
            else {
                switch ref {
                case let .id(raw): value = Int(raw)
                case let .new(key): value = playlistIDs[key] ?? playlistIDs[ref.description]
                case .root: value = nil
                }
            }
            guard let value, value > 0 else { throw RenderError.missingPlaylist }
            nodes.append(["Id": encoded[source.id]!, "ParentId": try encodedID(parent(source)),
                          "Attribute": source.isFolder ? "1" : "0", "Lib_Type": String(library),
                          "Dev_ID": String(value), "Timestamp": String(timestamp), "CheckType": String(check)])
            for child in children[source.id] ?? [] { try append(child, library: library) }
        }
        // rekordbox(Lib_Type 0) 덩어리가 iTunes(1)보다 앞이다. 체크한 것이 없는 라이브러리는 뿌리 행도 쓰지 않는다.
        for (library, id) in groups.enumerated() where states[id, default: 0] > 0 {
            nodes.append(["Id": "0", "ParentId": "0", "Attribute": "1", "Lib_Type": String(library),
                          "Dev_ID": "0", "Timestamp": "0", "CheckType": String(states[id]!)])
            for child in children[id] ?? [] { try append(child, library: library) }
        }
        let output = try canonical(root: root, nodes: nodes)
        try validateDeviceIDs(in: UsbSyncSelectionFile.parse(output), failure: .invalidSource)
        return output
    }

    /// 다시 읽은 바이트가 같은 입력으로 만든 파일과 바이트까지 같아야 한다.
    public static func verify(data: Data, draft: UsbSyncSelectionDraft, format: UsbFormat, playlistIDs: [String: Int],
                              contract: UsbSyncXMLWriteContract) throws {
        // renderer와 독립적으로 실제 출력의 Dev_ID 유일성을 본다.
        try validateDeviceIDs(in: UsbSyncSelectionFile.parse(data), failure: .verificationFailed)
        let expected = try render(draft: draft, format: format, playlistIDs: playlistIDs, contract: contract)
        guard data == expected else { throw RenderError.verificationFailed }
    }

    private static func validateDeviceIDs(in file: UsbSyncSelectionFile, failure: RenderError) throws {
        var owners: [Int64: String] = [:]
        // Lib0·Lib1은 같은 USB 번호 공간을 쓴다. 뿌리 행(Dev_ID 0)은 세지 않는다.
        for node in file.nodes where [0, 1].contains(node.libraryType) && !node.isRoot {
            guard let deviceID = UsbSyncSelectionFile.decimal(node.deviceID), deviceID > 0,
                  owners[deviceID] == nil else { throw failure }
            owners[deviceID] = node.key
        }
    }
}
