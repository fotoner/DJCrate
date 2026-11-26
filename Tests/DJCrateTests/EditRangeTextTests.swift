import DJCDomain
import Testing
@testable import DJCrate

/// 곡 편집 창에서 다듬는 동안 보이는 값(클립 옆 칩)
@Suite("곡 편집 창 실시간 값")
struct EditRangeTextTests {
    @Test func 다듬는_구간은_마디_구간과_마디_수를_적는다() {
        #expect(BarRange(3, 6).liveText == "마디 3-6 · 4마디")
        #expect(BarRange(5, 5).liveText == "마디 5 · 1마디")
    }

    @Test func 곡_머리가_든_구간은_마디_수에_곡_머리를_더해_적는다() {
        #expect(BarRange(0, 6).liveText == "마디 0-6 · 6마디 + 곡 머리")
    }
}
