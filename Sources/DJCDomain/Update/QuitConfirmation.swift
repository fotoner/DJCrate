import Foundation

/// 아직 rekordbox에 쓰지 않은 편집 수(#326). 상태 줄 칩과 켜진 채 종료 시트가 같은 수·같은 단위(「건」)를 쓴다.
/// 수는 사이드바 「rekordbox 쓰기 대기」 배지와 같은 정의다(곡과 쓰기 대기 재생 기록). 재생 목록 편집은 따로 센다.
public struct PendingWriteCount: Equatable, Sendable {
    public var items: Int
    public var playlistEdits: Int

    public init(items: Int, playlistEdits: Int) {
        self.items = items
        self.playlistEdits = playlistEdits
    }

    /// 쓸 것이 없다
    public var isEmpty: Bool { items <= 0 && playlistEdits <= 0 }

    /// 「쓰기 대기 N건」. 곡이 없고 재생 목록 편집만 있으면 「재생 목록 편집 N건」
    public var text: String {
        items > 0 ? String(ui: "쓰기 대기 \(items)건") : String(ui: "재생 목록 편집 \(playlistEdits)건")
    }
}

/// 종료 요청을 누가 골랐는가(#326). 켜진 채 종료 시트는 사용자가 고른 종료에서만 묻는다.
/// 로그아웃·재시작·전원 끔·업데이트 다시 켜기는 사용자가 앱을 끄려는 것이 아니라 막으면 그 일이 멈추므로 묻지 않는다.
/// 이유를 알 수 없는 종료도 사용자 종료를 막는 쪽이 아니라 묻지 않는 쪽으로 둔다.
public enum AppQuitCause: Equatable, Sendable {
    /// ⌘Q·메뉴 종료·Dock 종료
    case user
    /// 로그아웃·재시작·전원 끔
    case systemShutdown
    /// 업데이트를 설치하고 다시 켜기
    case updateRelaunch
    /// Apple 이벤트의 종료 이유를 읽었으나 모르는 값이다
    case unknown

    public var isUserChosen: Bool { self == .user }

    /// 네 글자 코드(`OSType`)를 값으로
    public static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Apple 이벤트 `quit`에 실려 오는 종료 이유의 열쇠(`kAEQuitReason`, 「why?」)
    public static let quitReasonKeyword = fourCC("why?")

    /// 이유가 일반 종료(`kAEQuitAll`)이거나 없으면 사용자 종료다
    private static let userReasons: Set<UInt32> = [fourCC("quia")]
    /// 로그아웃(`kAEReallyLogOut`·`kAELogOut`)·재시작(`kAERestart`·`kAEShowRestartDialog`)·전원 끔(`kAEShutDown`·`kAEShowShutdownDialog`)
    private static let systemReasons = Set(["rlgo", "logo", "rest", "rrst", "shut", "rsdn"].map(fourCC))

    /// 종료 요청의 출처를 가른다.
    /// - Parameters:
    ///   - quitReason: Apple 이벤트 `quit`의 종료 이유. 이벤트가 없거나(⌘Q·메뉴 종료는 이벤트가 아니다) 이유가 실리지 않았으면(Dock 종료) nil
    ///   - isPoweringOff: Mac을 끄는 중이라는 알림(`willPowerOff`)을 받았다. 로그아웃·재시작·전원 끔 모두에 온다
    ///   - isUpdateRelaunch: 업데이트 설치 뒤 다시 켜려고 앱을 끄는 중이다
    public static func classify(quitReason: UInt32?, isPoweringOff: Bool, isUpdateRelaunch: Bool) -> Self {
        if isPoweringOff { return .systemShutdown }
        if isUpdateRelaunch { return .updateRelaunch }
        guard let quitReason else { return .user }
        if userReasons.contains(quitReason) { return .user }
        if systemReasons.contains(quitReason) { return .systemShutdown }
        return .unknown
    }
}

