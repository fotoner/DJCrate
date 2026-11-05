internal import DJLinkExport
internal import DJLinkExportDBServer
internal import DJLinkExportModel
internal import DJLinkExportProtocol
internal import DJLinkKit
import Foundation

/// CDJ에 내어 줄 곡 하나(#273). DJLinkExport 타입을 밖에 내지 않으려고 쓰는 값만 옮긴다.
public struct LinkExportTrack: Equatable, Sendable {
    /// CDJ가 곡을 가리키는 번호(싣기 명령에 쓴다). 0은 쓰지 않는다
    public var id: UInt32
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    /// 조성 이름(예: "Am", "8A")
    public var key: String
    public var bpmX100: UInt32
    public var lengthSeconds: UInt32
    /// 음원의 절대 경로
    public var path: String
    /// 공유 뿌리(`shareRoot`) 아래 분석 파일(.DAT) 상대 경로. 없으면 빈 문자열(파형·그리드 없이 실린다)
    public var analysisPath: String
    /// 공유 뿌리 아래 앨범아트 상대 경로(rekordbox `ImagePath`). 없으면 빈 문자열(그림 없이 보인다)
    public var artworkPath: String
    /// rekordbox 파일 형식 번호(MP3 1, WAV 11). CDJ가 이 값으로 디코더를 고른다
    public var fileType: UInt8
    public var bitrate: UInt32
    public var rating: UInt8
    public var comment: String
    public var cues: [LinkExportCue]

    public init(id: UInt32, title: String, artist: String, album: String, genre: String, key: String, bpmX100: UInt32,
                lengthSeconds: UInt32, path: String, analysisPath: String, artworkPath: String = "", fileType: UInt8, bitrate: UInt32,
                rating: UInt8, comment: String, cues: [LinkExportCue]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.key = key
        self.bpmX100 = bpmX100
        self.lengthSeconds = lengthSeconds
        self.path = path
        self.analysisPath = analysisPath
        self.artworkPath = artworkPath
        self.fileType = fileType
        self.bitrate = bitrate
        self.rating = rating
        self.comment = comment
        self.cues = cues
    }
}

/// 메모리 큐·핫 큐 하나. 끝(`outMs`)이 시작보다 뒤면 루프다
public struct LinkExportCue: Equatable, Sendable {
    public var positionMs: UInt32
    public var outMs: UInt32
    /// 핫 큐 글자(A~H). nil이면 메모리 큐
    public var hotCue: Character?
    /// rekordbox 큐 색 번호(0은 색 없음)
    public var colour: UInt8

    public init(positionMs: UInt32, outMs: UInt32, hotCue: Character?, colour: UInt8) {
        self.positionMs = positionMs
        self.outMs = outMs
        self.hotCue = hotCue
        self.colour = colour
    }
}

/// 재생 목록·폴더 하나. 부모는 이 목록 배열 안의 순번이다(nil이면 맨 위)
public struct LinkExportPlaylist: Equatable, Sendable {
    public var name: String
    public var parent: Int?
    public var isFolder: Bool
    /// 곡 번호(`LinkExportTrack.id`) 순서대로, 겹쳐도 된다
    public var trackIDs: [UInt32]

    public init(name: String, parent: Int?, isFolder: Bool, trackIDs: [UInt32]) {
        self.name = name
        self.parent = parent
        self.isFolder = isFolder
        self.trackIDs = trackIDs
    }
}

/// 서버의 지금 상태
public struct LinkExportStatus: Equatable, Sendable {
    /// 참여한 장치 번호(rekordbox 범위: 유선 17·18, 무선 41). 참여 전이면 nil
    public var deviceNumber: Int?
    /// 참여하지 못한 이유(번호 충돌 등). 정상이면 nil
    public var down: String?
    /// 라이브러리를 마운트한 장치의 IPv4 주소
    public var mounted: Set<String>
    /// 플레이어가 상태 패킷으로 알린 재생 상태
    public var players: [LinkExportPlayer]

    public init(deviceNumber: Int?, down: String?, mounted: Set<String>, players: [LinkExportPlayer] = []) {
        self.deviceNumber = deviceNumber
        self.down = down
        self.mounted = mounted
        self.players = players
    }
}

