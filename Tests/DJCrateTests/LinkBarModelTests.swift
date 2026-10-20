import DJCApplication
@testable import DJCrate
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 창 아래 LINK 막대(#272): 장치가 보일 때만 단추를 띄우고, 펼치면 장치를 보이며 라이브러리를 내어 준다. rekordbox가 켜져 있으면 이유를 보인다.
/// 장치 찾기 상태는 직접 넣는다(포트를 열지 않는다).
@Suite("LINK 막대")
@MainActor
struct LinkBarModelTests {
    static let cdj1 = LinkDevice(number: 1, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.192")

    static func model() -> LinkBarModel { LinkBarModel(discovery: LinkDiscovery(source: .none)) }

    @Test func 장치가_없으면_단추를_보이지_않는다() {
        let model = Self.model()
        #expect(!model.isVisible)
        model.apply(.listening([]))
        #expect(!model.isVisible)
        model.apply(.unavailable)
        #expect(!model.isVisible)
    }

    @Test func 장치가_보이면_단추를_띄우고_펼쳐야_장치를_보인다() {
        let model = Self.model()
        model.apply(.listening([Self.cdj1]))
        #expect(model.isVisible)
        #expect(!model.showsDevices)
        model.toggle()
        #expect(model.showsDevices)
        #expect(model.devices == [Self.cdj1])
        model.toggle()
        #expect(!model.showsDevices)
    }

    @Test func rekordbox가_켜져_있으면_장치_대신_이유를_보인다() {
        let model = Self.model()
        model.apply(.listening([Self.cdj1]))
        model.toggle()
        model.apply(.blockedByRekordbox)
        #expect(model.isVisible)
        #expect(!model.showsDevices)
        #expect(model.blockReason != nil)
    }

    @Test func 장치가_모두_빠지면_단추를_숨긴다() {
        let model = Self.model()
        model.apply(.listening([Self.cdj1]))
        model.toggle()
        model.apply(.listening([]))
        #expect(!model.isVisible)
        #expect(!model.showsDevices)
    }

    @Test func 플레이어는_반씩_믹서_양쪽에_두고_그_밖의_장치는_오른쪽_끝에_둔다() {
        func device(_ number: Int, _ kind: LinkDevice.Kind) -> LinkDevice {
            LinkDevice(number: number, name: "\(number)", kind: kind, address: "169.254.0.\(number)")
        }
        let devices = [device(33, .mixer), device(4, .player), device(1, .player), device(3, .player), device(2, .player),
                       device(18, .rekordbox)]
        let arrangement = LinkArrangement(devices)
        #expect(arrangement.left.map(\.number) == [1, 2])
        #expect(arrangement.mixers.map(\.number) == [33])
        #expect(arrangement.right.map(\.number) == [3, 4, 18])
        // 홀수면 왼쪽이 하나 더 많다
        #expect(LinkArrangement([device(2, .player), device(1, .player), device(3, .player)]).left.map(\.number) == [1, 2])
    }

    // MARK: - 연결(#273·#274)

    static let own = LinkDevice(number: 17, name: "DJCrate", kind: .rekordbox, address: "169.254.1.2")

    static func connectable(notes: NotesBox, problem: LinkProblem? = nil,
                            updated: @escaping @Sendable (UInt32, [LinkLibrary.Cue]) async -> Void = { _, _ in }) -> LinkBarModel {
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in },
            stop: {},
            status: { LinkServerStatus(deviceNumber: 17, mounted: ["169.254.86.192"]) },
            load: { _, _ throws(LinkProblem) in if let problem { throw problem } },
            isRekordboxRunning: { false }, updateCues: updated)
        let row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                        folderPath: "/Users/dj/Music/10.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        return LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                            library: { .init(rows: [row], playlists: PlaylistLayout(), shareRoot: "/share") },
                            notify: { text, _ in notes.values.append(text) })
    }

    @MainActor final class NotesBox {
        var values: [String] = []
    }

    @Test func 변환본을_비우는_동안_켜면_다_비운_뒤에_내어_주고_켠_동안은_비우기를_시작하지_않는다() async throws {
        // #287 PR 리뷰: 비우기가 내어 주는지 한 번만 보면, 비우는 사이 켠 LINK가 CDJ에 내어 준 변환본을 지운다
        let started = Mutex(0)
        let source = LinkServerSource(start: { _, _, _, _ throws(LinkProblem) in started.withLock { $0 += 1 } }, stop: {},
                                      status: { LinkServerStatus(deviceNumber: 17) }, load: { _, _ throws(LinkProblem) in },
                                      isRekordboxRunning: { false })
        let row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                        folderPath: "/Users/dj/Music/10.flac", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [row], playlists: PlaylistLayout(), shareRoot: "/share") })
        model.apply(.listening([Self.cdj1]))
        let end = try #require(model.beginCacheClear())
        let connecting = Task { await model.connect() }
        while !model.isServing { await Task.yield() }
        // 켜는 중이면 새 비우기는 시작하지 않는다
        #expect(model.beginCacheClear() == nil)
        // 다 비울 때까지 서버를 띄우지 않는다(켜기가 서버를 띄울 틈을 준다)
        try await Task.sleep(for: .milliseconds(100))
        #expect(started.withLock { $0 } == 0)
        end()
        await connecting.value
        #expect(started.withLock { $0 } == 1)
        #expect(model.isConnected)
        #expect(model.beginCacheClear() == nil)
    }

    @Test func 연결한_동안_고친_큐를_바뀔_때만_차례대로_서버에_보낸다() async {
        // #281: DJCrate에서 고친 큐·루프를 CDJ가 다시 실으면 보이게 한다
        let sent = Mutex<[[UInt32]]>([])
        let model = Self.connectable(notes: NotesBox(), updated: { _, cues in sent.withLock { $0.append(cues.map(\.positionMs)) } })
        let cue = Cue(id: "1", contentID: "10", kind: 0, inMsec: 1_000, name: "", colorTableIndex: nil)
        model.updateCues(contentID: "10", cues: [cue])
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        model.updateCues(contentID: "10", cues: [cue])
        model.updateCues(contentID: "10", cues: [cue])
        model.updateCues(contentID: "10", cues: [])
        await model.cueUpdatesSent()
        #expect(sent.withLock { $0 } == [[1_000], []])
    }

    @Test func 연결한_동안_재생_목록_초안이_바뀌면_바뀔_때만_차례대로_서버에_보낸다() async {
        // 재생 목록 초안을 얹은 모양을 내어 준다. 추가 대기 곡(djc-)은 rekordbox 분석 파일이 없어 목록에서도 빠진다
        let sent = Mutex<[[String]]>([])
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in }, stop: {}, status: { LinkServerStatus(deviceNumber: 17) },
            load: { _, _ throws(LinkProblem) in }, isRekordboxRunning: { false },
            updatePlaylists: { playlists in sent.withLock { $0.append(playlists.map { "\($0.name):\($0.trackIDs.count)" }) } })
        func row(_ id: String) -> TrackRow {
            TrackRow(track: Track(id: id, uuid: "u\(id)", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                  composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                  folderPath: "/Users/dj/Music/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                  imagePath: nil, isDeleted: false),
                     cues: [], playCount: 0)
        }
        final class Layout: @unchecked Sendable { var value = PlaylistLayout() }
        let layout = Layout()
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [row("10"), row("djc-1")], playlists: layout.value, shareRoot: "/share") })
        model.updatePlaylists()
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        model.updatePlaylists()
        let draft = PlaylistLayout.Item(id: "new:1", name: "초안 목록",
                                        entries: [PlaylistEntry(trackNo: 1, contentID: "10"), PlaylistEntry(trackNo: 2, contentID: "djc-1")])
        layout.value = PlaylistLayout([(draft, 0)])
        model.updatePlaylists()
        model.updatePlaylists()
        await model.playlistUpdatesSent()
        #expect(sent.withLock { $0 } == [["초안 목록:1"]])
    }

    /// 문을 열 때까지 지나가는 쪽을 세워 둔다(보내기가 끝나기 전의 차례를 만들려고)
    final class Blocker: Sendable {
        private let state = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
        func pass() async {
            await withCheckedContinuation { continuation in
                let go = state.withLock { state -> Bool in
                    if state.open { return true }
                    state.waiting.append(continuation)
                    return false
                }
                if go { continuation.resume() }
            }
        }
        func open() {
            let waiting = state.withLock { state in
                state.open = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for continuation in waiting { continuation.resume() }
        }
        var waitingCount: Int { state.withLock { $0.waiting.count } }
    }

    final class LayoutBox: @unchecked Sendable { var value = PlaylistLayout() }

    static func layout(_ name: String) -> PlaylistLayout {
        PlaylistLayout([(PlaylistLayout.Item(id: "new:\(name)", name: name, entries: [PlaylistEntry(trackNo: 1, contentID: "10")]), 0)])
    }

    static let mp3Row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                              folderPath: "/Users/dj/Music/10.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                              imagePath: nil, isDeleted: false),
                                 cues: [], playCount: 0)

    @Test func 켜는_중에_바뀐_재생_목록_초안은_켠_뒤에_보낸다() async {
        let sent = Mutex<[[String]]>([])
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in await withCheckedContinuation { c in gate.withLock { $0 = c } } },
            stop: {}, status: { LinkServerStatus(deviceNumber: 17) }, load: { _, _ throws(LinkProblem) in },
            isRekordboxRunning: { false }, updatePlaylists: { playlists in sent.withLock { $0.append(playlists.map(\.name)) } })
        let layout = LayoutBox()
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [Self.mp3Row], playlists: layout.value, shareRoot: "/share") })
        model.apply(.listening([Self.cdj1]))
        let connecting = Task { await model.connect() }
        while gate.withLock({ $0 == nil }) { await Task.yield() }
        // 켤 때 읽은 모양(빈 목록)으로 서버가 뜨는 사이 초안이 바뀌었다
        layout.value = Self.layout("켜는 중")
        model.updatePlaylists()
        gate.withLock { $0?.resume(); $0 = nil }
        await connecting.value
        await model.playlistUpdatesSent()
        #expect(sent.withLock { $0 } == [["켜는 중"]])
    }

    @Test func 늦게_넣는_iTunes_목록은_앞서_걸어_둔_재생_목록_보내기에_지워지지_않는다() async {
        // 둘이 서로 다른 줄로 보내면 늦게 끝난 초안 보내기가 iTunes 폴더 없는 모양으로 덮었다(리뷰)
        let sent = Mutex<[[String]]>([])
        let blocker = Blocker()
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in }, stop: {}, status: { LinkServerStatus(deviceNumber: 17) },
            load: { _, _ throws(LinkProblem) in }, isRekordboxRunning: { false },
            updatePlaylists: { playlists in
                await blocker.pass()
                sent.withLock { $0.append(playlists.map(\.name)) }
            })
        let layout = LayoutBox()
        let ready = ITunesBox()
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [Self.mp3Row], playlists: layout.value, iTunes: ready.tree, shareRoot: "/share") })
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        layout.value = Self.layout("첫째")
        model.updatePlaylists()
        layout.value = Self.layout("둘째")
        model.updatePlaylists()
        while blocker.waitingCount == 0 { await Task.yield() }
        ready.tree = SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: [.init(id: "B", name: "Later", paths: ["/Users/dj/Music/10.mp3"])]),
                                         tracks: [Self.mp3Row.track]).tree
        let adding = Task { await model.addITunesWhenReady() }
        blocker.open()
        await adding.value
        await model.playlistUpdatesSent()
        #expect(sent.withLock { $0.last } == ["iTunes", "Later", "둘째"])
    }

    @Test func 끄기_전에_걸어_둔_재생_목록_보내기는_다시_켠_서버에_보내지_않는다() async {
        let sent = Mutex<[[String]]>([])
        let blocker = Blocker()
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in }, stop: {}, status: { LinkServerStatus(deviceNumber: 17) },
            load: { _, _ throws(LinkProblem) in }, isRekordboxRunning: { false },
            updatePlaylists: { playlists in
                await blocker.pass()
                sent.withLock { $0.append(playlists.map(\.name)) }
            })
        let layout = LayoutBox()
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [Self.mp3Row], playlists: layout.value, shareRoot: "/share") })
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        layout.value = Self.layout("첫째")
        model.updatePlaylists()
        layout.value = Self.layout("둘째")
        model.updatePlaylists()
        while blocker.waitingCount == 0 { await Task.yield() }
        // 첫째가 서버에서 끝나기 전에 끄고 다시 켠다. 다시 켠 서버는 켤 때 읽은 모양(둘째)으로 뜬다
        let reconnect = Task {
            await model.disconnect()
            await model.connect()
        }
        while model.isConnected { await Task.yield() }
        blocker.open()
        await reconnect.value
        await model.playlistUpdatesSent()
        #expect(sent.withLock { $0 } == [["첫째"]])
    }

    @Test func 켜는_중에_고친_큐는_연결된_뒤에_보낸다() async {
        // 켜는 동안(.connecting) 고친 큐를 버리면, 켤 때 읽은 옛 초안 큐가 그대로 남았다(#281 리뷰)
        let sent = Mutex<[[UInt32]]>([])
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in await withCheckedContinuation { c in gate.withLock { $0 = c } } },
            stop: {}, status: { LinkServerStatus(deviceNumber: 17) }, load: { _, _ throws(LinkProblem) in },
            isRekordboxRunning: { false }, updateCues: { _, cues in sent.withLock { $0.append(cues.map(\.positionMs)) } })
        let row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                        folderPath: "/Users/dj/Music/10.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [row], playlists: PlaylistLayout(), shareRoot: "/share") })
        model.apply(.listening([Self.cdj1]))
        let connecting = Task { await model.connect() }
        while gate.withLock({ $0 == nil }) { await Task.yield() }
        #expect(model.isServing)
        model.updateCues(contentID: "10", cues: [Cue(id: "1", contentID: "10", kind: 0, inMsec: 3_000, name: "", colorTableIndex: nil)])
        gate.withLock { $0?.resume(); $0 = nil }
        await connecting.value
        await model.cueUpdatesSent()
        #expect(sent.withLock { $0 } == [[3_000]])
    }

    @Test func 연결을_켜면_내어_준_곡_수와_참여_번호를_보이고_자신은_목록에서_뺀다() async {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes)
        model.apply(.listening([Self.cdj1, Self.own]))
        await model.connect()
        #expect(model.connection == .on(tracks: 1))
        #expect(model.server?.deviceNumber == 17)
        #expect(model.devices == [Self.cdj1])
        #expect(model.isMounted(Self.cdj1))
        #expect(model.acceptsDrop(Self.cdj1))
        #expect(model.connectionText != nil)
        #expect(notes.values.isEmpty)
    }

    @Test func LINK를_펼치면_내어_주고_접으면_내어_주기를_끈다() async throws {
        let model = Self.connectable(notes: NotesBox())
        model.apply(.listening([Self.cdj1]))
        model.toggle()
        #expect(model.isExpanded)
        // 펼치기가 띄운 연결을 기다린다(안전망 300초, TEST-32)
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !model.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.connection == .on(tracks: 1))
        model.toggle()
        #expect(!model.isExpanded)
        while model.connection != .off, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.connection == .off)
        #expect(model.server == nil)
    }

    @Test func rekordbox가_켜져_있으면_펼쳐도_내어_주지_않는다() async {
        let model = Self.connectable(notes: NotesBox())
        model.apply(.blockedByRekordbox)
        model.toggle()
        #expect(model.isExpanded)
        #expect(model.connection == .off)
    }

    @Test func 펼친_채_rekordbox가_꺼지면_다시_내어_준다() async throws {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes)
        model.apply(.blockedByRekordbox)
        model.toggle()
        // 포트를 다시 열면 빈 목록이 먼저 온다
        model.apply(.listening([]))
        #expect(model.connection == .off)
        model.apply(.listening([Self.cdj1]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !model.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.connection == .on(tracks: 1))
        #expect(notes.values.isEmpty)
    }

    @Test func 켤_때_iTunes_목록을_읽는_중이었으면_다_읽은_뒤_켜_둔_서버에_넣는다() async throws {
        let updated = Mutex<[[LinkLibrary.Playlist]]>([])
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in }, stop: {}, status: { LinkServerStatus(deviceNumber: 17) },
            load: { _, _ throws(LinkProblem) in }, isRekordboxRunning: { false },
            updatePlaylists: { playlists in updated.withLock { $0.append(playlists) } })
        let row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                        folderPath: "/Users/dj/Music/10.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        let ready = ITunesBox()
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [row], playlists: PlaylistLayout(), iTunes: ready.tree, shareRoot: "/share") })
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        await model.addITunesWhenReady()
        #expect(updated.withLock { $0.isEmpty })
        ready.tree = SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: [.init(id: "B", name: "Later", paths: ["/Users/dj/Music/10.mp3"])]),
                                         tracks: [row.track]).tree
        await model.addITunesWhenReady()
        await model.addITunesWhenReady()
        #expect(updated.withLock { $0.map { $0.map(\.name) } } == [["iTunes", "Later"]])
    }

    @MainActor final class ITunesBox {
        var tree: [SyncedITunesLibrary.Node]?
    }

    @Test func CDJ가_실은_DJCrate_곡을_바뀔_때만_알리고_끄면_비운다() async {
        let reports = NotesBox()
        let box = LoadedBox()
        let source = LinkServerSource(
            start: { _, _, _, _ throws(LinkProblem) in }, stop: {},
            status: { LinkServerStatus(deviceNumber: 17, players: [2: LinkPlayerState(loadedTrackID: box.id)]) },
            load: { _, _ throws(LinkProblem) in }, isRekordboxRunning: { false })
        let row = TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                                        folderPath: "/Users/dj/Music/10.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        let model = LinkBarModel(discovery: LinkDiscovery(source: .none), session: LinkSession(source: source),
                                 library: { .init(rows: [row], playlists: PlaylistLayout(), shareRoot: "/share") },
                                 cdjTracks: { reports.values.append($0.sorted().joined(separator: ",")) })
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        #expect(reports.values == [])
        box.id = 1
        await model.refreshStatus()
        await model.refreshStatus()
        #expect(reports.values == ["10"])
        await model.disconnect()
        #expect(reports.values == ["10", ""])
    }

    final class LoadedBox: @unchecked Sendable {
        var id: UInt32?
    }

    @Test func 참여하고_플레이어가_마운트할_때까지는_상태를_자주_본다() async {
        let model = Self.connectable(notes: NotesBox())
        #expect(model.pollInterval == model.statusInterval)
        model.apply(.listening([Self.cdj1, Self.own]))
        await model.connect()
        // 가짜 서버는 17번으로 참여했고 cdj1이 마운트했다
        #expect(model.pollInterval == model.statusInterval)
        let other = LinkDevice(number: 2, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.211")
        model.apply(.listening([Self.cdj1, other]))
        #expect(model.pollInterval == model.settlingInterval)
    }

    @Test func 장치가_없으면_연결하지_않고_이유를_알린다() async {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes)
        await model.connect()
        #expect(model.connection == .off)
        #expect(notes.values == [LinkText.problem(.noDevice)])
    }

    @Test func 연결을_끄기_전에는_플레이어에_곡을_놓을_수_없다() {
        let model = Self.connectable(notes: NotesBox())
        model.apply(.listening([Self.cdj1]))
        #expect(!model.acceptsDrop(Self.cdj1))
    }

    @Test func 싣기가_막히면_이유를_알린다() async {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes, problem: .notMounted(1))
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        await model.load(contentID: "10", on: Self.cdj1)
        #expect(notes.values == [LinkText.problem(.notMounted(1))])
    }

    @Test func rekordbox가_켜지면_연결을_끄고_알린다() async {
        let notes = NotesBox()
        let model = Self.connectable(notes: notes)
        model.apply(.listening([Self.cdj1]))
        await model.connect()
        model.apply(.blockedByRekordbox)
        #expect(model.connection == .off)
        #expect(model.server == nil)
        #expect(notes.values.count == 1)
    }
}
