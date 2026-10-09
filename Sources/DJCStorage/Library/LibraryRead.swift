import DJCDomain
import Foundation
import RekordboxKit

/// 사본 컬렉션과 초안을 조회한다. SQL 연결·음원·초안에는 쓰지 않는다.
public struct LibraryRead {
    private let library: RekordboxLibrary
    private let tracks: [Track]
    private let byID: [String: Track]
    private let home: URL
    private let shareRoot: URL
    private let commentRule: (any CommentRule)?
    private let gains: [String: Double]

    public init(snapshot: URL, home: URL = DJCPaths.userData, shareRoot: URL? = nil, commentPreset: CommentPreset = .none) throws {
        let snapshot = try Self.resolve(database: snapshot)
        library = try RekordboxLibrary.load(snapshot: snapshot)
        tracks = library.tracks.sorted { $0.id < $1.id }
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.commentRule = commentPreset.rule
        self.home = home
        self.shareRoot = shareRoot ?? snapshot.deletingLastPathComponent().appending(path: "share")
        gains = GainDraftStore.all(url: home.appending(path: "gain-drafts.json"))
    }

    /// 명시한 사본 또는 기존 최신 스냅샷만 사용한다. 라이브 경로·링크를 DB로 열지 않는다.
    public static func resolve(database: URL?, snapshots: URL = LibrarySnapshot.defaultDirectory,
                               liveDatabase: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/master.db")) throws -> URL {
        let candidate = try database ?? LibrarySnapshot.latest(in: snapshots)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let live = liveDatabase.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        // 끊어진 링크는 풀리지 않으므로 저장된 대상 경로도 확인한다.
        let destination = try? fm.destinationOfSymbolicLink(atPath: candidate.path)
        let linked = destination.map {
            URL(filePath: $0, relativeTo: candidate.deletingLastPathComponent())
                .resolvingSymlinksInPath().standardizedFileURL
        }
        let source = try? fm.attributesOfItem(atPath: live.path)
        let target = try? fm.attributesOfItem(atPath: resolved.path)
        let sameFile = source?[.systemNumber] as? UInt64 == target?[.systemNumber] as? UInt64
            && source?[.systemFileNumber] as? UInt64 == target?[.systemFileNumber] as? UInt64 && source != nil && target != nil
        guard resolved != live, linked != live, !sameFile else {
            throw ReadFailure("live_database", String(ui: "라이브 master.db는 열 수 없습니다. djc snapshot으로 사본을 만든 뒤 읽으세요"))
        }
        return candidate
    }

    public func search(query: String, bpm: ClosedRange<Double>? = nil, key: String? = nil,
                       playlistID: String? = nil, filter: LibraryFilter = .all) throws -> TrackList {
        guard !filter.requiresCommentRule || commentRule != nil else {
            throw ReadFailure("invalid_arguments", String(ui: "코멘트 규칙 필터는 --comment-preset anisong을 지정한 뒤 쓰세요"))
        }
        let allowed = try playlistID.map { Set(try playlistTracks(id: $0).map(\.id)) }
        let needle = query.lowercased()
        // 파일 확인은 이 필터를 고를 때만 한다(곡마다 파일 시스템에 묻는다).
        let missing = filter == .missingFile
            ? MissingFiles.scan(tracks, exists: { FileManager.default.fileExists(atPath: $0) }).trackIDs : []
        let result = tracks.filter { track in
            let encrypted = track.title.hasPrefix("$A7:")
            let haystack = [encrypted ? "" : track.title, encrypted ? "" : (track.artist ?? ""), track.comment, track.genre ?? ""]
                .joined(separator: "\u{1F}").lowercased()
            guard needle.isEmpty || haystack.contains(needle),
                  bpm.map({ range in track.bpm.map(range.contains) ?? false }) ?? true,
                  key.map({ track.key?.caseInsensitiveCompare($0) == .orderedSame }) ?? true,
                  allowed?.contains(track.id) ?? true else { return false }
            return filter.includes(track: track, comment: commentRule?.evaluate(track.comment),
                                   hasCues: !library.cues(for: track).isEmpty, playCount: library.playCounts[track.id, default: 0],
                                   tempoChanges: filter == .tempoChange ? grid(for: track).tempoChanges : [],
                                   fileMissing: missing.contains(track.id))
        }
        return TrackList(tracks: result.map(TrackRecord.init))
    }

    /// rekordbox 곡 색 목록(읽지 못했으면 rekordbox 기본 여덟 색)
    public var colors: [TrackColor] { library.colors.isEmpty ? TrackColor.rekordboxDefaults : library.colors }

    /// 곡이 살아 있는 재생 목록(폴더 제외)에 들었는지. 평점·곡 색 쓰기를 확인한 범위를 가른다(`TagWriteScope`).
    public func isInPlaylist(id: String) -> Bool {
        library.playlists.contains { !$0.isFolder && $0.trackIDs.contains(id) }
    }

