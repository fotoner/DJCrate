import DJCDomain
import Foundation

// 자동 저장 엔진(`AutoReflection`)의 피동 포트. 실제 구현은 조립 지점(`AppComposition`)이 고른다.
// 시계·실행 감지·파일 확인·쓰기 잠금·기록은 DJCAdapters(`.live`), 앱 쪽 보류 사유·시점 스냅샷은 화면 쪽이 붙인다.
// 시험은 가짜를 넣는다(PortTestKit `MemoryWriteLocks`·`ManualReflectionClock`·`MemoryAutoReflectionRecords`).

/// 자동 저장의 수치(스펙 가정 절. E1 측정 없이 정한 값이라 시험은 주입한 값으로만 단정한다)
public struct AutoReflectionTiming: Equatable, Sendable {
    /// T_edit: 마지막 편집 뒤 저장까지
    public var editDelay: Duration
    /// T_quiet: rekordbox·Agent가 꺼진 뒤 조용함
    public var quietDelay: Duration
    /// T_bulk: 대량 유예
    public var bulkDelay: Duration
    /// M: 대량으로 보는 곡 수
    public var bulkTracks: Int
    /// K: 자동 저장 한 번에 갱신할 곡 행의 상한
    public var rowLimit: Int
    /// 처음 몇 번만 성공 토스트를 보인다(R15)
    public var successToasts: Int

    public init(editDelay: Duration, quietDelay: Duration, bulkDelay: Duration, bulkTracks: Int, rowLimit: Int, successToasts: Int) {
        self.editDelay = editDelay
        self.quietDelay = quietDelay
        self.bulkDelay = bulkDelay
        self.bulkTracks = bulkTracks
        self.rowLimit = rowLimit
        self.successToasts = successToasts
    }

    /// 스펙 가정 절의 값: 3초·10초·30초·50곡·200행·5번
    public static let standard = Self(editDelay: .seconds(3), quietDelay: .seconds(10), bulkDelay: .seconds(30), bulkTracks: 50,
                                      rowLimit: 200, successToasts: 5)
}

/// 엔진의 시계(핵심부는 시각·잠자기를 직접 쓰지 않는다)
public struct ReflectionClock: Sendable {
    public var now: @Sendable () -> Date
    /// 기다린다. 취소되면 던진다
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }
}

/// 편집 활동 신호(R1·R19): 하나라도 켜져 있으면 편집 중이라 자동 저장을 미룬다. 자동 저장은 입력을 확정하지 않는다.
/// 창이 뒤로 가는 것은 편집 활동이 아니다(그것만으로는 쓰지 않는다).
public struct EditActivity: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// 미확정 값이 있는 칸의 포커스(Return 전)
    public static let fieldEditing = Self(rawValue: 1 << 0)
    /// 입력기 조합 중
    public static let composing = Self(rawValue: 1 << 1)
    /// 마우스 누름·끌기
    public static let pointerDown = Self(rawValue: 1 << 2)
    /// 태그 시트나 곡 편집 창이 열려 있다
    public static let editorOpen = Self(rawValue: 1 << 3)

    /// 편집 중인지
    public var isEditing: Bool { !isEmpty }
}

/// 조용함 조건(R2)이 보는 대상 폴더의 파일 상태. 메인 액터 밖에서 읽는다
public struct LibraryQuietStamps: Equatable, Sendable {
    /// `-wal` 크기(없으면 nil)
    public var walSize: Int64?
    /// `-shm`이 있는지
    public var shmExists: Bool
    /// master.db 크기·시각
    public var database: RekordboxFileStamp?
    /// masterPlaylists6.xml 크기·시각(없으면 nil)
    public var playlistsXML: RekordboxFileStamp?

    public init(walSize: Int64?, shmExists: Bool, database: RekordboxFileStamp?, playlistsXML: RekordboxFileStamp?) {
        self.walSize = walSize
        self.shmExists = shmExists
        self.database = database
        self.playlistsXML = playlistsXML
    }
}

