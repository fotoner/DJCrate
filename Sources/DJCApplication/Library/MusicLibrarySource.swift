import DJCDomain
import Foundation

/// Music(iTunes) 보관함과 rekordbox iTunes 동기화 선택(포트). DB 스냅샷 옆 목록 사본(`.itunes.json`)도 여기서 읽고 쓴다.
/// Music·rekordbox에는 쓰지 않는다. 실제 구현(`MusicLibrarySource.live`)은 DJCAdapters, 시험은 메모리 구현(`memory`)을 쓴다.
public struct MusicLibrarySource: Sendable {
    /// Music 보관함 전체와 rekordbox 동기화 선택을 읽는다(느리다, 메인 밖에서). 읽지 못하면 `unavailable`
    public var capture: @Sendable () -> ITunesLibrarySnapshot
    /// DB 사본 옆 목록 사본. 없으면 `notCaptured`, 읽지 못하면 `unavailable`
    public var cached: @Sendable (_ database: URL) -> ITunesLibrarySnapshot
    /// DB 사본 옆에 목록 사본을 쓴다
    public var save: @Sendable (ITunesLibrarySnapshot, _ database: URL) throws -> Void
    /// rekordbox 폴더의 동기화 선택 원문(`playlists3.sync`). 파일이 없으면 nil, 있는데 읽지 못하면 실패
    public var syncFile: @Sendable (_ directory: URL) -> Result<Data, any Error>?
    /// 동기화 선택 원문을 목록 사본에 적용한다(목록 계층이 맞지 않으면 던진다)
    public var applySelection: @Sendable (ITunesLibrarySnapshot, Data) throws -> ITunesLibrarySnapshot
    /// 동기화 선택 원문에서 맨 위(Music 보관함 전체)를 골랐는지
    public var rootSelected: @Sendable (Data) -> Bool
    /// 그 rekordbox 폴더의 동기화 선택이 `since`(전에 읽은 원문)와 달라졌는지
    public var selectionChanged: @Sendable (_ since: Data?, _ directory: URL) -> Bool

    public init(capture: @escaping @Sendable () -> ITunesLibrarySnapshot,
                cached: @escaping @Sendable (_ database: URL) -> ITunesLibrarySnapshot,
                save: @escaping @Sendable (ITunesLibrarySnapshot, _ database: URL) throws -> Void,
                syncFile: @escaping @Sendable (_ directory: URL) -> Result<Data, any Error>?,
                applySelection: @escaping @Sendable (ITunesLibrarySnapshot, Data) throws -> ITunesLibrarySnapshot,
                rootSelected: @escaping @Sendable (Data) -> Bool,
                selectionChanged: @escaping @Sendable (_ since: Data?, _ directory: URL) -> Bool) {
        self.capture = capture
        self.cached = cached
        self.save = save
        self.syncFile = syncFile
        self.applySelection = applySelection
        self.rootSelected = rootSelected
        self.selectionChanged = selectionChanged
    }
}

/// Music 결과는 병렬로 읽되, 같은 DB 사본 옆 목록 사본의 채택·저장은 요청 순서 확인과 한 잠금 안에서 끝낸다.
/// 한 프로세스에 하나를 두고(조립 지점이 넘긴다) 라이브러리 읽기·Music 최신화·iTunes 동기화가 함께 쓴다.
public final class ITunesRefreshCoordinator: @unchecked Sendable {
    public struct Ticket: Sendable {
        let snapshotPath: String
        let sequence: UInt64
        let sourcePath: String
        let writeEpoch: UInt64
    }

    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var latestBySnapshot: [String: UInt64] = [:]
    private var writeEpochBySource: [String: UInt64] = [:]

    public init() {}

    public func begin(snapshot: URL, sourceDatabase: URL? = nil) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        nextSequence &+= 1
        let snapshotPath = snapshot.standardizedFileURL.path
        let sourcePath = (sourceDatabase ?? snapshot).standardizedFileURL.path
        latestBySnapshot[snapshotPath] = nextSequence
        return Ticket(snapshotPath: snapshotPath, sequence: nextSequence, sourcePath: sourcePath,
                      writeEpoch: writeEpochBySource[sourcePath, default: 0])
    }

    public func commit(_ ticket: Ticket, snapshot: URL, current: () -> ITunesLibrarySnapshot,
                       latest: () -> ITunesLibrarySnapshot) -> ITunesLibrarySnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard latestBySnapshot[ticket.snapshotPath] == ticket.sequence,
              writeEpochBySource[ticket.sourcePath, default: 0] == ticket.writeEpoch else { return current() }
        return latest()
    }

    public func publish(sources: [URL], update: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        invalidateSourcesLocked(sources)
        update()
    }

    public func invalidateSnapshots(_ snapshots: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        for snapshot in snapshots {
            nextSequence &+= 1
            latestBySnapshot[snapshot.standardizedFileURL.path] = nextSequence
        }
    }

    private func invalidateSourcesLocked(_ sources: [URL]) {
        for source in sources {
            let path = source.standardizedFileURL.path
            writeEpochBySource[path, default: 0] &+= 1
            nextSequence &+= 1
            latestBySnapshot[path] = nextSequence
        }
    }
}
