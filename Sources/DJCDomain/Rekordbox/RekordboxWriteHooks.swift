import Foundation

/// 쓰기 입구 안의 단계(실패 주입·진단용 시각 훅이 가리키는 자리). R10·R11의 자리와 같은 이름을 쓴다.
public enum RekordboxWriteStep: String, Hashable, Codable, CaseIterable, Sendable {
    /// 쓰기 기록 남기기·고치기(`master.db.djc-write`)
    case journalWrite
    /// DB 트랜잭션 시작(`BEGIN IMMEDIATE`)
    case begin
    /// DB COMMIT(체크포인트 포함)
    case commit
    /// DB 파일 교체(복원의 `.djc-restore`를 다 만든 뒤)
    case databaseReplace
    /// `-wal`·`-shm` 삭제
    case sidecarRemove
    /// 분석·그림·XML 파일 하나의 교체·삭제(파일 경계마다 한 번)
    case fileReplace
    /// 커밋 뒤 읽기 검사
    case verify
    /// 자동 복구(`recover`)
    case recovery
    /// 미정리 목록 적기
    case cleanupListWrite
    /// 쓰기 기록 지우기
    case journalRemove
    /// 보고서 저장
    case reportSave
}

/// 훅을 부르는 때
public enum RekordboxWriteMoment: Hashable, Sendable {
    /// 그 단계 바로 직전의 rekordbox·Agent 실행 재확인(R10)
    case recheck(RekordboxWriteStep)
    case before(RekordboxWriteStep)
    case after(RekordboxWriteStep)
}

/// 쓰기 입구의 실패 주입·진단용 시각 훅. 실제 실행은 `.none`(아무것도 하지 않는다)이다.
/// 시험·자가 테스트가 관문을 만들 때 넣는다(관문 주입: `RekordboxWriteGuard(isRekordboxRunning:)`를 단계마다로 넓힌다).
/// 입구는 정한 자리마다 `checkpoint`와 `timing`을 부르고, 재확인 자리에서는 `isRekordboxRunning`이 있으면 실제 확인 대신 그 답을 쓴다.
public struct RekordboxWriteHooks: Sendable {
    /// 자리마다 부른다. 던지면 그 자리에서 실패한 것으로 다룬다(실패 주입). 진단은 여기서 프로세스를 끝내 강제 종료를 흉내 낸다
    public var checkpoint: @Sendable (RekordboxWriteMoment) throws -> Void
    /// 재확인 때와 단계 끝마다 그 시각을 넘긴다(E1: 마지막 재확인부터 그 단계 끝까지)
    public var timing: @Sendable (RekordboxWriteMoment, ContinuousClock.Instant) -> Void
    /// 단계 직전 실행 재확인을 바꿔 넣는다(켜짐 흉내, true면 켜짐). nil이면 실제 확인
    public var isRekordboxRunning: (@Sendable (RekordboxWriteStep) -> Bool)?

    public init(checkpoint: @escaping @Sendable (RekordboxWriteMoment) throws -> Void = { _ in },
                timing: @escaping @Sendable (RekordboxWriteMoment, ContinuousClock.Instant) -> Void = { _, _ in },
                isRekordboxRunning: (@Sendable (RekordboxWriteStep) -> Bool)? = nil) {
        self.checkpoint = checkpoint
        self.timing = timing
        self.isRekordboxRunning = isRekordboxRunning
    }

    /// 실제 실행: 주입 없음
    public static var none: Self { Self() }
}
