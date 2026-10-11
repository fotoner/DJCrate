import DJCDomain
import Testing

/// 인텔리전트 재생 목록의 조건 칸(`djmdPlaylist.SmartList`)을 모델로 읽는 규칙.
/// 형식은 pyrekordbox(MIT)가 적은 NODE/CONDITION XML이다([제3자]). rekordbox 7.2.18에서 직접 만든 목록으로는 아직 확인하지 않았다(#68, 묶음 3 M1).
/// 시험 문자열은 모두 합성이다.
@Suite("인텔리전트 재생 목록 조건 읽기")
struct SmartPlaylistParserTests {
    static func xml(match: String = "1", auto: String = "0", _ conditions: String) -> String {
        "<NODE Id=\"-1234567\" LogicalOperator=\"\(match)\" AutomaticUpdate=\"\(auto)\">\(conditions)</NODE>"
    }

    static func condition(_ property: String, _ op: Int, left: String = "", right: String = "", unit: String = "") -> String {
        "<CONDITION PropertyName=\"\(property)\" Operator=\"\(op)\" ValueUnit=\"\(unit)\" ValueLeft=\"\(left)\" ValueRight=\"\(right)\"/>"
    }

    static func definition(_ source: SmartPlaylistSource) -> SmartPlaylistDefinition? {
        if case let .definition(definition) = source { definition } else { nil }
    }

    static func reason(_ source: SmartPlaylistSource) -> String? {
        if case let .unreadable(reason) = source { reason } else { nil }
    }

    @Test func 조건_하나를_읽는다() throws {
        let source = SmartPlaylistSource(xml: Self.xml(Self.condition("artist", 1, left: "합성 아티스트")))
        let definition = try #require(Self.definition(source))
        #expect(definition.match == .all)
        #expect(definition.automaticUpdate == false)
        #expect(definition.conditions.count == 1)
        let condition = definition.conditions[0]
        #expect(condition.propertyName == "artist")
        #expect(condition.property == .artist)
        #expect(condition.operatorCode == 1)
        #expect(condition.operator == .equal)
        #expect(condition.left == "합성 아티스트")
        #expect(condition.right == "")
        #expect(condition.unit == "")
    }

    @Test func 하나라도_맞는_목록과_자동_갱신을_읽는다() throws {
        let source = SmartPlaylistSource(xml: Self.xml(match: "2", auto: "1", Self.condition("year", 5, left: "2015", right: "2020")))
        let definition = try #require(Self.definition(source))
        #expect(definition.match == .any)
        #expect(definition.automaticUpdate)
        #expect(definition.conditions[0].operator == .inRange)
        #expect(definition.conditions[0].right == "2020")
    }

    @Test func 조건_순서를_그대로_둔다() throws {
        let source = SmartPlaylistSource(xml: Self.xml(
            Self.condition("name", 8, left: "가") + Self.condition("album", 9, left: "나") + Self.condition("artist", 10, left: "다")))
        let definition = try #require(Self.definition(source))
        #expect(definition.conditions.map(\.propertyName) == ["name", "album", "artist"])
        #expect(definition.conditions.map(\.operatorCode) == [8, 9, 10])
    }

    @Test func 따옴표와_꺾쇠_같은_XML_글자를_값으로_푼다() throws {
        let text = "<NODE Id=\"1\" LogicalOperator=\"1\" AutomaticUpdate=\"0\">"
            + "<CONDITION PropertyName=\"name\" Operator=\"8\" ValueUnit=\"\" ValueLeft=\"A &amp; B &quot;C&quot; &lt;D&gt;\" ValueRight=\"\"/></NODE>"
        let definition = try #require(Self.definition(SmartPlaylistSource(xml: text)))
        #expect(definition.conditions[0].left == "A & B \"C\" <D>")
    }

    @Test func 앞뒤_공백과_줄바꿈이_있어도_읽는다() throws {
        let text = "\n  " + Self.xml(Self.condition("name", 1, left: "x")) + "\n"
        #expect(Self.definition(SmartPlaylistSource(xml: text)) != nil)
    }

    @Test func 알_수_없는_항목과_연산자는_조건으로_남기고_이름과_번호를_보존한다() throws {
        let source = SmartPlaylistSource(xml: Self.xml(Self.condition("newField", 99, left: "x")))
        let condition = try #require(Self.definition(source)?.conditions.first)
        #expect(condition.propertyName == "newField")
        #expect(condition.property == nil)
        #expect(condition.operatorCode == 99)
        #expect(condition.operator == nil)
    }

    @Test func 알려진_항목_이름과_연산자_번호를_모두_옮겼다() {
        let names = ["artist", "album", "albumArtist", "originalArtist", "bpm", "grouping", "comments", "producer", "stockDate",
                     "dateCreated", "counter", "fileName", "genre", "key", "label", "mixName", "myTag", "rating", "dateReleased",
                     "remixedBy", "duration", "name", "year"]
        #expect(names.allSatisfy { SmartPlaylistProperty(rawValue: $0) != nil })
        #expect(SmartPlaylistProperty.allCases.count == names.count)
        #expect((1...11).allSatisfy { SmartPlaylistOperator(rawValue: $0) != nil })
        #expect(SmartPlaylistOperator(rawValue: 0) == nil)
        #expect(SmartPlaylistOperator(rawValue: 12) == nil)
    }

    // MARK: 읽지 못하는 것