/// CDJ가 보낸 재생 기록 편집. CDJ는 곡을 얼마간 튼 뒤 "기록에 넣기"를 보낸다(rekordbox가 LINK HISTORY를 만드는 요청)
public enum LinkExportHistoryEvent: Equatable, Sendable {
    /// 그 곡(서버가 매긴 번호)을 기록 끝에 넣었다. 같은 곡을 잇달아 두 번 넣으면 DJLinkKit이 한 번으로 친다.
    /// `history`는 서버가 연 기록 번호다. CDJ가 기록을 지우면 서버는 새 번호로 다시 연다
    case added(trackID: UInt32, history: UInt32)
    /// 그 곡을 기록에서 뺐다
    case removed(trackID: UInt32, history: UInt32)
    /// CDJ가 그 곡의 큐를 저장하거나 지웠다(#280). 서버는 내어 주는 큐 목록을 이미 바꿨다
    case cue(trackID: UInt32, edit: LinkExportCueEdit)
}

/// CDJ가 보낸 큐 저장·삭제 하나. 시각은 rekordbox 시간축 ms다
public struct LinkExportCueEdit: Equatable, Sendable {
    public var deleted: Bool
    /// rekordbox `djmdCue.Kind` 부호: 0 메모리, 1~3·5~9 핫큐 A~H, 4 활성 메모리 루프
    public var kind: Int
    public var inMs: UInt32
    /// 루프 끝. 루프가 아니면 nil
    public var outMs: UInt32?
    public var comment: String

    public init(deleted: Bool, kind: Int, inMs: UInt32, outMs: UInt32?, comment: String) {
        self.deleted = deleted
        self.kind = kind
        self.inMs = inMs
        self.outMs = outMs
        self.comment = comment
    }
}

/// 플레이어가 NFS로 서버의 파일을 찾거나 처음부터 읽으려 한 것(DJLinkKit `LinkExport.observe_files`).
/// CDJ의 상태 패킷에는 로드 실패 칸이 없어, 못 읽는 형식을 실으려 한 것을 이것으로 안다(#277)
public struct LinkExportFileRequest: Equatable, Sendable {
    /// 이 Mac의 파일 경로(음원·분석 파일·그림)
    public var path: String
    /// 요청한 플레이어 번호. 알림을 듣지 못한 주소면 nil
    public var player: Int?
    /// 그 플레이어의 기종 이름(장치 알림의 이름). 모르면 빈 값
    public var model: String

    public init(path: String, player: Int?, model: String) {
        self.path = path
        self.player = player
        self.model = model
    }
}

/// 플레이어 하나의 재생 상태(상태 패킷)
public struct LinkExportPlayer: Equatable, Sendable {
    public var number: Int
    public var isPlaying: Bool
    public var isMaster: Bool
    public var isSync: Bool
    /// 이 서버가 내어 준 곡을 실었으면 그 번호. 다른 곳(USB 등)의 곡이면 nil
    public var loadedTrackID: UInt32?
    /// 피치를 반영한 BPM×100. 모르면 0
    public var bpmX100: Int

    public init(number: Int, isPlaying: Bool, isMaster: Bool, isSync: Bool, loadedTrackID: UInt32?, bpmX100: Int) {
        self.number = number
        self.isPlaying = isPlaying
        self.isMaster = isMaster
        self.isSync = isSync
        self.loadedTrackID = loadedTrackID
        self.bpmX100 = bpmX100
    }
}

public enum LinkExportError: Error, Equatable, Sendable {
    /// 그 장치로 가는 네트워크 인터페이스를 찾지 못함
    case noInterface(peer: String)
    /// 포트를 열지 못함(rekordbox·nfsd가 쓰는 중 등). DJLinkKit의 설명
    case bind(String)
    /// 아직 네트워크에 참여하지 못함
    case notJoined
    /// 그 플레이어가 네트워크에 없음
    case playerMissing(Int)
    /// 그 플레이어가 아직 라이브러리를 마운트하지 않음
    case notMounted(Int)
    case other(String)
}

