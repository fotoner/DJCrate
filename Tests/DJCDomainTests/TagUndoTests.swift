@testable import DJCDomain
import Foundation
import Testing

/// 저장 뒤 ⌘Z(R12, #405)의 태그 몫: 편집 한 번이 바꾼 칸만 지금 rekordbox 값 위에서 편집 전 값으로 되돌린다(평점·곡 색 포함).
/// 앨범·아티스트 칸은 이름·앨범 행을 함께 고쳐 막아 둔 규칙(공유 앨범·동명 앨범·동기화 상태)에 걸리므로 저장 뒤에는 되돌리지 않는다.
@Suite("태그 저장 뒤 ⌘Z 역편집")
struct TagUndoTests {
    static func fields(title: String = "원래 제목", artist: String = "가수", rating: String = "", color: String = "") -> TagFields {
        var fields = TagFields()
        fields.title = title
        fields.artist = artist
        fields.rating = rating
        fields.color = color
        return fields
    }

    @Test func 편집이_바꾼_칸만_편집_전_값으로_되돌린다() throws {
        let original = Self.fields(rating: "2")
        // 편집 전: 초안 없음(rekordbox 값). 편집: 제목·평점
        var after = TagDraft(trackUUID: "t", base: original)
        after.fields.title = "새 제목"
        after.fields.rating = "5"
        // 저장 뒤: rekordbox가 새 값이고 그사이 코멘트를 바깥에서 고쳤다
        var written = after.fields
        written.comment = "바깥 코멘트"
        let current = TagDraft(trackUUID: "t", base: written)
        let reverted = try #require(TagUndo.reverting(before: nil, after: after, onto: current))
        #expect(reverted.base == written)
        #expect(Set(reverted.changedKeys) == [.title, .rating])
        #expect(reverted.fields.title == "원래 제목" && reverted.fields.rating == "2" && reverted.fields.comment == "바깥 코멘트")
    }

    /// 앨범·아티스트도 되돌린다(S12). 되돌린 초안이 도메인 쓰기 규칙(`TagDraft.issues`)에 새로 걸리면 그때만 정할 수 없다
    @Test func 앨범과_아티스트도_되돌리고_쓰기_규칙에_걸리면_정할_수_없다() throws {
        let original = Self.fields()
        var after = TagDraft(trackUUID: "t", base: original)
        after.fields.artist = "새 가수"
        let reverted = try #require(TagUndo.reverting(before: nil, after: after, onto: TagDraft(trackUUID: "t", base: after.fields)))
        #expect(reverted.changedKeys == [.artist] && reverted.fields.artist == "가수")
        // 숫자가 아닌 연도를 고친 편집을 되돌리면 쓰기 규칙에 걸린다
        var odd = original
        odd.year = "모름"
        var fixed = TagDraft(trackUUID: "t", base: odd)
        fixed.fields.year = "2020"
        #expect(TagUndo.reverting(before: nil, after: fixed, onto: TagDraft(trackUUID: "t", base: fixed.fields)) == nil)
    }

    /// 쓴 뒤 바깥에서 같은 칸을 또 바꿨으면(다시 읽기가 늦은 사이 rekordbox에서) 그 편집을 거꾸로 할 모양이 아니다(S4·G2)
    @Test func 되돌릴_칸의_지금_값이_편집_직후_값과_다르면_정할_수_없다() {
        let original = Self.fields(title: "A")
        var after = TagDraft(trackUUID: "t", base: original)
        after.fields.title = "B"
        var outside = after.fields
        outside.title = "C"
        #expect(TagUndo.reverting(before: nil, after: after, onto: TagDraft(trackUUID: "t", base: outside)) == nil)
    }

    @Test func 편집_전_초안이_있었으면_그_초안의_값으로_되돌린다() throws {
        let original = Self.fields()
        var before = TagDraft(trackUUID: "t", base: original)
        before.fields.title = "첫 편집"
        var after = before
        after.fields.title = "둘째 편집"
        let current = TagDraft(trackUUID: "t", base: after.fields)
        let reverted = try #require(TagUndo.reverting(before: before, after: after, onto: current))
        #expect(reverted.fields.title == "첫 편집" && reverted.changedKeys == [.title])
    }

    @Test func 편집을_버린_것을_되돌리면_버린_값을_다시_편집으로_둔다() throws {
        let original = Self.fields()
        var before = TagDraft(trackUUID: "t", base: original)
        before.fields.color = "3"
        // 편집 버리기(초안 없음) 뒤 저장할 것이 없었으니 rekordbox는 그대로다
        let current = TagDraft(trackUUID: "t", base: original)
        let reverted = try #require(TagUndo.reverting(before: before, after: nil, onto: current))
        #expect(reverted.changedKeys == [.color] && reverted.fields.color == "3")
    }
}
