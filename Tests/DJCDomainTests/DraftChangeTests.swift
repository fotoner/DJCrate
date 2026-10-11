import DJCDomain
import Testing

@Suite("초안 변경 스냅샷")
struct DraftChangeTests {
    @Test func 같은_상태는_이력을_만들지_않는다() {
        #expect(DraftChange(before: [1, 2], after: [1, 2]) == nil)
    }

    @Test func 반대_변경은_전후_값을_그대로_맞바꾼다() throws {
        let change = try #require(DraftChange(before: ["제목": "원본"], after: ["제목": "편집"]))
        #expect(change.reversed.before == change.after)
        #expect(change.reversed.after == change.before)
        #expect(change.reversed.reversed == change)
    }
}