    @Test(arguments: [
        "", "   ", "조건 없음", "<NODE", "<NODE></NODE><NODE></NODE>",
        "<RULE Id=\"1\" LogicalOperator=\"1\" AutomaticUpdate=\"0\"/>",
    ])
    func XML이_아니거나_NODE가_아니면_읽지_못한다(_ text: String) {
        #expect(Self.reason(SmartPlaylistSource(xml: text)) != nil)
    }

    @Test func 조건이_없으면_읽지_못한다() {
        #expect(Self.reason(SmartPlaylistSource(xml: Self.xml(""))) != nil)
    }

    @Test func 모두_하나라도_말고_다른_결합_번호는_읽지_못한다() {
        for match in ["0", "3", "x", ""] {
            #expect(Self.reason(SmartPlaylistSource(xml: Self.xml(match: match, Self.condition("name", 1, left: "x")))) != nil, "\(match)")
        }
    }

    @Test func 자동_갱신이_0_1이_아니면_읽지_못한다() {
        for auto in ["2", "x", ""] {
            #expect(Self.reason(SmartPlaylistSource(xml: Self.xml(auto: auto, Self.condition("name", 1, left: "x")))) != nil, "\(auto)")
        }
    }

    @Test func 연산자가_숫자가_아니면_읽지_못한다() {
        let text = Self.xml("<CONDITION PropertyName=\"name\" Operator=\"eq\" ValueUnit=\"\" ValueLeft=\"x\" ValueRight=\"\"/>")
        #expect(Self.reason(SmartPlaylistSource(xml: text)) != nil)
    }

    @Test func 칸이_빠졌거나_모르는_칸이_있으면_읽지_못한다() {
        // 조건의 ValueUnit 없음
        #expect(Self.reason(SmartPlaylistSource(xml: Self.xml(
            "<CONDITION PropertyName=\"name\" Operator=\"1\" ValueLeft=\"x\" ValueRight=\"\"/>"))) != nil)
        // 조건에 모르는 칸
        #expect(Self.reason(SmartPlaylistSource(xml: Self.xml(
            "<CONDITION PropertyName=\"name\" Operator=\"1\" ValueUnit=\"\" ValueLeft=\"x\" ValueRight=\"\" Extra=\"1\"/>"))) != nil)
        // 목록에 AutomaticUpdate 없음·모르는 칸
        #expect(Self.reason(SmartPlaylistSource(xml: "<NODE Id=\"1\" LogicalOperator=\"1\">" + Self.condition("name", 1, left: "x") + "</NODE>")) != nil)
        #expect(Self.reason(SmartPlaylistSource(xml: "<NODE Id=\"1\" LogicalOperator=\"1\" AutomaticUpdate=\"0\" Sort=\"1\">"
                                                 + Self.condition("name", 1, left: "x") + "</NODE>")) != nil)
    }

    @Test func 조건_밖의_자식이나_글자가_있으면_읽지_못한다() {
        // 중첩 NODE는 모양을 모른다
        #expect(Self.reason(SmartPlaylistSource(xml: Self.xml(
            "<NODE Id=\"2\" LogicalOperator=\"2\" AutomaticUpdate=\"0\">" + Self.condition("name", 1, left: "x") + "</NODE>"))) != nil)
        #expect(Self.reason(SmartPlaylistSource(xml: Self.xml(Self.condition("name", 1, left: "x") + "남은 글자"))) != nil)
        // 조건 안의 자식
        #expect(Self.reason(SmartPlaylistSource(xml: Self.xml(
            "<CONDITION PropertyName=\"name\" Operator=\"1\" ValueUnit=\"\" ValueLeft=\"x\" ValueRight=\"\"><X/></CONDITION>"))) != nil)
    }

    @Test func 외부_개체를_따라가지_않는다() {
        let text = "<!DOCTYPE NODE [<!ENTITY secret SYSTEM \"file:///etc/hosts\">]>"
            + "<NODE Id=\"1\" LogicalOperator=\"1\" AutomaticUpdate=\"0\">"
            + "<CONDITION PropertyName=\"name\" Operator=\"8\" ValueUnit=\"\" ValueLeft=\"&secret;\" ValueRight=\"\"/></NODE>"
        let source = SmartPlaylistSource(xml: text)
        // 읽지 못하거나, 읽혀도 파일 내용이 값에 들어가지 않는다
        if let value = Self.definition(source)?.conditions.first?.left { #expect(value.isEmpty) }
    }

    // MARK: DB 칸에서 읽기

    @Test func Attribute_4와_조건_칸이_있으면_조건으로_읽는다() {
        let text = Self.xml(Self.condition("name", 8, left: "x"))
        #expect(Self.definition(SmartPlaylistSource.reading(attribute: 4, smartList: text)) != nil)
    }

    @Test func Attribute_4인데_조건_칸이_비었으면_읽지_못한다() {
        #expect(Self.reason(SmartPlaylistSource.reading(attribute: 4, smartList: nil)) != nil)
        #expect(Self.reason(SmartPlaylistSource.reading(attribute: 4, smartList: "")) != nil)
        #expect(Self.reason(SmartPlaylistSource.reading(attribute: 4, smartList: "  \n")) != nil)
    }

    @Test func 종류가_4가_아니면_조건_칸이_있어도_읽지_못한다() {
        let text = Self.xml(Self.condition("name", 8, left: "x"))
        for attribute in [0, 1, 2, 3, 5] {
            #expect(Self.reason(SmartPlaylistSource.reading(attribute: attribute, smartList: text)) != nil, "\(attribute)")
        }
    }
}
