import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 창 아래 LINK 막대의 화면 모델(#272·#273·#274). 장치 찾기(`LinkDiscovery`)의 상태를 들고, LINK 단추로 장치 목록을 펼치고 접는다.
/// LINK 단추로 펼치면 라이브러리를 CDJ에 내어 주고(`LinkSession`), 플레이어 칸에 놓은 곡을 그 플레이어에 싣는다.
/// 조립 지점(`AppComposition`)이 한 번 만든다. 찾기는 받기만 하고, 보내는 일은 LINK를 펼쳤을 때만 한다(LNK-1·LNK-2).
@MainActor
@Observable
final class LinkBarModel {
    /// 연결을 켤 때 내어 줄 라이브러리
    struct LibraryInput {
        var rows: [TrackRow]
        var playlists: PlaylistLayout
        /// iTunes 재생 목록(다 읽었을 때만). nil이면 아직 읽는 중이라 다 읽은 뒤 연결 중인 서버에 더한다
        var iTunes: [SyncedITunesLibrary.Node]? = nil
        /// 큐 초안이 있는 곡(rekordbox 곡 ID)의 큐. rekordbox 큐 대신 내어 준다(#280)
        var draftCues: [String: [Cue]] = [:]
        var shareRoot: String
    }

    enum Connection: Equatable {
        case off
        case connecting
        /// 켜짐. 내어 준 곡 수
        case on(tracks: Int)
    }

    private(set) var state: LinkDiscoveryState = .idle
    /// 장치 목록을 펼쳤는지(rekordbox처럼 LINK 단추로 연다). 펼친 동안 라이브러리를 내어 준다
    private(set) var isExpanded = false
    private(set) var connection: Connection = .off
    /// 켠 서버의 상태(참여 번호·마운트한 장치). 꺼져 있으면 nil
    private(set) var server: LinkServerStatus?

    @ObservationIgnored private let discovery: LinkDiscovery
    @ObservationIgnored private let session: LinkSession
    @ObservationIgnored private let library: () -> LibraryInput?
    @ObservationIgnored private let notify: (_ text: String, _ kind: AppToast.Kind) -> Void
    /// 내어 주기를 껐을 때(LINK 재생 기록을 rekordbox 쓰기 대기에 올린다)
    @ObservationIgnored private let sessionEnded: () -> Void
    /// CDJ가 실은 곡(rekordbox 곡 ID)이 바뀌었을 때(DJCrate 덱이 같은 곡을 내리거나 막는다, #278)
    @ObservationIgnored private let cdjTracks: (_ loaded: Set<String>) -> Void
    /// 마지막으로 알린 CDJ 곡(바뀔 때만 알린다)
    @ObservationIgnored private var lastCDJTracks: Set<String> = []
    /// 펼친 채 rekordbox 때문에 막혔는지. 풀리고 장치가 다시 보이면 내어 주기를 다시 켠다
    @ObservationIgnored private var reconnectWhenFree = false
    /// 켠 서버에 iTunes 목록을 넣었는지(켤 때 아직 읽는 중이었으면 다 읽은 뒤 넣는다)
    @ObservationIgnored private var servesITunes = false
    /// 켠 서버에 마지막으로 보낸 재생 목록(재생 목록 초안을 얹은 모양)과 iTunes 목록. 같은 모양이면 다시 보내지 않는다
    @ObservationIgnored private var sentPlaylists: PlaylistLayout?
    @ObservationIgnored private var servedITunes: [SyncedITunesLibrary.Node] = []
    /// 켜는 동안 재생 목록 초안이 바뀌었는지(켠 뒤 보낸다)
    @ObservationIgnored private var playlistsChangedWhileConnecting = false
    @ObservationIgnored private var playlistTail: Task<Void, Never>?
    /// 연결을 끌 때마다 오른다. 끄기 전에 걸어 둔 큐·재생 목록 보내기가 다시 켠 서버에 옛 값을 보내지 않게 한다
    @ObservationIgnored private var linkEpoch = 0
    /// 진행 중인 LINK WAV 변환본 비우기 수(#287 PR 리뷰). 그동안 켜기는 다 비울 때까지 기다린다(CDJ가 찾은 변환본을 지우지 않게)
    @ObservationIgnored private var cacheClears = 0
    @ObservationIgnored private var cacheClearWaiters: [CheckedContinuation<Void, Never>] = []
    /// 연결한 뒤 서버에 보낸 곡별 큐(rekordbox 곡 ID). 같은 큐는 다시 보내지 않는다(#281)
    @ObservationIgnored private var sentCues: [String: [Cue]] = [:]
    /// 켜는 동안 고친 곡별 큐. 켜진 뒤에 보낸다(켤 때 읽은 초안 큐보다 새것이다)
    @ObservationIgnored private var pendingCues: [String: [Cue]] = [:]
    /// 큐 보내기를 받은 차례대로 하나씩 하는 줄의 끝
    @ObservationIgnored private var cueTail: Task<Void, Never>?
    /// 서버 상태를 다시 볼 간격
    @ObservationIgnored var statusInterval: Duration = .seconds(1)
    /// 참여하고 플레이어가 마운트할 때까지 볼 간격(연결됨·🔗가 늦게 보이지 않게)
    @ObservationIgnored var settlingInterval: Duration = .milliseconds(250)

    /// 다음 상태 확인까지 기다릴 시간: 켜는 중·참여 전·덱 있는 장치가 아직 마운트하지 않았으면 짧게
    var pollInterval: Duration {
        guard connection != .off else { return statusInterval }
        guard let server, server.deviceNumber != nil else { return settlingInterval }
        let unmounted = devices.contains { $0.hasDeck && !server.mounted.contains($0.address) }
        return unmounted ? settlingInterval : statusInterval
    }

    init(discovery: LinkDiscovery, session: LinkSession = LinkSession(source: .none), library: @escaping () -> LibraryInput? = { nil },
         notify: @escaping (_ text: String, _ kind: AppToast.Kind) -> Void = { _, _ in }, sessionEnded: @escaping () -> Void = {},
         cdjTracks: @escaping (_ loaded: Set<String>) -> Void = { _ in }) {
        self.discovery = discovery
        self.session = session
        self.library = library
        self.notify = notify
        self.sessionEnded = sessionEnded
        self.cdjTracks = cdjTracks
    }

    /// 보이는 장치. 연결을 켰으면 DJCrate 자신(서버가 참여한 번호)은 뺀다
    var devices: [LinkDevice] {
        let own = server?.deviceNumber
        return state.devices.filter { $0.number != own }
    }

    /// LINK 단추를 보일지. 장치가 있거나, 연결을 켰거나, rekordbox 때문에 멈춰 이유를 알려야 할 때 보인다
    var isVisible: Bool {
        if connection != .off { return true }
        switch state {
        case let .listening(devices): return !devices.isEmpty
        case .blockedByRekordbox: return true
        case .idle, .unavailable: return false
        }
    }

    /// LINK를 쓸 수 없는 이유(무엇을 하면 되는지까지). 쓸 수 있으면 nil
    var blockReason: String? {
        state == .blockedByRekordbox ? String(ui: "rekordbox가 같은 LINK 포트를 쓰고 있습니다. rekordbox를 끈 뒤 쓰세요") : nil
    }

    /// 펼쳐 장치 목록을 보일지
    var showsDevices: Bool { isExpanded && blockReason == nil && !devices.isEmpty }

    var isConnected: Bool { if case .on = connection { true } else { false } }

    /// 켜는 중이거나 켜져 있다(DJCrate에서 고친 큐를 받는다, #281)
    var isServing: Bool { connection != .off }

    /// LINK 단추 옆 글: 연결 상태. 참여 번호는 단추에 보인다
    var connectionText: String? {
        switch connection {
        case .off: nil
        case .connecting: String(ui: "연결하는 중…")
        case .on:
            if server?.deviceNumber != nil {
                String(ui: "연결됨")
            } else if let down = server?.down {
                String(ui: "참여하지 못했습니다: \(down)")
            } else {
                String(ui: "참여하는 중…")
            }
        }
    }

    /// 막대 가운데에 늘어놓을 차례: rekordbox처럼 플레이어를 반씩 믹서 양쪽에 둔다(1·2 | 믹서 | 3·4). 그 밖의 장치는 오른쪽 끝에 둔다
    var arrangement: LinkArrangement { LinkArrangement(devices) }

    /// 그 플레이어의 재생 상태(서버를 켰을 때만 안다)
    func player(_ device: LinkDevice) -> LinkPlayerState? { server?.players[device.number] }

    /// 그 장치가 DJCrate 라이브러리를 마운트했는지(곡을 실을 수 있는지)
    func isMounted(_ device: LinkDevice) -> Bool { server?.mounted.contains(device.address) ?? false }

    /// 곡을 놓을 수 있는 칸: 연결을 켰고 덱이 있는 장치
    func acceptsDrop(_ device: LinkDevice) -> Bool { isConnected && device.hasDeck }

    /// LINK 단추: 펼치면서 라이브러리를 내어 주고, 접으면서 내어 주기를 끈다(rekordbox의 LINK 단추처럼).
    /// rekordbox 때문에 막혔으면 펼쳐 이유만 보인다
    func toggle() {
        if isExpanded {
            isExpanded = false
            reconnectWhenFree = false
            Task { await disconnect() }
        } else {
            isExpanded = true
            if blockReason == nil { Task { await connect() } } else { reconnectWhenFree = true }
        }
    }

    func connect() async {
        guard connection == .off else { return }
        guard let input = library() else {
            notify(String(ui: "라이브러리를 읽은 뒤 LINK를 다시 누르세요"), .warning)
            return
        }
        connection = .connecting
        // 변환본을 비우는 중이면 다 비운 뒤에 내어 준다. 켜는 중으로 둔 뒤라 새 비우기는 시작하지 않는다
        while cacheClears > 0 { await withCheckedContinuation { cacheClearWaiters.append($0) } }
        guard connection == .connecting else { return }
        do {
            servesITunes = input.iTunes != nil
            playlistsChangedWhileConnecting = false
            let count = try await session.connect(rows: input.rows, playlists: input.playlists, iTunes: input.iTunes ?? [],
                                                  draftCues: input.draftCues, shareRoot: input.shareRoot, peers: state.devices)
            // 기다리는 사이 껐으면(rekordbox 켜짐·끄기) 켜진 것으로 되돌리지 않는다
            guard connection == .connecting else { return }
            connection = .on(tracks: count)
            // 켤 때 내어 준 초안의 큐는 보낸 것으로 치고, 켜는 동안 고친 큐를 보낸다
            sentCues = input.draftCues
            let pending = pendingCues
            pendingCues = [:]
            for (contentID, cues) in pending { updateCues(contentID: contentID, cues: cues) }
            sentPlaylists = input.playlists
            servedITunes = input.iTunes ?? []
            if playlistsChangedWhileConnecting { updatePlaylists() }
            await refreshStatus()
        } catch .cancelled {
            return
        } catch {
            if connection == .connecting { connection = .off }
            pendingCues = [:]
            notify(LinkText.problem(error), .warning)
        }
    }

    /// LINK WAV 변환본 비우기를 시작한다(설정 › 저장 공간). 켜는 중이거나 켜져 있으면 nil(CDJ가 읽는 변환본을 지우지 않는다).
    /// 확인과 표시를 한 번에 해 비우는 사이 켜도 돌려준 함수를 부를 때까지 켜기가 기다린다
    func beginCacheClear() -> (() -> Void)? {
        guard !isServing else { return nil }
        cacheClears += 1
        return { [weak self] in self?.endCacheClear() }
    }

    private func endCacheClear() {
        cacheClears -= 1
        guard cacheClears == 0 else { return }
        let waiters = cacheClearWaiters
        cacheClearWaiters = []
        waiters.forEach { $0.resume() }
    }

    func disconnect() async {
        guard connection != .off else { return }
        connection = .off
        server = nil
        sentCues = [:]
        pendingCues = [:]
        sentPlaylists = nil
        servedITunes = []
        linkEpoch += 1
        publishCDJTracks()
        await session.disconnect()
        sessionEnded()
    }

    /// DJCrate에서 고친 그 곡(rekordbox 곡 ID)의 큐를 서버에 보낸다(#281). 연결한 동안, 보낸 것과 다를 때만 받은 차례대로 보낸다.
    /// CDJ는 곡을 실을 때 큐를 다시 묻는다. 이미 실린 곡은 다시 실어야 보인다
    func updateCues(contentID: String, cues: [Cue]) {
        if connection == .connecting { pendingCues[contentID] = cues }
        guard isConnected, sentCues[contentID] != cues else { return }
        sentCues[contentID] = cues
        let previous = cueTail, epoch = linkEpoch
        cueTail = Task { [weak self, session] in
            await previous?.value
            guard self?.linkEpoch == epoch else { return }
            await session.updateCues(contentID: contentID, cues: cues)
        }
    }

    /// 재생 목록 초안이 바뀌면 켜 둔 서버의 재생 목록을 초안을 얹은 모양으로 바꾼다(곡은 그대로, 추가 대기 곡은 뺀다).
    /// 보낸 것과 다를 때만 받은 차례대로 보낸다. CDJ는 탐색 결과를 라이브러리 단위로 기억해 목록을 다시 열면 새 모양을 본다
    func updatePlaylists() {
        if connection == .connecting { playlistsChangedWhileConnecting = true }
        guard isConnected, let input = library(), input.playlists != sentPlaylists else { return }
        sentPlaylists = input.playlists
        // 내어 준 iTunes 폴더는 그대로 둔다(다시 읽는 중이면 앞에 내어 준 것). 아직 내어 주지 않았으면 다 읽은 뒤 넣는다(`addITunesWhenReady`)
        if servesITunes, let tree = input.iTunes { servedITunes = tree }
        sendPlaylists(input.playlists, iTunes: servedITunes)
    }

    /// 재생 목록 보내기를 한 줄로 차례대로 보낸다(초안 변경과 늦게 넣는 iTunes 목록이 서로 앞지르지 않게)
    private func sendPlaylists(_ playlists: PlaylistLayout, iTunes: [SyncedITunesLibrary.Node]) {
        let previous = playlistTail, epoch = linkEpoch
        playlistTail = Task { [weak self, session] in
            await previous?.value
            guard self?.linkEpoch == epoch else { return }
            await session.updatePlaylists(playlists, iTunes: iTunes)
        }
    }

    /// 걸어 둔 재생 목록 보내기가 다 끝날 때까지 기다린다
    func playlistUpdatesSent() async { await playlistTail?.value }

    /// 걸어 둔 큐 보내기가 다 끝날 때까지 기다린다(시험)
    func cueUpdatesSent() async { await cueTail?.value }

    /// 플레이어 칸에 놓은 곡(rekordbox 곡 ID)을 그 플레이어에 싣는다
    func drop(contentID: String, on device: LinkDevice) {
        Task { await load(contentID: contentID, on: device) }
    }

    func load(contentID: String, on device: LinkDevice) async {
        if await session.mayConvert(contentID: contentID, playerModel: device.name) {
            notify(String(ui: "CDJ가 읽을 수 있게 WAV로 바꾼 뒤 싣습니다"), .success)
        }
        do {
            try await session.load(contentID: contentID, player: device.number, playerModel: device.name)
        } catch {
            notify(LinkText.problem(error), .warning)
        }
    }

    /// 창이 떠 있는 동안 장치를 찾고, 연결을 켰으면 서버 상태를 본다(창의 `.task`가 부르고, 창이 닫히면 취소된다).
    func watch() async {
        // 창이 떠 있는 동안만 돈다(창의 `.task`가 취소하면 끝난다). 그동안 모델을 붙잡아도 된다
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [discovery] in
                await discovery.run { state in await self.apply(state) }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: await self.pollInterval) } catch { return }
                    await self.refreshStatus()
                }
            }
            await group.waitForAll()
        }
        await disconnect()
    }

    func apply(_ state: LinkDiscoveryState) {
        self.state = state
        if state == .blockedByRekordbox, isExpanded { reconnectWhenFree = true }
        // 펼친 채 rekordbox가 꺼지면 다시 내어 준다(펼친 동안 내어 준다). 포트를 다시 열면 빈 목록부터 오므로 장치가 보일 때까지 기다린다
        if reconnectWhenFree, case let .listening(devices) = state, !devices.isEmpty, isExpanded, connection == .off {
            reconnectWhenFree = false
            Task { await connect() }
        }
        // rekordbox가 켜지면 같은 포트를 쓰므로 비켜 준다(LNK-3)
        if state == .blockedByRekordbox, connection != .off {
            connection = .off
            server = nil
            sentCues = [:]
            pendingCues = [:]
            sentPlaylists = nil
            servedITunes = []
            linkEpoch += 1
            publishCDJTracks()
            Task { [session, sessionEnded] in
                await session.disconnect()
                sessionEnded()
            }
            notify(String(ui: "rekordbox가 켜져 LINK 연결을 껐습니다"), .warning)
        }
    }

    func refreshStatus() async {
        guard isConnected else { return }
        let status = await session.status()
        if isConnected { server = status }
        publishCDJTracks()
        await addITunesWhenReady()
    }

    /// CDJ가 실은 곡을 바뀔 때만 알린다(서버를 끄면 비운다)
    func publishCDJTracks() {
        let loaded = Set(server?.players.values.compactMap(\.contentID) ?? [])
        guard loaded != lastCDJTracks else { return }
        lastCDJTracks = loaded
        cdjTracks(loaded)
    }

    /// 켤 때 iTunes 목록을 아직 읽는 중이었으면, 다 읽은 뒤 켜 둔 서버의 재생 목록에 넣는다(서버를 다시 띄우지 않는다)
    func addITunesWhenReady() async {
        guard isConnected, !servesITunes, let input = library(), let tree = input.iTunes else { return }
        servesITunes = true
        sentPlaylists = input.playlists
        servedITunes = tree
        sendPlaylists(input.playlists, iTunes: tree)
        await playlistUpdatesSent()
    }
}