/// 켜진 채 종료 시트에 보일 내용(#326). 쓰기 대기가 있는데 rekordbox(또는 rekordboxAgent)가 켜져 있어 아직 쓰지 않았다는 것과 할 일을 알린다.
/// 1차에는 자동 쓰기가 없으므로 "다시 열면 저장된다"고 쓰지 않는다. 쓸지 말지는 늘 쓰기 관문이 정한다. 이 값은 문구만 정한다.
public struct QuitConfirmation: Equatable, Sendable {
    public enum Running: Equatable, Sendable {
        /// rekordbox 본체가 켜져 있다
        case rekordbox
        /// rekordbox는 꺼졌고 rekordboxAgent만 켜져 있다
        case agentOnly
    }

    public var running: Running
    public var pending: PendingWriteCount

    public init(running: Running, pending: PendingWriteCount) {
        self.running = running
        self.pending = pending
    }

    public var title: String { String(ui: "쓰기 대기가 남아 있습니다") }

    /// 본문. 수와 단위는 상태 줄 칩과 같다(곡이 있으면 「쓰기 대기 N건」, 재생 목록 편집만이면 「재생 목록 편집 N건」)
    public var message: String {
        let playlistOnly = pending.items <= 0
        let count = playlistOnly ? pending.playlistEdits : pending.items
        switch (running, playlistOnly) {
        case (.rekordbox, false):
            return String(ui: "rekordbox가 켜져 있어 쓰기 대기 \(count)건을 아직 rekordbox에 쓰지 않았습니다. 편집은 DJCrate에 남아 있으니 rekordbox를 끈 뒤 DJCrate에서 쓰세요")
        case (.rekordbox, true):
            return String(ui: "rekordbox가 켜져 있어 재생 목록 편집 \(count)건을 아직 rekordbox에 쓰지 않았습니다. 편집은 DJCrate에 남아 있으니 rekordbox를 끈 뒤 DJCrate에서 쓰세요")
        case (.agentOnly, false):
            return String(ui: "rekordboxAgent가 켜져 있어 쓰기 대기 \(count)건을 아직 rekordbox에 쓰지 않았습니다. 편집은 DJCrate에 남아 있으니 rekordboxAgent를 종료한 뒤 DJCrate에서 쓰세요")
        case (.agentOnly, true):
            return String(ui: "rekordboxAgent가 켜져 있어 재생 목록 편집 \(count)건을 아직 rekordbox에 쓰지 않았습니다. 편집은 DJCrate에 남아 있으니 rekordboxAgent를 종료한 뒤 DJCrate에서 쓰세요")
        }
    }

    public static var quitAnywayTitle: String { String(ui: "그냥 종료") }
    public static var cancelTitle: String { String(ui: "취소") }
}

extension AppQuitPolicy {
    /// 켜진 채 종료 시트를 띄울지(#326). 띄울 때만 내용을 돌려준다.
    /// 묻는 조건: 쓰기 대기가 있다 ∧ rekordbox가 켜져 있거나 rekordboxAgent만 켜져 있다 ∧ 쓰는 중이 아니다 ∧ 사용자가 고른 종료다.
    /// 감지를 못 했거나 아직 읽기 전이면(`unknown`·nil) 거짓으로 "켜져 있어"라고 말하지 않으므로 묻지 않는다.
    /// 쓰는 중이거나 쓰기 단계(미리 보기·확인 창·경고창)가 있으면 시트보다 기존 종료 판정(`decision(for:)`)이 앞선다.
    public static func confirmation(for activity: AppWriteActivity, cause: AppQuitCause, run: RekordboxRunState?,
                                    pending: PendingWriteCount) -> QuitConfirmation? {
        guard cause.isUserChosen, activity == .idle, !pending.isEmpty else { return nil }
        switch run {
        case .running: return QuitConfirmation(running: .rekordbox, pending: pending)
        case .agentOnly: return QuitConfirmation(running: .agentOnly, pending: pending)
        case .stopped, .unknown, nil: return nil
        }
    }
}
