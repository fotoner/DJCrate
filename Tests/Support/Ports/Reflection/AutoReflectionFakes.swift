import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 프로세스 사이 쓰기 잠금(`RekordboxWriteLock`)의 가짜: 쥔 키를 메모리에 둔다. 다른 프로세스가 쥔 것은 `holdElsewhere`로 흉내 낸다.
/// 가짜의 `lock`은 기본으로 기다리지 않는다: 누가 쥐고 있으면 `MemoryWriteLocks.Busy`를 던진다(시험이 멈추지 않게).
/// `blocksOnLock`을 켜면 풀릴 때까지 기다린다(기다리는 수는 `waiting`. 60초가 지나면 던진다).
/// 실제 구현은 stat·`flock`으로 막으므로 가짜도 협력 풀 밖에서 불렸는지 본다(`expectBlockingOffPool`).
public final class MemoryWriteLocks: Sendable {
    public struct Busy: Error, Equatable {}

    private struct State {
        var held: Set<RekordboxWriteLockKey> = []
        /// 키 계산을 부른 master.db
        var keyed: [URL] = []
        /// 잡은 차례(키)
        var taken: [RekordboxWriteLockKey] = []
        var blocks = false
        var waiting = 0
    }
    private let state = Mutex(State())

    public init() {}

    /// 링크를 푼 경로: 있는 경로는 실제로 링크를 풀고(시험의 임시 파일), 없는 경로(가짜 경로)는 표기만 맞춘다
    public static func resolve(_ database: URL) -> URL { database.standardizedFileURL.resolvingSymlinksInPath() }

    /// 대상 master.db의 키: 링크를 푼 부모 폴더 경로마다 고정된 값(실제 구현은 링크를 푼 부모 폴더의 장치·inode)
    public static func key(for database: URL) -> RekordboxWriteLockKey {
        let folder = resolve(database).deletingLastPathComponent().path
        return RekordboxWriteLockKey(device: 1, inode: UInt64(truncatingIfNeeded: folder.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) }))
    }

    /// 다른 프로세스가 그 키를 쥐었다(또는 놓았다)
    public func holdElsewhere(_ key: RekordboxWriteLockKey, _ held: Bool = true) {
        state.withLock { if held { $0.held.insert(key) } else { $0.held.remove(key) } }
    }

    public var heldKeys: Set<RekordboxWriteLockKey> { state.withLock { $0.held } }
    /// `lock`이 풀릴 때까지 기다리게 한다
    public func blocksOnLock(_ blocks: Bool = true) { state.withLock { $0.blocks = blocks } }
    /// `lock`에서 기다리는 수
    public var waiting: Int { state.withLock { $0.waiting } }
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
            resolve: { database in
                expectBlockingOffPool()
                return Self.resolve(database)
            },
            key: { [self] database in
                expectBlockingOffPool()
                state.withLock { $0.keyed.append(database) }
                return Self.key(for: database)
            },
            lock: { [self] key in
                expectBlockingOffPool()
                if let hold = take(key) { return hold }
                guard state.withLock({ $0.blocks }) else { throw Busy() }
                state.withLock { $0.waiting += 1 }
                defer { state.withLock { $0.waiting -= 1 } }
                for _ in 0..<60_000 {
                    usleep(1_000)
                    if let hold = take(key) { return hold }
                }
                throw Busy()
            },
            tryLock: { [self] key in
                expectBlockingOffPool()
                return take(key)
            })
    }
}

