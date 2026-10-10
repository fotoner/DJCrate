import DJCApplication
import DJCDomain
import Foundation

/// 라이브러리 읽기 흐름(`LibraryReadFlow`)이 보는 화면의 가짜. 상태를 메모리에 두고 받은 알림을 차례로 남긴다.
/// 읽은 결과는 앱의 `LibraryStore`처럼 사본·순번·곡 유무·Music 목록만 상태에 넣는다.
@MainActor
public final class FakeLibraryReadScreen {
    public var state = LibraryReadState()
    /// 받은 알림(차례대로). 읽은 결과 넣기는 "adopt <사본 이름>"
    public private(set) var events: [String] = []
    /// 넣은 읽기 결과(차례대로)
    public private(set) var adopted: [LibraryReadResult] = []
    /// 넣은 Music 최신화 결과(차례대로)
    public private(set) var music: [ITunesLibrarySnapshot] = []
    public var commentPreset: CommentPreset = .none

    public init() {}

    public var port: LibraryReadScreen {
        LibraryReadScreen(
            state: { [weak self] in self?.state ?? LibraryReadState() },
            apply: { [weak self] in self?.apply($0) },
            beginRead: { [weak self] in
                self?.events.append("begin")
                return LibraryReadStart(commentPreset: self?.commentPreset ?? .none) { [weak self] in self?.adopt($0) }
            })
    }

    private func apply(_ change: LibraryReadChange) {
        switch change {
        case let .phase(phase):
            state.phase = phase
            events.append("phase \(phase)")
        case let .error(message):
            state.hasError = true
            events.append("error \(message)")
        case let .musicStatus(status):
            state.musicStatus = status
            events.append("musicStatus \(status)")
        case let .music(result):
            state.music = result
            music.append(result)
            events.append("music \(result.status)")
        case let .damagedDrafts(files):
            events.append("damaged \(files.map(\.name))")
        case let .readFailed(failure, _):
            state.phase = failure.keepsPreviousLibrary ? .loaded : .failed(failure.message)
            if failure.keepsPreviousLibrary { state.hasError = true }
            events.append("failed \(failure.stage)")
        }
    }

    private func adopt(_ read: LibraryReadResult) {
        adopted.append(read)
        state.snapshot = read.snapshot
        state.revision += 1
        state.hasRows = !read.opened.loaded.rows.isEmpty
        state.music = read.opened.loaded.iTunesSnapshot
        state.musicStatus = read.opened.loaded.iTunesLibrary.status
        state.phase = .loaded
        state.hasError = false
        events.append("adopt \(read.snapshot.lastPathComponent)")
    }
}