    /// 초안을 시작할 때 쓰는 원본. 이미 열린 스냅샷에서만 읽는다.
    public func draftSource(id: String) throws -> (track: Track, cues: [Cue]) {
        guard let track = byID[id] else { throw ReadFailure("not_found", String(ui: "곡을 찾지 못했습니다. search로 ContentID를 확인하세요")) }
        return (track, library.cues(for: track))
    }

    public func track(id: String) throws -> TrackInfo {
        guard let track = byID[id] else { throw ReadFailure("not_found", String(ui: "곡을 찾지 못했습니다. search로 ContentID를 확인하세요")) }
        let gain = library.autoGains[id].map {
            GainRecord(linear: $0.gain, decibels: $0.gainDB, peak: $0.peak.isFinite ? $0.peak : nil)
        }
        return TrackInfo(track: TrackRecord(track), cues: library.cues(for: track).sorted {
            ($0.inMsec, $0.id) < ($1.inMsec, $1.id)
        }.map(CueRecord.init), grid: grid(for: track), gain: gain,
        playlists: sortedPlaylists.filter { !$0.isFolder && $0.trackIDs.contains(id) }.map { record($0, tree: false) },
        drafts: draftState(uuid: track.uuid))
    }

    public func playlists(tree: Bool) -> PlaylistList {
        PlaylistList(playlists: sortedPlaylists.filter { !tree || $0.parentID == "root" }.map { record($0, tree: tree) })
    }

    public func duplicates() -> DuplicateList {
        Self.duplicates(in: library)
    }

    public static func duplicates(in library: RekordboxLibrary) -> DuplicateList { LibraryRecords.duplicates(in: library) }

    public func playlist(id: String) throws -> PlaylistContents {
        guard let playlist = library.playlists.first(where: { $0.id == id }) else { throw missingPlaylist() }
        return PlaylistContents(playlist: record(playlist, tree: false), tracks: try playlistTracks(id: id).map(TrackRecord.init))
    }

    public func histories() -> HistoryList {
        HistoryList(histories: library.histories.map(historyRecord))
    }

    public func history(id: String) throws -> HistoryContents {
        guard let history = library.histories.first(where: { $0.id == id }) else {
            throw ReadFailure("not_found", String(ui: "재생 기록을 찾지 못했습니다. histories로 ID를 확인하세요"))
        }
        return HistoryContents(history: historyRecord(history), entries: history.entries.compactMap { entry in
            byID[entry.contentID].map { HistoryEntry(id: entry.id, trackNumber: entry.trackNumber, track: TrackRecord($0)) }
        })
    }

    private func historyRecord(_ history: RekordboxHistory) -> HistoryRecord {
        HistoryRecord(id: history.id, name: history.name, dateCreated: history.dateCreated,
                      trackCount: history.entries.lazy.filter { byID[$0.contentID] != nil }.count)
    }

