@testable import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// LINK 연결(#273·#274): 켜기 전 확인, 서버에 넘기는 라이브러리, 곡 싣기 번호. 가짜 서버 포트만 쓰고 소켓을 열지 않는다.
@Suite("LINK 연결")
struct LinkSessionTests {
    static let cdj2 = LinkDevice(number: 2, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.193")
    static let djm = LinkDevice(number: 33, name: "DJM-900NXS2", kind: .mixer, address: "169.254.98.242")

    static func row(_ id: String, path: String? = nil) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                              folderPath: path ?? "/Users/dj/Music/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                              imagePath: nil, isDeleted: false),
                 cues: [], playCount: 0)
    }

    /// 서버 포트가 받은 것을 적는다
    final class Fake: Sendable {
        let rekordbox = Mutex(false)
        let started = Mutex<[(library: LinkLibrary, shareRoot: String, peer: String)]>([])
        /// 마지막으로 띄운 서버의 재생 기록 알림(시험이 CDJ 대신 부른다)
        let history = Mutex<(@Sendable (LinkHistoryEvent) -> Void)?>(nil)
        let stopped = Mutex(0)
        let loaded = Mutex<[(player: Int, id: UInt32)]>([])
        let loadProblem = Mutex<LinkProblem?>(nil)
        /// 켜면 서버 띄우기를 시험이 풀어 줄 때까지 멈춘다(그 사이 끄기를 끼워 넣는다)
        let holdsStart = Mutex(false)
        let held = Mutex<CheckedContinuation<Void, Never>?>(nil)

        /// 켜면 rekordbox 확인을 시험이 풀어 줄 때까지 막는다(확인은 메인 밖 스레드에서 돈다)
        let holdsRekordboxCheck = Mutex(false)
        let checking = Mutex(false)
        let checkGate = DispatchSemaphore(value: 0)

        func releaseStart() { held.withLock { $0?.resume(); $0 = nil } }
        var isHolding: Bool { held.withLock { $0 != nil } }
        var isChecking: Bool { checking.withLock { $0 } }

        var source: LinkServerSource {
            LinkServerSource(
                start: { [self] library, root, peer, history throws(LinkProblem) in
                    self.history.withLock { $0 = history }
                    if holdsStart.withLock({ $0 }) {
                        await withCheckedContinuation { continuation in held.withLock { $0 = continuation } }
                    }
                    started.withLock { $0.append((library, root, peer)) }
                },
                stop: { [self] in stopped.withLock { $0 += 1 } },
                status: { LinkServerStatus(deviceNumber: 17, players: [2: LinkPlayerState(isPlaying: true, loadedTrackID: 2),
                                                                        1: LinkPlayerState(loadedTrackID: nil)]) },
                load: { [self] player, id throws(LinkProblem) in
                    if let problem = loadProblem.withLock({ $0 }) { throw problem }
                    loaded.withLock { $0.append((player, id)) }
                },
                isRekordboxRunning: { [self] in
                    if holdsRekordboxCheck.withLock({ $0 }) {
                        checking.withLock { $0 = true }
                        checkGate.wait()
                    }
                    return rekordbox.withLock { $0 }
                })
        }
    }

    @Test func 켜면_컬렉션으로_만든_라이브러리를_플레이어_쪽으로_띄운다() async throws {
        let fake = Fake()
        let session = LinkSession(source: fake.source)
        let count = try await session.connect(rows: [Self.row("10"), Self.row("djc-1")], playlists: PlaylistLayout(), shareRoot: "/share",
                                              peers: [Self.djm, Self.cdj2])
        #expect(count == 1)
        let start = try #require(fake.started.withLock { $0.first })
        #expect(start.library.tracks.map(\.contentID) == ["10"])
        #expect(start.shareRoot == "/share")
        #expect(start.peer == Self.cdj2.address)
        #expect(await session.isConnected)
    }

    @Test func rekordbox가_켜져_있으면_서버를_띄우지_않는다() async {
        let fake = Fake()
        fake.rekordbox.withLock { $0 = true }
        let session = LinkSession(source: fake.source)
        await #expect(throws: LinkProblem.rekordboxRunning) {
            try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        }
        #expect(fake.started.withLock { $0.isEmpty })
        #expect(!(await session.isConnected))
    }

    @Test func 보이는_장치가_없으면_켜지_않는다() async {
        let session = LinkSession(source: Fake().source)
        await #expect(throws: LinkProblem.noDevice) {
            try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [])
        }
    }

    @Test func 곡은_rekordbox_ID가_아니라_내어_준_번호로_싣는다() async throws {
        let fake = Fake()
        let session = LinkSession(source: fake.source)
        try await session.connect(rows: [Self.row("10"), Self.row("20")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        try await session.load(contentID: "20", player: 2)
        #expect(fake.loaded.withLock { $0.map(\.player) } == [2])
        #expect(fake.loaded.withLock { $0.map(\.id) } == [2])
    }

    @Test func 내어_주지_않은_곡과_꺼진_연결은_싣지_않는다() async throws {
        let fake = Fake()
        let session = LinkSession(source: fake.source)
        await #expect(throws: LinkProblem.notConnected) { try await session.load(contentID: "10", player: 2) }
        try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        await #expect(throws: LinkProblem.trackNotShared) { try await session.load(contentID: "djc-1", player: 2) }
        #expect(fake.loaded.withLock { $0.isEmpty })
    }

    @Test func 서버가_막은_이유를_그대로_넘긴다() async throws {
        let fake = Fake()
        fake.loadProblem.withLock { $0 = .notMounted(2) }
        let session = LinkSession(source: fake.source)
        try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        await #expect(throws: LinkProblem.notMounted(2)) { try await session.load(contentID: "10", player: 2) }
    }

    @Test func FLAC·ALAC일_수_있는_곡은_바꾼_WAV로_바꿔_끼운_뒤_한_번만_바꾸고_싣는다() async throws {
        let fake = Fake()
        let swapped = Mutex<[(id: UInt32, path: String, type: UInt8)]>([])
        let conversions = Mutex(0)
        let gate = Mutex<(@Sendable (String, String) -> Bool)?>(nil)
        var source = fake.source
        source.substitute = { id, path, type in swapped.withLock { $0.append((id, path, type)) } }
        source.setFileHold = { hold in gate.withLock { $0 = hold } }
        let converter = LinkAudioConverter { path throws(LinkProblem) in
            conversions.withLock { $0 += 1 }
            return path.hasSuffix(".flac") ? "/Users/dj/Music/DJCrate/LINK/x.wav" : nil
        }
        let session = LinkSession(source: source, converter: converter)
        let flac = Self.row("10", path: "/Users/dj/Music/10.flac")
        let aac = Self.row("20", path: "/Users/dj/Music/20.m4a")
        try await session.connect(rows: [flac, aac, Self.row("30")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        #expect(await session.mayConvert(contentID: "10"))
        #expect(!(await session.mayConvert(contentID: "30")))
        try await session.load(contentID: "10", player: 2)
        try await session.load(contentID: "10", player: 2)
        try await session.load(contentID: "20", player: 2)
        try await session.load(contentID: "30", player: 2)
        #expect(swapped.withLock { $0.map(\.id) } == [1])
        #expect(swapped.withLock { $0.map(\.type) } == [11])
        // FLAC 한 번, AAC일 수 있는 .m4a는 볼 때마다(바꾸지 않았으니), MP3는 보지 않는다
        #expect(conversions.withLock { $0 } == 2)
        #expect(!(await session.mayConvert(contentID: "10")))
        #expect(fake.loaded.withLock { $0.map(\.id) } == [1, 1, 2, 3])
        // 바꿔 끼운 원본·바꿀 필요가 없는 원본은 CDJ가 찾을 때 미루지 않는다(곧바로 실은 곡이 기다리지 않게)
        let hold = try #require(gate.withLock { $0 })
        #expect(!hold("/Users/dj/Music/10.flac", "CDJ-2000nexus"))
        #expect(!hold("/Users/dj/Music/20.m4a", "CDJ-2000nexus"))
    }

    @Test func 같은_곡을_바꾸는_동안_또_놓으면_진행_중인_변환을_함께_기다린다() async throws {
        // 두 변환이 같은 출력·임시 파일을 쓰면 한쪽이 덜 쓴 WAV를 내어 줄 수 있다(PR #279 리뷰)
        let fake = Fake()
        let conversions = Mutex(0)
        let swapped = Mutex(0)
        // 풀기 전에 닿은 변환은 멈추고, 푼 뒤에 닿은 변환은 바로 끝난다
        let gate = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
        var source = fake.source
        source.substitute = { _, _, _ in swapped.withLock { $0 += 1 } }
        let session = LinkSession(source: source, converter: LinkAudioConverter { _ throws(LinkProblem) in
            conversions.withLock { $0 += 1 }
            await withCheckedContinuation { continuation in
                let now = gate.withLock { state in
                    if state.open { return true }
                    state.waiting.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
            return "/Users/dj/Music/DJCrate/LINK/x.wav"
        })
        try await session.connect(rows: [Self.row("10", path: "/Users/dj/Music/10.flac")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        async let first: Void = session.load(contentID: "10", player: 1)
        async let second: Void = session.load(contentID: "10", player: 2)
        while gate.withLock({ $0.waiting.isEmpty }) { await Task.yield() }
        // 두 번째 싣기가 변환 앞에 닿을 틈을 준다
        try await Task.sleep(for: .milliseconds(100))
        let held = gate.withLock { state in
            state.open = true
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        held.forEach { $0.resume() }
        try await first
        try await second
        #expect(conversions.withLock { $0 } == 1)
        #expect(swapped.withLock { $0 } == 1)
        #expect(fake.loaded.withLock { $0.map(\.player).sorted() } == [1, 2])
    }

    @Test func 바꾸는_사이_끊고_다시_켜면_앞_싣기는_새_서버에_끼우지_않는다() async throws {
        // 같은 곡 번호라도 다시 읽은 라이브러리의 경로가 다를 수 있다(PR #279 리뷰)
        let fake = Fake()
        let swapped = Mutex(0)
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        var source = fake.source
        source.substitute = { _, _, _ in swapped.withLock { $0 += 1 } }
        let session = LinkSession(source: source, converter: LinkAudioConverter { _ throws(LinkProblem) in
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
            return "/Users/dj/Music/DJCrate/LINK/x.wav"
        })
        let row = Self.row("10", path: "/Users/dj/Music/10.flac")
        try await session.connect(rows: [row], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        let load = Task { () -> LinkProblem? in
            do throws(LinkProblem) { try await session.load(contentID: "10", player: 2); return nil } catch { return error }
        }
        while gate.withLock({ $0 == nil }) { await Task.yield() }
        await session.disconnect()
        try await session.connect(rows: [Self.row("10", path: "/Users/dj/Music/moved/10.flac")], playlists: PlaylistLayout(),
                                  shareRoot: "/share", peers: [Self.cdj2])
        gate.withLock { $0?.resume(); $0 = nil }
        #expect(await load.value == .notConnected)
        #expect(swapped.withLock { $0 } == 0)
        #expect(fake.loaded.withLock { $0.isEmpty })
    }

    @Test func FLAC·ALAC을_재생하는_기종에는_바꾸지_않고_원본을_싣는다() async throws {
        let fake = Fake()
        let conversions = Mutex(0)
        let swapped = Mutex(0)
        var source = fake.source
        source.substitute = { _, _, _ in swapped.withLock { $0 += 1 } }
        let session = LinkSession(source: source, converter: LinkAudioConverter { _ throws(LinkProblem) in
            conversions.withLock { $0 += 1 }
            return "/Users/dj/Music/DJCrate/LINK/x.wav"
        })
        try await session.connect(rows: [Self.row("10", path: "/Users/dj/Music/10.flac")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        #expect(!(await session.mayConvert(contentID: "10", playerModel: "CDJ-3000")))
        try await session.load(contentID: "10", player: 2, playerModel: "CDJ-3000")
        try await session.load(contentID: "10", player: 2, playerModel: "CDJ-2000NXS2")
        #expect(conversions.withLock { $0 } == 0)
        #expect(swapped.withLock { $0 } == 0)
        // 못 읽는 기종에 실으면 그때 바꾼다
        #expect(await session.mayConvert(contentID: "10", playerModel: "CDJ-2000nexus"))
        try await session.load(contentID: "10", player: 1, playerModel: "CDJ-2000nexus")
        #expect(conversions.withLock { $0 } == 1)
        #expect(swapped.withLock { $0 } == 1)
    }

    @Test func 바꾸지_못하면_싣지_않고_이유를_넘긴다() async throws {
        let fake = Fake()
        let gate = Mutex<(@Sendable (String, String) -> Bool)?>(nil)
        var source = fake.source
        source.setFileHold = { hold in gate.withLock { $0 = hold } }
        let session = LinkSession(source: source, converter: LinkAudioConverter { path throws(LinkProblem) in
            // 바꾸는 사이 CDJ가 같은 원본을 찾아 서버가 답을 미뤘다
            _ = gate.withLock { $0 }?(path, "CDJ-2000nexus")
            throw .conversionFailed("깨진 파일")
        })
        let flac = Self.row("10", path: "/Users/dj/Music/10.flac")
        try await session.connect(rows: [flac], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        await #expect(throws: LinkProblem.conversionFailed("깨진 파일")) { try await session.load(contentID: "10", player: 2) }
        // 바꾸지 못한 원본은 곧바로 원본으로 답한다(CDJ가 다시 물을 때마다 또 바꾸지 않게)
        let hold = try #require(gate.withLock { $0 })
        #expect(!hold("/Users/dj/Music/10.flac", "CDJ-2000nexus"))
        #expect(fake.loaded.withLock { $0.isEmpty })
    }

    @Test func CDJ가_못_읽는_원본을_읽으려_하면_바꾸는_동안_답을_미루고_WAV로_바꿔_끼운다() async throws {
        // CDJ 상태 패킷에는 로드 실패 칸이 없다. 플레이어가 NFS로 원본을 찾으면 바꾸는 동안 답하지 않고(CDJ가 다시 묻는다),
        // 다 바꾼 뒤의 요청에 WAV로 답해 첫 싣기부터 실리게 한다. 제때 실렸으니 알리지 않는다
        let fake = Fake()
        let swapped = Mutex<[(id: UInt32, path: String, type: UInt8)]>([])
        let conversions = Mutex(0)
        let events = Mutex<[LinkBackgroundConversion]>([])
        let gate = Mutex<(@Sendable (String, String) -> Bool)?>(nil)
        let heldWhileConverting = Mutex<Bool?>(nil)
        var source = fake.source
        source.substitute = { id, path, type in swapped.withLock { $0.append((id, path, type)) } }
        source.setFileHold = { hold in gate.withLock { $0 = hold } }
        let session = LinkSession(source: source, converter: LinkAudioConverter { path throws(LinkProblem) in
            conversions.withLock { $0 += 1 }
            heldWhileConverting.withLock { $0 = gate.withLock { $0 }?(path, "CDJ-2000nexus") }
            return "/Users/dj/Music/DJCrate/LINK/x.wav"
        }, backgroundConversion: { event in events.withLock { $0.append(event) } })
        try await session.connect(rows: [Self.row("10"), Self.row("20", path: "/Users/dj/Music/20.flac")], playlists: PlaylistLayout(),
                                  shareRoot: "/share", peers: [Self.cdj2])
        let hold = try #require(gate.withLock { $0 })
        #expect(hold("/Users/dj/Music/20.flac", "CDJ-2000nexus"))
        #expect(!hold("/Users/dj/Music/10.mp3", "CDJ-2000nexus"))
        let history = try #require(fake.history.withLock { $0 })
        history(.fileRequested(path: "/Users/dj/Music/20.flac", playerModel: "CDJ-2000nexus"))
        while swapped.withLock({ $0.isEmpty }) || hold("/Users/dj/Music/20.flac", "CDJ-2000nexus") { await Task.yield() }
        #expect(heldWhileConverting.withLock { $0 } == true)
        #expect(swapped.withLock { $0.map(\.id) } == [2])
        #expect(swapped.withLock { $0.map(\.type) } == [11])
        #expect(events.withLock { $0.isEmpty })
        // 바꾼 뒤에는 원본을 또 읽어도(앞 요청의 READ 등), 바꾼 WAV를 읽어도 다시 바꾸지 않는다. 곡은 CDJ가 싣는다
        let generation = await session.currentGeneration
        await session.fileRequested(path: "/Users/dj/Music/20.flac", playerModel: "CDJ-2000nexus", generation: generation)
        await session.fileRequested(path: "/Users/dj/Music/DJCrate/LINK/x.wav", playerModel: "CDJ-2000nexus", generation: generation)
        #expect(conversions.withLock { $0 } == 1)
        #expect(fake.loaded.withLock { $0.isEmpty })
        #expect(!(await session.mayConvert(contentID: "20")))
    }

    @Test func 바꾸는_데_오래_걸려_원본으로_답했으면_다_바꾼_뒤_다시_실으라고_알린다() async throws {
        let fake = Fake()
        let clock = LinkFileHoldTests.Clock()
        let events = Mutex<[LinkBackgroundConversion]>([])
        let gate = Mutex<(@Sendable (String, String) -> Bool)?>(nil)
        var source = fake.source
        source.setFileHold = { hold in gate.withLock { $0 = hold } }
        let session = LinkSession(source: source, converter: LinkAudioConverter { path throws(LinkProblem) in
            // 바꾸는 사이 CDJ가 상한보다 오래 다시 물어 서버가 원본으로 답했다
            let hold = gate.withLock { $0 }
            _ = hold?(path, "CDJ-2000nexus")
            clock.advance(LinkFileHold.limit + .seconds(1))
            _ = hold?(path, "CDJ-2000nexus")
            return "/Users/dj/Music/DJCrate/LINK/x.wav"
        }, backgroundConversion: { event in events.withLock { $0.append(event) } }, fileHold: LinkFileHold(now: { clock.now() }))
        try await session.connect(rows: [Self.row("20", path: "/Users/dj/Music/20.flac")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        await session.fileRequested(path: "/Users/dj/Music/20.flac", playerModel: "CDJ-2000nexus", generation: await session.currentGeneration)
        #expect(events.withLock { $0 } == [.finished(title: "곡 20")])
    }

    @Test func 읽을_수_있는_기종·다른_파일·바꿀_필요_없는_음원은_백그라운드에서_바꾸지_않는다() async throws {
        let fake = Fake()
        let conversions = Mutex<[String]>([])
        let events = Mutex<[LinkBackgroundConversion]>([])
        var source = fake.source
        let swapped = Mutex(0)
        source.substitute = { _, _, _ in swapped.withLock { $0 += 1 } }
        let session = LinkSession(source: source, converter: LinkAudioConverter { path throws(LinkProblem) in
            conversions.withLock { $0.append(path) }
            // AAC .m4a는 바꿀 필요가 없다
            return nil
        }, backgroundConversion: { event in events.withLock { $0.append(event) } })
        try await session.connect(rows: [Self.row("10"), Self.row("20", path: "/Users/dj/Music/20.flac"),
                                         Self.row("30", path: "/Users/dj/Music/30.m4a")], playlists: PlaylistLayout(),
                                  shareRoot: "/share", peers: [Self.cdj2])
        let generation = await session.currentGeneration
        await session.fileRequested(path: "/Users/dj/Music/20.flac", playerModel: "CDJ-3000", generation: generation)
        await session.fileRequested(path: "/Users/dj/Music/10.mp3", playerModel: "CDJ-2000nexus", generation: generation)
        await session.fileRequested(path: "/share/PIONEER/USBANLZ/P000/0000/ANLZ0000.DAT", playerModel: "CDJ-2000nexus",
                                    generation: generation)
        // 바꿀 필요가 없다고 본 음원은 이 연결에서 다시 보지 않는다
        await session.fileRequested(path: "/Users/dj/Music/30.m4a", playerModel: "CDJ-2000nexus", generation: generation)
        await session.fileRequested(path: "/Users/dj/Music/30.m4a", playerModel: "CDJ-2000nexus", generation: generation)
        // 끄고 다시 켜기 전(앞 차례)의 요청은 지나친다
        await session.fileRequested(path: "/Users/dj/Music/20.flac", playerModel: "CDJ-2000nexus", generation: generation - 1)
        #expect(conversions.withLock { $0 } == ["/Users/dj/Music/30.m4a"])
        #expect(swapped.withLock { $0 } == 0)
        #expect(events.withLock { $0.isEmpty })
    }

    @Test func 백그라운드에서_바꾸지_못하면_곡_이름과_이유를_알린다() async throws {
        let fake = Fake()
        let events = Mutex<[LinkBackgroundConversion]>([])
        let session = LinkSession(source: fake.source, converter: LinkAudioConverter { _ throws(LinkProblem) in
            throw .conversionFailed("깨진 파일")
        }, backgroundConversion: { event in events.withLock { $0.append(event) } })
        try await session.connect(rows: [Self.row("20", path: "/Users/dj/Music/20.flac")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        await session.fileRequested(path: "/Users/dj/Music/20.flac", playerModel: "", generation: await session.currentGeneration)
        #expect(events.withLock { $0 } == [.failed(title: "곡 20", .conversionFailed("깨진 파일"))])
        // 실패한 곡은 끌어 놓으면 다시 바꿔 본다
        #expect(await session.mayConvert(contentID: "20"))
    }

    @Test func DJCrate에서_고친_큐는_내어_준_번호로_서버에_보낸다() async throws {
        // #281: 연결한 뒤 고친 큐·루프도 CDJ가 곡을 다시 실으면 보이게 한다. 내어 주지 않은 곡·꺼진 연결은 보내지 않는다
        let fake = Fake()
        let sent = Mutex<[(id: UInt32, cues: [LinkLibrary.Cue])]>([])
        var source = fake.source
        source.updateCues = { id, cues in sent.withLock { $0.append((id, cues)) } }
        let session = LinkSession(source: source)
        let cues = [Cue(id: "1", contentID: "20", kind: 0, inMsec: 1_000, name: "", colorTableIndex: nil),
                    Cue(id: "2", contentID: "20", kind: 2, inMsec: 2_000, name: "", colorTableIndex: nil, outMsec: 4_000)]
        await session.updateCues(contentID: "20", cues: cues)
        try await session.connect(rows: [Self.row("10"), Self.row("20")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        await session.updateCues(contentID: "20", cues: cues)
        await session.updateCues(contentID: "99", cues: cues)
        #expect(sent.withLock { $0.map(\.id) } == [2])
        #expect(sent.withLock { $0.first?.cues } == [LinkLibrary.Cue(positionMs: 1_000, outMs: 0, hotCue: nil, colour: 0),
                                                     LinkLibrary.Cue(positionMs: 2_000, outMs: 4_000, hotCue: "B", colour: 0)])
    }

    @Test func CDJ가_저장한_큐는_rekordbox_곡_ID로_알린다() async throws {
        // #280: CDJ MEMORY로 더한 큐를 DJCrate 큐 초안으로 옮기려고 앱에 알린다. 내어 주지 않은 번호는 버린다
        let fake = Fake()
        let edits = Mutex<[LinkCueEdit]>([])
        let session = LinkSession(source: fake.source, cueEdited: { edit in edits.withLock { $0.append(edit) } })
        try await session.connect(rows: [Self.row("10"), Self.row("20")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        let events = try #require(fake.history.withLock { $0 })
        let memory = LinkCueEdit(contentID: "", deleted: false, kind: 0, inMs: 12_000, outMs: nil, comment: "")
        events(.cue(2, memory))
        events(.cue(99, memory))
        var expected = memory
        expected.contentID = "20"
        #expect(edits.withLock { $0 } == [expected])
    }

    @Test func CDJ가_기록에_넣고_뺀_곡을_rekordbox_곡과_연결_차례로_알린다() async throws {
        let fake = Fake()
        let plays = Mutex<[LinkPlay]>([])
        let session = LinkSession(source: fake.source, played: { play in plays.withLock { $0.append(play) } })
        try await session.connect(rows: [Self.row("10"), Self.row("20")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        let history = try #require(fake.history.withLock { $0 })
        history(.added(2, history: 7))
        history(.added(99, history: 7))
        history(.removed(1, history: 8))
        #expect(plays.withLock { $0 } == [LinkPlay(contentID: "20", linkID: 2, session: 1, history: 7),
                                         LinkPlay(contentID: "10", linkID: 1, session: 1, history: 8, removed: true)])
        // 다시 켜면 차례가 바뀐다
        await session.disconnect()
        try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        let second = try #require(fake.history.withLock { $0 })
        second(.added(1, history: 7))
        #expect(plays.withLock { $0.last } == LinkPlay(contentID: "10", linkID: 1, session: 3, history: 7))
    }

    @Test func 상태의_실은_곡은_내어_준_곡에서_제목을_찾는다() async throws {
        let session = LinkSession(source: Fake().source)
        try await session.connect(rows: [Self.row("10"), Self.row("20")], playlists: PlaylistLayout(), shareRoot: "/share",
                                  peers: [Self.cdj2])
        let status = try #require(await session.status())
        #expect(status.players[2]?.title == "곡 20")
        #expect(status.players[2]?.contentID == "20")
        #expect(status.players[1]?.contentID == nil)
        #expect(status.players[2]?.isPlaying == true)
        #expect(status.players[1]?.title == nil)
    }

    @Test func 끄면_서버를_내리고_다시_싣지_않는다() async throws {
        let fake = Fake()
        let session = LinkSession(source: fake.source)
        try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        await session.disconnect()
        await session.disconnect()
        #expect(fake.stopped.withLock { $0 } == 1)
        #expect(await session.status() == nil)
        await #expect(throws: LinkProblem.notConnected) { try await session.load(contentID: "10", player: 2) }
    }

    @Test func 켜는_도중에_끄면_띄운_서버를_바로_내리고_켜지지_않는다() async throws {
        let fake = Fake()
        fake.holdsStart.withLock { $0 = true }
        let session = LinkSession(source: fake.source)
        let connecting = Task {
            try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        }
        // 띄우기가 멈출 때까지 기다린다(안전망 300초, TEST-32)
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !fake.isHolding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(fake.isHolding)
        // 끄기는 켜기 뒤에 줄을 선다. 들어온 것을 본 뒤 띄우기를 풀어 준다
        let disconnecting = Task { await session.disconnect() }
        while await session.currentGeneration < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        fake.releaseStart()
        await #expect(throws: LinkProblem.cancelled) { try await connecting.value }
        await disconnecting.value
        // 띄운 서버는 켜기가 바로 내린다. 끄기는 이미 내려간 서버를 다시 내리지 않는다
        #expect(fake.started.withLock { $0.count } == 1)
        #expect(fake.stopped.withLock { $0 } == 1)
        #expect(!(await session.isConnected))
    }

    @Test func rekordbox_확인을_기다리는_사이_끄면_서버를_띄우지_않는다() async throws {
        let fake = Fake()
        fake.holdsRekordboxCheck.withLock { $0 = true }
        let session = LinkSession(source: fake.source)
        let connecting = Task {
            try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !fake.isChecking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(fake.isChecking)
        // 끄기는 줄 서서 기다린다. 확인을 풀어 준 뒤 둘 다 끝난다
        let disconnecting = Task { await session.disconnect() }
        while await session.currentGeneration < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        fake.checkGate.signal()
        await #expect(throws: LinkProblem.cancelled) { try await connecting.value }
        await disconnecting.value
        #expect(fake.started.withLock { $0.isEmpty })
        #expect(!(await session.isConnected))
    }

    @Test func 끈_뒤에_앞_켜기가_실패해도_알릴_실패가_아니다() async throws {
        let fake = Fake()
        fake.holdsStart.withLock { $0 = true }
        // 앞 켜기의 띄우기가 포트 충돌로 실패하는 경우
        let failing = LinkServerSource(
            start: { library, root, peer, history throws(LinkProblem) in
                try await fake.source.start(library, root, peer, history)
                throw .portInUse("UDP 50000")
            },
            stop: fake.source.stop, status: fake.source.status, load: fake.source.load,
            isRekordboxRunning: fake.source.isRekordboxRunning)
        let failingSession = LinkSession(source: failing)
        let connecting = Task {
            try await failingSession.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share",
                                             peers: [Self.cdj2])
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !fake.isHolding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let disconnecting = Task { await failingSession.disconnect() }
        while await failingSession.currentGeneration < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        fake.releaseStart()
        await #expect(throws: LinkProblem.cancelled) { try await connecting.value }
        await disconnecting.value
        #expect(!(await failingSession.isConnected))
    }

    @Test func 켜기_끄기_켜기가_겹쳐도_서버는_마지막_켜기_하나만_남는다() async throws {
        let fake = Fake()
        fake.holdsStart.withLock { $0 = true }
        let session = LinkSession(source: fake.source)
        let first = Task {
            try await session.connect(rows: [Self.row("10")], playlists: PlaylistLayout(), shareRoot: "/share", peers: [Self.cdj2])
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !fake.isHolding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        fake.holdsStart.withLock { $0 = false }
        let off = Task { await session.disconnect() }
        // 끄기가 먼저 차례를 받은 뒤에 두 번째 켜기를 띄운다
        while await session.currentGeneration < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let second = Task {
            try await session.connect(rows: [Self.row("10"), Self.row("20")], playlists: PlaylistLayout(), shareRoot: "/share",
                                      peers: [Self.cdj2])
        }
        while await session.currentGeneration < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        // 줄 선 끄기·두 번째 켜기는 첫 켜기가 끝날 때까지 서버에 손대지 않는다
        #expect(fake.started.withLock { $0.isEmpty })
        fake.releaseStart()
        await #expect(throws: LinkProblem.cancelled) { try await first.value }
        await off.value
        #expect(try await second.value == 2)
        #expect(fake.started.withLock { $0.map(\.library.tracks.count) } == [1, 2])
        #expect(fake.stopped.withLock { $0 } == 1)
        #expect(await session.isConnected)
    }
}
