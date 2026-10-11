@testable import DJCrate
import DJCApplication
import Testing

@Suite("USB 동기화 창 닫기")
@MainActor
struct UsbSyncCloseTests {
    /// rekordbox의 닫기 확인과 같은 문구(2026-10-08 실험 G2a)
    @Test func 닫기_확인은_rekordbox와_같은_문구다() {
        let prompt = UsbSyncModel.unsyncedClosePrompt
        #expect(prompt.title == "변경 사항이 동기화되지 않았습니다.")
        #expect(prompt.text == "변경한 내용을 지금 바로 동기화합니까?")
        #expect(prompt.confirm == "예" && prompt.cancel == "아니오")
    }

    /// 닫기는 확인 창·쓰기를 기다리는 동안 다시 불릴 수 있다. 첫 닫기가 끝나기 전 두 번째 닫기는 아무것도 하지 않는다.
    @Test func 닫는_중에_다시_닫으면_들어가지_않는다() {
        let model = UsbSyncModel(volumeKey: "synthetic")
        #expect(model.beginClosing())
        #expect(!model.beginClosing())
        model.endClosing()
        #expect(model.beginClosing())
    }
}
