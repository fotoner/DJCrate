import DJCApplication
import DJCDomain
import Foundation

/// 상태 줄 칩이 보이는 것 하나(R3 표의 "상태 줄" 칸): 글자·모양·툴팁·팝오버 보조 글. 엔진 상태를 R3 표의 줄 순서대로 글로 옮긴다.
struct ReflectionStatusLine: Equatable {
    /// 칩 앞의 모양(색만으로 알리지 않는다: 글자가 늘 이유를 말한다)
    enum Symbol: Equatable {
        /// 저장 대기 없음
        case saved
        /// 저장 대기(자동 저장이 곧 쓰거나 기다린다, 직접 저장할 편집이 남았다)
        case pending
        case writing
        /// 지금은 쓰지 못한다: 쓸 수 없음·켜짐·다른 일
        case warning
        /// 자동 저장이 멈췄다
        case stopped
        /// 끝나지 않은 저장 기록
        case interrupted
    }

    var title: String
    var symbol: Symbol
    /// 칩 툴팁(비활성 이유·할 일, STR-13). 없으면 달지 않는다
    var help: String?
    /// 팝오버 보조 글: 칩이 말한 이유의 전문과 함께 걸린 다른 이유
    var details: [String] = []
}

/// 엔진이 모은 조건(`ReflectionConditions`)을 상태 줄의 글로 옮긴다. 어느 줄에 드는지는 `ReflectionStatusRow.first`가 고른다.
/// 쓸 수 없음(#327)·켜짐 이유(#326)는 지금 칩과 같은 문구를 쓴다.
@MainActor
enum ReflectionStatusText {
    /// - Parameters:
    ///   - count: 저장 대기 수(저장소의 쓰기 대기와 같은 정의)
    ///   - showsWriting: 쓰기 단계가 1초 넘게 이어졌다(짧은 쓰기가 깜빡이지 않게 그때부터 「저장하는 중」을 보인다)
    static func line(status: AutoReflectionStatus, conditions: ReflectionConditions, row: ReflectionStatusRow,
                     count: PendingWriteCount, showsWriting: Bool) -> ReflectionStatusLine {
        let holds = conditions.holds
        switch row {
        case .interrupted:
            let failed = holds.contains(.interrupted(recoveryFailed: true))
            return ReflectionStatusLine(title: failed ? String(ui: "복구하지 못한 쓰기가 있습니다") : String(ui: "쓰다가 중단된 기록이 있습니다"),
                                        symbol: .interrupted)
        case .unwritable:
            let block = holds.compactMap { hold -> LibraryWriteBlock? in if case let .unwritable(block) = hold { block } else { nil } }.first
            let help = block?.reason ?? String(ui: "DJCrate가 확인하지 못한 파일 구성이라 저장하지 않습니다. rekordbox 폴더를 확인하세요")
            return ReflectionStatusLine(title: reasonFirst(String(ui: "rekordbox에 저장할 수 없음"), count), symbol: .warning, help: help,
                                        details: [help])
        case .busy:
            guard let hold = busyHolds.first(where: holds.contains) else {
                return ReflectionStatusLine(title: countText(count), symbol: .warning)
            }
            let help = busyHelp(hold)
            return ReflectionStatusLine(title: reasonFirst(busyTitle(hold), count), symbol: .warning, help: help, details: [help].compactMap { $0 })
        case .nothingPending:
            return ReflectionStatusLine(title: String(ui: "저장 대기 없음"), symbol: .saved)
        case .writing:
            guard showsWriting else { return ReflectionStatusLine(title: countText(count), symbol: .pending) }
            return ReflectionStatusLine(title: String(ui: "rekordbox에 저장하는 중…"), symbol: .writing)
        case .manualRun:
            return ReflectionStatusLine(title: countText(count), symbol: .pending)
        case .stopped:
            let reason = holds.contains(.stoppedAfterFailure) ? String(ui: "저장하지 못해 자동 저장이 멈췄습니다") : String(ui: "복원해서 자동 저장이 멈췄습니다")
            return ReflectionStatusLine(title: reasonFirst(reason, count), symbol: .stopped)
        case .leftover:
            let reasons = leftoverReasons(conditions)
            guard let first = reasons.first else { return ReflectionStatusLine(title: countText(count), symbol: .pending) }
            return ReflectionStatusLine(title: String(ui: "\(countText(count)) · \(first)"), symbol: .pending, details: Array(reasons.dropFirst()))
        case .waiting:
            if case let .grace(seconds) = status { return ReflectionStatusLine(title: String(ui: "\(seconds)초 뒤 저장"), symbol: .pending) }
            guard let reason = waitingReason(holds) else { return ReflectionStatusLine(title: countText(count), symbol: .pending) }
            return ReflectionStatusLine(title: reasonFirst(reason, count), symbol: .pending)
        }
    }

    // MARK: - 글

    /// 이유 뒤에 저장 대기 수를 잇는다(수가 없으면 이유만)
    private static func reasonFirst(_ reason: String, _ count: PendingWriteCount) -> String {
        count.isEmpty ? reason : String(ui: "\(reason) · \(count.text)")
    }

