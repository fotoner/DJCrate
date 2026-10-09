@testable import DJCrate
import DJCApplication
import Testing

/// USB 큐·그리드 가져오기 확인 창. 가져오는 칸 규칙은 DJCApplicationTests `UsbCueGridImportTests`
@Suite("USB 큐·그리드 가져오기 확인 창")
@MainActor
struct UsbCueGridImportPromptTests {
    /// rekordbox 7.2.19 실험 X1(2026-10-08): 평점·색·코멘트는 가져오지 않으므로 확인 창에도 적지 않는다
    @Test func 확인_창은_평점을_적지_않고_비트_그리드를_적는다() {
        let prompt = UsbSyncModel.cueGridImportPrompt
        #expect(!prompt.text.contains("- 레이팅") && prompt.text.contains("- 비트 그리드"))
    }
}
