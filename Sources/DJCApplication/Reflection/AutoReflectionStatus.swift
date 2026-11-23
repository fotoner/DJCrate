import DJCDomain
import Foundation

/// 자동 저장의 칩 상태: 사용자가 상태 줄에서 보는 상태 하나(상태 그림 `specs/autosave-20261123/state-diagram.md`의 상태).
/// 엔진(`AutoReflection`)이 정하고 상태 줄(`ReflectionStatusModel`)이 글자·모양으로 바꾼다. 쓸 수 없음(#327)은 칩이 따로 앞에 보인다.
public enum AutoReflectionStatus: Equatable, Sendable {
    /// 저장됨: 저장 대기가 없다
    case saved
    /// 저장 대기: 마지막 편집 뒤 T_edit를 기다린다(R1)
    case pending
    /// 대량 유예: 「N초 뒤 저장 · [취소]」(R14)
    case grace(secondsLeft: Int)
    /// rekordbox(또는 rekordboxAgent만) 켜짐(R2)
    case rekordboxRunning(agentOnly: Bool)
    /// 둘 다 꺼진 뒤 조용함 다섯 조건을 기다린다(R2)
    case quietWaiting
    /// 보류: 이유를 보인다. 조건이 풀리면 저절로 다시 시작한다
    case held(ReflectionHold)
    /// 저장 중: 쓰는 묶음의 곡만 잠긴다(R21)
    case writing
    /// 자동 저장하지 않는 편집이 남았다(R3 8번 줄). 수는 상태 줄의 저장 대기 수와 같은 정의다
    case leftover(count: Int)
    /// 멈춤: 실패·복원 뒤(R7·R8). ⌘S·저장 단추로 저장에 성공하면 다시 시작한다
    case stopped(ReflectionHold)
    /// 중단: 쓰기 기록이 남았다(R11). 복원 안내만 보인다
    case interrupted(recoveryFailed: Bool)
    /// ⌘Q 뒤 대기 중인 대상 편집을 저장하고 끄기를 기다린다(R17)
    case quitting
}

/// 상태 줄과 ⌘S가 보는 지금 조건(R3 표의 입력). 엔진이 모으고 상태 줄이 `ReflectionStatusRow.first`로 줄을 고른다.
public struct ReflectionConditions: Equatable, Sendable {
    public var holds: Set<ReflectionHold>
    public var leftovers: Set<ReflectionLeftover>
    /// rekordbox에 쓰는 중(자동·수동)
    public var writing: Bool
    /// 자동 저장 대기(T_edit·대량 유예·조용함 대기)
    public var waiting: Bool
    /// 저장 대기(곡 초안·재생 목록 초안·재생 기록)가 있다
    public var hasPending: Bool
    /// 입력 중인 칸(Return 전)이 있다(R19)
    public var editingField: Bool
    /// 이 실행이 자동 저장하는지(R18)
    public var autoSaves: Bool

    public init(holds: Set<ReflectionHold> = [], leftovers: Set<ReflectionLeftover> = [], writing: Bool = false, waiting: Bool = false,
                hasPending: Bool = false, editingField: Bool = false, autoSaves: Bool = false) {
        self.holds = holds
        self.leftovers = leftovers
        self.writing = writing
        self.waiting = waiting
        self.hasPending = hasPending
        self.editingField = editingField
        self.autoSaves = autoSaves
    }
}

/// 스펙 R3 표의 줄(1~9). 한 번에 여러 줄에 들면 위에 있는 줄을 따른다.
public enum ReflectionStatusRow: Int, CaseIterable, Comparable, Sendable {
    /// 1: 복원 실패(R7), 중단 기록 남음(R11)
    case interrupted = 1
    /// 2: 쓸 수 없음(#327: 지원 밖 버전·DB 구조·카운터(R20)·백업 폴더)
    case unwritable
    /// 3: rekordbox·Agent 켜짐, 막힌 초안 비교 창·가져오기 시트가 열림, USB 쓰기 중
    case busy
    /// 4: 저장 대기 없음
    case nothingPending
    /// 5: rekordbox에 쓰는 중(자동·수동)
    case writing
    /// 6: 자동 저장을 하지 않는 실행(디버그 일반·`--db`·`DJC_DB`·진단, R18)
    case manualRun
    /// 7: 멈춤: 실패 뒤(R7), 복원 뒤(R8)
    case stopped
    /// 8: 자동 저장하지 않는 편집이 남음(대상 밖·제안·확인 필요·백업 조건 미달·백업 전 실패 보류·[취소] 뒤·K행을 넘는 역편집·base 없음)
    case leftover
    /// 9: 자동 저장 대기, 대량 유예, 조용함 대기, LINK 켜짐, 시점 스냅샷 대기·진행, 라이브러리 읽기
    case waiting

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 저장 단추가 보이는지(R3 표의 "저장 단추" 칸)
    public var showsSaveButton: Bool {
        switch self {
        case .manualRun, .stopped, .leftover: true
        case .interrupted, .unwritable, .busy, .nothingPending, .writing, .waiting: false
        }
    }

    /// ⌘S가 하는 일(R3 표의 "⌘S" 칸)
    public var saveCommand: ReflectionSaveCommand {
        switch self {
        case .interrupted: .restoreOnly
        case .unwritable, .busy: .refuseWithReason
        case .nothingPending: .commitFieldThenFollow
        case .writing: .queueFront
        case .manualRun: .saveNow
        case .stopped: .saveAndResume
        case .leftover: .saveAllLeftovers
        case .waiting: .saveNowIfAllowed
        }
    }

    /// 조건이 드는 줄 가운데 맨 위 줄.
    /// 몸체는 W2-E(#404)가 채운다. 그 전에는 지금 동작(저장 대기가 있으면 단추가 보이는 수동 저장)과 같은 줄을 고른다.
    public static func first(_ conditions: ReflectionConditions) -> Self {
        conditions.hasPending ? .manualRun : .nothingPending
    }
}

/// ⌘S(저장 단추도 같다)가 하는 일(R3 표)
public enum ReflectionSaveCommand: Equatable, Sendable {
    /// 쓰지 않는다. 기록으로 복원과 "이대로 둔다"만 된다
    case restoreOnly
    /// 이유를 보이고 쓰지 않는다
    case refuseWithReason
    /// 입력 중인 칸이 있으면 확정한 뒤 5~9번 줄을 따른다. 없으면 꺼진다(R19)
    case commitFieldThenFollow
    /// 대기열 맨 앞에 넣는다
    case queueFront
    /// 지금 저장한다
    case saveNow
    /// 저장한다. 성공하면 자동 저장이 다시 시작한다
    case saveAndResume
    /// 남은 편집을 모두 저장한다. 확인이 필요하면 지금의 확인 창을 띄운다
    case saveAllLeftovers
    /// 관문이 허락하면 지금 저장한다
    case saveNowIfAllowed
}