/// 쓰기 잠금 포트의 계약: 같은 master.db는 같은 키, 쥔 키는 다시 들어갈 수 없다(시도는 nil), 풀면 다시 잡힌다, 다른 대상은 따로 잡힌다.
/// 다른 폴더 둘(`database`·`other`)을 준다. `links`(그 master.db를 가리키는 파일·폴더 링크)를 주면 링크를 푼 경로·키·쓰기 기록 자리가
/// 원본과 같은지도 본다(R9·R11: 링크로 가리켜도 같은 잠금, 같은 기록)
public func rekordboxWriteLockContract(_ lock: RekordboxWriteLock, database: URL, other: URL, links: [URL] = []) throws {
    let key = try lock.key(database)
    #expect(try lock.key(database) == key)
    let resolved = try lock.resolve(database)
    for link in links {
        #expect(try lock.resolve(link) == resolved, "링크를 푼 경로가 원본과 같다: \(link.path)")
        #expect(try lock.key(link) == key)
        #expect(RekordboxWriteJournal.url(resolvedDatabase: try lock.resolve(link)) == RekordboxWriteJournal.url(resolvedDatabase: resolved))
    }
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

/// 자동 저장 기록(`AutoReflectionRecords`)의 가짜. `failsLoad`면 읽기가 던진다(엔진은 멈춤으로 본다). `failsSave`면 남기기가 던진다
public final class MemoryAutoReflectionRecords: Sendable {
    public struct LoadFailure: Error {}
    public struct SaveFailure: Error {}
    private let state = Mutex<(record: AutoReflectionRecord, saves: Int, failsLoad: Bool, failsSave: Bool)>((AutoReflectionRecord(), 0, false, false))

    public init(_ record: AutoReflectionRecord = AutoReflectionRecord()) { state.withLock { $0.record = record } }

    public var record: AutoReflectionRecord { state.withLock { $0.record } }
    public var saves: Int { state.withLock { $0.saves } }
    public func failLoading(_ fails: Bool = true) { state.withLock { $0.failsLoad = fails } }
    public func failSaving(_ fails: Bool = true) { state.withLock { $0.failsSave = fails } }

    public var port: AutoReflectionRecords {
        AutoReflectionRecords(load: { [self] in
            try state.withLock { state in
                if state.failsLoad { throw LoadFailure() }
                return state.record
            }
        }, save: { [self] record in
            try state.withLock { state in
                if state.failsSave { throw SaveFailure() }
                state.record = record
                state.saves += 1
            }
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
    /// 실행 상태를 본 횟수(엔진 판정과 자동 쓰기 동안의 메인 밖 표본, #295 E4)
    private let runStateCalls = Mutex(0)
    /// 켜면 실행 상태 보기가 풀릴 때까지 막힌다(오래 걸리는 관찰을 흉내 낸다)
    private let runStateHeld = Mutex(false)
    private let quiet = Mutex(LibraryQuietStamps(walSize: nil, shmExists: false, database: RekordboxFileStamp(size: 4096, modifiedNanoseconds: 1),
                                                 playlistsXML: nil))
    private let published = Mutex<[AutoReflectionStatus]>([])

    public init() {}

    /// rekordbox·Agent 실행 상태를 바꾼다
    public func setRunState(_ value: RekordboxRunState) { runState.withLock { $0 = value } }
    /// 조용함 조건의 파일 상태를 바꾼다
    public func setQuietStamps(_ value: LibraryQuietStamps) { quiet.withLock { $0 = value } }
    /// 지금 조용함 조건의 파일 상태
    public var quietStamps: LibraryQuietStamps { quiet.withLock { $0 } }
    /// 실행 상태를 본 횟수(끝난 것만)
    public var runStateChecks: Int { runStateCalls.withLock { $0 } }
    /// 실행 상태 보기를 막거나 푼다(막힌 동안 부른 쪽은 기다린다, 60초 안전망)
    public func holdRunState(_ held: Bool = true) { runStateHeld.withLock { $0 = held } }
    /// 다음에 조용함 조건의 파일 상태를 읽을 때 한 번 한다(읽는 동안 바깥에서 생긴 일을 흉내 낸다, 메인 밖에서 불린다)
    public func onNextQuietStamps(_ body: @escaping @Sendable () -> Void) { nextQuietStamps.withLock { $0 = body } }
    private let nextQuietStamps = Mutex<(@Sendable () -> Void)?>(nil)
    /// 엔진이 알린 칩 상태(차례대로)
    public var publishedStatuses: [AutoReflectionStatus] { published.withLock { $0 } }

    @MainActor
    public func ports(holds: @escaping @MainActor () -> Set<ReflectionHold> = { [] },
                      pointSnapshot: @escaping @MainActor () async -> AutoSnapshotGate = { .satisfied }) -> AutoReflectionPorts {
        AutoReflectionPorts(clock: clock.clock, runState: { [self] in
                                for _ in 0..<60_000 where runStateHeld.withLock({ $0 }) { usleep(1_000) }
                                defer { runStateCalls.withLock { $0 += 1 } }
                                return runState.withLock { $0 }
                            },
                            quietStamps: { [self] _ in
                                nextQuietStamps.withLock { hook in defer { hook = nil }; return hook }?()
                                return quiet.withLock { $0 }
                            }, writeLock: locks.port, records: records.port,
                            pointSnapshot: pointSnapshot, appHolds: holds,
                            publish: { [self] status, _ in published.withLock { $0.append(status) } })
    }
}
