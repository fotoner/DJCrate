import Foundation

/// 재생 목록 초안 파일 잠금(프로세스 사이, flock, #260). 앱은 rekordbox에 쓰는 동안, CLI는 초안을 읽어 계획하고 저장하는 동안 잡는다.
/// 쓰는 동안 CLI가 초안 파일을 고치면 쓴 뒤 정리가 그 편집을 지우거나 낡은 편집으로 남긴다. 프로세스가 죽으면 커널이 푼다(남은 파일은 잠금이 아니다).
public enum PlaylistDraftLock {
    /// 초안 파일 옆의 잠금 파일
    public static func url(for playlist: URL) -> URL {
        playlist.deletingLastPathComponent().appending(path: "playlist-drafts.lock")
    }

    /// 잡으면 푸는 함수(여러 번 불러도 된다)를, 다른 곳이 들고 있으면 `wait`초 동안 다시 해 본 뒤 nil을 준다.
    /// 잠금 파일을 열지 못하면 잡은 것으로 본다(초안 저장이 같은 이유로 실패해 알린다).
    public static func acquire(_ url: URL, wait: TimeInterval = 0) -> (@Sendable () -> Void)? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { return {} }
        let deadline = Date().addingTimeInterval(wait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(descriptor)
                return nil
            }
            usleep(20_000)
        }
        let held = Held(descriptor)
        return { held.release() }
    }

    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?

        init(_ descriptor: Int32) { self.descriptor = descriptor }

        // 푸는 함수를 버리면 잠금도 푼다(파일 설명자를 남기지 않게)
        deinit { release() }

        func release() {
            lock.withLock {
                guard let descriptor else { return }
                // 닫으면 flock도 풀린다
                close(descriptor)
                self.descriptor = nil
            }
        }
    }
}
