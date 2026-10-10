import DJCDomain
import Foundation

/// 라이브러리 화면의 읽기 단계(앱: 라이브러리 화면 모델의 `phase`)
public enum LibraryReadPhase: Sendable, Equatable {
    case idle
    case loading(String)
    case loaded
    case failed(String)
}

/// 읽기 흐름이 순서를 정할 때 보는 화면 상태(앱: 라이브러리 화면 모델의 값). 부를 때마다 지금 값을 새로 읽는다.
public struct LibraryReadState: Sendable {
    public var phase: LibraryReadPhase = .idle
    /// 목록을 읽은 사본
    public var snapshot: URL?
    /// 사본을 채택할 때마다 오르는 순번(동기화 창이 연 뒤 목록이 바뀌었는지 본다)
    public var revision = 0
    /// 읽은 곡이 있다(없으면 실패를 실패 화면으로 알린다)
    public var hasRows = false
    /// 목록 위 오류가 떠 있다
    public var hasError = false
    /// rekordbox에 쓰는 중이다
    public var isWriting = false
    /// 지금 보이는 Music(iTunes) 목록
    public var music = ITunesLibrarySnapshot(status: .notCaptured)
    /// 사이드바 iTunes 절의 상태(읽는 중·미캡처 안내)
    public var musicStatus: ITunesLibrarySnapshot.Status = .notCaptured

    public init(phase: LibraryReadPhase = .idle, snapshot: URL? = nil, revision: Int = 0, hasRows: Bool = false, hasError: Bool = false,
                isWriting: Bool = false, music: ITunesLibrarySnapshot = ITunesLibrarySnapshot(status: .notCaptured),
                musicStatus: ITunesLibrarySnapshot.Status = .notCaptured) {
        self.phase = phase
        self.snapshot = snapshot
        self.revision = revision
        self.hasRows = hasRows
        self.hasError = hasError
        self.isWriting = isWriting
        self.music = music
        self.musicStatus = musicStatus
    }

    public var isLoading: Bool { if case .loading = phase { true } else { false } }
    var isLoaded: Bool { phase == .loaded }
    /// 읽기를 그만둘 때 돌아갈 단계(곡이 있으면 그 목록, 없으면 빈 화면)
    var settledPhase: LibraryReadPhase { hasRows ? .loaded : .idle }
}

/// 읽기 흐름이 화면에 알리는 것. 무엇을 바꿀지는 흐름이 정하고, 화면은 표시만 바꾼다.
public enum LibraryReadChange: Sendable {
    case phase(LibraryReadPhase)
    /// 읽기 순번이 바뀌었다(읽기를 시작하거나 버렸다). 화면은 이 값으로 쓰기 판정 단추를 다시 계산한다
    case readSequence(LibraryReadSequence)
    /// 목록은 그대로 두고 오류만 알린다
    case error(String)
    /// 사이드바 iTunes 절 상태를 바꾼다(읽는 중 ↔ 미캡처)
    case musicStatus(ITunesLibrarySnapshot.Status)
    /// Music 최신화 결과를 목록에 넣는다
    case music(ITunesLibrarySnapshot)
    /// 읽기 전에 옮겨 보관한 손상 초안 파일(#174)
    case damagedDrafts([DamagedDraftFile])
    /// 읽기 실패. 오류는 진단 기록에 남긴다
    case readFailed(LibraryReadFailure, any Error)
}

/// 한 번 읽은 결과(화면이 곡 목록·초안 표시에 넣는다)
public struct LibraryReadResult: Sendable {
    public var opened: LoadLibrary.Opened
    public var snapshot: URL
    /// 이 읽기의 세대(USB 작업 사본의 출처로 남긴다)
    public var generation: Int
    /// 명시적 동기화의 다시 읽기(태그 base 옮기기·알림)
    public var synchronizingDrafts: Bool

    public init(opened: LoadLibrary.Opened, snapshot: URL, generation: Int, synchronizingDrafts: Bool) {
        self.opened = opened
        self.snapshot = snapshot
        self.generation = generation
        self.synchronizingDrafts = synchronizingDrafts
    }
}

/// 읽기를 시작할 때 화면이 주는 것: 읽기에 쓸 설정과, 읽기 전 화면 값을 붙든 채 결과를 넣는 함수
@MainActor
public struct LibraryReadStart {
    public var commentPreset: CommentPreset
    public var adopt: @MainActor (LibraryReadResult) -> Void

    public init(commentPreset: CommentPreset, adopt: @escaping @MainActor (LibraryReadResult) -> Void) {
        self.commentPreset = commentPreset
        self.adopt = adopt
    }
}

/// 읽기 흐름이 보는 화면(앱: 라이브러리 화면 모델 `LibraryStore`). 흐름은 상태를 읽고(`state`) 진행·결과를 알린다(`apply`).
/// 읽은 곡 목록을 넣는 일은 `beginRead`가 돌려준 함수가 한다(읽는 동안 고친 입력을 디스크의 옛 값으로 덮지 않게 읽기 전 값을 붙든다).
@MainActor
public struct LibraryReadScreen {
    public var state: @MainActor () -> LibraryReadState
    public var apply: @MainActor (LibraryReadChange) -> Void
    public var beginRead: @MainActor () -> LibraryReadStart

    public init(state: @escaping @MainActor () -> LibraryReadState, apply: @escaping @MainActor (LibraryReadChange) -> Void,
                beginRead: @escaping @MainActor () -> LibraryReadStart) {
        self.state = state
        self.apply = apply
        self.beginRead = beginRead
    }

    /// 화면이 없는 곳: 읽은 결과를 버린다
    public static var none: Self {
        Self(state: { LibraryReadState() }, apply: { _ in }, beginRead: { LibraryReadStart(commentPreset: .none) { _ in } })
    }
}
