import Foundation

/// 앱 종료 요청(⌘Q·메뉴·Dock·업데이트의 다시 켜기·로그아웃)을 받았을 때 할 일
public enum AppQuitDecision: Equatable, Sendable {
    /// 바로 끈다
    case terminateNow
    /// 아직 아무것도 쓰지 않은 취소할 수 있는 단계다. 취소하고 바로 끈다
    case cancelPreparationThenTerminate
    /// rekordbox에 쓰는 중이다. 끝날 때까지 기다렸다 끈다
    case waitForRekordboxWrite
    /// 자동 저장이 곧 쓸 대상 편집이 있다(⌘Q, R17). 그 저장을 기다렸다 끈다
    case waitForAutoSave
    /// 복원까지 실패해 사용자가 경고창을 확인해야 한다. 끄지 않고 그 경고창을 남긴다
    case keepOpenForAcknowledgement
    /// USB에 쓰는 중이다. 끄지 않는다
    case refuseWhileWritingUsb

    /// 사용자에게 보일 이유(끄지 않을 때만)
    public var message: String? {
        switch self {
        case .refuseWhileWritingUsb: String(ui: "USB에 쓰는 중이라 지금은 종료하지 않았습니다. 쓰기가 끝나면 다시 종료하세요")
        default: nil
        }
    }

    /// 기다렸다 끄는가
    public var isWaiting: Bool { self == .waitForRekordboxWrite || self == .waitForAutoSave }
}

/// 종료 요청을 받았을 때 자동 저장의 형편(R17). 앱이 자동 저장 엔진의 상태에서 만든다.
/// 로그아웃·전원 끔은 새 쓰기를 시작하지 않으므로 늘 `off`로 판정한다(이미 시작한 쓰기는 쓰기 단계로 기다린다)
public enum QuitAutoSave: Equatable, Sendable {
    /// 이 실행은 자동 저장하지 않는다
    case off
    /// 자동 저장은 하지만 곧 쓸 대상 편집이 없다(저장됨·대량 유예·확인 필요·멈춤·보류). 남은 편집은 초안으로 남는다
    case idle
    /// 곧 쓴다(마지막 편집 뒤 대기·조용함 대기·시점 스냅샷)
    case waiting
    /// 자동 저장이 지금 쓰는 중이다(미리 보기 포함)
    case writing
}

/// 앱 종료 판정(#300): 쓰기 단계마다 정한다. 기다리는 동안에도 단계가 바뀔 때마다 같은 판정을 다시 한다.
/// "쓰기가 끝났는가"는 `RekordboxWritePhase.isFinished`와 한 판단이다(업데이트 설치 미루기와 같다).
public enum AppQuitPolicy {
    /// - Parameter autoSave: 자동 저장의 형편(R17). 곧 쓸 대상 편집이 있으면 그 저장을 기다린 뒤 끄고, ⌘Q가 기다리는 자동 저장은 미리 보기도 기다린다
    public static func decision(for activity: AppWriteActivity, autoSave: QuitAutoSave = .off) -> AppQuitDecision {
        // USB는 쓰는 중에 끊으면 USB DB가 반쯤 쓴 채로 남는다. 기다리게 하지 않고 거절한다.
        if activity.writingUsb { return .refuseWhileWritingUsb }
        switch activity.rekordbox {
        case .acknowledging: return .keepOpenForAcknowledgement
        // 자동 저장의 미리 보기는 ⌘Q가 기다리는 저장이다(R17). 수동 저장의 미리 보기는 취소하고 끈다
        case .cancellable: return autoSave == .writing ? .waitForRekordboxWrite : .cancelPreparationThenTerminate
        // 확인 창은 답하지 않고 닫으면 쓰지 않는다
        case .confirming: return .terminateNow
        // 나머지는 끊으면 안 되는 쓰기가 끝났는가(`isFinished`)로 가른다. 업데이트 설치 미루기와 같은 판단이다.
        // 끝났으면 자동 저장이 곧 쓸 대상 편집을 기다린다(R17)
        case .idle, .writing, .readingBack:
            guard activity.rekordbox.isFinished else { return .waitForRekordboxWrite }
            switch autoSave {
            case .waiting, .writing: return .waitForAutoSave
            case .off, .idle: return .terminateNow
            }
        }
    }
}

/// 종료를 기다리는 중(「rekordbox에 쓰는 중… 끝나면 종료합니다」). 시각만 든다. 지난 시간은 보이는 쪽이 시계를 읽어 구한다.
public struct QuitWait: Equatable, Sendable {
    public var startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// 기다린 지 몇 초가 지났는가(내림, 시계가 거꾸로 가도 0)
    public func elapsedSeconds(at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt)))
    }

    public static var title: String { String(ui: "rekordbox에 저장하는 중… 끝나면 종료합니다") }

    public static func elapsedText(seconds: Int) -> String { String(ui: "\(seconds)초 지났습니다") }
}
