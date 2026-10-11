import DJCDomain
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("쓰기 대상 구조 안내")
struct BlockedStructureReasonTests {
    @Test(arguments: ["missing", "deleted", "duplicate"])
    func 재동기화할_대상과_지원하지_않는_구조를_구별한다(kind: String) throws {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "1", uuid: "structural-track")
        if kind != "missing" { try fixture.add(spec) }
        if kind == "deleted" { try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '1'") }
        if kind == "duplicate" { spec.id = "2"; try fixture.add(spec) }
        var fields = TagFields()
        fields.title = spec.title
        var draft = TagDraft(trackUUID: spec.uuid, base: fields)
        draft.fields.comment = "합성 코멘트"
        let report = try RekordboxWriter.write(drafts: [], tags: [draft], to: fixture.database,
                                               dryRun: true, backups: fixture.backups, shareRoot: fixture.shareRoot)
        let reason = try #require(report.tagBlocked.first?.reason)
        #expect(reason.contains(kind == "duplicate" ? "지원하지" : "동기화"))
        #expect(report.tagWritten.isEmpty)
    }
}