    public func drafts() -> DraftList {
        let uuids = CueDraftStore.uuids(directory: home.appending(path: "cue-drafts"))
            .union(GridDraftStore.uuids(directory: home.appending(path: "grid-drafts")))
            .union(TagDraftStore.uuids(directory: home.appending(path: "tag-drafts"))).union(gains.keys)
            .union(ArtworkDraftStore.uuids(directory: home.appending(path: ArtworkDraftStore.folderName)))
        let byUUID = Dictionary(tracks.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return DraftList(drafts: uuids.sorted().compactMap { uuid in
            let state = draftState(uuid: uuid)
            guard !state.kinds.isEmpty else { return nil }
            return DraftRecord(trackUUID: uuid, contentID: byUUID[uuid]?.id, title: byUUID[uuid]?.title, kinds: state.kinds)
        })
    }

    public func paths(query: String) -> PathList {
        PathList(paths: tracks.filter { $0.title.contains(query) && !$0.isStreaming }.map(\.folderPath))
    }

    /// 제목에 검색어가 든 곡의 파일 경로를 라이브러리(DB) 순서로(텍스트 `djc path`, JSON은 `paths`의 ID 순서)
    public func titlePaths(query: String) -> [String] {
        library.tracks.filter { $0.title.contains(query) && !$0.isStreaming }.map(\.folderPath)
    }

    /// 라이브러리 현황(`checkFiles`면 음원 파일이 있는지도 센다). 텍스트는 `render()`, JSON은 `Report(_:)`
    public func libraryReport(checkFiles: Bool) -> LibraryReport {
        LibraryReport(library: library, checkFiles: checkFiles, commentRule: commentRule)
    }

    public func report(checkFiles: Bool) -> Report { Report(libraryReport(checkFiles: checkFiles)) }

    public static func parse(comment: String) -> ParsedComment {
        let rule = AnisongCommentRule()
        let parsed = rule.parse(comment).map { value in
            ParsedComment.Parsed(prefix: value.prefix.rawValue, workRef: value.workRef, workName: value.workName,
                                 season: value.season, seasonStyle: value.seasonStyle.map {
                switch $0 { case .parenthesized: "parenthesized"; case .plain: "plain"; case .season: "season" }
            }, abbreviations: value.abbreviations, usages: value.usages.map { .init(kind: $0.kind.rawValue, numbers: $0.numbers) },
                                 episodes: value.episodes, isCharacterSong: value.isCharacterSong, isTVSize: value.isTVSize,
                                 variants: value.variants, isFormerAffiliation: value.isFormerAffiliation,
                                 airingYear: value.tail.airingYear, airingQuarter: value.tail.airingQuarter,
                                 movieYear: value.tail.movieYear, boomboxVolumes: value.tail.boomboxVolumes)
        }
        return ParsedComment(classification: rule.evaluate(comment).classification, parsed: parsed)
    }

    public static func compatibility(snapshot: URL, version: String?) throws -> Compatibility {
        let snapshot = try resolve(database: snapshot)
        try RekordboxCompatibility.checkApp(version: version)
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        try RekordboxCompatibility.checkSchema(db)
        let counters = try RekordboxCompatibility.updateCounters(db)
        if let local = counters.local { try RekordboxCompatibility.checkCounters(local: local, cloud: counters.cloud) }
        return Compatibility(appVersion: version, verifiedAppVersions: RekordboxCompatibility.verifiedAppVersions.sorted(),
                             databaseVersion: RekordboxCompatibility.databaseVersion,
                             localUpdateCount: counters.local, cloudUpdateCount: counters.cloud)
    }

    private func grid(for track: Track) -> GridRecord {
        guard let url = RekordboxShare.analysisURL(track.analysisDataPath, root: shareRoot),
              let grid = try? BeatGrid.load(anlz: url), !grid.beats.isEmpty else {
            return GridRecord(status: "unavailable", beatCount: 0, segments: [], tempoChanges: [])
        }
        return GridRecord(status: "available", beatCount: grid.beats.count,
                          segments: GridDraft.segments(from: grid), tempoChanges: grid.tempoChanges)
    }

    private func draftState(uuid: String) -> DraftState {
        // 외부 DB의 UUID를 경로 조각으로 쓸 때 초안 폴더 밖을 읽지 않는다.
        guard !uuid.isEmpty, !uuid.contains("/"), uuid != ".", uuid != ".." else {
            return DraftState(cue: false, grid: false, gain: gains[uuid] != nil, tag: false)
        }
        var state = DraftState(cue: CueDraftStore.load(trackUUID: uuid, directory: home.appending(path: "cue-drafts"))?.hasChanges == true,
                               grid: GridDraftStore.load(trackUUID: uuid, directory: home.appending(path: "grid-drafts"))?.hasChanges == true,
                               gain: gains[uuid] != nil,
                               tag: TagDraftStore.load(trackUUID: uuid, directory: home.appending(path: "tag-drafts"))?.hasChanges == true)
        state.artwork = (try? ArtworkDraftStore.load(trackUUID: uuid, directory: home.appending(path: ArtworkDraftStore.folderName))) != nil
        return state
    }

    private var sortedPlaylists: [RekordboxPlaylist] {
        library.playlists.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }
    }

    private func missingPlaylist() -> ReadFailure {
        ReadFailure("not_found", String(ui: "재생 목록을 찾지 못했습니다. playlists로 ID를 확인하세요"))
    }

    private func playlistTracks(id: String, visited: Set<String> = []) throws -> [Track] {
        guard let playlist = library.playlists.first(where: { $0.id == id }) else { throw missingPlaylist() }
        guard !visited.contains(id) else { return [] }
        if !playlist.isFolder { return playlist.trackIDs.compactMap { byID[$0] } }
        var seen = Set<String>()
        return try sortedPlaylists.filter { $0.parentID == id }.flatMap {
            try playlistTracks(id: $0.id, visited: visited.union([id]))
        }.filter { seen.insert($0.id).inserted }
    }

    private func record(_ playlist: RekordboxPlaylist, tree: Bool, visited: Set<String> = []) -> PlaylistRecord {
        let children = tree && playlist.isFolder && !visited.contains(playlist.id)
            ? sortedPlaylists.filter { $0.parentID == playlist.id }.map { record($0, tree: true, visited: visited.union([playlist.id])) } : nil
        return PlaylistRecord(id: playlist.id, name: playlist.name, parentID: playlist.parentID, sequence: playlist.seq,
                              isFolder: playlist.isFolder, trackCount: (try? playlistTracks(id: playlist.id).count) ?? 0, children: children)
    }
}
