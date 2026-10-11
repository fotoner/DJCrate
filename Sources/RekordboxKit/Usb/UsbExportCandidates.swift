import CryptoKit
import DJCDomain
import Darwin
import Foundation

/// 로컬 스냅샷 **사본**과 share(읽기만)에서 USB 내보내기 후보·재생 목록을 읽는다.
/// share의 파일은 lstat만 하고 열지 않는다(크기·시각만 본다). 라이브 master.db를 연 연결이면 읽지 않는다.
public enum UsbExportCandidates {
    /// 라이브 master.db. 공개 함수는 늘 이 경로와 비교한다(바꿀 수 있는 인자로 두지 않는다)
    static var liveDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/master.db")
    }

    /// 한 번에 넘기는 자리표시자 수(SQLite 한계보다 넉넉히 작게)
    static let chunkSize = 500

    public static func load(database: CipherDatabase, share: URL, contentIDs: [String]) throws -> [UsbExportCandidate] {
        try load(database: database, share: share, contentIDs: contentIDs, liveDatabase: liveDatabase)
    }

    /// 시험만 라이브 경로를 바꿔 넘긴다.
    static func load(database: CipherDatabase, share: URL, contentIDs: [String], liveDatabase: URL) throws -> [UsbExportCandidate] {
        try refuseLive(database, liveDatabase: liveDatabase)
        var seen: Set<String> = []
        let ids = contentIDs.filter { seen.insert($0).inserted }
        var byID: [String: UsbExportCandidate] = [:]
        var cues: [String: [UsbCueTraits]] = [:]
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[start..<min(start + chunkSize, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try database.query("""
                SELECT c.ID, c.MasterSongID, c.MasterDBID, ar.Name, al.Name, c.FolderPath, c.FileNameL, c.FileType, c.FileSize,
                    c.AnalysisDataPath, c.ImagePath, c.Title, c.Commnt, c.ISRC, c.Subtitle, c.ReleaseDate, c.DateCreated, c.StockDate,
                    c.LabelID, c.RemixerID, c.OrgArtistID, c.Lyricist, c.ColorID, c.Rating, c.SearchStr, al.Compilation
                FROM djmdContent c
                LEFT JOIN djmdArtist ar ON ar.ID = c.ArtistID
                LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
                WHERE c.ID IN (\(marks)) AND c.rb_local_deleted = 0
                """, chunk.map { .text($0) }) { row in
                let candidate = candidate(row, share: share)
                byID[candidate.localContentID] = candidate
            }
            try database.query("""
                SELECT ContentID, Kind, ColorTableIndex, Color, InMsec, OutMsec, ActiveLoop, BeatLoopSize, InMpegFrame
                FROM djmdCue WHERE ContentID IN (\(marks)) AND rb_local_deleted = 0 ORDER BY ContentID, InMsec, ID
                """, chunk.map { .text($0) }) { row in
                guard let id = row.string(0) else { return }
                cues[id, default: []].append(UsbCueTraits(
                    kind: row.int(1) ?? 0, colorTableIndex: row.int(2), color: row.int(3), inMsec: row.int(4) ?? 0,
                    outMsec: row.int(5) ?? 0, activeLoop: row.int(6) ?? 0, beatLoopSize: row.int(7) ?? 0, inMpegFrame: row.int(8) ?? 0))
            }
        }
        return ids.compactMap { id in
            guard var candidate = byID[id] else { return nil }
            candidate.cues = cues[id] ?? []
            return candidate
        }
    }

    /// 목록·폴더 트리. 폴더면 안까지 깊이 우선, 형제는 Seq 순. 뿌리의 부모는 nil(USB 맨 위).
    /// 스마트 목록(Attribute 4 또는 SmartList 규칙이 있음)은 attribute 4로 넘기고 계획기가 막는다.
    public static func playlistTree(database: CipherDatabase, rootIDs: [String]) throws -> [UsbPlaylistInput] {
        try playlistTree(database: database, rootIDs: rootIDs, liveDatabase: liveDatabase)
    }

    static func playlistTree(database: CipherDatabase, rootIDs: [String], liveDatabase: URL) throws -> [UsbPlaylistInput] {
        try refuseLive(database, liveDatabase: liveDatabase)
        struct Row { var id: String; var seq: Int; var name: String; var attribute: Int; var parentID: String }
        var rows: [String: Row] = [:]
        var children: [String: [Row]] = [:]
        try database.query("SELECT ID, Seq, Name, Attribute, ParentID, SmartList FROM djmdPlaylist WHERE rb_local_deleted = 0") { row in
            guard let id = row.string(0) else { return }
            let attribute = row.int(3) ?? 0
            // 기존 재생 목록 읽기와 같은 판정
            let smart = attribute > 1 || !(row.string(5) ?? "").isEmpty
            let item = Row(id: id, seq: row.int(1) ?? 0, name: row.string(2) ?? "", attribute: smart ? 4 : (attribute == 1 ? 1 : 0),
                           parentID: row.string(4) ?? "root")
            rows[id] = item
            children[item.parentID, default: []].append(item)
        }
        for missing in rootIDs where rows[missing] == nil {
            throw UsbError.readFailed(detail: "playlist not found: \(missing)")
        }
        let tracks = try entries(database)
        var result: [UsbPlaylistInput] = []
        var visited: Set<String> = []
        func visit(_ row: Row, parent: String?) {
            guard visited.insert(row.id).inserted else { return }
            result.append(UsbPlaylistInput(localID: row.id, name: row.name, parentLocalID: parent, attribute: row.attribute,
                                           trackLocalIDs: row.attribute == 1 ? [] : tracks[row.id] ?? []))
            guard row.attribute == 1 else { return }
            let sorted = (children[row.id] ?? []).sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }
            for child in sorted { visit(child, parent: row.id) }
        }
        for id in rootIDs { if let row = rows[id] { visit(row, parent: nil) } }
        return result
    }

    /// 목록의 곡(TrackNo 순, 같은 곡이 여러 번 있을 수 있다)
    public static func tracks(ofPlaylist id: String, database: CipherDatabase) throws -> [String] {
        try tracks(ofPlaylist: id, database: database, liveDatabase: liveDatabase)
    }

    static func tracks(ofPlaylist id: String, database: CipherDatabase, liveDatabase: URL) throws -> [String] {
        try refuseLive(database, liveDatabase: liveDatabase)
        var result: [String] = []
        try database.query("""
            SELECT ContentID FROM djmdSongPlaylist WHERE PlaylistID = ? AND rb_local_deleted = 0 ORDER BY TrackNo, ID
            """, [.text(id)]) { row in
            if let content = row.string(0) { result.append(content) }
        }
        return result
    }

    // MARK: - 곡 한 행

    static func candidate(_ row: CipherDatabase.Row, share: URL) -> UsbExportCandidate {
        let folderPath = row.string(5)
        let isStreaming = folderPath.map { !$0.hasPrefix("/") } ?? false
        let audio = isStreaming ? nil : folderPath.flatMap(regularFile)
        let analysis = analysisFiles(share: share, path: row.string(9))
        let artwork = artworkFiles(share: share, imagePath: row.string(10))
        // 아래 칸은 USB 파일 형식에서 빈 값으로만 본 칸이다.
        let metadata = UsbTrackMetadataFlags(
            hasLabel: present(row.string(18)), hasRemixer: present(row.string(19)), hasOriginalArtist: present(row.string(20)),
            hasLyricist: nonEmpty(row.string(21)), hasColor: present(row.string(22)), hasRating: (row.int(23) ?? 0) > 0,
            hasSubtitle: nonEmpty(row.string(14)), hasSearchString: nonEmpty(row.string(24)), isCompilation: (row.int(25) ?? 0) > 0)
        return UsbExportCandidate(
            localContentID: row.string(0) ?? "", masterSongID: row.string(1) ?? "", masterDBID: row.string(2) ?? "",
            artistName: row.string(3), albumName: row.string(4), fileNameL: row.string(6) ?? "", sourcePath: folderPath,
            isStreaming: isStreaming, fileType: row.int(7) ?? 0, fileSize: Int64(row.int(8) ?? 0), actualFileSize: audio?.size,
            analysis: analysis.state, analysisModifiedAt: analysis.modified, artwork: artwork.source,
            artworkPathSetButMissing: artwork.missing, cues: [], metadata: metadata,
            analysisFileBytes: analysis.sizes.isEmpty ? nil : analysis.sizes)
    }

    static func nonEmpty(_ text: String?) -> Bool { !(text ?? "").isEmpty }

    /// ID 칸: 비었거나 "0"이면 없음
    static func present(_ id: String?) -> Bool { nonEmpty(id) && id != "0" }

    // MARK: - 파일

    struct FileInfo { var size: Int64; var modified: Date }

    /// lstat으로 본 일반 파일(링크·폴더·없음은 nil). 파일을 열지 않는다.
    static func regularFile(_ path: String) -> FileInfo? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileInfo(size: Int64(info.st_size), modified: Date(timeIntervalSince1970: modified))
    }

    /// share 기준 경로 → 절대 경로. ".."가 있으면 share 밖이라 nil
    static func sharePath(_ share: URL, _ relative: String) -> String? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return share.path + "/" + parts.joined(separator: "/")
    }

    /// AnalysisDataPath(.DAT)에서 확장자만 바꿔 .EXT·.2EX를 본다.
    static func analysisFiles(share: URL, path: String?) -> (state: UsbAnalysisState, modified: Date?, sizes: [Int64]) {
        guard let path, let dat = sharePath(share, path) else { return (.missing, nil, []) }
        let stem = (dat as NSString).deletingPathExtension
        let files = [dat, stem + ".EXT", stem + ".2EX"].map(regularFile)
        let found = files.compactMap { $0 }
        let modified = found.map(\.modified).max()
        let sizes = found.map(\.size)
        let state: UsbAnalysisState = switch (files[0] != nil, files[1] != nil, files[2] != nil) {
        case (false, _, _): .missing
        case (true, true, true): .complete
        case (true, true, false): .missing2EX
        case (true, false, _): .datOnly
        }
        return (state, modified, sizes)
    }

    /// ImagePath와 같은 폴더의 artwork_s.jpg(작은 것)·artwork_m.jpg(중간). artwork.jpg 자체는 쓰지 않는다.
    static func artworkFiles(share: URL, imagePath: String?) -> (source: UsbArtworkSource?, missing: Bool) {
        guard let imagePath, !imagePath.isEmpty else { return (nil, false) }
        guard let image = sharePath(share, imagePath) else { return (nil, true) }
        let folder = (image as NSString).deletingLastPathComponent
        let smallPath = folder + "/artwork_s.jpg", mediumPath = folder + "/artwork_m.jpg"
        guard let small = regularFile(smallPath), let medium = regularFile(mediumPath) else { return (nil, true) }
        return (UsbArtworkSource(smallPath: smallPath, mediumPath: mediumPath, smallBytes: Int(small.size), mediumBytes: Int(medium.size)),
                false)
    }

    /// 로컬 음원과 USB 파일이 같은 내용인지: 크기가 같고 SHA-256이 같음. 둘 다 읽기만 하고, 링크·폴더·없는 파일은 다르다고 본다.
    public static func sameContent(sourcePath: String, usbFile: URL) -> Bool {
        guard let source = regularFile(sourcePath), let target = regularFile(usbFile.path), source.size == target.size,
              let left = sha256(sourcePath), let right = sha256(usbFile.path)
        else { return false }
        return left == right
    }

    static func sha256(_ path: String) -> SHA256.Digest? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return sha256(reading: handle)
    }

    /// 읽다가 오류가 나면 nil(앞부분만 해시한 값을 내지 않는다 → 같은 내용으로 보지 않는다)
    static func sha256(reading handle: FileHandle) -> SHA256.Digest? {
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize()
    }

    // MARK: - 목록 항목

    static func entries(_ database: CipherDatabase) throws -> [String: [String]] {
        var tracks: [String: [String]] = [:]
        // 기존 재생 목록 읽기와 같은 순서
        try database.query("""
            SELECT PlaylistID, ContentID FROM djmdSongPlaylist WHERE rb_local_deleted = 0 ORDER BY PlaylistID, TrackNo, ID
            """) { row in
            if let playlist = row.string(0), let content = row.string(1) { tracks[playlist, default: []].append(content) }
        }
        return tracks
    }

    // MARK: - 라이브 DB 거부

    /// 연결이 연 파일이 라이브 master.db(링크·같은 inode 포함)면 던진다.
    static func refuseLive(_ database: CipherDatabase, liveDatabase: URL) throws {
        var opened: String?
        try database.query("PRAGMA database_list") { row in
            if row.string(1) == "main" { opened = row.string(2) }
        }
        guard let opened, !opened.isEmpty else { return }
        let live = liveDatabase.path
        let sameName = UsbScratchRoots.realPath(opened).map { $0 == UsbScratchRoots.realPath(live) } ?? false
        var a = stat(), b = stat()
        let sameFile = stat(opened, &a) == 0 && stat(live, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
        if sameName || sameFile || opened == live {
            throw UsbError.writeRefused([UsbBlock(code: "liveDatabase", scope: .volume,
                                                  message: String(ui: "라이브 master.db는 열 수 없습니다. djc snapshot으로 사본을 만든 뒤 읽으세요"))])
        }
    }
}