    private static func countText(_ count: PendingWriteCount) -> String {
        count.isEmpty ? String(ui: "저장 대기") : count.text
    }

    /// 3번 줄 사유를 칩이 말하는 차례
    private static let busyHolds: [ReflectionHold] = [.rekordboxRunning, .agentRunning, .usbBusy, .blockedDraftsOpen, .importSheetOpen, .walRemains,
                                                      .shuttingDown, .cleanupPending, .cleanupStoreMissing, .playlistCopyFailed]

    static func busyTitle(_ hold: ReflectionHold) -> String {
        switch hold {
        case .rekordboxRunning: ReflectionChip.Reason.rekordboxRunning.text
        case .agentRunning: ReflectionChip.Reason.agentRunning.text
        case .usbBusy: String(ui: "USB에 쓰는 중…")
        case .blockedDraftsOpen: String(ui: "막힌 편집 비교 창이 열려 있습니다")
        case .importSheetOpen: String(ui: "가져오기 창이 열려 있습니다")
        case .walRemains: String(ui: "rekordbox가 정상 종료되지 않았습니다")
        case .shuttingDown: String(ui: "종료하는 중입니다")
        default: String(ui: "이전 저장의 정리가 끝나지 않았습니다")
        }
    }

    /// 칩 툴팁이자 ⌘S가 이유로 보이는 문장(원인과 할 일, STR-16)
    static func busyHelp(_ hold: ReflectionHold) -> String? {
        switch hold {
        case .rekordboxRunning: ReflectionPrompts.quitRekordboxText
        case .agentRunning: String(ui: "rekordboxAgent를 종료한 뒤 저장하세요")
        case .usbBusy: String(ui: "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요")
        case .blockedDraftsOpen: LibraryStore.writesBlockedBySheetReason
        case .importSheetOpen: String(ui: "가져오기 창에서 적용하거나 닫은 뒤 다시 시도하세요")
        case .walRemains: String(ui: "rekordbox가 정상적으로 종료되지 않은 것 같습니다(WAL 파일이 남아 있음). rekordbox를 한 번 켰다가 종료한 뒤 다시 시도하세요")
        case .shuttingDown: nil
        default: ReflectionSession.playlistSaveFailureText
        }
    }

    /// 3번 줄에서 칩과 ⌘S가 말하는 사유
    static func topBusyHold(_ conditions: ReflectionConditions) -> ReflectionHold? {
        busyHolds.first(where: conditions.holds.contains)
    }

    /// 3번 줄에서 ⌘S가 이유로 보일 알림(칩이 말하는 사유 기준)
    static func refusal(_ conditions: ReflectionConditions) -> (title: String, detail: String?)? {
        guard let hold = topBusyHold(conditions) else { return nil }
        switch hold {
        case .rekordboxRunning: return (String(ui: "rekordbox가 켜져 있어 저장하지 않았습니다"), ReflectionPrompts.quitRekordboxText)
        case .agentRunning: return (ReflectionChip.Reason.agentRunning.text, busyHelp(hold))
        default: return (busyHelp(hold) ?? busyTitle(hold), nil)
        }
    }

    /// 8번 줄: 자동 저장하지 않고 남긴 이유(말하는 차례). 같은 문장은 한 번만
    private static func leftoverReasons(_ conditions: ReflectionConditions) -> [String] {
        var reasons: [String] = []
        func add(_ text: String) { if !reasons.contains(text) { reasons.append(text) } }
        let leftovers = conditions.leftovers, holds = conditions.holds
        if leftovers.contains(.cancelled) { add(String(ui: "자동 저장을 취소함")) }
        if leftovers.contains(.needsConfirmation) { add(String(ui: "확인이 필요함")) }
        if leftovers.contains(.outsideScope) { add(String(ui: "자동 저장 대상이 아님")) }
        if leftovers.contains(.suggestion) { add(String(ui: "다른 곳에서 만든 편집")) }
        if leftovers.contains(.overRowLimit) || leftovers.contains(.undoOverRowLimit) { add(String(ui: "양이 많아 자동 저장하지 않음")) }
        if leftovers.contains(.noBase) { add(String(ui: "기준 값이 없음")) }
        if holds.contains(.preBackupFailure) { add(String(ui: "백업을 만들지 못함")) }
        if holds.contains(.backupNoClone) { add(String(ui: "백업 폴더가 다른 디스크임")) }
        if holds.contains(.lowDiskSpace) { add(String(ui: "디스크 공간이 모자람")) }
        return reasons
    }

    /// 9번 줄: 기다리는 이유(없으면 그냥 저장 대기)
    private static func waitingReason(_ holds: Set<ReflectionHold>) -> String? {
        if holds.contains(.libraryReading) { return String(ui: "rekordbox 라이브러리를 읽는 중…") }
        if holds.contains(.pointSnapshot) { return String(ui: "복원 시점을 남기는 중…") }
        if holds.contains(.lockBusy) { return String(ui: "다른 프로그램이 쓰는 중…") }
        if holds.contains(.linkServer) { return String(ui: "LINK가 켜져 있습니다") }
        if holds.contains(.quietWaiting) { return ReflectionChip.Reason.rekordboxStopped.text }
        return nil
    }
}
