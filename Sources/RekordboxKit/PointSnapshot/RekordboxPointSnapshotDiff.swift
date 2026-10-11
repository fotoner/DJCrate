import DJCDomain
import Foundation

/// 시점 스냅샷과 지금 라이브러리의 비교(#225). 두 DB는 임시 폴더에 복사한 사본으로 읽는다(라이브 DB·스냅샷 폴더에 읽기 곁 파일을 남기지 않게).
/// 값·문구는 DJCDomain `RekordboxPointSnapshotDiff`.
extension RekordboxPointSnapshotDiff {
    // MARK: - 비교

    /// 스냅샷과 지금 라이브러리(`database`·share)를 견준다. 대상은 부르는 쪽이 적는다. 읽기만 한다.
    public static func compare(_ entry: RekordboxPointSnapshot.Entry, database: URL, shareRoot: URL?,
                               guard writeGuard: RekordboxWriteGuard = .system) throws -> RekordboxPointSnapshotDiff {
        let share = try RekordboxPointSnapshot.resolvedShare(database, shareRoot: shareRoot, guard: writeGuard)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "djc-point-diff-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let then = scratch.appending(path: "then.db"), now = scratch.appending(path: "now.db")
        try fm.copyItem(at: entry.url.appending(path: "master.db"), to: then)
        try fm.copyItem(at: database, to: now)
        let old = try RekordboxLibrary.load(snapshot: then), current = try RekordboxLibrary.load(snapshot: now)
        var diff = RekordboxPointSnapshotDiff()
        diff.compareTracks(old: old, current: current)
        diff.comparePlaylists(old: old.playlists, current: current.playlists)
        diff.compareFiles(snapshotShare: entry.url.appending(path: "share"), currentShare: share, old: old, current: current)
        if let db = try? CipherDatabase(path: now.path, key: RekordboxKey.derive()) {
            defer { db.close() }
            diff.currentCloudUpdateCount = (try? RekordboxCompatibility.updateCounters(db))?.cloud
        }
        return diff
    }

    mutating func compareTracks(old: RekordboxLibrary, current: RekordboxLibrary) {
        let before = Dictionary(old.tracks.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.tracks.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        tracksRemoved = current.tracks.filter { before[$0.uuid] == nil }.map(\.title)
        tracksRestored = old.tracks.filter { after[$0.uuid] == nil }.map(\.title)
        addedOrGoneUUIDs = Set(current.tracks.filter { before[$0.uuid] == nil }.map(\.uuid))
            .union(old.tracks.filter { after[$0.uuid] == nil }.map(\.uuid))
        changedTrackUUIDs.formUnion(addedOrGoneUUIDs)
        func cues(_ library: RekordboxLibrary, _ track: Track) -> [String] {
            library.cues(for: track).map { "\($0.kind)|\($0.inMsec)|\($0.outMsec)|\($0.name)|\($0.color ?? -1)|\($0.activeLoop)" }.sorted()
        }
        func tags(_ track: Track) -> [String?] {
            [track.title, track.artist, track.album, track.albumArtist, track.genre, track.composer, track.releaseYear.map(String.init),
             track.trackNumber.map(String.init), track.key, track.comment, String(track.rating), track.colorID, track.imagePath]
        }
        for track in current.tracks {
            guard let then = before[track.uuid] else { continue }
            var changed = false
            if cues(old, then) != cues(current, track) { cuesChanged.append(track.title); changed = true }
            if then.bpm != track.bpm { gridsChanged.append(track.title); gridUUIDs.insert(track.uuid); changed = true }
            if tags(then) != tags(track) { tagsChanged.append(track.title); changed = true }
            if changed { changedTrackUUIDs.insert(track.uuid) }
        }
    }

    mutating func comparePlaylists(old: [RekordboxPlaylist], current: [RekordboxPlaylist]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        playlistsRemoved = current.filter { before[$0.id] == nil }.map(\.name)
        playlistsRestored = old.filter { after[$0.id] == nil }.map(\.name)
        playlistsChanged = current.compactMap { playlist in
            guard let then = before[playlist.id] else { return nil }
            let same = then.name == playlist.name && then.parentID == playlist.parentID && then.seq == playlist.seq
                && then.trackIDs == playlist.trackIDs && then.isFolder == playlist.isFolder
            return same ? nil : playlist.name
        }
    }

    /// 분석·앨범아트 파일을 경로·크기·수정 시각으로 견준다. 분석 파일이 다른 곡은 그리드·분석이 바뀌는 곡에 더한다.
    mutating func compareFiles(snapshotShare: URL, currentShare: URL, old: RekordboxLibrary, current: RekordboxLibrary) {
        // 분석 파일 폴더(`/PIONEER/USBANLZ/…/`) → 곡
        var owners: [String: Track] = [:]
        // 지금 곡의 제목을 먼저(바뀐 제목으로 보인다)
        for track in current.tracks + old.tracks {
            guard let path = track.analysisDataPath, !path.isEmpty else { continue }
            let folder = String(path.drop { $0 == "/" }).split(separator: "/").dropLast().joined(separator: "/")
            owners[folder] = owners[folder] ?? track
        }
        for (folder, keyPath) in [("PIONEER/USBANLZ", \RekordboxPointSnapshotDiff.analysisFiles), ("PIONEER/Artwork", \.artworkFiles)] {
            let then = RekordboxPointSnapshot.fileStamps(snapshotShare.appending(path: folder))
            let now = RekordboxPointSnapshot.fileStamps(currentShare.appending(path: folder))
            var counts = FileCounts()
            var touched: [String] = []
            for (path, stamp) in now {
                if let old = then[path] { if old != stamp { counts.changed += 1; touched.append(path) } } else { counts.removed += 1; touched.append(path) }
            }
            for path in then.keys where now[path] == nil { counts.restored += 1; touched.append(path) }
            self[keyPath: keyPath] = counts
            guard folder == "PIONEER/USBANLZ" else { continue }
            for path in touched {
                let owner = (folder + "/" + path).split(separator: "/").dropLast().joined(separator: "/")
                guard let track = owners[owner] else { continue }
                changedTrackUUIDs.insert(track.uuid)
                // 빠지거나 돌아오는 곡은 그 묶음에 이미 있다
                if !addedOrGoneUUIDs.contains(track.uuid), gridUUIDs.insert(track.uuid).inserted { gridsChanged.append(track.title) }
            }
        }
    }
}
