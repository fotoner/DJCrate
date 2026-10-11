import Foundation

/// USB 읽기·쓰기 오류. 로컬 rekordbox 쓰기 오류(`DJCError`)와 섞지 않는다.
/// `errorDescription`은 앱에 보일 이유와 할 일, `description`은 CLI용 상세(기술 정보·경로 포함)다.
public enum UsbError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// 쓰기 전 막힘. USB는 그대로
    case writeRefused([UsbBlock])
    /// 쓰기 뒤 실패, 백업으로 되돌림
    case writeRolledBack(reason: String)
    /// 쓰기 전 Mac 사본에서 만든 DB를 다시 읽어 확인하지 못함. USB는 열지 않았다(detail은 번역하지 않는 기술 정보)
    case planCheckFailed(detail: String)
    case restoreFailed(reason: String, restoreError: String, backup: String)
    /// 복원을 미룸(rekordbox가 켜져 있음, 복원 대상이 그 사이 바뀜 등. reason이 이유)
    case restorePending(reason: String)
    /// 끝나지 않은 쓰기가 있음
    case recoveryNeeded(volumeName: String)
    /// USB 라이브러리를 읽지 못함(detail은 번역하지 않는 기술 정보)
    case readFailed(detail: String)
    /// 새 rekordbox 버전 등 모르는 형식
    case formatUnsupported(detail: String)
    case diskImageToolFailed(detail: String)
    /// 임시 폴더 밖 경로 거부(lab·디스크 이미지 도구). reason은 영어 고정 식별자
    case pathRefused(path: String, reason: String)
    /// 쓰는 도중 볼륨이 사라짐(뽑힘·강제 분리). 복원하지 않고 멈춘다 — 저널은 회복용으로 남긴다
    case volumeLost(volumeName: String)
    /// 쓰는 도중 같은 자리(마운트 지점)의 볼륨이 처음 USB가 아니게 됨(빠지고 다른 USB가 붙음) 또는 정체를 확인하지 못함.
    /// 그 볼륨에는 아무것도 쓰지 않고(되돌리기도 하지 않고) 멈춘다 — 저널은 처음 USB의 회복용으로 남긴다
    case volumeChanged(volumeName: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .writeRefused(blocks):
            blocks.isEmpty ? String(ui: "USB에 쓰지 않았습니다. 조건을 확인한 뒤 다시 시도하세요")
                : blocks.map(\.message).joined(separator: "\n")
        case .writeRolledBack:
            String(ui: "USB에 쓴 결과를 확인하지 못해 쓰기 전 상태로 되돌렸습니다. USB를 다시 읽은 뒤 다시 시도하세요")
        case .planCheckFailed:
            String(ui: "USB에 쓸 내용을 Mac에서 만들어 확인하지 못해 USB에 쓰지 않았습니다. USB를 다시 읽은 뒤 다시 시도하세요")
        case .restoreFailed:
            String(ui: "USB를 쓰기 전 상태로 되돌리지 못했습니다. 기기에 꽂기 전에 `djc usb-recover`로 회복하세요")
        case let .restorePending(reason):
            String(ui: "USB 복원을 미뤘습니다(\(reason)). 이유를 푼 뒤 `djc usb-recover`로 회복하세요")
        case .recoveryNeeded:
            String(ui: "이 USB에 끝나지 않은 쓰기가 있습니다. 먼저 `djc usb-recover`로 회복하세요")
        case .readFailed:
            String(ui: "USB 라이브러리를 읽지 못했습니다. USB를 다시 연결한 뒤 다시 시도하세요")
        case .formatUnsupported:
            String(ui: "이 USB 라이브러리 형식은 아직 지원하지 않습니다. DJCrate 업데이트를 확인하세요")
        case .diskImageToolFailed:
            String(ui: "디스크 이미지를 다루지 못했습니다. 임시 폴더의 여유 공간을 확인한 뒤 다시 시도하세요")
        case let .pathRefused(_, reason):
            String(ui: "임시 폴더 아래의 경로만 쓸 수 있습니다(\(reason))")
        case .volumeLost:
            String(ui: "USB 연결이 끊겼습니다. 다시 연결한 뒤 `djc usb-recover`로 회복하세요")
        case .volumeChanged:
            String(ui: "쓰는 도중 USB가 바뀌어(또는 확인하지 못해) 멈췄습니다. 지금 USB에는 쓰지 않았습니다. 처음 USB를 다시 꽂고 `djc usb-recover`로 회복하세요")
        case .cancelled:
            String(ui: "USB 작업을 취소했습니다")
        }
    }

    public var description: String {
        switch self {
        case let .writeRefused(blocks):
            // 확인 안 된 규칙은 이름(rawValue)을 code 옆에 적는다. 문구에는 번역된 설명만 있다.
            String(ui: "USB에 쓰지 않았습니다:")
                + blocks.map { "\n- [\($0.code)\($0.rule.map { ":" + $0.rawValue } ?? "")] \($0.message)" }.joined()
        case let .writeRolledBack(reason):
            String(ui: "USB에 쓴 결과를 확인하지 못해 쓰기 전 상태로 되돌렸습니다: \(reason)")
        case let .planCheckFailed(detail):
            String(ui: "USB에 쓸 내용을 Mac에서 만들어 확인하지 못해 USB에 쓰지 않았습니다: \(detail)")
        case let .restoreFailed(reason, restoreError, backup):
            String(ui: """
            USB에 쓴 결과를 확인하지 못했고 쓰기 전 상태로 되돌리지도 못했습니다. USB를 기기에 꽂지 말고 `djc usb-recover`로 회복하세요.
            백업: \(backup)
            확인 실패: \(reason)
            복원 실패: \(restoreError)
            """)
        case let .restorePending(reason):
            String(ui: "USB 복원을 미뤘습니다. 이유를 푼 뒤 `djc usb-recover`를 실행하세요: \(reason)")
        case let .recoveryNeeded(volumeName):
            String(ui: "USB(\(volumeName))에 끝나지 않은 쓰기가 있습니다. 먼저 `djc usb-recover`를 실행하세요")
        case let .readFailed(detail):
            String(ui: "USB 라이브러리를 읽지 못했습니다: \(detail)")
        case let .formatUnsupported(detail):
            String(ui: "지원하지 않는 USB 라이브러리 형식입니다: \(detail)")
        case let .diskImageToolFailed(detail):
            String(ui: "디스크 이미지 도구가 실패했습니다: \(detail)")
        case let .pathRefused(path, reason):
            String(ui: "임시 폴더 아래의 경로만 쓸 수 있습니다(\(reason)): \(path)")
        case let .volumeLost(volumeName):
            String(ui: "쓰는 도중 USB(\(volumeName)) 연결이 끊겼습니다. 다시 연결한 뒤 `djc usb-recover`를 실행하세요")
        case let .volumeChanged(volumeName):
            String(ui: "쓰는 도중 그 자리의 USB가 처음 USB(\(volumeName))가 아니게 되어(또는 확인하지 못해) 멈췄습니다. 지금 붙은 USB에는 쓰지 않았습니다. 처음 USB를 다시 꽂고 `djc usb-recover`를 실행하세요")
        case .cancelled:
            String(ui: "USB 작업을 취소했습니다")
        }
    }
}
