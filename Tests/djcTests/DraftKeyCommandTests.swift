import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// `djc draft tag --musical-key`(#5): Camelot 이름(1A~12B)만 받고 "8a"는 다듬으며 ''는 키를 지운다.
extension DraftCommandTests {
    /// 곡 101은 키 5A(살아 있는 djmdKey 줄)
    func keyedFixture() throws -> RekordboxFixture {
        let fixture = try fixture()
        try fixture.insert("djmdKey", ["ID": .text("1010000005"), "ScaleName": .text("5A"), "Seq": .int(1), "rb_local_deleted": .int(0)])
        try fixture.execute("UPDATE djmdContent SET KeyID = '1010000005' WHERE ID = '101'")
        return fixture
    }

    /// 다듬기·거절 조합은 Domain `MusicalKeyTagTests`. 여기서는 옵션이 그 규칙을 거쳐 초안이 되는지만 본다.
    @Test(arguments: [("8a", "8A"), ("", "")])
    func 키_옵션은_Camelot_이름으로_다듬어_초안에_담는다(raw: String, expected: String) throws {
        let fixture = try keyedFixture()
        let output = try run(["tag", "101", "--musical-key", raw], fixture: fixture)
        #expect(output.status == 0)
        let draft = try #require(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")))
        #expect(draft.base.musicalKey == "5A" && draft.fields.musicalKey == expected)
        #expect(draft.changedKeys == [.musicalKey])
    }

    @Test func Camelot_이름이_아니면_거절하고_초안을_만들지_않는다() throws {
        let fixture = try keyedFixture()
        let output = try run(["tag", "101", "--musical-key", "Am"], fixture: fixture)
        #expect(output.status != 0)
        let error = try #require(output.document(error: true)["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_arguments" && (error["message"] as? String)?.contains("1A~12B") == true)
        #expect(TagDraftStore.load(trackUUID: "track-101", directory: directory(fixture, "tag")) == nil)
    }

    @Test func 키_칸이_없던_옛_초안은_읽지_못한_초안으로_옮기지_않고_키_기준은_곡의_지금_키다() throws {
        let fixture = try keyedFixture()
        let folder = directory(fixture, "tag")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = #"{"trackUUID":"track-101","base":{"title":"시험 곡","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":""},"fields":{"title":"시험 곡","artist":"","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":"옛 코멘트"}}"#
        try Data(old.utf8).write(to: folder.appending(path: "track-101.json"))
        // 키 옵션 없이 고쳐도 옛 초안을 손상 파일로 옮기지 않는다
        #expect(try run(["tag", "101", "--title", "새 제목"], fixture: fixture).status == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "home/damaged-drafts").path))
        let titled = try #require(TagDraftStore.load(trackUUID: "track-101", directory: folder))
        #expect(titled.fields.title == "새 제목" && titled.fields.comment == "옛 코멘트" && !titled.changedKeys.contains(.musicalKey))
        // 키를 고치면 기준은 곡의 지금 키다
        #expect(try run(["tag", "101", "--musical-key", "8A"], fixture: fixture).status == 0)
        let keyed = try #require(TagDraftStore.load(trackUUID: "track-101", directory: folder))
        #expect(keyed.base.musicalKey == "5A" && keyed.fields.musicalKey == "8A" && keyed.fields.comment == "옛 코멘트")
        #expect(Set(keyed.changedKeys) == [.title, .comment, .musicalKey])
    }
}
