import DJCStorage
import Foundation
import Testing

/// 재생 목록 초안 파일 잠금(#260): 앱이 rekordbox에 쓰는 동안과 CLI가 초안을 읽어 저장하는 동안 서로 고치지 못하게 한다.
/// flock이라 같은 프로세스 안에서도 따로 연 잠금끼리 막는다. 프로세스가 죽으면 커널이 푼다.
@Suite("재생 목록 초안 파일 잠금")
struct PlaylistDraftLockTests {
    func playlistURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-playlist-lock-\(UUID())/playlist-drafts.json")
    }

    @Test func 잡은_동안_다른_잡기는_실패하고_풀면_다시_잡는다() throws {
        let url = PlaylistDraftLock.url(for: playlistURL())
        let first = try #require(PlaylistDraftLock.acquire(url))
        #expect(PlaylistDraftLock.acquire(url) == nil)
        first()
        // 두 번 풀어도 된다
        first()
        let second = try #require(PlaylistDraftLock.acquire(url))
        second()
    }

    @Test func 기다리는_동안_풀리면_잡는다() throws {
        let url = PlaylistDraftLock.url(for: playlistURL())
        let first = try #require(PlaylistDraftLock.acquire(url))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { first() }
        let second = try #require(PlaylistDraftLock.acquire(url, wait: 3))
        second()
    }

    @Test func 잠금_파일은_초안_파일_옆에_두고_폴더가_없으면_만든다() throws {
        let playlist = playlistURL()
        let url = PlaylistDraftLock.url(for: playlist)
        #expect(url.deletingLastPathComponent() == playlist.deletingLastPathComponent())
        #expect(url.lastPathComponent != playlist.lastPathComponent)
        let release = try #require(PlaylistDraftLock.acquire(url))
        release()
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
}
