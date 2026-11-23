import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 프로세스 사이 쓰기 잠금(`RekordboxWriteLock`)의 가짜: 쥔 키를 메모리에 둔다. 다른 프로세스가 쥔 것은 `holdElsewhere`로 흉내 낸다.
/// 가짜의 `lock`은 기다리지 않는다: 누가 쥐고 있으면 `MemoryWriteLocks.Busy`를 던진다(시험이 멈추지 않게).
/// 실제 구현은 stat·`flock`으로 막으므로 가짜도 협력 풀 밖에서 불렸는지 본다(`expectBlockingOffPool`).
public final class MemoryWriteLocks: Sendable {
    public struct Busy: Error, Equatable {}

    private struct State {
        var held: Set<RekordboxWriteLockKey> = []
        /// 키 계산을 부른 master.db
        var keyed: [URL] = []
        /// 잡은 차례(키)
        var taken: [RekordboxWriteLockKey] = []
    }
    private let state = Mutex(State())

    public init() {}

    /// 대상 master.db의 키: 부모 폴더 경로마다 고정된 값(실제 구현은 링크를 푼 부모 폴더의 장치·inode)
    public static func key(for database: URL) -> RekordboxWriteLockKey {
        let folder = database.deletingLastPathComponent().standardizedFileURL.path
        return RekordboxWriteLockKey(device: 1, inode: UInt64(truncatingIfNeeded: folder.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) }))
    }

    /// 다른 프로세스가 그 키를 쥐었다(또는 놓았다)
    public func holdElsewhere(_ key: RekordboxWriteLockKey, _ held: Bool = true) {
        state.withLock { if held { $0.held.insert(key) } else { $0.held.remove(key) } }
    }

    public var heldKeys: Set<RekordboxWriteLockKey> { state.withLock { $0.held } }
    /// 이 포트로 잡은 차례(시도 성공 포함)
    public var taken: [RekordboxWriteLockKey] { state.withLock { $0.taken } }

    private func take(_ key: RekordboxWriteLockKey) -> RekordboxWriteLock.Hold? {
        let taken = state.withLock { state -> Bool in
            guard !state.held.contains(key) else { return false }
            state.held.insert(key)
            state.taken.append(key)
            return true
        }
        guard taken else { return nil }
        let released = Mutex(false)
        return RekordboxWriteLock.Hold(key: key) { [self] in
            guard !released.withLock({ value in defer { value = true }; return value }) else { return }
            _ = state.withLock { $0.held.remove(key) }
        }
    }

    public var port: RekordboxWriteLock {
        RekordboxWriteLock(
            key: { [self] database in
                expectBlockingOffPool()
                state.withLock { $0.keyed.append(database) }
                return Self.key(for: database)
            },
            lock: { [self] key in
                expectBlockingOffPool()
                guard let hold = take(key) else { throw Busy() }
                return hold
            },
            tryLock: { [self] key in
                expectBlockingOffPool()
                return take(key)
            })
    }
}

/// 쓰기 잠금 포트의 계약: 같은 master.db는 같은 키, 쥔 키는 다시 들어갈 수 없다(시도는 nil), 풀면 다시 잡힌다, 다른 대상은 따로 잡힌다.
/// 다른 폴더 둘(`database`·`other`)을 준다. 실제 구현의 별칭·링크 규칙은 어댑터 시험이 따로 본다
public func rekordboxWriteLockContract(_ lock: RekordboxWriteLock, database: URL, other: URL) throws {
    let key = try lock.key(database)
    #expect(try lock.key(database) == key)
    let otherKey = try lock.key(other)
    #expect(otherKey != key)
    let hold = try #require(try lock.tryLock(key))
    #expect(hold.key == key)
    #expect(try lock.tryLock(key) == nil)
    let otherHold = try #require(try lock.tryLock(otherKey))
    hold.release()
    let again = try lock.lock(key)
    again.release()
    otherHold.release()
    #expect(try lock.tryLock(key).map { $0.release(); return true } == true)
}

/// 손으로 넘기는 시계: `sleep`은 `advance`로 그 시각이 지날 때까지 기다린다(시험은 걸린 시간이 아니라 순서로 판정한다, TEST-30)
public final class ManualReflectionClock: Sendable {
    private struct Sleeper {
        var until: Date
        var continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var now: Date
        var sleepers: [Int: Sleeper] = [:]
        var nextID = 0
        /// 잠들기 전에 취소된 잠(취소 처리기가 먼저 돌았다)
        var cancelled: Set<Int> = []
    }
    private let state: Mutex<State>

    public init(start: Date = Date(timeIntervalSince1970: 1_764_000_000)) { state = Mutex(State(now: start)) }

    public var now: Date { state.withLock { $0.now } }
    /// 지금 기다리는 수
    public var sleeping: Int { state.withLock { $0.sleepers.count } }

    private static func interval(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18
    }

