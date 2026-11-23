import DJCDomain
import Foundation

/// 저장 뒤 ⌘Z가 대기열에 넣는 역편집(R12). 여러 곡에 걸쳐도 한 번의 쓰기로 전부 쓰거나 전부 쓰지 않는다.
/// K행을 넘으면 자동으로 쓰지 않고 ⌘S·저장 단추로 쓴다. 역편집 대상(새 큐 ID 등)을 정하는 일은 W3-F(#405)가 한다.
public struct ReflectionUndoEdit: Equatable, Sendable {
    /// 사용자 동작 하나의 ID(같은 ⌘Z를 두 번 넣지 않는다)
    public var id: String
    /// 되돌릴 값을 담은 초안 묶음
    public var batch: DraftWriteBatch
    /// 이 쓰기가 갱신할 곡 행 수(K와 견준다)
    public var rowCount: Int

    public init(id: String, batch: DraftWriteBatch, rowCount: Int) {
        self.id = id
        self.batch = batch
        self.rowCount = rowCount
    }
}

/// 자동 저장 대기열에 넣는 요청
public enum AutoReflectionRequest: Equatable, Sendable {
    /// ⌘S·저장 단추: 대기 중인 자동 저장을 기다리지 않고 지금 저장한다. 쓰는 중이면 대기열 맨 앞에 넣는다(R3)
    case saveNow
    /// 저장 뒤 ⌘Z의 역편집(R12)
    case undo(ReflectionUndoEdit)
}

/// 자동 저장 엔진(R1~R24의 몸통): 대상 편집을 T_edit 뒤에, rekordbox가 꺼지고 조용해지면, 보류 사유가 없을 때 사용자 조작 없이 저장한다.
/// 저장은 반영 세션(`ReflectionSession`)의 단계로 한다. 쓸지 말지의 마지막 판정은 늘 쓰기 관문이 다시 한다.
/// 앱 수명 동안 조립 지점(`AppComposition`)이 하나 든다. CLI는 쓰지 않는다.
///
/// 지금은 계약만 있는 빈 엔진이다: 아무것도 쓰지 않고 상태도 바꾸지 않는다. 몸체는 W2-D(#403)가 채운다.
@MainActor
public final class AutoReflection {
    public let session: ReflectionSession
    public let ports: AutoReflectionPorts
    public let timing: AutoReflectionTiming
    public let run: AutoReflectionRun
    /// 지금 칩 상태
    public private(set) var status: AutoReflectionStatus = .saved
    /// 상태 줄·⌘S가 보는 지금 조건
    public private(set) var conditions = ReflectionConditions()

    public init(session: ReflectionSession, ports: AutoReflectionPorts, run: AutoReflectionRun, timing: AutoReflectionTiming = .standard) {
        self.session = session
        self.ports = ports
        self.run = run
        self.timing = timing
    }

    /// 첫 읽기와 재시작 정리(R22)가 끝난 뒤 부른다. 남아 있던 대상 편집은 R1과 같은 조건으로 저장한다
    public func start() {}

    /// 앱을 끌 때 대기와 감시를 멈춘다(쓰는 중인 저장은 끝까지 간다)
    public func stop() {}

    /// 대상 편집이 생겼다(저장 대기가 바뀔 때마다). 마지막 편집 뒤 T_edit를 다시 센다
    public func edited() {}

    /// 편집 활동 신호(R1·R19). 편집 중이면 자동 저장을 미룬다
    public func setActivity(_ activity: EditActivity) {}

    /// 대기열에 넣는다
    public func enqueue(_ request: AutoReflectionRequest) {}

    /// 대량 유예의 [취소](R14). 초안은 남고 그 판은 다음 편집이나 ⌘S까지 자동 저장하지 않는다
    public func cancelGrace() {}

    /// ⌘Q(R17): 대기 중인 대상 편집을 저장하고(미리 보기 단계도 기다린다) 끝나면 돌아온다. 유예·확인 필요 편집은 쓰지 않는다
    public func prepareToQuit() async {}

    /// 로그아웃·전원 끔(R17): 새 쓰기를 시작하지 않는다. 이미 시작한 쓰기만 마친다
    public func shutdown() {}
}
