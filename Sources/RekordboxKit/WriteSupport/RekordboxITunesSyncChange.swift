import DJCDomain
import Foundation

/// 선택 창을 열 때의 원문을 base로 보관한다. iTunes 이외의 라이브러리·제품 정보는 유지한다.
public struct RekordboxITunesSyncChange: Sendable {
    public let base: Data
    public let source: [ITunesSyncSelection.Node]
    public let selection: ITunesSyncSelection

    public init(base: Data, source: [ITunesSyncSelection.Node], selection: ITunesSyncSelection) {
        self.base = base; self.source = source; self.selection = selection
    }

    public func render(timestamp: (String) -> Int64 = { _ in Int64(Date.now.timeIntervalSince1970 * 1000) }) throws -> Data {
        let document = try Self.document(base)
        let playlists = document.rootElement()!.elements(forName: "PLAYLISTS")[0]
        let grouped = Dictionary(grouping: source, by: \.id)
        guard grouped.values.allSatisfy({ $0.count == 1 }), source.allSatisfy({
            $0.id != "0" && RekordboxITunesSelection.normalizedID($0.id) == $0.id
        }), selection.selectedIDs.subtracting(["0"]).isSubset(of: Set(grouped.keys)) else { throw Self.invalidSource }
        let byID = grouped.mapValues { $0[0] }
        for node in source {
            var seen: Set<String> = [node.id], parent = node.parentID
            while let id = parent {
                guard seen.insert(id).inserted, let ancestor = byID[id], ancestor.isFolder else { throw Self.invalidSource }
                parent = ancestor.parentID
            }
        }
        let children = Dictionary(grouping: source, by: { $0.parentID ?? "0" })
        let included = selection.expandedIDs(in: source)
        var states: [String: Int] = [:]
        func state(_ id: String) -> Int {
            let childStates = (children[id] ?? []).map { state($0.id) }
            let result: Int
            // 하위를 모두 다시 골라도 부모의 부분 선택(2)은 유지된다. 부모를 직접 고를 때만 1이다.
            if included.contains(id) || (id == "0" && selection.selectedIDs.contains("0")) { result = 1 }
            else if childStates.contains(where: { $0 > 0 }) { result = 2 }
            else { result = 0 }
            states[id] = result
            return result
        }
        _ = state("0")
        var replacement: [XMLNode] = []
        func append(_ id: String, parent: String, folder: Bool) {
            let check = states[id, default: 0]
            guard id == "0" || check > 0 else { return }
            let node = XMLElement(name: "NODE")
            let fields = [("Id", id), ("ParentId", parent), ("Attribute", folder ? "1" : "0"),
                          ("Timestamp", String(id == "0" ? 0 : timestamp(id))), ("Lib_Type", "1"), ("CheckType", String(check))]
            for (key, value) in fields { node.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
            replacement.append(node)
            for child in children[id] ?? [] { append(child.id, parent: id, folder: child.isFolder) }
        }
        append("0", parent: "0", folder: true)
        var inserted = false
        let existing = playlists.children ?? []
        existing.forEach { $0.detach() }
        for child in existing {
            if let node = child as? XMLElement, node.name == "NODE", node.attribute(forName: "Lib_Type")?.stringValue == "1" {
                if !inserted { replacement.forEach { playlists.addChild($0) }; inserted = true }
            } else { playlists.addChild(child) }
        }
        if !inserted { replacement.forEach { playlists.addChild($0) } }
        let data = document.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
        _ = try Self.document(data)
        return data
    }

    /// 시각은 실행마다 달라지므로 변경 여부는 계층·선택 칸으로만 판정한다.
    static func state(of data: Data) throws -> [String] {
        try document(data).rootElement()!.elements(forName: "PLAYLISTS")[0].elements(forName: "NODE").map { node in
            (node.attributes ?? []).filter { $0.name != "Timestamp" }.map { "\($0.name ?? "")=\($0.stringValue ?? "")" }.sorted().joined(separator: ";")
        }
    }

    private static func document(_ data: Data) throws -> XMLDocument {
        _ = try RekordboxITunesSelection.parse(data)
        guard !String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("<!DOCTYPE") else { throw invalidSource }
        let doc = try XMLDocument(data: data, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.attribute(forName: "Version")?.stringValue == "3.0.0",
              root.elements(forName: "PLAYLISTS").count == 1 else { throw invalidSource }
        let expected: Set<String> = ["Id", "ParentId", "Attribute", "Timestamp", "Lib_Type", "CheckType"]
        for node in root.elements(forName: "PLAYLISTS")[0].elements(forName: "NODE")
        where node.attribute(forName: "Lib_Type")?.stringValue == "1" {
            guard Set((node.attributes ?? []).compactMap(\.name)) == expected,
                  let value = node.attribute(forName: "Timestamp")?.stringValue, let time = Int64(value), time >= 0 else { throw invalidSource }
        }
        return doc
    }

    static var invalidSource: DJCError {
        .writeRefused(String(ui: "iTunes 동기화 파일이나 폴더 구조를 확인할 수 없습니다. rekordbox에서 다시 동기화한 뒤 창을 다시 여세요."))
    }
}
