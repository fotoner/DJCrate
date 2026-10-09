import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// `djc draft tag --rating`·`--color`(#65): 평점은 별 수(1~5, 0·빈칸은 지우기), 곡 색은 번호('1'~'8')나 rekordbox 색 이름.
/// 쓰기를 확인한 범위 밖의 곡(곡 상태 0·256·257 밖)은 초안을 만들지 않고 이유를 알린다(`TagWriteScope`). 재생 목록에 든 곡은 R65(2026-10-09)로 열었다.
/// 상태·재생 목록별 범위와 옛 초안 읽기·기준 맞추기는 Domain `RatingColorTagTests`가 보고, 여기서는 옵션이 초안이 되는 길과 오류 코드만 본다.
extension DraftCommandTests {
    /// 곡 101: 상태 0, 평점 2, 색 Red('2'), 색 줄 여덟
    func ratedFixture(state: Int = 0) throws -> RekordboxFixture {
        let fixture = try fixture()
        for color in TrackColor.rekordboxDefaults {
            try fixture.insert("djmdColor", ["ID": .text(color.id), "SortKey": .int(Int(color.id) ?? 0), "Commnt": .text(color.name),
                                             "rb_local_deleted": .int(0)])
        }
        try fixture.execute("UPDATE djmdContent SET rb_data_status = ?, Rating = 2, ColorID = '2' WHERE ID = '101'", [.int(state)])
        return fixture
    }

    /// 값 다듬기·거절 조합은 `RatingColorTagTests`(도메인)가 본다. 여기서는 옵션이 그 규칙을 거쳐 초안이 되는지만 본다.
    @Test func 평점은_별_수로_색은_rekordbox_이름도_받아_초안에_담는다() throws {
        let fixture = try ratedFixture()
        let output = try run(["tag", "101", "--rating", "★★★★★", "--color", "blue"], fixture: fixture)
        #expect(output.status == 0)
        let draft = try #require(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")))
        #expect(draft.base.rating == "2" && draft.fields.rating == "5")
        #expect(draft.base.color == "2" && draft.fields.color == "7")
        #expect(draft.changedKeys == [.rating, .color])
        // 고를 수 없는 값은 옵션 오류로 거절하고 초안을 바꾸지 않는다
        let refused = try run(["tag", "101", "--color", "빨강"], fixture: fixture)
        let error = try #require(refused.document(error: true)["error"] as? [String: Any])
        #expect(refused.status != 0 && error["code"] as? String == "invalid_arguments")
        #expect(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")) == draft)
    }

    @Test func 쓰기를_확인하지_않은_상태의_곡은_평점_초안을_만들지_않는다() throws {
        let fixture = try ratedFixture(state: 258)
        let output = try run(["tag", "101", "--rating", "4"], fixture: fixture)
        #expect(output.status != 0)
        let error = try #require(output.document(error: true)["error"] as? [String: Any])
        let message = error["message"] as? String
        #expect(error["code"] as? String == "unverified_field" && message?.contains("평점") == true && message?.contains("초안") == false)
    }
}
