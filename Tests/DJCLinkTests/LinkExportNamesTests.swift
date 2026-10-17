@testable import DJCLink
import Testing

/// CDJ의 ARTIST·ALBUM·GENRE 목록(2026-10-16 실기): 같은 이름이 곡 수만큼 따로 나왔다. 같은 이름은 한 번호로 합친다.
@Suite("LINK 이름 합치기")
struct LinkExportNamesTests {
    @Test func 같은_이름은_처음_나온_차례의_한_번호로_합친다() {
        let merged = LinkExportServer.mergedIDs(["Aimer", "鈴木このみ", "Aimer", "", "鈴木このみ", "Aimer", ""])
        #expect(merged.names == ["Aimer", "鈴木このみ", ""])
        #expect(merged.ids == [0, 1, 0, 2, 1, 0, 2])
    }

    @Test func 대소문자가_다르면_다른_이름이다() {
        #expect(LinkExportServer.mergedIDs(["AiRI", "AIRI"]).ids == [0, 1])
    }
}
