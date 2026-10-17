import DJCDomain
import Foundation

/// LINK 서버의 지금 상태(#273)
public struct LinkServerStatus: Equatable, Sendable {
    /// 참여한 장치 번호. 참여하는 중이면 nil
    public var deviceNumber: Int?
    /// 참여하지 못한 이유(번호 충돌 등)
    public var down: String?
    /// 라이브러리를 마운트한 장치의 주소
    public var mounted: Set<String>
    /// 플레이어 번호별 재생 상태
    public var players: [Int: LinkPlayerState]

    public init(deviceNumber: Int? = nil, down: String? = nil, mounted: Set<String> = [], players: [Int: LinkPlayerState] = [:]) {
        self.deviceNumber = deviceNumber
        self.down = down
        self.mounted = mounted
        self.players = players
    }
}

/// 플레이어 하나의 재생 상태(LINK 막대의 간단한 표시)
public struct LinkPlayerState: Equatable, Sendable {
    public var isPlaying: Bool
    public var isMaster: Bool
    public var isSync: Bool
    /// 내어 준 곡을 실었으면 그 번호. 다른 곳(USB 등)의 곡이면 nil
    public var loadedTrackID: UInt32?
    /// 실은 곡 제목. 연결(`LinkSession.status`)이 내어 준 곡에서 찾아 채운다
    public var title: String?
    /// 실은 곡의 rekordbox 곡 ID. 연결이 채운다(DJCrate가 내어 준 곡일 때만)
    public var contentID: String?
    /// 피치를 반영한 BPM. 모르면 nil
    public var bpm: Double?

    public init(isPlaying: Bool = false, isMaster: Bool = false, isSync: Bool = false, loadedTrackID: UInt32? = nil,
                title: String? = nil, bpm: Double? = nil) {
        self.isPlaying = isPlaying
        self.isMaster = isMaster
        self.isSync = isSync
        self.loadedTrackID = loadedTrackID
        self.title = title
        self.bpm = bpm
    }
}

/// CDJ가 보낸 편집(서버가 매긴 곡 번호): 재생 기록 넣기·빼기(서버가 연 기록 번호)와 큐 저장·삭제(#280).
/// 플레이어가 서버의 파일을 읽으려 한 것도 함께 알린다
public enum LinkHistoryEvent: Equatable, Sendable {
    case added(UInt32, history: UInt32)
    case removed(UInt32, history: UInt32)
    /// 큐 저장·삭제. `contentID`는 비어 있고, 세션이 곡 번호로 채워 앱에 알린다
    case cue(UInt32, LinkCueEdit)
    /// 플레이어가 NFS로 그 파일(이 Mac의 경로)을 찾거나 처음부터 읽었다. 음원·분석 파일·그림 모두 온다.
    /// `playerModel`은 그 플레이어의 기종 이름(모르면 빈 값)
    case fileRequested(path: String, playerModel: String)
}

/// CDJ에서 실은 곡을 그 기종이 못 읽어 백그라운드에서 바꾼 일(#277). 화면이 알린다
public enum LinkBackgroundConversion: Equatable, Sendable {
    /// 바꾸는 데 오래 걸려(`LinkFileHold.limit`) 그 싣기가 원본을 받아 실패한 뒤 바꿔 끼웠다. CDJ에서 다시 실으면 WAV가 실린다
    case finished(title: String)
    case failed(title: String, LinkProblem)
}

/// CDJ가 재생 기록에 넣거나 뺀 rekordbox 곡(rekordbox의 LINK HISTORY). 앱이 DJCrate에 보존한다
public struct LinkPlay: Equatable, Sendable {
    /// rekordbox 곡 ID
    public var contentID: String
    /// 서버가 매긴 곡 번호
    public var linkID: UInt32
    /// 연결 차례. 서버를 띄울 때마다 바뀐다
    public var session: Int
    /// 서버가 연 기록 번호. CDJ가 기록을 지우면 서버가 새로 연다. 앱은 (차례, 기록 번호)마다 기록 하나를 만든다
    public var history: UInt32
    /// 기록에서 뺐는지(아니면 넣었다)
    public var removed: Bool

    public init(contentID: String, linkID: UInt32, session: Int, history: UInt32 = 1, removed: Bool = false) {
        self.contentID = contentID
        self.linkID = linkID
        self.session = session
        self.history = history
        self.removed = removed
    }
}

