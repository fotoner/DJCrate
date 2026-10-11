import Foundation

/// 인텔리전트 재생 목록 조건 칸(`djmdPlaylist.SmartList`)의 항목 이름. 값은 XML `PropertyName` 그대로다.
/// 형식 근거는 pyrekordbox(MIT)의 `masterdb/smartlist.py`다([제3자], `THIRD_PARTY_NOTICES.md`). rekordbox 7.2.18에서 직접 만든 목록으로는
/// 아직 확인하지 않았다(#68, 묶음 3 M1). 이 목록에 있다고 계산하는 것은 아니다 — 계산하는 항목은 `SmartPlaylistEvaluator`가 따로 정한다.
public enum SmartPlaylistProperty: String, CaseIterable, Sendable {
    case artist, album, albumArtist, originalArtist, bpm, grouping, comments, producer, stockDate, dateCreated, counter, fileName
    case genre, key, label, mixName, myTag, rating, dateReleased, remixedBy, duration, name, year
}

/// 조건 연산자 번호(XML `Operator`). 근거는 `SmartPlaylistProperty`와 같다.
public enum SmartPlaylistOperator: Int, CaseIterable, Sendable {
    case equal = 1, notEqual, greater, less, inRange, inLast, notInLast, contains, notContains, startsWith, endsWith
}

/// 읽은 조건 칸. 모르는 항목·연산자도 원문 그대로 남겨(`propertyName`·`operatorCode`) 계산기가 "지원하지 않는 조건"으로 알린다.
public struct SmartPlaylistDefinition: Hashable, Sendable {
    /// 조건을 모두 만족(1) / 하나라도 만족(2)(XML `LogicalOperator`)
    public enum Match: Int, Hashable, Sendable {
        case all = 1, any = 2
    }

    public struct Condition: Hashable, Sendable {
        public var propertyName: String
        public var operatorCode: Int
        /// XML `ValueUnit`(날짜 상대 값의 단위 같은 것). 빈 글자가 기본이다.
        public var unit: String
        public var left: String
        /// 범위 연산자의 뒤 값. 쓰지 않으면 빈 글자.
        public var right: String

        public init(propertyName: String, operatorCode: Int, unit: String = "", left: String = "", right: String = "") {
            self.propertyName = propertyName
            self.operatorCode = operatorCode
            self.unit = unit
            self.left = left
            self.right = right
        }

        public var property: SmartPlaylistProperty? { SmartPlaylistProperty(rawValue: propertyName) }
        public var `operator`: SmartPlaylistOperator? { SmartPlaylistOperator(rawValue: operatorCode) }
    }

    public var match: Match
    /// XML `AutomaticUpdate`. 계산에는 쓰지 않는다(뜻을 아직 확인하지 않았다).
    public var automaticUpdate: Bool
    public var conditions: [Condition]

    public init(match: Match, automaticUpdate: Bool, conditions: [Condition]) {
        self.match = match
        self.automaticUpdate = automaticUpdate
        self.conditions = conditions
    }
}

/// 조건 칸을 읽은 결과. 읽지 못하면 이유(사용자에게 보이는 한 문장)를 들고, 그런 목록은 곡을 보이지 않는다.
public enum SmartPlaylistSource: Hashable, Sendable {
    case definition(SmartPlaylistDefinition)
    case unreadable(String)

    /// `SmartList` 칸 글자(NODE/CONDITION XML)를 읽는다. 알려진 모양과 조금이라도 다르면(모르는 칸·중첩·남은 글자) 읽지 않는다.
    public init(xml: String) {
        self = SmartPlaylistXML.read(xml)
    }

    /// `djmdPlaylist`의 `Attribute`와 `SmartList` 칸에서. 인텔리전트 목록은 `Attribute` 4다(XML NODE의 고아 행으로 확인한 값).
    public static func reading(attribute: Int, smartList: String?) -> SmartPlaylistSource {
        guard attribute == 4 else { return .unreadable(String(ui: "알 수 없는 재생 목록 종류입니다(Attribute \(attribute))")) }
        let text = smartList?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return .unreadable(String(ui: "조건 칸이 비어 있습니다")) }
        return SmartPlaylistSource(xml: text)
    }

    /// 인텔리전트 목록을 편집(이름·지우기·옮기기·곡 넣기·순서)하려 할 때 알리는 이유. 쓰기 경로가 막는 문구와 같다.
    public static var readOnlyReason: String { String(ui: "인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)") }

    /// 조건 칸을 읽었는지(읽었어도 계산할 수 있는지는 계산기가 따로 본다)
    public var definition: SmartPlaylistDefinition? {
        if case let .definition(definition) = self { definition } else { nil }
    }
}

/// `SmartList` XML 읽기. 외부 개체는 따라가지 않는다(Foundation `XMLParser` 기본값).
private enum SmartPlaylistXML {
    private static let nodeAttributes: Set<String> = ["Id", "LogicalOperator", "AutomaticUpdate"]
    private static let conditionAttributes: Set<String> = ["PropertyName", "Operator", "ValueUnit", "ValueLeft", "ValueRight"]

    final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Element] = []
        var text = ""
        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    final class Reader: NSObject, XMLParserDelegate {
        var root: Element?
        private var stack: [Element] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let element = Element(name: elementName, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(element) } else if root == nil { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }

    static func read(_ xml: String) -> SmartPlaylistSource {
        let text = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unreadable(String(ui: "조건 칸이 비어 있습니다")) }
        let reader = Reader()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = reader.root else { return .unreadable(String(ui: "조건 칸이 올바른 XML이 아닙니다")) }
        let shape = SmartPlaylistSource.unreadable(String(ui: "조건 칸의 모양이 알려진 형식과 다릅니다"))
        guard root.name == "NODE", Set(root.attributes.keys) == nodeAttributes, isBlank(root.text) else { return shape }
        guard let matchValue = root.attributes["LogicalOperator"], let match = Int(matchValue).flatMap(SmartPlaylistDefinition.Match.init(rawValue:)) else {
            return .unreadable(String(ui: "알 수 없는 조건 결합 방식입니다(LogicalOperator \(root.attributes["LogicalOperator"] ?? ""))"))
        }
        guard let auto = root.attributes["AutomaticUpdate"], auto == "0" || auto == "1" else {
            return .unreadable(String(ui: "알 수 없는 자동 갱신 값입니다(AutomaticUpdate \(root.attributes["AutomaticUpdate"] ?? ""))"))
        }
        var conditions: [SmartPlaylistDefinition.Condition] = []
        for child in root.children {
            guard child.name == "CONDITION", Set(child.attributes.keys) == conditionAttributes, child.children.isEmpty, isBlank(child.text),
                  let property = child.attributes["PropertyName"], let code = child.attributes["Operator"].flatMap({ Int($0) }),
                  let unit = child.attributes["ValueUnit"], let left = child.attributes["ValueLeft"], let right = child.attributes["ValueRight"]
            else { return shape }
            conditions.append(.init(propertyName: property, operatorCode: code, unit: unit, left: left, right: right))
        }
        guard !conditions.isEmpty else { return .unreadable(String(ui: "조건이 하나도 없습니다")) }
        return .definition(SmartPlaylistDefinition(match: match, automaticUpdate: auto == "1", conditions: conditions))
    }

    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
