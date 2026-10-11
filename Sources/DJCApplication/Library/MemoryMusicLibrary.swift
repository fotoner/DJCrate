import DJCDomain
import Foundation
import Synchronization

/// 파일·Music 없이 메모리에만 두는 Music 보관함(`MusicLibrarySource`의 메모리 구현). 유스케이스·화면 시험이 쓴다.
/// 목록 사본은 DB 경로별, 동기화 선택 원문은 rekordbox 폴더별로 둔다. 원문은 고른 목록 ID를 쉼표로 이은 UTF-8이다
/// (rekordbox의 `playlists3.sync` 형식이 아니다: 해석은 실제 구현만 한다). 맨 위(Music 전체)는 ID "0"이다.
public final class MemoryMusicLibrary: Sendable {
    private struct State {
        var captured = ITunesLibrarySnapshot(status: .unavailable)
        var sidecars: [String: ITunesLibrarySnapshot] = [:]
        var syncFiles: [String: Data] = [:]
        var unreadableSync: Set<String> = []
        var failsSave: Set<String> = []
        var captures = 0
        var saves: [String] = []
    }
    private let state = Mutex(State())

    public init() {}

    /// Music 조회 결과
    public func setCapture(_ snapshot: ITunesLibrarySnapshot) { state.withLock { $0.captured = snapshot } }
    /// DB 사본 옆 목록 사본
    public func setCached(_ snapshot: ITunesLibrarySnapshot?, for database: URL) {
        state.withLock { $0.sidecars[Self.key(database)] = snapshot }
    }
    public func cached(_ database: URL) -> ITunesLibrarySnapshot? { state.withLock { $0.sidecars[Self.key(database)] } }
    /// rekordbox 폴더의 동기화 선택(고른 목록 ID). nil이면 파일 없음
    public func setSelection(_ ids: [String]?, in directory: URL) {
        state.withLock { $0.syncFiles[Self.key(directory)] = ids.map(Self.syncData) }
    }
    /// 동기화 파일이 있지만 읽지 못한다
    public func setUnreadableSelection(in directory: URL) { state.withLock { _ = $0.unreadableSync.insert(Self.key(directory)) } }
    /// 이 DB 옆 목록 사본 저장이 실패한다
    public func failSave(for database: URL) { state.withLock { _ = $0.failsSave.insert(Self.key(database)) } }
    public var captureCount: Int { state.withLock { $0.captures } }
    /// 목록 사본을 저장한 DB(차례대로)
    public var savedDatabases: [String] { state.withLock { $0.saves } }

    /// 고른 목록 ID로 만든 동기화 원문
    public static func syncData(_ ids: [String]) -> Data { Data(ids.joined(separator: ",").utf8) }

    public var source: MusicLibrarySource {
        MusicLibrarySource(
            capture: { [self] in state.withLock { $0.captures += 1; return $0.captured } },
            cached: { [self] database in state.withLock { $0.sidecars[Self.key(database)] } ?? ITunesLibrarySnapshot(status: .notCaptured) },
            save: { [self] snapshot, database in
                try state.withLock { state in
                    guard !state.failsSave.contains(Self.key(database)) else { throw CocoaError(.fileWriteNoPermission) }
                    state.sidecars[Self.key(database)] = snapshot
                    state.saves.append(Self.key(database))
                }
            },
            syncFile: { [self] directory in
                state.withLock { state in
                    let key = Self.key(directory)
                    if state.unreadableSync.contains(key) { return .failure(CocoaError(.fileReadNoPermission)) }
                    return state.syncFiles[key].map { .success($0) }
                }
            },
            applySelection: { snapshot, data in
                guard let text = String(data: data, encoding: .utf8) else { throw ITunesSelectionError.invalidFile }
                let ids = Set(text.split(separator: ",").map(String.init)).subtracting(["0"])
                var result = try ITunesLibrarySnapshot.select(ids: ids, from: snapshot.availablePlaylists)
                result.status = snapshot.status
                result.syncData = data
                return result
            },
            rootSelected: { data in String(data: data, encoding: .utf8)?.split(separator: ",").contains("0") ?? false },
            selectionChanged: { [self] since, directory in
                state.withLock { $0.syncFiles[Self.key(directory)] } != since
            })
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