/// DJCrate 라이브러리를 rekordbox처럼 CDJ에 내어 주는 서버(DJLinkKit `DJLinkExport`, #273).
/// 알림·상태를 보내고 dbserver·NFS를 연다. 음원·분석 파일은 읽기만 한다. 사용자가 LINK 단추로 막대를 펼쳤을 때만 만든다(LNK-2).
public final class LinkExportServer: Sendable {
    private let export: LinkExport
    private let source: ExportSource

    private init(export: LinkExport, source: ExportSource) {
        self.export = export
        self.source = source
    }

    /// 곡 하나를 다른 파일로 내어 준다(CDJ가 못 읽는 형식을 바꾼 WAV 등). CDJ는 곡 정보의 경로·형식으로 파일을 찾아 읽는다.
    /// NFS는 서버를 띄울 때 연 폴더(`exportRoots`) 안만 찾으므로, 새 파일이 그 밖이면 곡 정보의 경로는 원본 그대로 두고 원본 이름으로 내어 준다
    public func substitute(trackID: UInt32, path: String, fileType: UInt8) async {
        await Task { @DJLinkActor [source, export] in
            // 이미 그 곡 정보를 받은 CDJ는 곡 번호별로 기억한 옛 경로로 찾는다(CDJ-2000nexus 실기). 그 이름으로도 WAV를 내어 준다
            guard let original = source.substitute(trackID: trackID, path: path, fileType: fileType) else { return }
            export.redirect_file(original, to: path)
        }.value
    }

    /// 플레이어의 파일 요청(이 Mac의 경로, 기종 이름)을 보류할지 묻는 함수를 건다. true면 답하지 않아 플레이어가 같은 요청을 다시 보낸다(#277).
    /// DJLinkKit 액터에서 NFS 답을 하는 도중에 부르므로 짧게 끝나야 한다
    public func setFileHold(_ hold: @escaping @Sendable (_ path: String, _ playerModel: String) -> Bool) async {
        await Task { @DJLinkActor [export] in
            // DJLinkKit은 "지금 답할지"를 묻는다(보류의 반대)
            export.gate_files { path, player in !hold(path, player?.name ?? "") }
        }.value
    }

    /// 곡 하나의 큐 목록을 바꾼다(#281). CDJ는 곡을 실을 때 큐를 다시 묻는다. 이미 실린 곡은 다시 실어야 보인다
    public func updateCues(trackID: UInt32, cues: [LinkExportCue]) async {
        await Task { @DJLinkActor [source] in source.replaceCues(trackID: trackID, cues: cues) }.value
    }

    /// 재생 목록 나무를 바꾼다(곡·경로는 그대로). CDJ 탐색 결과는 라이브러리 단위로 기억하므로 새 라이브러리로 바꿔 끼운다
    public func updatePlaylists(_ playlists: [LinkExportPlaylist]) async {
        await Task { @DJLinkActor [source] in source.replacePlaylists(playlists) }.value
    }

    /// 곡과 재생 목록으로 서버를 띄운다. `peer`(보이는 CDJ 하나의 주소)로 가는 인터페이스에 참여한다.
    /// 시험 프로세스에서는 DJLinkKit이 소켓을 만들지 않고 바로 실패한다.
    /// - Parameter onHistory: CDJ가 재생 기록에 곡을 넣거나 뺄 때(rekordbox의 LINK HISTORY). DJLinkKit 액터에서 부른다
    /// - Parameter onFileRequest: 플레이어가 파일을 찾거나 처음부터 읽을 때. DJLinkKit 액터에서 NFS 답을 하는 도중에 부르므로 짧게 끝낸다
    public static func start(tracks: [LinkExportTrack], playlists: [LinkExportPlaylist], shareRoot: String, peer: String,
                             onHistory: @escaping @Sendable (LinkExportHistoryEvent) -> Void = { _ in },
                             onFileRequest: @escaping @Sendable (LinkExportFileRequest) -> Void = { _ in }) async throws -> LinkExportServer {
        try await Task { @DJLinkActor in
            guard let address = try? LinkAddress(peer), let interface = interface(toward: address) else {
                throw LinkExportError.noInterface(peer: peer)
            }
            let source = ExportSource(library: library(tracks: tracks, playlists: playlists), shareRoot: shareRoot,
                                      tracks: tracks, onHistory: onHistory)
            do {
                // 장치 찾기가 방금 들은 알림을 넘겨 CDJ의 다음 알림(약 2초 간격)을 기다리지 않고 바로 참여한다
                let export = try await LinkExport.start(source, interface, seedAnnouncements: RecentAnnouncements.recent())
                export.observe_files { path, player in
                    onFileRequest(LinkExportFileRequest(path: path, player: player.map { Int($0.number) }, model: player?.name ?? ""))
                }
                return LinkExportServer(export: export, source: source)
            } catch let error as LinkError {
                throw LinkExportError.bind(error.description)
            }
        }.value
    }

