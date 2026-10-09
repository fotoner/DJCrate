import DJCDomain
import DJCEnvironment
import Foundation

/// 쓰기를 확인한 rekordbox·DB 구조에서만 쓴다.
///
/// rekordbox가 업데이트로 DB 구조를 바꾸면 DJCrate가 넣는 행이 rekordbox가 기대하는 모양과 달라질 수 있다.
/// 그래서 새 행을 넣는 표는 칸이 정확히 같아야 하고, 고치거나 읽는 칸은 모두 있어야 한다.
/// 설치된 rekordbox는 확인한 주.부 버전(7.2.x)일 때만 라이브 DB에 쓴다. 설치를 못 찾으면 DB 구조 검사에 맡긴다.
public enum RekordboxCompatibility {
    /// 쓰기를 확인한 rekordbox 주.부 버전
    public static let verifiedAppVersions: Set<String> = ["7.2"]
    /// `djmdProperty.DBVersion`
    public static let databaseVersion = "6000"

    /// 행을 새로 넣는 표: 칸이 정확히 같아야 한다(rekordbox 7.2.18)
    static let exactColumns: [String: Set<String>] = [
        "djmdCue": ["ID", "ContentID", "InMsec", "InFrame", "InMpegFrame", "InMpegAbs", "OutMsec", "OutFrame", "OutMpegFrame",
                    "OutMpegAbs", "Kind", "Color", "ColorTableIndex", "ActiveLoop", "Comment", "BeatLoopSize", "CueMicrosec",
                    "InPointSeekInfo", "OutPointSeekInfo", "ContentUUID", "UUID", "rb_data_status", "rb_local_data_status",
                    "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "contentCue": ["ID", "ContentID", "Cues", "rb_cue_count", "UUID", "rb_data_status", "rb_local_data_status",
                       "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        // 곡 추가(RekordboxTrackWriter)
        "djmdContent": ["ID", "FolderPath", "FileNameL", "FileNameS", "Title", "ArtistID", "AlbumID", "GenreID", "BPM", "Length", "TrackNo",
                        "BitRate", "BitDepth", "Commnt", "FileType", "Rating", "ReleaseYear", "RemixerID", "LabelID", "OrgArtistID", "KeyID",
                        "StockDate", "ColorID", "DJPlayCount", "ImagePath", "MasterDBID", "MasterSongID", "AnalysisDataPath", "SearchStr",
                        "FileSize", "DiscNo", "ComposerID", "Subtitle", "SampleRate", "DisableQuantize", "Analysed", "ReleaseDate",
                        "DateCreated", "ContentLink", "Tag", "ModifiedByRBM", "HotCueAutoLoad", "DeliveryControl", "DeliveryComment",
                        "CueUpdated", "AnalysisUpdated", "TrackInfoUpdated", "Lyricist", "ISRC", "SamplerTrackInfo", "SamplerPlayOffset",
                        "SamplerGain", "VideoAssociate", "LyricStatus", "ServiceID", "OrgFolderPath", "Reserved1", "Reserved2", "Reserved3",
                        "Reserved4", "ExtInfo", "rb_file_id", "DeviceID", "rb_LocalFolderPath", "SrcID", "SrcTitle", "SrcArtistName",
                        "SrcAlbumName", "SrcLength", "UUID", "rb_data_status", "rb_local_data_status", "rb_local_deleted", "rb_local_synced",
                        "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdArtist": ["ID", "Name", "SearchStr", "UUID", "rb_data_status", "rb_local_data_status", "rb_local_deleted", "rb_local_synced",
                       "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdAlbum": ["ID", "Name", "AlbumArtistID", "ImagePath", "Compilation", "SearchStr", "UUID", "rb_data_status",
                      "rb_local_data_status", "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdGenre": ["ID", "Name", "UUID", "rb_data_status", "rb_local_data_status", "rb_local_deleted", "rb_local_synced", "usn",
                      "rb_local_usn", "created_at", "updated_at"],
        // 분석까지 붙인 곡 추가·분석 붙이기(파일 행·오토게인 행을 새로 넣는다)
        "contentFile": ["ID", "ContentID", "Path", "Hash", "Size", "rb_local_path", "rb_insync_hash", "rb_insync_local_usn",
                        "rb_file_hash_dirty", "rb_local_file_status", "rb_in_progress", "rb_process_type", "rb_temp_path", "rb_priority",
                        "rb_file_size_dirty", "UUID", "rb_data_status", "rb_local_data_status", "rb_local_deleted", "rb_local_synced",
                        "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdMixerParam": ["ID", "ContentID", "GainHigh", "GainLow", "PeakHigh", "PeakLow", "UUID", "rb_data_status",
                           "rb_local_data_status", "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        // 재생 목록 쓰기(목록·곡 항목·클라우드 거울 행을 새로 넣는다). 곡 삭제도 곡 항목을 지우고 번호를 당긴다.
        "djmdPlaylist": ["ID", "Seq", "Name", "ImagePath", "Attribute", "ParentID", "SmartList", "UUID", "rb_data_status",
                         "rb_local_data_status", "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdSongPlaylist": ["ID", "PlaylistID", "ContentID", "TrackNo", "UUID", "rb_data_status", "rb_local_data_status",
                             "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdCloudFilterPlaylist": ["ID", "PlaylistUUID", "Seq", "ParentID", "UUID", "rb_data_status", "rb_local_data_status",
                                    "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        // 재생 기록 쓰기(#43, 연·월 폴더·기록·항목 행을 새로 넣는다). 곡 행의 `DJPlayCount`·`TrackInfoUpdated`는 위 `djmdContent` 칸 전체에 있다.
        // 곡 삭제가 읽고 고치는 `djmdSongHistory` 칸은 아래 `requiredColumns`에도 그대로 둔다(막힘 문구가 칸을 하나씩 적는다).
        "djmdHistory": ["ID", "Seq", "Name", "Attribute", "ParentID", "DateCreated", "UUID", "rb_data_status", "rb_local_data_status",
                        "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
        "djmdSongHistory": ["ID", "HistoryID", "ContentID", "TrackNo", "UUID", "rb_data_status", "rb_local_data_status",
                            "rb_local_deleted", "rb_local_synced", "usn", "rb_local_usn", "created_at", "updated_at"],
    ]

    /// 고치거나 읽는 칸: 있어야 한다
    static let requiredColumns: [String: Set<String>] = [
        "agentRegistry": ["registry_id", "int_1"],
        "djmdProperty": ["DBVersion"],
        // 곡의 키: 고를 줄을 찾고(ScaleName, 삭제 표시) 읽는다. 이 표는 고치지 않는다(2026-10-04 키 쓰기).
        "djmdKey": ["ID", "ScaleName", "rb_local_deleted"],
        // 곡 색: 곡 행 `ColorID`가 가리킬 줄이 살아 있는지 보고(ID, 삭제 표시) 색 이름(Commnt)을 읽는다. 이 표는 고치지 않는다(#65, 2026-10-04 묶음 2).
        // 곡 행의 `Rating`·`ColorID`는 `djmdContent` 칸 전체(위)에 들어 있다.
        "djmdColor": ["ID", "Commnt", "rb_local_deleted"],
        // 곡 삭제 때 지우거나 번호를 당기는 표(곡 항목 djmdSongPlaylist는 위에서 칸 전체를 본다). 당기는 행의 상태(rb_data_status)를 고치고
        // 순번 자리의 지운 표시(rb_local_deleted)와 동기화 상태를 읽는다(#196).
        "djmdSongHistory": ["ID", "HistoryID", "ContentID", "TrackNo", "rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"],
        // 곡 삭제·합치기는 이 표가 어느 곡을 가리키는지(ContentID1·ContentID2) 읽어 가리키는 곡을 막는다(#196). 이 표는 고치지 않는다.
        "djmdRecommendLike": ["ContentID1", "ContentID2"],
        // 곡 삭제·합치기는 아직 규칙을 확인하지 않은 표 9개(`RekordboxTrackWriter.unverifiedReferenceTables`)에 그 곡이 들어 있는지 ContentID로 읽어
        // 들어 있으면 막는다(#203). 칸이 없어지면 백업 전에 거절한다. 이 표들은 고치지 않는다.
        "contentActiveCensor": ["ContentID"],
        "djmdActiveCensor": ["ContentID"],
        "djmdCloudExportSongPlaylist": ["ContentID"],
        "djmdSongHotCueBanklist": ["ContentID"],
        "djmdSongMyTag": ["ContentID"],
        "djmdSongRelatedTracks": ["ContentID"],
        "djmdSongRequestList": ["ContentID"],
        "djmdSongSampler": ["ContentID"],
        "djmdSongTagList": ["ContentID"],
    ]

    /// DB 구조와 DB 버전을 확인한다. 다르면 `writeRefused`.
    public static func checkSchema(_ db: CipherDatabase) throws {
        var problems: [String] = []
        for (table, expected) in exactColumns.sorted(by: { $0.key < $1.key }) {
            let columns = try self.columns(of: table, in: db)
            let extra = columns.subtracting(expected).sorted(), missing = expected.subtracting(columns).sorted()
            if !extra.isEmpty { problems.append(String(ui: "\(table)에 모르는 칸(\(extra.joined(separator: ", ")))")) }
            if !missing.isEmpty { problems.append(String(ui: "\(table)에 없는 칸(\(missing.joined(separator: ", ")))")) }
        }
        for (table, expected) in requiredColumns.sorted(by: { $0.key < $1.key }) {
            let missing = expected.subtracting(try columns(of: table, in: db)).sorted()
            if !missing.isEmpty { problems.append(String(ui: "없는 칸 \(missing.map { "\(table).\($0)" }.joined(separator: ", "))")) }
        }
        if problems.isEmpty {
            var versions: [String] = []
            try db.query("SELECT DBVersion FROM djmdProperty") { versions.append($0.string(0) ?? "?") }
            if versions != [databaseVersion] {
                problems.append(String(ui: "DB 버전 \(versions.joined(separator: ", "))(확인한 버전 \(databaseVersion))"))
            }
        }
        guard problems.isEmpty else {
            throw DJCError.writeRefused(String(ui: "rekordbox DB 구조가 DJCrate가 확인한 모양과 다릅니다: \(problems.joined(separator: "; ")). rekordbox가 업데이트됐다면 DJCrate도 확인이 필요합니다"))
        }
    }

    /// 변경 카운터 두 개(`agentRegistry`의 정수 칸만 읽는다. 인증값이 든 칸은 읽지 않는다).
    /// - local: 이 컴퓨터에서 나눠 준 마지막 번호(`localUpdateCount`)
    /// - cloud: 클라우드 동기화가 본 가장 큰 번호(`lastUpdateCount`, 동기화를 안 쓰면 없거나 0)
    public static func updateCounters(_ db: CipherDatabase) throws -> (local: Int?, cloud: Int?) {
        var local: Int?, cloud: Int?
        try db.query("SELECT registry_id, int_1 FROM agentRegistry WHERE registry_id IN ('localUpdateCount', 'lastUpdateCount')") { row in
            if row.string(0) == "localUpdateCount" { local = row.int(1) } else { cloud = row.int(1) }
        }
        return (local, cloud)
    }

    /// 로컬 카운터가 클라우드 동기화 카운터보다 작으면 쓰지 않는다. rekordbox가 동기화하며 그 번호 밑의 변경을
    /// 되돌렸다는 사례가 있다(조사 2026-09-26). 동기화를 안 쓰면(값 없음·0) 통과.
    public static func checkCounters(local: Int, cloud: Int?) throws {
        guard let cloud, cloud > 0, local < cloud else { return }
        throw DJCError.writeRefused(String(ui: "rekordbox 변경 카운터(\(local))가 클라우드 동기화 카운터(\(cloud))보다 작습니다. rekordbox를 한 번 켜서 동기화를 끝낸 뒤 종료하고 다시 시도하세요"))
    }

    /// 설치된 rekordbox 버전을 확인한다. 못 찾으면(nil) 통과.
    public static func checkApp(version: String?) throws {
        guard let version else { return }
        let parts = version.split(separator: ".")
        let majorMinor = parts.prefix(2).joined(separator: ".")
        guard parts.count >= 2, verifiedAppVersions.contains(majorMinor) else {
            let verified = verifiedAppVersions.sorted().map { "\($0).x" }.joined(separator: ", ")
            throw DJCError.writeRefused(String(ui: "rekordbox \(version)는 DJCrate가 쓰기를 확인하지 않은 버전입니다(확인: \(verified))"))
        }
    }

    /// `/Applications/rekordbox N/rekordbox.app` 중 가장 높은 판의 버전
    public static func installedAppVersion(applications: URL = URL(filePath: "/Applications")) -> String? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        return apps.filter { $0.hasPrefix("rekordbox") }.sorted().reversed().lazy.compactMap { folder -> String? in
            let info = applications.appending(path: folder).appending(path: "rekordbox.app/Contents/Info.plist")
            guard let plist = NSDictionary(contentsOf: info) else { return nil }
            return plist["CFBundleShortVersionString"] as? String
        }.first
    }

    static func columns(of table: String, in db: CipherDatabase) throws -> Set<String> {
        var names: Set<String> = []
        try db.query("PRAGMA table_info(\(table))") { names.insert($0.string(1) ?? "") }
        return names
    }
}

/// 라이브 rekordbox DB에 쓰기 전에 보는 환경. 시험에서는 가짜로 바꾼다.
public struct RekordboxWriteGuard: Sendable {
    public var isLive: @Sendable (URL) -> Bool
    public var isRekordboxRunning: @Sendable () -> Bool
    public var appVersion: @Sendable () -> String?
    private let liveDirectories: [URL]
    /// 시험 프로세스에서 쓰기·복원을 거부할 폴더. 실제 rekordbox 폴더는 늘 들어 있고, 시험은 합성 폴더를 더해 입구마다 막히는지 본다.
    private let protectedInTests: [URL]

    /// 시험에서는 합성 라이브 루트만 주입한다. 환경 변수로 사본을 골라도 실제 라이브 루트는 보호한다.
    public init(isLive: (@Sendable (URL) -> Bool)? = nil, isRekordboxRunning: @escaping @Sendable () -> Bool,
                appVersion: @escaping @Sendable () -> String?, liveDirectories: [URL] = [
                    LibrarySnapshot.rekordboxDirectory,
                    LibrarySnapshot.realRekordboxDirectory
                ], protectedInTests: [URL] = []) {
        self.liveDirectories = liveDirectories
        self.protectedInTests = [LibrarySnapshot.realRekordboxDirectory] + protectedInTests
        self.isLive = isLive ?? { database in
            liveDirectories.contains { RekordboxWriter.isLive(database, liveDatabase: $0.appending(path: "master.db")) }
        }
        self.isRekordboxRunning = isRekordboxRunning
        self.appVersion = appVersion
    }

    public static let system = RekordboxWriteGuard(isRekordboxRunning: LibrarySnapshot.isRekordboxRunning,
                                                   appVersion: { RekordboxCompatibility.installedAppVersion() })

    /// 사본 옆 파일이 라이브 동기화 파일의 링크여도 원본 경계로 판단한다.
    func checkAdjacentFile(_ file: URL, database: URL) throws {
        guard !adjacentFileIsLive(file, database: database) else {
            throw DJCError.writeRefused(String(ui: "사본 DB에 라이브 동기화 파일을 사용할 수 없습니다. 동기화 파일도 실제 사본으로 복사하세요."))
        }
    }

    /// 라이브가 아닌 DB(사본) 옆 파일이 라이브 폴더의 같은 이름 파일과 같은 파일인지(링크). 그 파일을 고치면 라이브가 바뀐다.
    /// 던지지 않아, 그 파일을 고칠 곡 정보 초안만 막고 나머지는 쓰려는 쪽이 쓴다.
    func adjacentFileIsLive(_ file: URL, database: URL) -> Bool {
        liveDirectories.contains { directory in
            Self.sameFile(file, directory.appending(path: file.lastPathComponent))
                && !Self.sameFile(database, directory.appending(path: "master.db"))
        }
    }

    /// DB와 share를 함께 검사하고, 생략된 라이브 share는 같은 라이브러리에서 고른다.
    func checkTargets(_ database: URL, shareRoot: URL?, dryRun: Bool) throws -> URL? {
        let share = try resolveShareRoot(database, shareRoot: shareRoot)
        if isLive(database) { try checkLive(database, dryRun: dryRun) }
        return share
    }

    /// 복원도 같은 대상 경계를 쓰되, 비상 복원의 버전 검사 예외는 유지한다.
    func resolveShareRoot(_ database: URL, shareRoot: URL?) throws -> URL? {
        try refuseProtectedInTests([database, shareRoot])
        let directory = liveDirectories.first { Self.sameFile(database, $0.appending(path: "master.db")) }
        let shareRoot = shareRoot ?? (isLive(database) ? directory?.appending(path: "share") ?? RekordboxShare.directory : nil)
        for directory in liveDirectories {
            if let shareRoot, Self.contains(shareRoot, in: directory.appending(path: "share")),
               !Self.sameFile(database, directory.appending(path: "master.db")) {
                throw DJCError.writeRefused(String(ui: "사본 DB에 라이브 share를 사용할 수 없습니다. share 폴더도 실제 사본으로 복사한 뒤 다시 시도하세요"))
            }
        }
        return shareRoot
    }

    /// 시험 프로세스는 실제 rekordbox 폴더에 쓰거나 되돌리지 않는다. 쓰기·복원 입구가 모두 지나는 `resolveShareRoot`에서
    /// 주입한 `isLive`와 상관없이 막는다(#182: 시험이 실제 라이브러리로 복원해 라이브러리를 덮었다).
    func refuseProtectedInTests(_ targets: [URL?], isTest: Bool = TestProcess.isRunning) throws {
        guard isTest else { return }
        for target in targets.compactMap({ $0 }) where protectedInTests.contains(where: { Self.contains(target, in: $0) }) {
            throw DJCError.writeRefused(String(ui: "시험 중에는 실제 rekordbox 라이브러리에 쓰지 않습니다. DJC_REKORDBOX_DIR로 사본 폴더를 주세요"))
        }
    }

    /// 경로와 device/inode를 함께 본다. 파일이 아직 없는 끊어진 심볼릭 링크도 경로로 막는다.
    static func sameFile(_ candidate: URL, _ reference: URL) -> Bool {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let live = reference.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        if resolved.path == live.path { return true }
        if let destination = try? fm.destinationOfSymbolicLink(atPath: candidate.path),
           URL(filePath: destination, relativeTo: candidate.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardizedFileURL.path == live.path { return true }
        guard let source = try? fm.attributesOfItem(atPath: live.path),
              let target = try? fm.attributesOfItem(atPath: resolved.path),
              let sourceDevice = source[.systemNumber] as? UInt64, let targetDevice = target[.systemNumber] as? UInt64,
              let sourceInode = source[.systemFileNumber] as? UInt64, let targetInode = target[.systemFileNumber] as? UInt64 else { return false }
        return sourceDevice == targetDevice && sourceInode == targetInode
    }

    /// 별칭 폴더 아래 새 경로도 조상을 따라가며 검사해 루트의 하드 링크를 놓치지 않는다.
    static func contains(_ candidate: URL, in root: URL) -> Bool {
        var ancestor = candidate.resolvingSymlinksInPath().standardizedFileURL
        while true {
            if sameFile(ancestor, root) { return true }
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            guard parent.path != ancestor.path else { return false }
            ancestor = parent
        }
    }

    /// 라이브 DB면 rekordbox가 꺼져 있고 WAL이 비었고 확인한 버전이어야 한다.
    func checkLive(_ database: URL, dryRun: Bool) throws {
        guard !dryRun else { throw DJCError.writeRefused(String(ui: "미리 보기는 스냅샷 사본으로만 합니다")) }
        guard !isRekordboxRunning() else {
            throw DJCError.writeRefused(String(ui: "rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 다시 시도하세요"))
        }
        // 하드 링크 별칭 옆에는 원본 WAL이 없을 수 있으므로 원래 라이브 경로도 검사한다.
        let originals = liveDirectories.map { $0.appending(path: "master.db") }.filter { Self.sameFile(database, $0) }
        for source in [database, database.resolvingSymlinksInPath()] + originals {
            let wal = URL(filePath: source.path + "-wal")
            if let size = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? Int, size > 0 {
                throw DJCError.writeRefused(String(ui: "rekordbox가 정상적으로 종료되지 않은 것 같습니다(WAL 파일이 남아 있음). rekordbox를 한 번 켰다가 종료한 뒤 다시 시도하세요"))
            }
        }
        try RekordboxCompatibility.checkApp(version: appVersion())
    }
}
