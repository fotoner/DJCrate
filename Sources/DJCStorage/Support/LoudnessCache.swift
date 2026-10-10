import DJCDomain
import DJCEnvironment
import Foundation
import Synchronization

/// 곡 음량 측정값(파일 경로·크기·수정 시각별). 곡을 다시 열 때 디코딩을 기다리지 않고 바로 오토게인을 건다.
/// 고치기는 메인 액터에서 하고, 읽기(`value(for:)`)는 덱이 곡을 올릴 때 메인 스레드 밖에서도 한다.
@MainActor
public final class LoudnessCache {
    /// `DJC_HOME`을 주면 그 아래 `loudness.json`(#195). 처음 쓰는 쪽(덱 불러오기면 메인 밖)에서 파일을 읽는다.
    public nonisolated static let shared = LoudnessCache(url: DJCCachePaths.current.loudness)

    public nonisolated let url: URL
    private nonisolated let saveDelay: Duration
    private nonisolated let values: Mutex<[String: Loudness]>
    /// 파일 상태로 키 만들기(시험이 어느 스레드에서 읽는지 본다)
    private nonisolated let key: @Sendable (URL) -> String?
    private var saveTask: Task<Void, Never>?

    public nonisolated convenience init(url: URL, saveDelay: Duration = .seconds(2)) {
        self.init(url: url, saveDelay: saveDelay, key: Self.fileKey)
    }

    nonisolated init(url: URL, saveDelay: Duration, key: @escaping @Sendable (URL) -> String?) {
        self.url = url
        self.saveDelay = saveDelay
        self.key = key
        var decoded: [String: Loudness] = [:]
        if let data = try? Data(contentsOf: url),
           let values = try? JSONDecoder().decode([String: Loudness].self, from: data) {
            decoded = values
        }
        values = Mutex(decoded)
    }

    public nonisolated func value(for file: URL) -> Loudness? {
        guard let key = key(file) else { return nil }
        return values.withLock { $0[key] }
    }

    public func store(_ loudness: Loudness, for file: URL) {
        guard let key = key(file), values.withLock({ $0[key] }) != loudness else { return }
        values.withLock { $0[key] = loudness }
        scheduleSave()
    }

    /// 지금 라이브러리에 없는 파일의 항목(옮기거나 다시 인코딩해 쌓인 옛 키 포함)을 지운다(#217). 지운 개수를 돌려준다.
    /// - 라이브러리 경로(`keeping`)가 비어 있으면 읽기 실패와 구분할 수 없어 아무것도 지우지 않는다.
    /// - 파일이 있으면 지금 키(크기·수정 시각)만, 못 읽는 곡(꺼 둔 외장 드라이브 등)은 그 경로의 항목을 그대로 둔다.
    /// - 파일 상태를 읽는 일은 메인 스레드와 협력 풀 밖에서 하고, 그동안 새로 저장된 항목은 건드리지 않는다.
    @discardableResult
    public func prune(keeping paths: Set<String>) async -> Int {
        guard !paths.isEmpty else { return 0 }
        let stored = values.withLock { Array($0.keys) }, key = key
        // 잠든 외장 볼륨이면 파일 상태 읽기가 오래 막혀, 협력 풀이 아닌 GCD 스레드에서 읽고 기다린다(옛 detached처럼 취소는 보지 않는다)
        let stale = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .background).async {
                var currentKeys: [String: String?] = [:]
                for path in paths { currentKeys[path] = key(URL(filePath: path)) }
                continuation.resume(returning: stored.filter { key in
                    guard let path = Self.path(of: key), let current = currentKeys[path] else { return true }
                    guard let current else { return false }
                    return current != key
                })
            }
        }
        let removable = values.withLock { values in stale.filter { values[$0] != nil } }
        guard !removable.isEmpty else { return 0 }
        values.withLock { values in removable.forEach { values[$0] = nil } }
        // 기다리던 저장이 옛 값을 다시 쓰지 않도록 새 값으로 다시 예약한다
        scheduleSave()
        return removable.count
    }

    /// 키 `경로|크기|수정 시각`의 경로(경로에 `|`가 있어도 뒤 두 칸만 뗀다)
    nonisolated private static func path(of key: String) -> String? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return parts.dropLast(2).joined(separator: "|")
    }

    private func scheduleSave() {
        // 곡을 빠르게 넘길 때 매번 쓰지 않도록 모아서 저장한다.
        saveTask?.cancel()
        let snapshot = values.withLock { $0 }, url = url, delay = saveDelay
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 마지막으로 예약한 저장이 끝날 때까지(시험이 고정 시간 대신 저장이 끝난 상태를 기다린다)
    public func waitForSave() async {
        await saveTask?.value
    }

    /// 캐시 비우기(설정 › 저장 공간): 기다리던 저장을 거두고 메모리와 파일을 함께 비운다(나중에 옛 값을 다시 쓰지 않게)
    public func clear() {
        saveTask?.cancel()
        saveTask = nil
        values.withLock { $0 = [:] }
        try? FileManager.default.removeItem(at: url)
    }

    /// 경로 + 크기 + 수정 시각(파일을 바꾸면 다시 잰다)
    nonisolated static func fileKey(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(file.path)|\(size)|\(Int(modified.timeIntervalSince1970))"
    }
}