    /// CDJ와 같은 서브넷에 있는 인터페이스를 먼저 고른다. 경로 조회(`interface_toward`)만 쓰면 169.254/16 경로가
    /// Wi‑Fi(en0)에도 있을 때 유선 대신 Wi‑Fi 주소가 나와, 알림이 CDJ에 닿지 않는다(2026-10-16 실기).
    private static func interface(toward peer: LinkAddress) -> Interface? {
        let all = interfaces()
        let candidates = all.map { (address: $0.address.octets, netmask: $0.netmask.octets) }
        if let index = LinkSubnet.pick(peer: peer.octets, among: candidates) { return all[index] }
        return interface_toward(all, peer)
    }

    /// 서버를 내리고 포트를 모두 돌려준다.
    public func stop() async {
        await Task { @DJLinkActor [export] in await export.stop() }.value
    }

    public func status() async -> LinkExportStatus {
        await Task { @DJLinkActor [export] in
            let snapshot = export.snapshot()
            let number: Int?, down: String?
            switch snapshot.link {
            case let .up(value): (number, down) = (Int(value), nil)
            case let .down(why): (number, down) = (nil, why)
            case .waiting, .joining: (number, down) = (nil, nil)
            }
            let players = snapshot.players.map {
                LinkExportPlayer(number: Int($0.number), isPlaying: $0.playing, isMaster: $0.master, isSync: $0.sync,
                                 loadedTrackID: $0.loaded, bpmX100: Int($0.bpm_x100))
            }
            return LinkExportStatus(deviceNumber: number, down: down, mounted: Set(snapshot.mounted.map(\.description)),
                                    players: players)
        }.value
    }

    /// 플레이어에 곡을 싣게 한다(플레이어가 이 서버의 라이브러리를 마운트한 뒤에만 된다).
    public func load(player: Int, trackID: UInt32) async throws {
        try await Task { @DJLinkActor [export] in
            guard let number = UInt8(exactly: player) else { throw LinkExportError.playerMissing(player) }
            let snapshot = export.snapshot()
            guard case .up = snapshot.link else { throw LinkExportError.notJoined }
            guard let target = snapshot.players.first(where: { $0.number == number }) else {
                throw LinkExportError.playerMissing(player)
            }
            guard snapshot.mounted.contains(target.address) else { throw LinkExportError.notMounted(player) }
            do {
                try await export.load_track(number, trackID)
            } catch {
                throw LinkExportError.other("\(error)")
            }
        }.value
    }

    /// DJLinkExport 열 기반 라이브러리. 분석 파일 경로는 `library_from`이 비워 두므로 따로 채운다
    @DJLinkActor
    static func library(tracks: [LinkExportTrack], playlists: [LinkExportPlaylist]) -> Library {
        let library = library_from(tracks.map { track in
            TestTrack(id: UInt64(track.id), title: track.title, artist: track.artist, album: track.album,
                      comment: track.comment, bpm_x100: track.bpmX100, length_sec: track.lengthSeconds,
                      rating: track.rating, key: track.key, cues: track.cues.map(cue), path: track.path, genre: track.genre,
                      bitrate: track.bitrate, file_type: track.fileType)
        })
        var analysis = StrColumn()
        for track in tracks { analysis.push(track.analysisPath) }
        library.analysis_path = analysis
        // 앨범아트: `library_from`이 비워 둬 CDJ 목록·덱에 그림이 하나도 나오지 않았다(2026-10-16 실기). 서버는 이 경로를 공유 뿌리 아래에서
        // 찾고, 옆의 중간 크기("_m") 파일을 먼저 쓴다
        var artwork = StrColumn()
        for track in tracks { artwork.push(track.artworkPath) }
        library.artwork_path = artwork
        mergeNames(library)
        let rowOfID = Dictionary(tracks.enumerated().map { ($0.element.id, Row($0.offset)) }, uniquingKeysWith: { first, _ in first })
        library.set_playlists(playlistTree(playlists, row: { rowOfID[$0] }))
        return library
    }