/// 곡 싣기·연결이 막힌 이유. 화면이 한 문장으로 바꾼다
public enum LinkProblem: Error, Equatable, Sendable {
    /// rekordbox가 같은 포트를 쓰는 중
    case rekordboxRunning
    /// 네트워크에 보이는 장치가 없어 참여할 인터페이스를 고를 수 없음
    case noDevice
    /// 그 장치로 가는 인터페이스를 찾지 못함
    case noInterface
    /// 포트를 열지 못함(DJLinkKit의 설명)
    case portInUse(String)
    /// 연결을 켜지 않음
    case notConnected
    /// 아직 네트워크에 참여하는 중
    case notJoined
    /// 내어 주지 않는 곡(추가 대기·USB·스트리밍·파일 없음·모르는 형식)
    case trackNotShared
    /// 그 플레이어가 네트워크에 없음
    case playerMissing(Int)
    /// 그 플레이어가 아직 라이브러리를 마운트하지 않음
    case notMounted(Int)
    /// 켜는 도중에 끄기를 요청함(알릴 일이 아니다)
    case cancelled
    /// CDJ가 못 읽는 형식을 WAV로 바꾸지 못함(까닭)
    case conversionFailed(String)
    case failed(String)
}

/// LINK 서버 포트(#273). 실제 구현은 DJLinkKit `DJLinkExport`를 띄운다. 한 번에 서버 하나만 둔다.
public struct LinkServerSource: Sendable {
    /// 라이브러리를 내어 주는 서버를 띄운다(이미 떠 있으면 내리고 새로 띄운다). `peer` 장치로 가는 인터페이스에 참여한다.
    /// CDJ가 재생 기록에 곡을 넣거나 빼면 `history`로 알린다(서버를 띄운 동안 아무 스레드에서나)
    public var start: @Sendable (_ library: LinkLibrary, _ shareRoot: String, _ peer: String,
                                 _ history: @escaping @Sendable (LinkHistoryEvent) -> Void) async throws(LinkProblem) -> Void
    /// 서버를 내리고 포트를 돌려준다
    public var stop: @Sendable () async -> Void
    public var status: @Sendable () async -> LinkServerStatus?
    /// 플레이어에 곡을 싣게 한다
    public var load: @Sendable (_ player: Int, _ trackID: UInt32) async throws(LinkProblem) -> Void
    /// rekordbox·rekordboxAgent가 켜져 있는지. 프로세스를 띄워 보므로 메인 밖에서 부른다
    public var isRekordboxRunning: @Sendable () -> Bool
    /// 띄운 서버의 재생 목록 나무를 바꾼다(곡은 그대로). iTunes 목록을 연결한 뒤에 다 읽었을 때 쓴다
    public var updatePlaylists: @Sendable (_ playlists: [LinkLibrary.Playlist]) async -> Void
    /// 곡 하나를 다른 파일·형식으로 내어 준다(CDJ가 못 읽는 형식을 바꾼 WAV)
    public var substitute: @Sendable (_ trackID: UInt32, _ path: String, _ fileType: UInt8) async -> Void
    /// 곡 하나의 큐 목록을 바꾼다(연결한 뒤 DJCrate에서 고친 큐, #281). CDJ는 곡을 실을 때 다시 묻는다
    public var updateCues: @Sendable (_ trackID: UInt32, _ cues: [LinkLibrary.Cue]) async -> Void
    /// 플레이어의 파일 요청(이 Mac의 경로, 기종 이름)을 보류할지 묻는 함수를 띄운 서버에 건다. true면 답하지 않는다(#277).
    /// NFS가 답하는 도중에 부르므로 바로 끝나야 한다
    public var setFileHold: @Sendable (_ hold: @escaping @Sendable (_ path: String, _ playerModel: String) -> Bool) async -> Void

