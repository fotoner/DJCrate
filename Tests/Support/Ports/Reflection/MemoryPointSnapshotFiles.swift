import DJCApplication
import DJCDomain
import Foundation
import Synchronization

/// 시점 스냅샷 파일의 메모리 가짜: 만든 스냅샷을 기억하고 부른 차례를 남긴다. 실제(`PointSnapshotFiles.live`)처럼 목록은 최근 것부터,
/// 찾기는 폴더 이름(ID) 또는 겹치지 않는 이름, 고정한 것과 스냅샷 폴더 밖의 항목은 지우지 않는다(`pointSnapshotFilesContract`).
public final class MemoryPointSnapshotFiles: Sendable {
    public struct State: Sendable {
        public var entries: [RekordboxPointSnapshotEntry] = []
        public var diff = RekordboxPointSnapshotDiff()
        public var compareFails = false
        public var liveAndRunning = false
        public var calls: [String] = []
        /// 마지막으로 지은 폴더 번호
        var folders = 0
    }
    public let state = Mutex(State())
    public var calls: [String] { state.withLock { $0.calls } }

    public init() {}

    /// 스냅샷 폴더 `directory`에 스냅샷 하나를 둔다
    public func add(_ name: String, at date: Date, kind: RekordboxPointSnapshotKind = .manual, pinned: Bool = false, restoredFrom: String? = nil,
                    directory: URL = URL(filePath: "/points")) {
        state.withLock {
            var metadata = RekordboxPointSnapshotMetadata(name: name, kind: kind, createdAt: date, pinned: pinned)
            metadata.restoredFrom = restoredFrom
            let url = Self.folder(in: directory, &$0)
            $0.entries.append(RekordboxPointSnapshotEntry(url: url, metadata: metadata))
        }
    }

    /// 겹치지 않는 폴더 이름(ID). 실제처럼 이름과 따로 짓는다(실제는 뜬 시각)
    static func folder(in directory: URL, _ state: inout State) -> URL {
        state.folders += 1
        return directory.appending(path: "point-\(state.folders)")
    }

    static func entries(_ state: State, in directory: URL) -> [RekordboxPointSnapshotEntry] {
        state.entries.filter { $0.url.deletingLastPathComponent().path == directory.path }
            .sorted { ($0.metadata.createdAt, $0.id) > ($1.metadata.createdAt, $1.id) }
    }

    static func owned(_ url: URL, in directory: URL, _ state: State) throws -> Int {
        guard url.deletingLastPathComponent().path == directory.path, let index = state.entries.firstIndex(where: { $0.url == url }) else {
            throw DJCError.writeRefused("스냅샷 폴더 밖")
        }
        return index
    }

    public var port: PointSnapshotFiles {
        PointSnapshotFiles(
            create: { name, _, _, directory, _, now in
                self.state.withLock { state in
                    state.calls.append("create \(name)")
                    let entry = RekordboxPointSnapshotEntry(url: Self.folder(in: directory, &state),
                                                            metadata: RekordboxPointSnapshotMetadata(name: name, kind: .manual, createdAt: now))
                    state.entries.append(entry)
                    return entry
                }
            },
            list: { directory in self.state.withLock { Self.entries($0, in: directory) } },
            find: { key, directory in
                self.state.withLock { state in
                    let entries = Self.entries(state, in: directory)
                    if let entry = entries.first(where: { $0.id == key }) { return entry }
                    let named = entries.filter { !$0.metadata.name.isEmpty && $0.metadata.name == key }
                    return named.count == 1 ? named[0] : nil
                }
            },
            setPinned: { pinned, url, directory in
                try self.state.withLock { state in
                    state.calls.append("pin \(pinned)")
                    let index = try Self.owned(url, in: directory, state)
                    state.entries[index].metadata.pinned = pinned
                }
            },
            delete: { url, directory in
                try self.state.withLock { state in
                    let index = try Self.owned(url, in: directory, state)
                    state.calls.append("delete \(state.entries[index].metadata.name)")
                    if state.entries[index].metadata.pinned { throw DJCError.writeRefused("고정") }
                    state.entries.remove(at: index)
                }
            },
            compare: { _, _, _ in
                try self.state.withLock { state in
                    state.calls.append("compare")
                    if state.compareFails { throw DJCError.writeRefused("비교 실패") }
                    return state.diff
                }
            },
            size: { _ in 10 },
            canClone: { _, _ in true },
            isLiveAndRunning: { _ in self.state.withLock { $0.liveAndRunning } },
            isRekordboxRunning: { false },
            takeAutoIfDue: { _, _, _, _, _, _, _ in .skipped(.unchanged) },
            discard: { _ in })
    }
}