    /// 같은 이름의 아티스트·앨범·장르·레이블을 한 번호로 합친다. `library_from`(DJLinkKit의 시험용 만들기)은 곡마다 새 번호를 매겨,
    /// CDJ의 ARTIST·ALBUM·GENRE 목록에 같은 이름이 곡 수만큼 따로 나왔다(2026-10-16 실기). 합친 뒤 정렬·검색 색인을 다시 만든다
    static func mergeNames(_ library: Library) {
        func merge(_ names: Interner, _ column: [UInt32]) -> (Interner, [UInt32]) {
            let merged = mergedIDs(column.map { names.name($0) })
            var interner = Interner()
            for name in merged.names { _ = interner.push(name) }
            return (interner, merged.ids)
        }
        (library.artists, library.artist) = merge(library.artists, library.artist)
        (library.albums, library.album) = merge(library.albums, library.album)
        (library.genres, library.genre) = merge(library.genres, library.genre)
        (library.labels, library.label) = merge(library.labels, library.label)
        // 화면 번호는 0을 비워 두므로 1부터다(`library_from`과 같다)
        library.artist_ids = library.artist.map { $0 + 1 }
        library.album_ids = library.album.map { $0 + 1 }
        library.genre_ids = library.genre.map { $0 + 1 }
        library.label_ids = library.label.map { $0 + 1 }
        library.build_ranks()
        library.build_search()
    }

    /// 곡마다의 이름 → 겹치지 않는 이름 목록과 곡마다의 번호(처음 나온 차례). 이름이 같으면 같은 번호다
    /// 내어 주는 큐 하나(DJLinkExport `Cue`에서 번호를 뺀 값). 시험이 DJLinkKit 없이 규칙을 본다
    struct ServedCue: Equatable {
        var kind: UInt8
        var positionMs: UInt32
        var outMs: UInt32
        var colour: UInt8
    }

    /// CDJ의 큐 저장·삭제를 내어 주는 큐 목록에 옮긴다(#280). 덱·초안과 같은 규칙: 메모리 큐는 ±30ms 안이면 같은 큐,
    /// 핫큐는 그 칸을 바꾸고, 활성 루프(Kind 4)는 하나만 둔다. 시각 차례로 돌려준다
    static func editedCues(_ cues: [ServedCue], deleted: Bool, kind: UInt8, inMs: UInt32, outMs: UInt32) -> [ServedCue] {
        let memory: Set<UInt8> = [0, 4]
        func near(_ cue: ServedCue) -> Bool { memory.contains(cue.kind) && abs(Int64(cue.positionMs) - Int64(inMs)) <= 30 }
        var next = cues
        if memory.contains(kind) {
            if deleted {
                let closest = next.indices.filter { near(next[$0]) }
                    .min { abs(Int64(next[$0].positionMs) - Int64(inMs)) < abs(Int64(next[$1].positionMs) - Int64(inMs)) }
                if let closest { next.remove(at: closest) }
                return next
            }
            guard !next.contains(where: near) else { return cues }
            if kind == 4 { for i in next.indices where next[i].kind == 4 { next[i].kind = 0 } }
            next.append(ServedCue(kind: kind, positionMs: inMs, outMs: outMs > inMs ? outMs : 0, colour: 0))
        } else {
            next.removeAll { $0.kind == kind }
            if !deleted { next.append(ServedCue(kind: kind, positionMs: inMs, outMs: outMs > inMs ? outMs : 0, colour: 0)) }
        }
        return next.sorted { $0.positionMs < $1.positionMs }
    }

