import DJCDomain
import Testing

struct ITunesSyncSelectionTests {
    let nodes: [ITunesSyncSelection.Node] = [
        .init(id: "F", parentID: nil, isFolder: true),
        .init(id: "A", parentID: "F", isFolder: false),
        .init(id: "E", parentID: "F", isFolder: true),
        .init(id: "B", parentID: "E", isFolder: false),
        .init(id: "C", parentID: nil, isFolder: false),
    ]

    @Test func 폴더를_고르면_하위와_나중에_추가된_목록도_포함한다() {
        var selection = ITunesSyncSelection()
        selection.setSelected(true, id: "F", in: nodes)
        #expect(selection.expandedIDs(in: nodes) == ["F", "A", "E", "B"])
        let added = nodes + [.init(id: "D", parentID: "E", isFolder: false)]
        #expect(selection.expandedIDs(in: added).contains("D"))
        #expect(selection.state(of: "F", in: nodes) == .on)
    }

    @Test func 하위_하나를_해제하면_다른_선택을_남기고_부모는_부분_선택이다() {
        var selection = ITunesSyncSelection(selectedIDs: ["F"])
        selection.setSelected(false, id: "B", in: nodes)
        #expect(selection.expandedIDs(in: nodes) == ["A"])
        #expect(selection.state(of: "F", in: nodes) == .mixed)
        #expect(selection.state(of: "E", in: nodes) == .off)
        selection.setSelected(false, id: "F", in: nodes)
        #expect(selection.selectedIDs.isEmpty)
    }

    @Test func 빈_폴더와_알_수_없는_ID도_선택을_잃지_않는다() {
        var selection = ITunesSyncSelection(selectedIDs: ["9"])
        selection.setSelected(true, id: "E", in: Array(nodes.prefix(3)))
        #expect(selection.state(of: "E", in: Array(nodes.prefix(3))) == .on)
        #expect(selection.selectedIDs.contains("9"))
    }

    @Test func 하위_목록을_모두_다시_골라도_부모는_부분_선택을_유지한다() {
        let selection = ITunesSyncSelection(selectedIDs: ["A", "B"])
        #expect(selection.state(of: "F", in: nodes) == .mixed)
        #expect(selection.state(of: "E", in: nodes) == .mixed)
    }

    @Test func 전체_선택에서_하나를_해제하면_명시한_하위_선택만_남는다() {
        var selection = ITunesSyncSelection(selectedIDs: ["0"])
        #expect(selection.expandedIDs(in: nodes) == Set(nodes.map(\.id)))
        #expect(selection.state(of: "0", in: nodes) == .on)
        selection.setSelected(false, id: "A", in: nodes)
        #expect(!selection.selectedIDs.contains("0"))
        #expect(selection.expandedIDs(in: nodes) == ["E", "B", "C"])
        #expect(selection.state(of: "F", in: nodes) == .mixed)
    }
}
