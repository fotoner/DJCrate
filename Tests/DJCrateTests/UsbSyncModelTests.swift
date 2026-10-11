@testable import DJCrate
import DJCApplication
import DJCDomain
import Observation
import Synchronization
import Testing

/// 동기화 창 화면 모델(`UsbSyncModel`): 유스케이스(`UsbSync`)가 내보낸 상태·알림을 관찰 상태와 오류·안내 칸으로 옮긴다.
@Suite("USB 동기화 창 화면 모델")
@MainActor
struct UsbSyncModelTests {
    @Test func 알림을_오류와_안내_칸에_보이고_지운다() {
        let model = UsbSyncModel(volumeKey: "synthetic")
        model.show(.problem("막힘"))
        model.show(.info("결과"))
        #expect(model.error == "막힘" && model.message == "결과")
        model.show(.clearInfo)
        #expect(model.error == "막힘" && model.message == nil)
        model.show(.clearProblem)
        #expect(model.error == nil)
    }

    /// 유스케이스가 "다음 닫기까지 남김"을 돌려주면 보이던 이유 뒤에 안내를 붙인다(오류가 없으면 안내 칸에)
    @Test func 다음_닫기까지_남기면_보이던_이유_뒤에_안내를_붙인다() {
        let hint = "한 번 더 닫으면 USB에 쓰지 않고 닫습니다."
        let failed = UsbSyncModel(volumeKey: "synthetic")
        failed.show(.problem("rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요"))
        #expect(!failed.finishClose(.stayUntilNextClose))
        #expect(failed.error == "rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요\n" + hint && failed.message == nil)
        let noticed = UsbSyncModel(volumeKey: "synthetic")
        noticed.show(.info("쓰기 결과 설명"))
        #expect(!noticed.finishClose(.stayUntilNextClose))
        #expect(noticed.error == nil && noticed.message == "쓰기 결과 설명\n" + hint)
        let quiet = UsbSyncModel(volumeKey: "synthetic")
        #expect(!quiet.finishClose(.stayUntilNextClose) && quiet.message == hint)
        #expect(quiet.finishClose(.close) && !quiet.finishClose(.stay))
        #expect(quiet.message == hint, "그냥 남길 때는 안내를 더 붙이지 않는다")
    }

    /// 동기화 후 미리 보기 칸의 문구(계획의 표시 값 → 화면 문구)
    @Test func 미리_보기_칸_표시_문구() {
        #expect(UsbSyncPreviewMark.created.note == "새로 만듦" && UsbSyncPreviewMark.moved.note == "옮김")
        #expect(UsbSyncPreviewMark.unlinked.note == nil)
    }

    /// 핵심부 유스케이스는 관찰 가능하지 않다. 체크를 바꾸면 유스케이스 상태가 화면 모델로 와서 관찰이 알린다
    @Test func 유스케이스_상태가_바뀌면_화면_모델의_관찰이_알린다() {
        let model = UsbSyncModel(volumeKey: "synthetic")
        let changed = Mutex(false)
        withObservationTracking { _ = model.selection } onChange: { changed.withLock { $0 = true } }
        model.selectAllRekordbox()
        #expect(changed.withLock { $0 })
        #expect(model.selection.selectedIDs.contains(UsbSyncSource.rekordboxSelectionID))
    }
}