    /// 그 행과 같은 음원 경로를 쓰는 행과 그 곡 id(그 행 포함, 차례대로). 바꿔 끼울 때 경로·형식·곡 정보를 모두 이 행들에 적용한다.
    /// 범위 밖이면 빈 값
    static func substitutionTargets(paths: [String], ids: [UInt64], of row: Int) -> [(row: Int, id: String)] {
        guard paths.indices.contains(row) else { return [] }
        return paths.indices.filter { paths[$0] == paths[row] && ids.indices.contains($0) }.map { ($0, String(ids[$0])) }
    }

    /// 서버를 띄울 때 NFS가 여는 폴더: 곡 경로의 앞 세 단계(그 아래에 무엇이 더 있을 때만). DJLinkKit `Files.exports`와 같은 규칙이다.
    /// 띄운 뒤에는 늘지 않는다(#287)
    static func exportRoots(trackPaths: [String]) -> Set<String> {
        Set(trackPaths.compactMap(exportRoot(of:)))
    }

    /// 그 파일을 NFS가 찾을 수 있는지(연 폴더 안인지)
    static func isExported(_ path: String, roots: Set<String>) -> Bool {
        exportRoot(of: path).map(roots.contains) ?? false
    }

    /// 바꿔 끼울 때 곡 정보에 줄 경로. 새 파일을 NFS가 찾을 수 있으면 그 경로, 아니면 원본 경로(서버가 원본 이름으로 새 파일을 내어 준다).
    /// 음악 폴더 밖(외장 디스크 등)의 곡만 내어 주면 `~/Music` 아래 변환본은 연 폴더 밖이다(#287)
    static func servedPath(original: String, substitute: String, roots: Set<String>) -> String {
        isExported(substitute, roots: roots) ? substitute : original
    }

    private static func exportRoot(of path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), components.count > 3 else { return nil }
        return "/" + components.prefix(3).joined(separator: "/")
    }

    static func mergedIDs(_ perTrack: [String]) -> (names: [String], ids: [UInt32]) {
        var names: [String] = []
        var index: [String: UInt32] = [:]
        let ids = perTrack.map { name -> UInt32 in
            if let id = index[name] { return id }
            let id = UInt32(names.count)
            index[name] = id
            names.append(name)
            return id
        }
        return (names, ids)
    }

    /// 재생 목록 나무. 부모는 목록 안 순번, 차례는 목록 순서다(CDJ는 같은 층에서 폴더 먼저, 그 안에서 이 차례로 보인다)
    static func playlistTree(_ playlists: [LinkExportPlaylist], row: (UInt32) -> DJLinkExportModel.Row?) -> Playlists {
        var lists = Playlists()
        for (index, playlist) in playlists.enumerated() {
            lists.ids.append(1000 + UInt64(index))
            lists.names.push(playlist.name)
            lists.parent.append(playlist.parent.flatMap { UInt32(exactly: $0) } ?? NO_ID)
            lists.seq.append(UInt32(index))
            lists.attribute.append(playlist.isFolder ? ATTRIBUTE_FOLDER : 0)
            lists.smart.push("")
            lists.members.append(playlist.trackIDs.compactMap(row))
        }
        return lists
    }

    static func cue(_ cue: LinkExportCue) -> DJLinkExportModel.Cue {
        DJLinkExportModel.Cue(position_ms: cue.positionMs, out_ms: cue.outMs,
            kind: cue.hotCue.flatMap { DJLinkExportModel.Cue.kind_of_letter($0) } ?? DJLinkExportModel.Cue.MEMORY, colour: cue.colour)
    }
}

/// 고정 라이브러리. `StaticSource`와 같되 곡 정보(`details`)에 파일 형식을 실어 준다.
/// 형식이 0이면 서버가 MP3(1)로 보내 WAV가 E-8305로 실리지 않는다(DJLinkKit docs/LINK-EXPORT-HARDWARE.md).
/// 곡 정보를 주면 서버는 목록 둘째 열(아티스트·앨범·장르·레이블)과 비트레이트도 그 값을 쓰므로 함께 채운다.
@DJLinkActor
private final class ExportSource: Source {
    private var snapshot: Library
    private let root: String
    private var details: [String: DJLinkExportModel.TrackDetails]
    private let onHistory: @Sendable (LinkExportHistoryEvent) -> Void
    /// 서버를 띄울 때 NFS가 연 폴더(띄운 곡 경로로 정해진다)
    private let exportRoots: Set<String>
    /// 서버가 연 재생 기록 번호(서버를 띄운 동안 하나)
    private var historySession: UInt32 = 0