    public init(start: @escaping @Sendable (LinkLibrary, String, String, @escaping @Sendable (LinkHistoryEvent) -> Void) async throws(LinkProblem) -> Void,
                stop: @escaping @Sendable () async -> Void,
                status: @escaping @Sendable () async -> LinkServerStatus?,
                load: @escaping @Sendable (Int, UInt32) async throws(LinkProblem) -> Void,
                isRekordboxRunning: @escaping @Sendable () -> Bool,
                updatePlaylists: @escaping @Sendable ([LinkLibrary.Playlist]) async -> Void = { _ in },
                substitute: @escaping @Sendable (UInt32, String, UInt8) async -> Void = { _, _, _ in },
                updateCues: @escaping @Sendable (UInt32, [LinkLibrary.Cue]) async -> Void = { _, _ in },
                setFileHold: @escaping @Sendable (@escaping @Sendable (String, String) -> Bool) async -> Void = { _ in }) {
        self.start = start
        self.stop = stop
        self.status = status
        self.load = load
        self.isRekordboxRunning = isRekordboxRunning
        self.updatePlaylists = updatePlaylists
        self.substitute = substitute
        self.updateCues = updateCues
        self.setFileHold = setFileHold
    }

    /// 서버를 띄우지 않는다(화면 시험·자가 테스트 실행). 연결을 켜면 쓸 수 없다고 한다
    public static let none = LinkServerSource(start: { _, _, _, _ throws(LinkProblem) in throw .noInterface }, stop: {},
                                              status: { nil }, load: { _, _ throws(LinkProblem) in throw .notConnected },
                                              isRekordboxRunning: { false })
}

/// CDJ가 못 읽는 음원(FLAC·ALAC)을 WAV로 바꾸는 포트(#277). 원본은 읽기만 하고, 바꾼 파일은 다시 쓴다(캐시)
public struct LinkAudioConverter: Sendable {
    /// 그 음원이 바꿔야 하는 형식이면 바꾼 WAV 경로, 바꿀 필요가 없으면(AAC .m4a 등) nil
    public var convert: @Sendable (_ path: String) async throws(LinkProblem) -> String?

    public init(convert: @escaping @Sendable (String) async throws(LinkProblem) -> String?) {
        self.convert = convert
    }

    /// 바꾸지 않는다(시험·화면 시험)
    public static let none = LinkAudioConverter { _ throws(LinkProblem) in nil }
}

