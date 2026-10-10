@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 연결되지 않은 초안 시트의 화면 모델(#249): 목록을 읽고, 고른 것만 확인한 뒤 버리며, 버리지 못하면 이유를 보인다.
@Suite("연결되지 않은 초안 화면 모델")
@MainActor
struct UnlinkedDraftsModelTests {
    final class Fake {
        var drafts: [UnlinkedDraft] = []
        var discarded: [Set<String>] = []
        var failed = 0
        var writing = false
    }

    static func draft(_ uuid: String) -> UnlinkedDraft { UnlinkedDraft(uuid: uuid, kinds: [.cue], title: "곡 \(uuid)", modified: nil) }

    func model(_ fake: Fake) -> UnlinkedDraftsModel {
        UnlinkedDraftsModel(details: { fake.drafts },
                            discard: { uuids in
                                fake.discarded.append(uuids)
                                fake.drafts.removeAll { uuids.contains($0.uuid) }
                                return fake.failed
                            },
                            isWriting: { fake.writing })
    }

    @Test func 읽으면_목록을_채우고_사라진_곡은_고른_것에서_뺀다() {
        let fake = Fake()
        fake.drafts = [Self.draft("a"), Self.draft("b")]
        let model = model(fake)
        #expect(model.drafts.isEmpty)
        model.reload()
        #expect(model.drafts.map(\.uuid) == ["a", "b"])
        model.chooseAll()
        #expect(model.selected == ["a", "b"] && !model.canChooseAll)
        fake.drafts = [Self.draft("b")]
        model.reload()
        #expect(model.selected == ["b"])
    }

    @Test func 고르기_토글과_버리기_단추_막힘() {
        let fake = Fake()
        fake.drafts = [Self.draft("a"), Self.draft("b")]
        let model = model(fake)
        model.reload()
        #expect(!model.canDiscard)
        model.setSelected("a", true)
        #expect(model.isSelected("a") && model.canDiscard)
        fake.writing = true
        #expect(!model.canDiscard, "rekordbox에 쓰는 동안은 버리지 않는다")
        fake.writing = false
        model.setSelected("a", false)
        #expect(model.selected.isEmpty)
    }

    @Test func 확인한_뒤_고른_것만_버리고_목록을_다시_읽는다() {
        let fake = Fake()
        fake.drafts = [Self.draft("a"), Self.draft("b")]
        let model = model(fake)
        model.reload()
        model.setSelected("a", true)
        model.askDiscard()
        #expect(model.confirming)
        model.discard()
        #expect(fake.discarded == [["a"]])
        #expect(model.drafts.map(\.uuid) == ["b"] && model.selected.isEmpty && model.failure == nil)
    }

    @Test func 버리지_못한_곡이_있으면_수와_할_일을_알린다() {
        let fake = Fake()
        fake.drafts = [Self.draft("a")]
        fake.failed = 1
        let model = model(fake)
        model.reload()
        model.chooseAll()
        model.discard()
        #expect(model.failure == "1곡의 초안을 버리지 못했으니 초안 폴더의 접근 권한을 확인한 뒤 다시 버리세요.")
        fake.failed = 0
        model.setSelected("a", true)
        model.discard()
        #expect(model.failure == nil)
    }
}