    init(library: Library, shareRoot: String, tracks: [LinkExportTrack], onHistory: @escaping @Sendable (LinkExportHistoryEvent) -> Void) {
        snapshot = library
        root = shareRoot
        self.onHistory = onHistory
        exportRoots = LinkExportServer.exportRoots(trackPaths: tracks.map(\.path))
        var details: [String: DJLinkExportModel.TrackDetails] = [:]
        for (row, track) in tracks.enumerated() {
            func id(_ column: [UInt32]) -> UInt32 { column.indices.contains(row) ? column[row] : 0 }
            details[String(track.id)] = DJLinkExportModel.TrackDetails(
                id: String(track.id), title: track.title, artist_id: id(library.artist_ids), artist: track.artist,
                album_id: id(library.album_ids), album: track.album, genre_id: id(library.genre_ids), genre: track.genre,
                label_id: id(library.label_ids), key: track.key, comment: track.comment, rating: track.rating,
                bpm_x100: track.bpmX100, duration_sec: track.lengthSeconds, file_type: UInt32(track.fileType),
                bitrate: track.bitrate, path: track.path)
        }
        self.details = details
    }

    func library() -> Library? { snapshot }

    /// 그 곡의 경로·형식만 바꾼 새 라이브러리로 바꿔 끼운다(CDJ 탐색 기억은 라이브러리 단위라 새로 읽힌다)
    /// 그 곡의 큐 목록을 바꾼다(DJCrate에서 고친 큐, #281)
    func replaceCues(trackID: UInt32, cues: [LinkExportCue]) {
        guard let row = snapshot.row_of_id(UInt64(trackID)) else { return }
        snapshot.set_cues_of(row, cues.enumerated().map { index, cue in
            var served = LinkExportServer.cue(cue)
            served.id = UInt32(index + 1)
            return served
        })
    }

    /// - Returns: 바꾸기 전 원본 경로. 그 곡이 없으면 nil
    @discardableResult
    func substitute(trackID: UInt32, path: String, fileType: UInt8) -> String? {
        let current = snapshot
        guard let row = current.row_of_id(UInt64(trackID)) else { return nil }
        // 같은 음원을 가리키는 곡이 여럿이면 경로·형식·곡 정보를 모두 함께 바꾼다(경로만 바뀐 곡이 WAV를 FLAC 형식으로 내보내지 않게)
        let paths = (0..<current.folder_path.len()).map { current.folder_path.get($0) }
        let targets = LinkExportServer.substitutionTargets(paths: paths, ids: current.ids, of: Int(row))
        let original = paths[Int(row)]
        // 새 파일이 연 폴더 밖이면 CDJ가 그 경로를 찾지 못한다. 그때는 경로를 원본 그대로 두고 형식만 바꾼다(원본 이름으로 새 파일을 내어 준다)
        let served = LinkExportServer.servedPath(original: original, substitute: path, roots: exportRoots)
        let next = current.clone()
        if served != original { next.map_folder_paths { $0 == original ? served : $0 } }
        for target in targets {
            if next.file_type.indices.contains(target.row) { next.file_type[target.row] = fileType }
            guard var detail = details[target.id] else { continue }
            detail.path = served
            detail.file_type = UInt32(fileType)
            details[target.id] = detail
        }
        snapshot = next
        return original
    }

    /// 재생 목록만 바꾼 새 라이브러리로 바꿔 끼운다(재생 기록 나무는 함께 옮긴다)
    func replacePlaylists(_ playlists: [LinkExportPlaylist]) {
        let current = snapshot
        let next = current.clone()
        next.set_playlists(LinkExportServer.playlistTree(playlists, row: { current.row_of_id(UInt64($0)) }))
        snapshot = next
    }
    func share_root() -> String { root }
    func details(_ id: String) -> DJLinkExportModel.TrackDetails? { details[id] }

