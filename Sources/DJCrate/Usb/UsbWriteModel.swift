import DJCApplication
import DJCDomain
import Foundation
import Observation

/// USB 쓰기 세션의 화면 모델: 핵심부 세션(`UsbWriteSession`)이 출력 포트로 내보낸 흐름 상태를 관찰 상태로 옮긴다.
/// 덮개(`UsbWritingOverlay`)와 사이드바·쓰기 대기·시트는 `UsbStore`를 거쳐 읽는다. 잠금·진행의 규칙은 세션에 있다.
@MainActor @Observable
final class UsbWriteModel {
    @ObservationIgnored let session: UsbWriteSession
    /// 볼륨별 잠금(쓰기 중 표시)
    private(set) var busyVolumes: Set<String> = []
    /// 지금 쓰는 볼륨과 진행(덮개가 읽는다)
    private(set) var activeWrite: UsbActiveWrite?
    /// 이 실행에서 옮긴 쓰기의 백업(사이드바 "쓰기 전으로 되돌리기…")
    private(set) var migrationBackups: [String: URL] = [:]
    /// 마지막 옮기기 미리 보기의 막힘(사이드바 도움말)
    private(set) var migrationBlockReasons: [String: String] = [:]

    init(session: UsbWriteSession = UsbWriteSession()) {
        self.session = session
        apply(session.state)
        session.output = UsbWriteSessionOutput(changed: { [weak self] in self?.apply($0) })
    }

    /// 덮개의 취소 단추. 받을지는 세션이 정한다(DB 교체가 시작되면 받지 않는다)
    func cancel() { session.cancel() }

    /// 칸마다 따로 옮긴다. Observation은 같은 값이면 알리지 않으므로, 쓰는 동안 진행이 자주 바뀌어도
    /// 잠금·옮기기만 보는 뷰는 다시 그리지 않는다(`UsbWriteModelTests`가 본다)
    private func apply(_ state: UsbWriteSessionState) {
        busyVolumes = state.busyVolumes
        activeWrite = state.activeWrite
        migrationBackups = state.migrationBackups
        migrationBlockReasons = state.migrationBlockReasons
    }
}