/// LINK 연결(#273·#274): 사용자가 켜면 라이브러리를 만들어 서버를 띄우고, 플레이어에 놓은 곡을 싣는다.
/// 내어 준 라이브러리는 켤 때의 것이다(서버가 공유 폴더를 켤 때 정한다). 라이브러리가 바뀌면 다시 켠다.
public actor LinkSession {
    private let source: LinkServerSource
    private var library: LinkLibrary?
    /// 켜기·끄기 차례. 켜기를 기다리는 사이(rekordbox 확인·서버 띄우기) 끄기가 끼어들면 그 켜기는 서버를 띄우지 않거나 바로 내린다
    private var generation = 0
    /// 서버를 띄워 둔 채인지. 끄기는 띄운 서버가 있을 때만 내린다
    private var serverUp = false
    /// 마지막으로 줄 세운 켜기·끄기. 서버 띄우기·내리기는 부른 차례대로 하나씩 한다(겹쳐 뜨거나 새 서버를 내리지 않게)
    private var tail: Task<Void, Never>?

    /// CDJ가 재생 기록에 곡을 넣거나 뺐을 때(아무 스레드에서나 부른다)
    private let played: @Sendable (LinkPlay) -> Void
    /// CDJ가 내어 준 곡의 큐를 저장하거나 지웠을 때(#280, 아무 스레드에서나 부른다)
    private let cueEdited: @Sendable (LinkCueEdit) -> Void

    /// FLAC·ALAC를 WAV로 바꾸는 포트(끌어 놓아 실을 때와 CDJ에서 고른 원본을 플레이어가 읽으려 할 때, #277)
    private let converter: LinkAudioConverter
    /// 이 연결에서 WAV로 바꿔 내어 준 원본 경로. 같은 음원을 가리키는 곡은 서버가 함께 바꾼다
    private var substituted: Set<String> = []
    /// 이 연결에서 바꿀 필요가 없다고 본 원본 경로(AAC .m4a 등). CDJ가 다시 읽을 때 코덱을 또 보지 않는다
    private var unconvertible: Set<String> = []
    /// 바꾸는 동안 그 원본 요청에 답하지 않게 하는 보류(서버가 액터 밖에서 묻는다)
    private let fileHold: LinkFileHold
    /// CDJ가 원본을 요청해 백그라운드에서 바꾸는 일을 알린다(아무 스레드에서나 부른다)
    private let backgroundConversion: @Sendable (LinkBackgroundConversion) -> Void
    /// 진행 중인 변환(원본 경로별). 같은 곡을 바꾸는 동안 또 놓으면 이 변환을 함께 기다린다(같은 출력 파일을 두 번 쓰지 않게)
    private var converting: [String: Task<Result<String?, LinkProblem>, Never>] = [:]

    public init(source: LinkServerSource, converter: LinkAudioConverter = .none, played: @escaping @Sendable (LinkPlay) -> Void = { _ in },
                cueEdited: @escaping @Sendable (LinkCueEdit) -> Void = { _ in },
                backgroundConversion: @escaping @Sendable (LinkBackgroundConversion) -> Void = { _ in },
                fileHold: LinkFileHold = LinkFileHold()) {
        self.source = source
        self.converter = converter
        self.played = played
        self.cueEdited = cueEdited
        self.backgroundConversion = backgroundConversion
        self.fileHold = fileHold
    }

    public var isConnected: Bool { library != nil }

    /// 켜기·끄기 차례(시험이 끄기가 들어온 것을 기다릴 때 읽는다)
    var currentGeneration: Int { generation }

    /// 연결을 켠다. rekordbox가 켜져 있으면 포트를 열지 않는다(LNK-3). 내어 준 곡 수를 돌려준다
    @discardableResult
    /// - Parameter iTunes: 맨 위 "iTunes" 폴더에 넣을 iTunes 재생 목록(다 읽었을 때만, 아니면 빈 값)
    /// - Parameter draftCues: 큐 초안이 있는 곡(rekordbox 곡 ID)의 큐. rekordbox 큐 대신 내어 준다(#280)
    public func connect(rows: [TrackRow], playlists: PlaylistLayout, iTunes: [SyncedITunesLibrary.Node] = [],
                        draftCues: [String: [Cue]] = [:], shareRoot: String, peers: [LinkDevice]) async throws(LinkProblem) -> Int {
        // 차례는 기다리기 전에 받는다. 그래야 기다리는 사이 들어온 끄기가 이 켜기를 무른다
        generation += 1
        let mine = generation
        let result = await serialized { session in
            await session.connectNow(rows: rows, playlists: playlists, iTunes: iTunes, draftCues: draftCues, shareRoot: shareRoot,
                                     peers: peers, mine: mine)
        }
        return try result.get()
    }

    /// 켜 둔 서버의 재생 목록 나무를 바꾼다(곡은 켤 때 그대로). 꺼져 있으면 하지 않는다
    public func updatePlaylists(_ playlists: PlaylistLayout, iTunes: [SyncedITunesLibrary.Node]) async {
        await serialized { session in await session.updatePlaylistsNow(playlists, iTunes: iTunes) }
    }

    private func updatePlaylistsNow(_ layout: PlaylistLayout, iTunes: [SyncedITunesLibrary.Node]) async {
        guard var library else { return }
        library.setPlaylists(layout: layout, iTunes: iTunes)
        self.library = library
        await source.updatePlaylists(library.playlists)
    }

    /// 연결을 끈다. 켜는 중이어도 끈다(그 켜기는 차례가 바뀐 것을 보고 서버를 띄우지 않거나 내린다)
    public func disconnect() async {
        generation += 1
        library = nil
        await serialized { session in await session.stopNow() }
    }

    private func connectNow(rows: [TrackRow], playlists: PlaylistLayout, iTunes: [SyncedITunesLibrary.Node], draftCues: [String: [Cue]],
                            shareRoot: String, peers: [LinkDevice], mine: Int) async -> Result<Int, LinkProblem> {
        guard generation == mine else { return .failure(.cancelled) }
        let source = source
        if await BlockingWork.run(qos: .utility, { source.isRekordboxRunning() }) { return .failure(.rekordboxRunning) }
        guard generation == mine else { return .failure(.cancelled) }
        // 참여할 인터페이스는 플레이어(없으면 아무 장치) 쪽으로 고른다
        guard let peer = peers.first(where: \.hasDeck) ?? peers.first(where: { $0.kind != .rekordbox }) else {
            return .failure(.noDevice)
        }
        let built = LinkLibrary.build(rows: rows, playlists: playlists, iTunes: iTunes, draftCues: draftCues)
        // 서버가 매긴 곡 번호 → rekordbox 곡 ID. 이 켜기에서 띄운 서버의 기록만 이 차례로 알린다
        let contentIDs = Dictionary(built.tracks.map { ($0.id, $0.contentID) }, uniquingKeysWith: { first, _ in first })
        let played = played, cueEdited = cueEdited
        let history: @Sendable (LinkHistoryEvent) -> Void = { event in
            switch event {
            case let .added(id, list):
                if let contentID = contentIDs[id] { played(LinkPlay(contentID: contentID, linkID: id, session: mine, history: list)) }
            case let .removed(id, list):
                if let contentID = contentIDs[id] {
                    played(LinkPlay(contentID: contentID, linkID: id, session: mine, history: list, removed: true))
                }
            case let .cue(id, edit):
                guard let contentID = contentIDs[id] else { return }
                var edit = edit
                edit.contentID = contentID
                cueEdited(edit)
            case let .fileRequested(path, model):
                // 서버 액터에서 NFS 답을 하는 도중에 불린다. 바꾸기는 세션에서 따로 한다
                Task { await self.fileRequested(path: path, playerModel: model, generation: mine) }
            }
        }
        fileHold.reset(candidates: Set(built.tracks.map(\.path).filter(LinkLibrary.mayNeedConversion(path:))))
        do {
            try await source.start(built, shareRoot, peer.address, history)
        } catch {
            // 기다리는 사이 껐거나 다시 켰으면 이 실패는 알릴 일이 아니다(화면이 뒤 켜기의 상태를 끄지 않게)
            return .failure(generation == mine ? error : .cancelled)
        }
        serverUp = true
        guard generation == mine else {
            await stopNow()
            return .failure(.cancelled)
        }
        library = built
        substituted = []
        unconvertible = []
        let hold = fileHold
        await source.setFileHold { path, model in hold.shouldHold(path: path, playerModel: model) }
        return .success(built.tracks.count)
    }

    private func stopNow() async {
        guard serverUp else { return }
        serverUp = false
        await source.stop()
    }

    /// 앞서 줄 세운 일이 끝난 뒤에 `work`를 한다
    private func serialized<T: Sendable>(_ work: @escaping @Sendable (isolated LinkSession) async -> T) async -> T {
        let previous = tail
        let task = Task { () async -> T in
            await previous?.value
            return await work(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// 서버 상태. 플레이어가 실은 곡은 내어 준 곡에서 제목을 찾아 채운다
    public func status() async -> LinkServerStatus? {
        // 기다리는 사이 껐거나 다시 켰으면 지금 라이브러리로 찾는다
        guard library != nil, var status = await source.status(), let library else { return nil }
        for (number, player) in status.players {
            let track = player.loadedTrackID.flatMap(library.track(linkID:))
            status.players[number]?.title = track?.title
            status.players[number]?.contentID = track?.contentID
        }
        return status
    }

    /// rekordbox 곡(`contentID`)을 플레이어에 싣는다. 그 기종이 못 읽을 수 있는 형식(FLAC·ALAC)이면 WAV로 바꿔 그 파일을 내어 준 뒤 싣는다(#277).
    /// FLAC·ALAC을 재생하는 기종(`LinkPlayerFormats`)에는 바꾸지 않고 원본을 싣는다
    /// - Parameter playerModel: 플레이어 기종 이름(장치 알림의 이름). 모르면 빈 값(바꾸는 쪽으로 둔다)
    public func load(contentID: String, player: Int, playerModel: String = "") async throws(LinkProblem) {
        guard let library else { throw .notConnected }
        guard let id = library.linkID(of: contentID) else { throw .trackNotShared }
        let mine = generation
        if needsConversion(id, library: library, playerModel: playerModel), let track = library.track(linkID: id) {
            let converted = await convert(track.path)
            // 바꾸지 못했으면 그 원본을 기다리던 CDJ의 요청에 곧바로 원본으로 답한다
            if case .failure = converted { fileHold.release(track.path) }
            if let wav = try converted.get() {
                // 바꾸는 사이 끄거나 다시 켰으면 지금 서버에 바꿔 끼우지 않는다(다시 읽은 라이브러리는 같은 번호라도 경로가 다를 수 있다)
                guard generation == mine, self.library?.linkID(of: contentID) == id else { throw .notConnected }
                await substitute(id, original: track.path, wav: wav)
                fileHold.release(track.path)
            } else if generation == mine {
                unconvertible.insert(track.path)
                fileHold.release(track.path)
            }
        }
        try await source.load(player, id)
    }

    /// CDJ에서 고른 곡의 원본을 플레이어가 읽으려 했다(#277). 그 기종이 못 읽는 형식이면 백그라운드에서 WAV로 바꿔 끼운다.
    /// 바꾸는 동안 서버는 그 요청에 답하지 않고(`LinkFileHold`), CDJ가 다시 보낸 요청에 WAV로 답해 첫 싣기부터 WAV가 실린다.
    /// CDJ는 곡 번호별로 처음 받은 경로를 기억하므로 서버가 원본 이름으로도 WAV를 내어 준다(CDJ-2000nexus 실기).
    /// 내어 준 곡의 원본이 아닌 파일(분석 파일·그림·바꾼 WAV)은 지나친다
    func fileRequested(path: String, playerModel: String, generation mine: Int) async {
        guard generation == mine, let library, let id = library.linkID(ofPath: path), let track = library.track(linkID: id),
              needsConversion(id, library: library, playerModel: playerModel) else { return }
        // 같은 원본을 바꾸는 중이면(LOOKUP·READ가 이어 오거나 다시 실었을 때) 그 변환에 맡긴다
        guard converting[path] == nil else { return }
        switch await convert(path) {
        case let .success(wav?):
            guard generation == mine, self.library?.linkID(ofPath: path) == id else { return }
            await substitute(id, original: path, wav: wav)
            // 보류하던 싣기는 다음 요청에 WAV를 받아 그대로 실린다. 오래 걸려 원본으로 답했으면 다시 실으라고 알린다
            if !fileHold.release(path) { backgroundConversion(.finished(title: track.title)) }
        case .success(nil):
            if generation == mine { unconvertible.insert(path) }
            fileHold.release(path)
        case let .failure(problem):
            fileHold.release(path)
            if generation == mine { backgroundConversion(.failed(title: track.title, problem)) }
        }
    }

    /// 바꾼 WAV를 내어 준다. 함께 기다린 다른 싣기가 먼저 바꿔 끼웠으면 다시 끼우지 않는다
    private func substitute(_ id: UInt32, original: String, wav: String) async {
        guard !substituted.contains(original) else { return }
        substituted.insert(original)
        await source.substitute(id, wav, LinkLibrary.wavFileType)
    }

    /// 그 원본을 바꾼다. 같은 원본을 바꾸는 중이면 그 변환을 함께 기다린다
    private func convert(_ path: String) async -> Result<String?, LinkProblem> {
        if let running = converting[path] { return await running.value }
        let task = Task { [converter] () -> Result<String?, LinkProblem> in
            do throws(LinkProblem) { return .success(try await converter.convert(path)) } catch { return .failure(error) }
        }
        converting[path] = task
        let result = await task.value
        converting[path] = nil
        return result
    }

    /// DJCrate에서 고친 그 곡(rekordbox 곡 ID)의 큐를 서버에 보낸다(#281). 내어 주지 않은 곡이거나 꺼져 있으면 보내지 않는다
    public func updateCues(contentID: String, cues: [Cue]) async {
        guard let library, let id = library.linkID(of: contentID) else { return }
        await source.updateCues(id, LinkLibrary.linkCues(cues))
    }

    /// 그 곡을 그 기종에 실을 때 형식을 바꿀 수도 있는지(바꾸는 동안 화면이 알린다)
    public func mayConvert(contentID: String, playerModel: String = "") -> Bool {
        guard let library, let id = library.linkID(of: contentID) else { return false }
        return needsConversion(id, library: library, playerModel: playerModel)
    }

    private func needsConversion(_ id: UInt32, library: LinkLibrary, playerModel: String) -> Bool {
        guard !LinkPlayerFormats.playsLossless(model: playerModel), let track = library.track(linkID: id),
              !substituted.contains(track.path), !unconvertible.contains(track.path) else { return false }
        return LinkLibrary.mayNeedConversion(path: track.path)
    }
}
