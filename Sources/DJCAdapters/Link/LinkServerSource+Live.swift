import DJCApplication
import DJCDomain
import DJCEnvironment
import DJCLink
import Foundation
import RekordboxKit

extension LinkServerSource {
    /// 실제 서버(`LinkExportServer`, DJLinkKit `DJLinkExport`)와 rekordbox 실행 확인. 부를 때마다 서버 자리 하나를 새로 만든다
    public static func live() -> LinkServerSource {
        let slot = LinkServerSlot()
        let directories = [DJCIdentity.dataDirectory, LibrarySnapshot.rekordboxDirectory, URL.libraryDirectory]
            .flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }
        var port = LinkServerSource(
            start: { library, shareRoot, peer, history, beforeBind throws(LinkProblem) in
                try await slot.start(library, shareRoot: shareRoot, peer: peer, protectedDirectories: directories,
                                     history: history, beforeBind: beforeBind)
            },
            stop: { await slot.stop() },
            status: { await slot.status() },
            load: { player, id throws(LinkProblem) in try await slot.load(player: player, trackID: id) },
            isRekordboxRunning: { LibrarySnapshot.isRekordboxRunning() },
            updatePlaylists: { playlists in await slot.updatePlaylists(playlists.map(LinkExportPlaylist.init)) },
            substitute: { id, path, fileType throws(LinkProblem) in try await slot.substitute(id, path: path, fileType: fileType) },
            updateCues: { id, cues in
                await slot.updateCues(id, cues.map { LinkExportCue(positionMs: $0.positionMs, outMs: $0.outMs, hotCue: $0.hotCue, colour: $0.colour) })
            },
            setFileHold: { hold in await slot.setFileHold(hold) })
        port.protectedDirectories = directories
        return port
    }
}

/// 떠 있는 서버 하나. 내리는 중이면 다 내린 뒤에 새로 띄운다(앞 서버가 포트를 쥔 채 새 서버가 바인드하지 않게)
private actor LinkServerSlot {
    private var server: LinkExportServer?
    private var stopping: Task<Void, Never>?

    func start(_ library: LinkLibrary, shareRoot: String, peer: String, protectedDirectories: [String],
               history: @escaping @Sendable (LinkHistoryEvent) -> Void,
               beforeBind: @escaping LinkServerSource.BindingCheck) async throws(LinkProblem) -> LinkPreparedAudio {
        await stop()
        do {
            let started = try await LinkExportServer.start(tracks: library.tracks.map(LinkExportTrack.init),
                                                      playlists: library.playlists.map(LinkExportPlaylist.init),
                                                      shareRoot: shareRoot, peer: peer, beforeBind: beforeBind, onHistory: { event in
                                                          switch event {
                                                          case let .added(id, list): history(.added(id, history: list))
                                                          case let .removed(id, list): history(.removed(id, history: list))
                                                          case let .cue(id, edit):
                                                              history(.cue(id, LinkCueEdit(contentID: "", deleted: edit.deleted, kind: edit.kind,
                                                                                           inMs: edit.inMs, outMs: edit.outMs, comment: edit.comment)))
                                                          }
                                                      }, onFileRequest: { request in
                                                          history(.fileRequested(path: request.path, playerModel: request.model))
                                                      }, cacheDirectory: DJCIdentity.linkAudioDirectory, allowsAudio: {
                                                          LinkLibrary.allowsAudioPath($0, protectedDirectories: protectedDirectories)
                                                      })
            guard let audio = await started.preparedAudio() else {
                await started.stop()
                throw LinkExportError.unsafeFile
            }
            server = started
            return LinkPreparedAudio(audio.paths, retaining: audio.owner)
        } catch let problem as LinkProblem {
            throw problem
        } catch {
            throw Self.problem(error)
        }
    }

    func stop() async {
        if let server {
            self.server = nil
            stopping = Task { await server.stop() }
        }
        await stopping?.value
    }

    func setFileHold(_ hold: @escaping @Sendable (String, String) -> Bool) async {
        await server?.setFileHold(hold)
    }

    func substitute(_ trackID: UInt32, path: String, fileType: UInt8) async throws(LinkProblem) {
        guard let server else { throw .notConnected }
        do { try await server.substitute(trackID: trackID, path: path, fileType: fileType) } catch { throw Self.problem(error) }
    }

    func updatePlaylists(_ playlists: [LinkExportPlaylist]) async {
        await server?.updatePlaylists(playlists)
    }

    func updateCues(_ trackID: UInt32, _ cues: [LinkExportCue]) async {
        await server?.updateCues(trackID: trackID, cues: cues)
    }

    func status() async -> LinkServerStatus? {
        guard let server else { return nil }
        let status = await server.status()
        let players = Dictionary(status.players.map { player in
            (player.number, LinkPlayerState(isPlaying: player.isPlaying, isMaster: player.isMaster, isSync: player.isSync,
                                            loadedTrackID: player.loadedTrackID,
                                            bpm: player.bpmX100 > 0 ? Double(player.bpmX100) / 100 : nil))
        }, uniquingKeysWith: { first, _ in first })
        return LinkServerStatus(deviceNumber: status.deviceNumber, down: status.down, mounted: status.mounted, players: players)
    }

    func load(player: Int, trackID: UInt32) async throws(LinkProblem) {
        guard let server else { throw .notConnected }
        do {
            try await server.load(player: player, trackID: trackID)
        } catch {
            throw Self.problem(error)
        }
    }

    static func problem(_ error: any Error) -> LinkProblem {
        switch error as? LinkExportError {
        case .noInterface: .noInterface
        case .unsafeFile: .unsafeFile
        case let .bind(why): .portInUse(why)
        case .notJoined: .notJoined
        case let .playerMissing(number): .playerMissing(number)
        case let .notMounted(number): .notMounted(number)
        case let .other(why): .failed(why)
        case nil: .failed("\(error)")
        }
    }
}

extension LinkExportTrack {
    init(_ track: LinkLibrary.Track) {
        self.init(id: track.id, title: track.title, artist: track.artist, album: track.album, genre: track.genre, key: track.key,
                  bpmX100: track.bpmX100, lengthSeconds: track.lengthSeconds, path: track.path, analysisPath: track.analysisPath,
                  artworkPath: track.artworkPath,
                  fileType: track.fileType, bitrate: track.bitrateKbps, rating: track.rating, comment: track.comment,
                  cues: track.cues.map { LinkExportCue(positionMs: $0.positionMs, outMs: $0.outMs, hotCue: $0.hotCue, colour: $0.colour) })
    }
}

extension LinkExportPlaylist {
    init(_ playlist: LinkLibrary.Playlist) {
        self.init(name: playlist.name, parent: playlist.parent, isFolder: playlist.isFolder, trackIDs: playlist.trackIDs)
    }
}
