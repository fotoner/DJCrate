@testable import DJCrate
import Testing

@Suite("동기화 목록 줄의 툴팁")
struct PlaylistSyncRowHelpTests {
    @Test("막힘 이유, 비활성 이유, 흐린 줄의 뜻, 이름 순서로 하나만 고른다")
    func precedence() {
        #expect(PlaylistSyncRowHelp.text(issue: "막힘", lockedReason: "잠김", hint: "뜻", name: "이름") == "막힘")
        #expect(PlaylistSyncRowHelp.text(issue: nil, lockedReason: "잠김", hint: "뜻", name: "이름") == "잠김")
        #expect(PlaylistSyncRowHelp.text(issue: nil, lockedReason: nil, hint: "뜻", name: "이름") == "뜻")
        #expect(PlaylistSyncRowHelp.text(issue: nil, lockedReason: nil, hint: nil, name: "이름") == "이름")
    }
}