    /// 시각을 넘기고 그때까지 기다리던 잠을 깨운다
    public func advance(_ duration: Duration) {
        let woken: [CheckedContinuation<Void, any Error>] = state.withLock { state in
            state.now += Self.interval(duration)
            let due = state.sleepers.filter { $0.value.until <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in woken { continuation.resume() }
    }

    private func nextID() -> Int {
        state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
    }

    /// 잠을 넣는다. 취소 확인과 넣기를 한 잠금 안에서 해서, 취소 처리기가 먼저 돌았어도 놓치지 않는다
    private func store(_ id: Int, _ duration: Duration, _ continuation: CheckedContinuation<Void, any Error>) {
        let cancelled: Bool = state.withLock { state in
            if state.cancelled.remove(id) != nil || Task.isCancelled { return true }
            state.sleepers[id] = Sleeper(until: state.now + Self.interval(duration), continuation: continuation)
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    /// 잠을 깨운다(취소). 아직 넣지 않은 잠이면 표시해 두어 넣을 때 바로 깨운다
    private func cancel(_ id: Int) {
        let sleeper: Sleeper? = state.withLock { state in
            guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                state.cancelled.insert(id)
                return nil
            }
            return sleeper
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }

    private func sleep(_ duration: Duration) async throws {
        let id = nextID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                store(id, duration, continuation)
            }
        } onCancel: {
            cancel(id)
        }
    }

    public var clock: ReflectionClock {
        ReflectionClock(now: { [self] in now }, sleep: { [self] duration in try await sleep(duration) })
    }
}

/// 자동 저장 기록(`AutoReflectionRecords`)의 가짜. `failsLoad`면 읽기가 던진다(엔진은 멈춤으로 본다)
public final class MemoryAutoReflectionRecords: Sendable {
    public struct LoadFailure: Error {}
    private let state = Mutex<(record: AutoReflectionRecord, saves: Int, failsLoad: Bool)>((AutoReflectionRecord(), 0, false))

    public init(_ record: AutoReflectionRecord = AutoReflectionRecord()) { state.withLock { $0.record = record } }

    public var record: AutoReflectionRecord { state.withLock { $0.record } }
    public var saves: Int { state.withLock { $0.saves } }
    public func failLoading(_ fails: Bool = true) { state.withLock { $0.failsLoad = fails } }

    public var port: AutoReflectionRecords {
        AutoReflectionRecords(load: { [self] in
            try state.withLock { state in
                if state.failsLoad { throw LoadFailure() }
                return state.record
            }
        }, save: { [self] record in
            state.withLock { $0.record = record; $0.saves += 1 }
        })
    }
}

/// 자동 저장 기록 포트의 계약: 처음엔 빈 기록, 남긴 것을 같게 읽는다
public func autoReflectionRecordsContract(_ records: AutoReflectionRecords) throws {
    #expect(try records.load() == AutoReflectionRecord())
    let record = AutoReflectionRecord(stop: .afterFailure, cancelledRevisions: [DraftRevision(3), DraftRevision(1)],
                                      preBackupFailure: .init(cause: "백업 폴더", count: 1))
    try records.save(record)
    #expect(try records.load() == record)
    try records.save(AutoReflectionRecord())
    #expect(try records.load() == AutoReflectionRecord())
}

/// 엔진 시험의 가짜 포트 묶음. 정하지 않은 것은 rekordbox 꺼짐·조용한 파일·보류 없음·스냅샷 채움이다
public final class AutoReflectionFakes: Sendable {
    public let clock = ManualReflectionClock()
    public let locks = MemoryWriteLocks()
    public let records = MemoryAutoReflectionRecords()
    private let runState = Mutex(RekordboxRunState.stopped)
    private let quiet = Mutex(LibraryQuietStamps(walSize: nil, shmExists: false, database: RekordboxFileStamp(size: 4096, modifiedNanoseconds: 1),
                                                 playlistsXML: nil))
    private let published = Mutex<[AutoReflectionStatus]>([])

    public init() {}

    /// rekordbox·Agent 실행 상태를 바꾼다
    public func setRunState(_ value: RekordboxRunState) { runState.withLock { $0 = value } }
    /// 조용함 조건의 파일 상태를 바꾼다
    public func setQuietStamps(_ value: LibraryQuietStamps) { quiet.withLock { $0 = value } }
    /// 엔진이 알린 칩 상태(차례대로)
    public var publishedStatuses: [AutoReflectionStatus] { published.withLock { $0 } }

    @MainActor
    public func ports(holds: @escaping @MainActor () -> Set<ReflectionHold> = { [] },
                      pointSnapshot: @escaping @MainActor () async -> AutoSnapshotGate = { .satisfied }) -> AutoReflectionPorts {
        AutoReflectionPorts(clock: clock.clock, runState: { [self] in runState.withLock { $0 } },
                            quietStamps: { [self] _ in quiet.withLock { $0 } }, writeLock: locks.port, records: records.port,
                            pointSnapshot: pointSnapshot, appHolds: holds,
                            publish: { [self] status, _ in published.withLock { $0.append(status) } })
    }
}