/// 프로세스 사이 쓰기 잠금(R9). 같은 라이브러리에 쓰는 모든 입구가 같은 잠금을 잡는다. 키는 `RekordboxWriteLockKey`다.
/// 잠금은 다시 들어갈 수 없다: 같은 프로세스라도 쥔 키를 또 잡으면 기다리고(`lock`), 시도는 nil이다(`tryLock`).
/// - 쓰기 관문의 쓰기·복원 입구는 스스로 잠근다. 그래서 이 포트로 쥔 채 그 입구를 부르지 않는다. 엔진은 시도로 비었는지 보고 푼 뒤 부른다.
/// - 기록 판정은 쥔 잠금을 넘겨 그 아래에서 한다(`RekordboxWriteGate.journal`의 `hold`). 시점 스냅샷도 쥔 채 뜬다(R13):
///   잡기 → 기록 판정 → 스냅샷 → 풀기.
/// 실제 구현은 쓰기 입구와 같은 잠금 파일(`flock`)과 같은 링크 풀기(realpath)를 쓴다(DJCAdapters, W1-A).
public struct RekordboxWriteLock: Sendable {
    /// 쥔 잠금. `release`로 푼다(한 번만)
    public struct Hold: Sendable {
        public let key: RekordboxWriteLockKey
        public let release: @Sendable () -> Void

        public init(key: RekordboxWriteLockKey, release: @escaping @Sendable () -> Void) {
            self.key = key
            self.release = release
        }
    }

    /// master.db의 링크를 푼 경로(파일·폴더 링크와 시스템 볼륨 별칭을 푼다). 잠금 키·쓰기 기록 자리
    /// (`RekordboxWriteJournal.url(resolvedDatabase:)`)·준비 폴더가 이 경로를 쓴다. 읽지 못하면 던진다
    public var resolve: @Sendable (_ database: URL) throws -> URL
    /// 대상 master.db의 잠금 키: `resolve`한 경로의 부모 폴더의 장치·inode. 폴더를 읽지 못하면 던진다
    public var key: @Sendable (_ database: URL) throws -> RekordboxWriteLockKey
    /// 잡을 때까지 기다린다(메인 액터 밖에서 부른다)
    public var lock: @Sendable (RekordboxWriteLockKey) throws -> Hold
    /// 비차단 시도. 누가 쥐고 있으면 nil
    public var tryLock: @Sendable (RekordboxWriteLockKey) throws -> Hold?

    public init(resolve: @escaping @Sendable (URL) throws -> URL, key: @escaping @Sendable (URL) throws -> RekordboxWriteLockKey,
                lock: @escaping @Sendable (RekordboxWriteLockKey) throws -> Hold, tryLock: @escaping @Sendable (RekordboxWriteLockKey) throws -> Hold?) {
        self.resolve = resolve
        self.key = key
        self.lock = lock
        self.tryLock = tryLock
    }
}

/// 자동 저장이 다시 켜도 이어 가는 기록. `DJC_HOME` 아래 `auto-reflection.json` 한 파일이다(R7·R8·R14).
public struct AutoReflectionRecord: Codable, Equatable, Sendable {
    public static let fileName = "auto-reflection.json"

    /// 멈춤의 까닭(⌘S·저장 단추로 저장에 성공하면 지운다)
    public enum Stop: String, Codable, Sendable {
        /// 백업을 뜬 뒤 쓰기·검증에 실패해 복구를 마쳤다(R7)
        case afterFailure
        /// 쓰기 전 백업·복원 시점·중단 기록으로 복원했다(R8)
        case afterRestore
    }

    /// 백업 전 실패(R7): 같은 원인으로 두 번 나면 보류한다
    public struct PreBackupFailure: Codable, Equatable, Sendable {
        public var cause: String
        public var count: Int

        public init(cause: String, count: Int) {
            self.cause = cause
            self.count = count
        }
    }

    public var stop: Stop?
    /// [취소]한 초안의 판(R14). 판은 초안 저장소 안에서 겹치지 않아 판만으로 곡 초안·재생 목록 단계를 가리킨다.
    /// 그 초안이 새 판을 받으면(다음 편집) 저절로 풀린다
    public var cancelledRevisions: Set<DraftRevision>
    public var preBackupFailure: PreBackupFailure?

    public init(stop: Stop? = nil, cancelledRevisions: Set<DraftRevision> = [], preBackupFailure: PreBackupFailure? = nil) {
        self.stop = stop
        self.cancelledRevisions = cancelledRevisions
        self.preBackupFailure = preBackupFailure
    }