/// LINK 막대 가운데의 장치 차례
struct LinkArrangement: Equatable {
    var left: [LinkDevice]
    var mixers: [LinkDevice]
    var right: [LinkDevice]

    init(_ devices: [LinkDevice]) {
        let players = devices.filter(\.hasDeck).sorted { $0.number < $1.number }
        let half = (players.count + 1) / 2
        left = Array(players.prefix(half))
        mixers = devices.filter { $0.kind == .mixer }.sorted { $0.number < $1.number }
        right = Array(players.dropFirst(half)) + devices.filter { !$0.hasDeck && $0.kind != .mixer }.sorted { $0.number < $1.number }
    }
}

/// LINK 막힘 이유를 사람이 읽는 한 문장으로(무엇을 하면 되는지까지)
enum LinkText {
    static func problem(_ problem: LinkProblem) -> String {
        switch problem {
        case .rekordboxRunning: String(ui: "rekordbox가 같은 LINK 포트를 쓰고 있습니다. rekordbox를 끈 뒤 쓰세요")
        case .noDevice: String(ui: "네트워크에 CDJ가 보이지 않습니다. CDJ를 같은 네트워크에 연결한 뒤 켜세요")
        case .noInterface: String(ui: "CDJ로 가는 네트워크 연결을 찾지 못했습니다. 케이블·네트워크 설정을 확인한 뒤 다시 켜세요")
        case let .portInUse(why): String(ui: "LINK 포트를 열지 못했습니다(\(why)). 그 포트를 쓰는 앱을 끈 뒤 다시 켜세요")
        case .notConnected: String(ui: "LINK를 누른 뒤 곡을 놓으세요")
        case .notJoined: String(ui: "아직 LINK에 참여하는 중입니다. 잠시 뒤 다시 놓으세요")
        case .trackNotShared: String(ui: "이 곡은 LINK로 내어 주지 않습니다. rekordbox 컬렉션에 있고 파일이 있는 MP3·WAV·AIFF·M4A·FLAC 곡만 실을 수 있습니다")
        case let .playerMissing(number): String(ui: "\(number)번 플레이어가 네트워크에 없습니다. 플레이어를 확인한 뒤 다시 놓으세요")
        case let .notMounted(number): String(ui: "\(number)번 플레이어가 아직 DJCrate 라이브러리를 열지 않았습니다. 잠시 뒤 다시 놓으세요")
        case .cancelled: String(ui: "LINK 연결을 껐습니다")
        case let .failed(why): String(ui: "LINK 일이 실패했습니다: \(why)")
        case let .conversionFailed(why): String(ui: "CDJ가 읽을 수 있는 WAV로 바꾸지 못했습니다(\(why)). 음원 파일을 확인한 뒤 다시 놓으세요")
        }
    }

    /// CDJ에서 고른 곡을 백그라운드에서 바꾼 결과(#277)
    static func backgroundConversion(_ event: LinkBackgroundConversion) -> String {
        switch event {
        case let .finished(title): String(ui: "‘\(title)’ 곡을 CDJ가 읽을 수 있는 WAV로 바꿨습니다. CDJ에서 다시 실으세요")
        case let .failed(title, .conversionFailed(why)):
            String(ui: "‘\(title)’ 곡을 CDJ가 읽을 수 있는 WAV로 바꾸지 못했습니다(\(why)). 음원 파일을 확인하세요")
        case let .failed(title, why): String(ui: "‘\(title)’ 곡을 WAV로 바꾸지 못했습니다. \(problem(why))")
        }
    }
}
