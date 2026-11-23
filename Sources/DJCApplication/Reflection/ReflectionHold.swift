import DJCDomain
import Foundation

/// 자동 저장이 지금 쓰지 않는 이유 하나(R2·R3·R7·R8·R9·R10·R11·R13·R16·R17·R18·R20·R22). 엔진(`AutoReflection`)이 모아
/// 상태 줄(R3 표)과 ⌘S 판정에 넘긴다. 쓸지 말지는 이 값이 아니라 엔진·쓰기 관문이 정한다(관문은 늘 다시 본다).
///
/// 셋으로 나뉜다(`kind`).
/// - 보류: 조건이 풀리면 저절로 다시 시작한다.
/// - 멈춤: 사용자가 ⌘S·저장 단추로 저장에 성공하거나 복원해야 풀린다(R7·R8). `DJC_HOME` 아래에 남아 다시 켜도 이어진다.
/// - 중단: 쓰기 기록이 남았다(R11). 기록으로 복원과 "이대로 둔다"만 된다.
public enum ReflectionHold: Hashable, Sendable {
    // MARK: rekordbox 실행·종료 뒤 조용함(R2)

    /// rekordbox가 켜져 있다(감지하지 못하면 켜진 것으로 본다, SAFE-1)
    case rekordboxRunning
    /// rekordbox는 꺼졌고 rekordboxAgent만 켜져 있다
    case agentRunning
    /// 둘 다 꺼진 뒤 T_quiet 동안 꺼져 있고 master.db·masterPlaylists6.xml의 크기·시각이 그대로인지 기다린다(조건 1·4)
    case quietWaiting
    /// 0바이트보다 큰 `-wal`이 남았다(지금의 "정상 종료되지 않음" 안내, 조건 2)
    case walRemains
    /// `-shm`이 남았다(자동 저장만 보는 조건 3)
    case shmRemains
    /// 새로 읽은 사본으로 base를 다시 확인하는 중(조건 5)
    case baseRecheck

    // MARK: 쓸 수 없음(#327, R20, R3 2번 줄)

    /// 지원 밖 버전·DB 구조·카운터(로컬 < 클라우드)·백업 폴더
    case unwritable(LibraryWriteBlock)

    // MARK: 다른 일과 겹침(R16, R3 3번·9번 줄)

    /// 막힌 초안 비교 창이 열려 있다
    case blockedDraftsOpen
    /// USB·XML 가져오기 시트가 열려 있다
    case importSheetOpen
    /// USB 쓰기·내보내기·가져오기 중(USB 쓰기가 라이브 분석 파일을 읽는 동안 라이브러리를 바꾸지 않는다)
    case usbBusy
    /// LINK 서버가 켜져 있다
    case linkServer
    /// 라이브러리를 읽는 중
    case libraryReading
    /// 시점 스냅샷을 기다리거나 뜨는 중(R13: 오늘 뜰 차례면 스냅샷 뒤에 쓴다)
    case pointSnapshot

    // MARK: 쓰기 잠금·대상(R9·R10)

    /// 다른 프로세스가 같은 대상의 쓰기 잠금을 쥐었다(비차단 시도 실패)
    case lockBusy
    /// master.db의 링크 수가 1이 아니다(하드링크)
    case hardLinkedDatabase
    /// 분석 루트의 볼륨에 준비 폴더를 둘 수 없다
    case stagingUnavailable

    // MARK: 백업 조건(R13, R3 8번 줄)

    /// 백업 폴더가 대상과 다른 볼륨이라 클론이 안 된다
    case backupNoClone
    /// 여유 공간이 1GB와 master.db 크기의 3배 중 큰 값보다 적다
    case lowDiskSpace

    // MARK: 실패·복원 뒤(R7·R8)

    /// 백업을 뜨기 전 실패(백업 폴더 쓰기·사본 뜨기)가 같은 원인으로 두 번 났다(보류. 새 편집·⌘S 때 다시 시도)
    case preBackupFailure
    /// 멈춤: 백업을 뜬 뒤 쓰기·검증에 실패해 복구를 마쳤다
    case stoppedAfterFailure
    /// 멈춤: 쓰기 전 백업·복원 시점·중단 기록으로 복원했다
    case stoppedAfterRestore

    // MARK: 중단(R11, R3 1번 줄)

    /// 쓰기 기록이 남았다. 복구까지 실패해 남은 기록이면 `recoveryFailed`
    case interrupted(recoveryFailed: Bool)

    // MARK: 실행·시작·종료(R1·R17·R18)

    /// 자동 저장을 하지 않는 실행(디버그 일반·`--db`·`DJC_DB`·진단, R3 6번 줄)
    case notAutoRun(AutoReflectionRun.Off)
    /// 첫 읽기와 재시작 정리(R22)가 아직 끝나지 않았다
    case starting
    /// 편집 중(미확정 칸·입력기 조합·마우스 누름·편집 창). 마지막 편집 뒤 T_edit를 다시 센다
    case editing
    /// 로그아웃·전원 끔: 새 쓰기를 시작하지 않는다
    case shuttingDown

    // MARK: 정리(R22)

    /// 그 대상의 미정리 목록을 먼저 정리해야 한다
    case cleanupPending
    /// 미정리 목록의 초안 저장소를 확인할 수 없다(정리와 다음 쓰기를 보류)
    case cleanupStoreMissing
    /// 바깥에서 고친 재생 목록 단계의 사본을 남기지 못했다(다음 정리 때 다시 한다)
    case playlistCopyFailed

    /// 보류·멈춤·중단 가운데 어느 것인지
    public var kind: Kind {
        switch self {
        case .stoppedAfterFailure, .stoppedAfterRestore: .stop
        case .interrupted: .interrupted
        default: .hold
        }
    }

    public enum Kind: Hashable, Sendable {
        /// 조건이 풀리면 저절로 다시 시작한다
        case hold
        /// ⌘S·저장 단추로 저장에 성공하거나 복원해야 풀린다
        case stop
        /// 쓰기 기록이 남았다: 기록으로 복원과 "이대로 둔다"만 된다
        case interrupted
    }
}

/// 자동 저장이 스스로 쓰지 않고 남겨 두는 편집의 이유(R3 8번 줄). ⌘S·저장 단추로 함께 쓴다.
public enum ReflectionLeftover: Hashable, Sendable {
    /// 대상 밖 편집: 분석 붙이기·앨범아트·합치기·곡 넣기/빼기·iTunes 동기화·재생 기록·재생 목록/폴더 지우기(R4)
    case outsideScope
    /// 제안: 사람 편집이 아닌 출처·출처 모름·해시가 기록과 다름·출처가 섞임(R5)
    case suggestion
    /// 확인 필요: 막힘·제외·손실이 있어 배경에서 묻지 않고 뺀 곡(R6)
    case needsConfirmation
    /// [취소] 뒤 다음 편집이나 ⌘S까지(R14, 그 초안 판에 묶인다)
    case cancelled
    /// 같은 목록 단계 단위 하나가 K행을 넘는다(R14)
    case overRowLimit
    /// K행을 넘는 역편집(R12)
    case undoOverRowLimit
    /// base 없는 초안(R23)
    case noBase
}

/// 보류 사유를 집합으로 모으려고 더한다(같은 파일 밖이라 손으로 맞춘다. 경우를 더하면 여기도 더한다)
extension LibraryWriteBlock: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .unsupportedVersion(version):
            hasher.combine(0)
            hasher.combine(version)
        case .schema: hasher.combine(1)
        case .counters: hasher.combine(2)
        case .backupFolder: hasher.combine(3)
        }
    }
}