    private enum CodingKeys: String, CodingKey { case stop, cancelledRevisions, preBackupFailure }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stop = try container.decodeIfPresent(Stop.self, forKey: .stop)
        cancelledRevisions = Set(try container.decodeIfPresent([DraftRevision].self, forKey: .cancelledRevisions) ?? [])
        preBackupFailure = try container.decodeIfPresent(PreBackupFailure.self, forKey: .preBackupFailure)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(stop, forKey: .stop)
        try container.encode(cancelledRevisions.sorted(), forKey: .cancelledRevisions)
        try container.encodeIfPresent(preBackupFailure, forKey: .preBackupFailure)
    }
}

/// 자동 저장 기록 읽기·쓰기(실제 구현은 `DJC_HOME`의 파일)
public struct AutoReflectionRecords: Sendable {
    /// 없으면 빈 기록. 읽지 못하면 던진다(엔진은 멈춤으로 본다)
    public var load: @Sendable () throws -> AutoReflectionRecord
    public var save: @Sendable (AutoReflectionRecord) throws -> Void

    public init(load: @escaping @Sendable () throws -> AutoReflectionRecord, save: @escaping @Sendable (AutoReflectionRecord) throws -> Void) {
        self.load = load
        self.save = save
    }
}

/// 자동 시점 스냅샷과 자동 저장의 순서(R13, D24)
public enum AutoSnapshotGate: Equatable, Sendable {
    /// 채운 것으로 본다: 방금 떴거나, 오늘 이미 떴거나(`.alreadyToday`), 바뀐 것이 없거나(`.unchanged`), 클론이 안 되거나(`.noClone`),
    /// 뜨기에 실패했거나, 설정이 꺼져 있다(쓰기 백업 24시간 보존이 남는다)
    case satisfied
    /// 다른 프로세스가 잠금을 쥐었거나 중단 기록이 있어 뜨지 않았다(보류)
    case held(ReflectionHold)
}

/// 자동 저장 엔진이 받는 포트 묶음
@MainActor
public struct AutoReflectionPorts {
    public var clock: ReflectionClock
    /// rekordbox·Agent 실행 여부(메인 액터 밖에서 부른다. 확인하지 못하면 `.unknown` = 켜짐)
    public var runState: @Sendable () -> RekordboxRunState
    /// 조용함 조건의 파일 상태(메인 액터 밖에서 부른다)
    public var quietStamps: @Sendable (RekordboxWriteTarget) -> LibraryQuietStamps
    public var writeLock: RekordboxWriteLock
    public var records: AutoReflectionRecords
    /// 오늘 뜰 차례면 자동 시점 스냅샷을 뜬다. 한 잠금 아래에서 한다: `writeLock.tryLock`(못 잡으면 `.held(.lockBusy)`) →
    /// `gate.journal(target, hold)`(중단이면 `.held(.interrupted)`) → 스냅샷 → 풀기(R13)
    public var pointSnapshot: @MainActor () async -> AutoSnapshotGate
    /// 앱 쪽 보류 사유(USB 작업·LINK 서버·라이브러리 읽기·막힌 초안 비교 창·가져오기 시트·로그아웃)
    public var appHolds: @MainActor () -> Set<ReflectionHold>
    /// 칩 상태와 조건이 바뀌면 알린다(상태 줄)
    public var publish: @MainActor (AutoReflectionStatus, ReflectionConditions) -> Void

    public init(clock: ReflectionClock, runState: @escaping @Sendable () -> RekordboxRunState,
                quietStamps: @escaping @Sendable (RekordboxWriteTarget) -> LibraryQuietStamps, writeLock: RekordboxWriteLock,
                records: AutoReflectionRecords, pointSnapshot: @escaping @MainActor () async -> AutoSnapshotGate,
                appHolds: @escaping @MainActor () -> Set<ReflectionHold>,
                publish: @escaping @MainActor (AutoReflectionStatus, ReflectionConditions) -> Void = { _, _ in }) {
        self.clock = clock
        self.runState = runState
        self.quietStamps = quietStamps
        self.writeLock = writeLock
        self.records = records
        self.pointSnapshot = pointSnapshot
        self.appHolds = appHolds
        self.publish = publish
    }
}
