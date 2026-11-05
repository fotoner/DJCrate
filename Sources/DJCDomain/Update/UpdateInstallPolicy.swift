import Foundation


/// rekordbox 쓰기가 어느 단계에 있는가. 종료 대기(#300)와 업데이트 설치 미루기(#59)가 같은 단계로 판단한다.
/// 끊어도 되는 단계는 "아직 아무것도 쓰지 않은 단계"와 "쓴 뒤 읽기만 하는 단계"뿐이다.
public enum RekordboxWritePhase: Equatable, Sendable, CaseIterable {
    /// 쓰지 않는다
    case idle
    /// 미리 보기처럼 아직 아무것도 쓰지 않았고 취소할 수 있는 단계
    case cancellable
    /// 쓰기·복원 확인 창이 떠 있다(아직 아무것도 쓰지 않았다). 답하지 않고 닫으면 쓰지 않는다
    case confirming
    /// 끊으면 안 되는 단계: 백업·DB·분석 파일·초안 정리와 복원
    case writing
    /// 쓴 뒤 다시 읽기. 읽기만 하고 쓴 것은 이미 끝났다
    case readingBack
    /// 쓰기가 실패해 복원까지 실패했다. 사용자가 경고창을 확인해야 한다
    case acknowledging

    /// 끊으면 안 되는 쓰기가 끝났는가. 종료 대기와 업데이트 설치 미루기가 이 판단 하나를 같이 쓴다.
    /// 미리 보기·확인은 아직 쓰지 않았을 뿐 끝난 것이 아니다(업데이트는 사용자의 작업을 취소하지 않고 기다린다).
    public var isFinished: Bool { self == .idle || self == .readingBack }
}

/// 앱이 쓰는 중인 것. 앱이 이미 아는 쓰기 잠금 상태에서 만든다.
public struct AppWriteActivity: Equatable, Sendable {
    /// rekordbox 쓰기·복원·iTunes 동기화(쓰기 잠금)의 단계
    public var rekordbox: RekordboxWritePhase
    /// USB 쓰기·되돌리기·회복(진행 중이거나 볼륨을 붙잡은 작업)
    public var writingUsb: Bool

    public init(rekordbox: RekordboxWritePhase, writingUsb: Bool) {
        self.rekordbox = rekordbox
        self.writingUsb = writingUsb
    }

    public init(writingRekordbox: Bool, writingUsb: Bool) {
        self.init(rekordbox: writingRekordbox ? .writing : .idle, writingUsb: writingUsb)
    }

    public static let idle = AppWriteActivity(rekordbox: .idle, writingUsb: false)

    /// 지금 실제로 쓰는 중이다(끊으면 안 되는 rekordbox 쓰기나 USB 쓰기). 쓰는 동안 시스템이 앱을 예고 없이 끝내지 못하게 막는 때다.
    /// 미리 보기·확인 창·다시 읽기·경고창을 기다리는 동안은 아니다.
    public var isWritingNow: Bool { rekordbox == .writing || writingUsb }

    /// rekordbox 쓰기 잠금이 걸려 있다(어느 단계든). 켜면 끊지 않는 쓰기 단계로 본다.
    public var writingRekordbox: Bool {
        get { rekordbox != .idle }
        set { rekordbox = newValue ? .writing : .idle }
    }
}

/// 업데이트를 설치하고 앱을 다시 켜도 되는지. 쓰는 중에 앱이 꺼지면 라이브러리나 USB가 반쯤 쓴 채로 남는다.
/// 설치의 다시 켜기도 앱 끄기를 지난다(`AppQuitPolicy`). rekordbox 쓰기는 같은 단계 판단(`RekordboxWritePhase.isFinished`)을 쓴다.
public enum UpdateInstallDecision: Equatable, Sendable {
    case proceed
    case waitForRekordbox
    case waitForUsb

    /// 미룰 때 사용자에게 알리는 한 줄
    public var waitMessage: String? {
        switch self {
        case .proceed: nil
        case .waitForRekordbox: String(ui: "rekordbox에 쓰는 중이라 업데이트 설치를 미룹니다. 쓰기가 끝나면 이어서 설치합니다")
        case .waitForUsb: String(ui: "USB에 쓰는 중이라 업데이트 설치를 미룹니다. 쓰기가 끝나면 이어서 설치합니다")
        }
    }
}

public enum UpdateInstallPolicy {
    public static func decision(for activity: AppWriteActivity) -> UpdateInstallDecision {
        if !activity.rekordbox.isFinished { return .waitForRekordbox }
        if activity.writingUsb { return .waitForUsb }
        return .proceed
    }
}