    // 재생 기록: 서버를 띄운 동안 기록 하나를 열고, CDJ가 넣고 뺀 곡을 앱에 알린다. 기록은 앱이 DJCrate에 보존한다(LNK-13).
    // CDJ의 HISTORY 화면은 내어 준 라이브러리의 기록 목록을 읽으므로 같은 기록을 그 목록에도 넣는다(rekordbox처럼 CDJ에서도 보이게)

    func new_link_history() -> UInt32? {
        historySession += 1
        // 재생 목록 번호와 겹치지 않는 자리
        let id = 0x4C00_0000 + historySession
        var histories = snapshot.histories()
        histories.ids.append(UInt64(id))
        histories.names.push(Self.historyName(Date()))
        histories.parent.append(NO_ID)
        histories.seq.append(UInt32(histories.ids.count))
        histories.attribute.append(0)
        histories.smart.push("")
        histories.members.append([])
        snapshot.set_histories(histories)
        return id
    }

    /// CDJ의 큐 저장·삭제(#280)를 받아 내어 주는 큐를 바꾸고 앱에 알린다. 거절하면 서버가 빈 큐 목록으로 답해
    /// CDJ의 메모리 큐가 모두 사라졌다. 그 밖의 편집(태그·평점·그리드)은 받지 않는다(LNK-11)
    func edit(_ edit: Edit) -> Bool {
        let track: UInt32, cue: PlayerCue, deleted: Bool
        switch edit {
        case let .saveCue(id, saved): (track, cue, deleted) = (id, saved, false)
        case let .deleteCue(id, removed): (track, cue, deleted) = (id, removed, true)
        default: return false
        }
        guard let row = snapshot.row_of_id(UInt64(track)) else { return false }
        let served = snapshot.cues_of(row).map {
            LinkExportServer.ServedCue(kind: $0.kind, positionMs: $0.position_ms, outMs: $0.out_ms, colour: $0.colour)
        }
        let out = cue.out_ms ?? 0
        let next = LinkExportServer.editedCues(served, deleted: deleted, kind: cue.kind, inMs: cue.in_ms, outMs: out)
        snapshot.set_cues_of(row, next.enumerated().map { index, cue in
            DJLinkExportModel.Cue(id: UInt32(index + 1), position_ms: cue.positionMs, out_ms: cue.outMs, kind: cue.kind, colour: cue.colour)
        })
        onHistory(.cue(trackID: track, edit: LinkExportCueEdit(deleted: deleted, kind: Int(cue.kind), inMs: cue.in_ms,
                                                               outMs: out > cue.in_ms ? out : nil, comment: cue.comment)))
        return true
    }

    func add_to_history(_ history: UInt32, _ track: UInt32) -> Bool {
        guard let row = snapshot.row_of_id(UInt64(track)), edit(history: history, { $0.append(row) }) else { return false }
        onHistory(.added(trackID: track, history: history))
        return true
    }

    func remove_from_history(_ history: UInt32, _ track: UInt32) -> Bool {
        guard let row = snapshot.row_of_id(UInt64(track)),
              edit(history: history, { members in members.lastIndex(of: row).map { _ = members.remove(at: $0) } }) else { return false }
        onHistory(.removed(trackID: track, history: history))
        return true
    }

    /// 서버 라이브러리의 그 기록 곡 목록을 고친다. 그 기록이 없으면 false
    private func edit(history: UInt32, _ change: (inout [DJLinkExportModel.Row]) -> Void) -> Bool {
        var histories = snapshot.histories()
        guard let index = histories.index_of(UInt64(history)), histories.members.indices.contains(index) else { return false }
        change(&histories.members[index])
        snapshot.set_histories(histories)
        return true
    }

    /// rekordbox가 짓는 이름 "LINK HISTORY yyyy-MM-dd"(이 Mac의 날짜). 같은 이름의 번호 붙이기는 DJCrate 보존본이 한다
    private static func historyName(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "LINK HISTORY %04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
