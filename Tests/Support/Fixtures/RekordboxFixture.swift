import CommonCrypto
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxKit
import SQLCipher
import Synchronization

/// 테스트용 rekordbox 라이브러리.
///
/// 실제 rekordbox 7.2.18 master.db에서 뽑은 **구조만**(`Resources/rekordbox-7.2.18-schema.sql`, 데이터 없음)으로
/// 같은 키의 암호화 DB를 새로 만들고, 곡·큐·게인 행과 분석 파일을 합성해 넣는다. 실데이터·클라우드 토큰은 없다.
/// 시험이 끝나면 임시 폴더째 지운다.
public final class RekordboxFixture {
    public let root: URL
    public var database: URL { root.appending(path: "master.db") }
    /// 분석 파일 뿌리(`share`). `RekordboxWriter.write(shareRoot:)`에 넘긴다.
    public var shareRoot: URL { root.appending(path: "share") }
    public var backups: URL { root.appending(path: "backups") }
    public var audio: URL { root.appending(path: "audio") }

    /// `parent`: 사본을 둘 폴더. 임시 폴더의 다른 표기(`/tmp`·`/private/tmp`)로 경로 검사를 확인할 때 준다.
    public init(localUpdateCount: Int = 1000, parent: URL = FileManager.default.temporaryDirectory) throws {
        root = parent.appending(path: "djc-fixture-\(UUID().uuidString)")
        for dir in [shareRoot, backups, audio] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // 스키마를 넣은 DB는 프로세스마다 한 번 만들고 복사한다(시험마다 키 유도·스키마 실행을 되풀이하지 않는다).
        try FileManager.default.copyItem(at: try Self.template.get(), to: database)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: database.path)
        if localUpdateCount != Self.templateUpdateCount {
            try execute("UPDATE agentRegistry SET int_1 = ? WHERE registry_id = 'localUpdateCount'", [.int(localUpdateCount)])
        }
    }

    static let templateUpdateCount = 1000

    /// 구조·초기 행만 있는 DB(프로세스에 하나). 제품과 같은 연결(`CipherDatabase`, 문자열 키)로 만든다.
    /// 프로세스가 끝날 때 지운다.
    static let template: Result<URL, Error> = Result {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "djc-fixture-template-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        templateFolder.withLock { $0 = folder }
        atexit { RekordboxFixture.templateFolder.withLock { $0.map { try? FileManager.default.removeItem(at: $0) } } }
        let database = folder.appending(path: "master.db")
        let schema = try String(contentsOf: try TestResources.url("rekordbox-7.2.18-schema.sql"), encoding: .utf8)
        guard FileManager.default.createFile(atPath: database.path, contents: nil) else {
            throw FixtureError("DB를 만들지 못했습니다")
        }
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive(), writable: true)
        defer { db.close() }
        try db.execute("BEGIN")
        try db.execute(schema)
        try db.run("INSERT INTO agentRegistry (registry_id, int_1, created_at, updated_at) VALUES ('localUpdateCount', ?, ?, ?)",
                   [.int(templateUpdateCount), .text(stamp), .text(stamp)])
        try db.run("INSERT INTO djmdProperty (DBID, DBVersion, created_at, updated_at) VALUES ('1', '6000', ?, ?)",
                   [.text(stamp), .text(stamp)])
        try db.execute("COMMIT")
        return database
    }
    static let templateFolder = Mutex<URL?>(nil)

    /// 이 픽스처의 연결이 원시 키로 열지 못해 문자열 키(키 유도)로 연 횟수. 0이 아니면 시험이 다시 느려진다.
    /// 픽스처마다 센다(프로세스 전체로 세면 병렬로 도는 다른 시험의 열기 실패가 섞인다).
    public var passphraseFallbacks: Int { fallbacks.load(ordering: .relaxed) }
    private let fallbacks = Atomic<Int>(0)

    /// 픽스처 연결을 열고, 문자열 키로 다시 열었으면 센다.
    private func connect(writable: Bool) throws -> FixtureConnection {
        let db = try FixtureConnection(path: database.path, writable: writable)
        if db.usedPassphrase { fallbacks.add(1, ordering: .relaxed) }
        return db
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    static let stamp = "2026-01-01 00:00:00.000 +00:00"
    /// 라이브러리 공통값(실제 라이브러리에서는 곡 행마다 같다)
    public static let masterDBID = "2112110951"
    public static let deviceID = "00000000-test-device"

    /// 제품과 같은 연결(문자열 키, 열 때마다 키 유도). 제품 코드에 넘길 때 쓴다. 행 준비·확인은 `session`·`rows`가 빠르다.
    public func open() throws -> CipherDatabase {
        try CipherDatabase(path: database.path, key: RekordboxKey.derive(), writable: true)
    }

    /// 곡 하나를 넣는다(djmdContent + 큐 행 + contentCue JSON + 게인 행).
    @discardableResult
    public func add(_ track: TrackSpec) throws -> TrackSpec {
        try add(tracks: [track])
        return track
    }

    /// 여러 곡을 한 연결·트랜잭션으로 넣는다(곡 수천 개짜리 성능 확인용 라이브러리는 곡마다 열면 느리다).
    public func add(tracks: [TrackSpec]) throws {
        let db = try connect(writable: true)
        try db.run("BEGIN")
        for track in tracks { try Self.insert(track, into: db) }
        try db.run("COMMIT")
    }

    private static func insert(_ track: TrackSpec, into db: FixtureConnection) throws {
        try db.run("""
            INSERT INTO djmdContent (ID, UUID, Title, FileType, BitRate, Analysed, Length, BPM, FolderPath, CueUpdated, AnalysisDataPath,
                AnalysisUpdated, TrackInfoUpdated, MasterDBID, DeviceID, ArtistID, AlbumID, ComposerID, ImagePath,
                rb_data_status, rb_local_deleted, rb_local_usn, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 10, ?, ?)
            """, [.text(track.id), .text(track.uuid), .text(track.title), .int(track.fileType), .int(track.bitRate), .int(track.analysed),
                  .int(track.length), .int(track.bpm100), .text(track.folderPath),
                  track.cueUpdated.map { .text($0) } ?? .null, track.analysisDataPath.map { .text($0) } ?? .null,
                  .text(track.analysisUpdated), .text(track.trackInfoUpdated), .text(Self.masterDBID), .text(Self.deviceID),
                  track.artistID.map { .text($0) } ?? .null, track.albumID.map { .text($0) } ?? .null,
                  track.composerID.map { .text($0) } ?? .null, track.imagePath.map { .text($0) } ?? .null, .int(track.dataStatus),
                  .text(Self.stamp), .text(Self.stamp)])
        for cue in track.cues {
            try db.run("""
                INSERT INTO djmdCue (ID, ContentID, InMsec, InFrame, InMpegFrame, InMpegAbs, OutMsec, OutFrame, OutMpegFrame, OutMpegAbs,
                    Kind, Color, ColorTableIndex, ActiveLoop, Comment, BeatLoopSize, CueMicrosec, InPointSeekInfo, OutPointSeekInfo,
                    ContentUUID, UUID, rb_data_status, rb_local_data_status, rb_local_deleted, rb_local_synced, created_at, updated_at)
                VALUES (?, ?, ?, ?, 0, 0, ?, ?, 0, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?, ?)
                """, [.text(cue.id), .text(track.id), .int(cue.inMsec), .int(cue.inMsec * 150 / 1000), .int(cue.outMsec),
                      .int(max(cue.outMsec, 0) * 150 / 1000), .int(cue.kind), .int(cue.color),
                      cue.colorTableIndex.map { .int($0) } ?? .null, cue.activeLoop.map { .int($0) } ?? .null,
                      cue.comment.map { .text($0) } ?? .null, cue.beatLoopSize.map { .int($0) } ?? .null,
                      cue.cueMicrosec.map { .int($0) } ?? .null, cue.inSeek.map { .text($0) } ?? .null,
                      cue.outSeek.map { .text($0) } ?? .null, .text(track.uuid), .text(cue.uuid),
                      .text(Self.stamp), .text(Self.stamp)])
        }
        if !track.cues.isEmpty {
            let objects = track.cues.map { track.jsonObject(for: $0) }
            try db.run("""
                INSERT INTO contentCue (ID, ContentID, Cues, rb_cue_count, UUID, rb_data_status, rb_local_deleted, rb_local_usn, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, 11, ?, ?)
                """, [.text(track.uuid), .text(track.id), .text(CueJSON.serialize(objects)), .int(objects.count),
                      .text(UUID().uuidString.lowercased()), .int(track.dataStatus), .text(Self.stamp), .text(Self.stamp)])
        }
        if let gain = track.gain {
            try db.run("""
                INSERT INTO djmdMixerParam (ID, ContentID, GainHigh, GainLow, PeakHigh, PeakLow, UUID, rb_data_status, rb_local_deleted,
                    rb_local_usn, created_at, updated_at)
                VALUES (?, ?, ?, ?, 16256, 0, ?, ?, 0, 12, ?, ?)
                """, [.text("mp-\(track.id)"), .text(track.id), .int(gain.high), .int(gain.low),
                      .text(UUID().uuidString.lowercased()), .int(track.dataStatus), .text(Self.stamp), .text(Self.stamp)])
        }
    }

    /// 분석 파일을 share 아래 `AnalysisDataPath` 자리에 둔다.
    public func putAnalysis(for track: TrackSpec, dat: Data, ext: Data?) throws {
        guard let path = track.analysisDataPath else { throw FixtureError("분석 경로가 없는 곡") }
        let url = shareRoot.appending(path: String(path.drop(while: { $0 == "/" })))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dat.write(to: url)
        if let ext { try ext.write(to: url.deletingPathExtension().appendingPathExtension("EXT")) }
    }

    public func analysisURL(for track: TrackSpec, ext: String = "DAT") -> URL {
        shareRoot.appending(path: String((track.analysisDataPath ?? "").drop(while: { $0 == "/" })))
            .deletingPathExtension().appendingPathExtension(ext)
    }

    /// 재생 목록·폴더 하나(djmdPlaylist + 클라우드 거울 행 + 곡 항목). 동기화를 마친 행처럼 상태 256·usn을 채운다(곡 항목은 그 곡 행의 상태를 따른다).
    @discardableResult
    public func add(_ playlist: PlaylistSpec) throws -> PlaylistSpec {
        try add(playlists: [playlist])
        return playlist
    }

    /// 여러 재생 목록을 한 연결·트랜잭션으로 넣는다.
    public func add(playlists: [PlaylistSpec]) throws {
        let db = try connect(writable: true)
        try db.run("BEGIN")
        for playlist in playlists { try Self.insert(playlist, into: db) }
        try db.run("COMMIT")
    }

    private static func insert(_ playlist: PlaylistSpec, into db: FixtureConnection) throws {
        try db.run("""
            INSERT INTO djmdPlaylist (ID, Seq, Name, ImagePath, Attribute, ParentID, SmartList, UUID, rb_data_status, rb_local_data_status,
                rb_local_deleted, rb_local_synced, usn, rb_local_usn, created_at, updated_at)
            VALUES (?, ?, ?, NULL, ?, ?, NULL, ?, 256, 0, 0, 1, 20, 20, ?, ?)
            """, [.text(playlist.id), .int(playlist.seq), .text(playlist.name), .int(playlist.isFolder ? 1 : 0), .text(playlist.parentID),
                  .text(playlist.uuid), .text(Self.stamp), .text(Self.stamp)])
        try db.run("""
            INSERT INTO djmdCloudFilterPlaylist (ID, PlaylistUUID, Seq, ParentID, UUID, rb_data_status, rb_local_data_status, rb_local_deleted,
                rb_local_synced, usn, rb_local_usn, created_at, updated_at)
            VALUES (?, ?, 0, NULL, ?, 256, 0, 0, 0, 21, 21, ?, ?)
            """, [.text("cf-\(playlist.id)"), .text(playlist.uuid), .text(UUID().uuidString.lowercased()), .text(Self.stamp), .text(Self.stamp)])
        for (index, contentID) in playlist.contentIDs.enumerated() {
            // 곡 항목의 상태는 그 곡 행을 따른다: 동기화를 마친 곡(256)의 항목은 256, 상태 0 곡의 항목은 0(곡 빼기·합치기 규칙을 확인한 모양, #196).
            // 곡 행이 아직 없으면 256.
            var status = 256
            try db.query("SELECT rb_data_status FROM djmdContent WHERE ID = ?", [.text(contentID)]) { status = $0.int(0) ?? 256 }
            try db.run("""
                INSERT INTO djmdSongPlaylist (ID, PlaylistID, ContentID, TrackNo, UUID, rb_data_status, rb_local_data_status, rb_local_deleted,
                    rb_local_synced, usn, rb_local_usn, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, 22, 22, ?, ?)
                """, [.text(UUID().uuidString.lowercased()), .text(playlist.id), .text(contentID), .int(index + 1),
                      .text(UUID().uuidString.lowercased()), .int(status), .text(Self.stamp), .text(Self.stamp)])
        }
    }

    /// `.DAT`의 contentFile 행(그리드 BPM 변경 때 해시·크기를 고친다)
    public func addContentFile(for track: TrackSpec, hash: String, size: Int) throws {
        try execute("""
            INSERT INTO contentFile (ID, ContentID, Path, Hash, Size, UUID, rb_data_status, rb_local_deleted, rb_local_usn, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 13, ?, ?)
            """, [.text("cf-\(track.id)"), .text(track.id), .text(track.analysisDataPath ?? ""), .text(hash), .int(size),
                  .text(UUID().uuidString.lowercased()), .int(track.dataStatus), .text(Self.stamp), .text(Self.stamp)])
    }

    /// 아무 표에나 행 하나(created_at·updated_at은 자동). 아티스트·재생 목록·재생 이력 등.
    public func insert(_ table: String, _ values: [String: CipherDatabase.Value]) throws {
        try session { try $0.insert(table, values) }
    }

    public func execute(_ sql: String, _ values: [CipherDatabase.Value] = []) throws {
        try session { try $0.execute(sql, values) }
    }

    /// 질의 결과를 칸 이름 → 글자로(NULL은 "NULL").
    public func rows(_ sql: String, _ values: [CipherDatabase.Value] = []) throws -> [[String: String]] {
        try Session(db: connect(writable: false)).rows(sql, values)
    }

    /// 연결 하나로 문장 여럿을 실행한다(쓰기 연결이라 읽기도 된다). 픽스처 연결은 키 유도 없이 열리지만, 한 연결이 한 트랜잭션처럼 묶이지는 않는다.
    public func session<T>(_ body: (Session) throws -> T) throws -> T {
        try body(Session(db: connect(writable: true)))
    }

    /// `session`이 연 연결에서 실행하는 문장들(쓰기 연결이라 읽기도 된다)
    public struct Session {
        let db: FixtureConnection

        public func insert(_ table: String, _ values: [String: CipherDatabase.Value]) throws {
            var values = values
            values["created_at"] = values["created_at"] ?? .text(RekordboxFixture.stamp)
            values["updated_at"] = values["updated_at"] ?? .text(RekordboxFixture.stamp)
            let keys = values.keys.sorted()
            try db.run("INSERT INTO \(table) (\(keys.joined(separator: ", "))) VALUES (\(keys.map { _ in "?" }.joined(separator: ", ")))",
                       keys.map { values[$0]! })
        }

        public func execute(_ sql: String, _ values: [CipherDatabase.Value] = []) throws {
            try db.run(sql, values)
        }

        public func rows(_ sql: String, _ values: [CipherDatabase.Value] = []) throws -> [[String: String]] {
            var out: [[String: String]] = []
            try db.query(sql, values) { r in
                var row: [String: String] = [:]
                for i in 0..<r.count { row[r.name(Int32(i))] = r.string(Int32(i)) ?? "NULL" }
                out.append(row)
            }
            return out
        }
    }

    public func localUpdateCount() throws -> Int {
        Int(try rows("SELECT int_1 FROM agentRegistry WHERE registry_id = 'localUpdateCount'").first?["int_1"] ?? "") ?? -1
    }
}

/// 픽스처가 행을 넣고 읽는 연결. 원시 키(`x'…'`)로 열어 SQLCipher 키 유도(PBKDF2 256,000번)를 건너뛴다.
///
/// 제품 연결(`CipherDatabase`)은 열 때마다 문자열 키로 키를 유도해, 행 하나 넣거나 읽으려 열 때마다 수십 ms가 들었다(시험 시간의 대부분).
/// 원시 키는 파일 머리의 솔트로 프로세스에서 한 번만 유도한다. 파일 형식(SQLCipher 4 기본값)은 그대로라 제품 코드는 같은 파일을 문자열 키로 연다.
/// 원시 키로 열지 못하면 문자열 키로 다시 연다(`usedPassphrase`, 픽스처가 `passphraseFallbacks`로 센다).
final class FixtureConnection {
    private var handle: OpaquePointer?
    /// 원시 키로 열지 못해 문자열 키로 열었다(늘 false여야 빠르다)
    private(set) var usedPassphrase = false
    /// 솔트 → 원시 키 16진수
    private static let rawKeys = Mutex<[Data: String]>([:])
    private static let ready: Void = { _ = sqlite3_initialize() }()

    init(path: String, writable: Bool) throws {
        Self.ready
        let passphrase = try RekordboxKey.derive()
        if let raw = try? Self.rawKey(path: path, passphrase: passphrase), (try? open(path, writable, "\"x'\(raw)'\"")) != nil { return }
        usedPassphrase = true
        try open(path, writable, "'\(passphrase)'")
    }

    deinit { sqlite3_close_v2(handle) }

    /// `key`: `PRAGMA key` 오른쪽 글자(따옴표 포함)
    private func open(_ path: String, _ writable: Bool, _ key: String) throws {
        sqlite3_close_v2(handle)
        handle = nil
        guard sqlite3_open_v2(path, &handle, writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw FixtureError("픽스처 DB를 열지 못했습니다: \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
        try run("PRAGMA key = \(key)")
        var tables = 0
        try query("SELECT count(*) FROM sqlite_master") { tables = $0.int(0) ?? 0 }
        guard tables > 0 else { throw FixtureError("픽스처 DB에 표가 없습니다") }
    }

    /// SQLCipher 4 기본값: PBKDF2-HMAC-SHA512, 256,000번, 32바이트. 솔트는 파일 첫 16바이트.
    private static func rawKey(path: String, passphrase: String) throws -> String {
        guard let file = FileHandle(forReadingAtPath: path) else { throw FixtureError("DB 머리를 읽지 못했습니다") }
        defer { try? file.close() }
        guard let salt = try file.read(upToCount: 16), salt.count == 16 else { throw FixtureError("DB 머리가 짧습니다") }
        if let key = rawKeys.withLock({ $0[salt] }) { return key }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 256_000, &derived, derived.count)
        }
        guard status == kCCSuccess else { throw FixtureError("키를 유도하지 못했습니다") }
        let key = derived.map { String(format: "%02x", $0) }.joined()
        rawKeys.withLock { $0[salt] = key }
        return key
    }

    private var message: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown" }

    func run(_ sql: String, _ values: [CipherDatabase.Value] = []) throws {
        try query(sql, values) { _ in }
    }

    func query(_ sql: String, _ values: [CipherDatabase.Value] = [], _ each: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError("\(sql): \(message)") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result = switch value {
            case let .text(text): sqlite3_bind_text(statement, position, text, -1, transient)
            case let .int(number): sqlite3_bind_int64(statement, position, Int64(number))
            case let .real(number): sqlite3_bind_double(statement, position, number)
            case .null: sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else { throw FixtureError("\(sql): \(message)") }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try each(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw FixtureError("\(sql): \(message)")
            }
        }
    }

    struct Row {
        let statement: OpaquePointer?
        var count: Int { Int(sqlite3_column_count(statement)) }
        func name(_ column: Int32) -> String { sqlite3_column_name(statement, column).map { String(cString: $0) } ?? "" }
        func string(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }
        func int(_ column: Int32) -> Int? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
        }
    }
}

/// `Tests/Support/Resources`의 고정 파일(합성 MP3·rekordbox 구조)
public enum TestResources {
    public static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
            throw FixtureError("테스트 파일이 없습니다: \(name)")
        }
        return url
    }
}

/// 합성 곡. 기본값은 MP3 CBR 320kbps, 200초, 128 BPM.
public struct TrackSpec: Sendable {
    public var id: String
    public var uuid: String
    public var title = "시험 곡"
    /// 1 MP3, 4 M4A, 5 FLAC, 11 WAV
    public var fileType = 1
    /// 0 = VBR(분석한 곡) 또는 분석 전
    public var bitRate = 320
    /// 105 = 분석함, 0 = 분석 전(BitRate 등 분석 칸이 0)
    public var analysed = 105
    public var length = 200
    public var bpm100 = 12800
    /// 기본은 CBR MP3 테스트 음원(쓰기 모듈이 MP3 파일 머리로 VBR인지 본다)
    public var folderPath = (try? TestResources.url("mp3-lame-cbr.mp3").path) ?? "/tmp/djc-none.mp3"
    public var cueUpdated: String? = "1"
    public var analysisUpdated = "1"
    public var trackInfoUpdated = "1"
    public var analysisDataPath: String?
    public var cues: [CueSpec] = []
    /// 옛 rekordbox가 쓴 JSON처럼 칸 순서를 섞어 둔다(다시 쓸 때 순서를 지키는지 본다)
    public var legacyJSON = false
    public var gain: (high: Int, low: Int)?
    public var artistID: String?
    public var albumID: String?
    public var composerID: String?
    public var imagePath: String?
    /// 곡 행과 딸린 행(contentCue·오토게인·파일 행)의 `rb_data_status`. 기본 256 = 클라우드와 동기화를 마친 곡(대부분의 라이브러리),
    /// 0 = 아직 동기화하지 않은 곡(rekordbox 실험 곡·DJCrate가 막 넣은 곡). 곡 빼기·합치기 규칙은 0인 곡으로만 확인했다(#196).
    public var dataStatus = 256

    public init(id: String = String(Int.random(in: 100_000...999_999)), uuid: String = UUID().uuidString.lowercased()) {
        self.id = id
        self.uuid = uuid
    }

    /// rekordbox 큐 모델(초안의 base로 쓴다)
    public var rekordboxCues: [Cue] {
        cues.map { cue in
            Cue(id: cue.id, contentID: id, kind: cue.kind, inMsec: cue.inMsec, name: cue.comment ?? "",
                colorTableIndex: cue.colorTableIndex, outMsec: cue.outMsec, color: cue.color,
                activeLoop: cue.activeLoop ?? 0, beatLoopSize: cue.beatLoopSize ?? 0)
        }
    }

    func jsonObject(for cue: CueSpec) -> CueJSON.Object {
        var pairs: [(String, CueJSON.Value?)] = [
            ("ID", .string(cue.id)), ("ContentID", .string(id)), ("ContentUUID", .string(uuid)),
            ("InMsec", .int(cue.inMsec)), ("InFrame", .int(cue.inMsec * 150 / 1000)), ("InMpegFrame", .int(0)), ("InMpegAbs", .int(0)),
            ("InPointSeekInfo", cue.inSeek.map { .string($0) }),
            ("OutMsec", .int(cue.outMsec)), ("OutFrame", .int(max(cue.outMsec, 0) * 150 / 1000)), ("OutMpegFrame", .int(0)),
            ("OutMpegAbs", .int(0)), ("OutPointSeekInfo", cue.outSeek.map { .string($0) }),
            ("Kind", .int(cue.kind)), ("Color", .int(cue.color)), ("ColorTableIndex", cue.colorTableIndex.map { .int($0) }),
            ("ActiveLoop", cue.activeLoop.map { .int($0) }),
            ("Comment", cue.comment.flatMap { $0.isEmpty ? nil : .string($0) }),
            ("BeatLoopSize", cue.beatLoopSize.map { .int($0) }), ("CueMicrosec", cue.cueMicrosec.map { .int($0) }),
            ("UUID", .string(cue.uuid)),
            ("created_at", .string("2026-01-01T00:00:00.000+00:00")), ("updated_at", .string("2026-01-01T00:00:00.000+00:00")),
        ]
        if legacyJSON { pairs.reverse() }
        let present = pairs.compactMap { key, value in value.map { (key, $0) } }
        return CueJSON.Object(fields: present)
    }
}

/// 합성 재생 목록·폴더
public struct PlaylistSpec: Sendable {
    public var id: String
    public var uuid = UUID().uuidString.lowercased()
    public var name: String
    public var parentID: String
    public var seq: Int
    public var isFolder: Bool
    /// TrackNo 순서의 곡 ID(같은 곡이 여러 번 있을 수 있다)
    public var contentIDs: [String]

    public init(id: String = String(Int.random(in: 100_000...4_000_000_000)), name: String, parentID: String = "root", seq: Int,
                isFolder: Bool = false, contentIDs: [String] = []) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.seq = seq
        self.isFolder = isFolder
        self.contentIDs = contentIDs
    }
}

/// 합성 큐 행. 기본은 루프 아닌 메모리 큐(rekordbox 7 새 큐 모양).
public struct CueSpec: Sendable {
    public var id: String
    public var uuid = UUID().uuidString.lowercased()
    public var kind: Int
    public var inMsec: Int
    public var outMsec = -1
    public var comment: String?
    public var color = -1
    public var colorTableIndex: Int?
    public var activeLoop: Int?
    public var beatLoopSize: Int?
    public var cueMicrosec: Int?
    public var inSeek: String?
    public var outSeek: String?

    public init(id: String = String(Int.random(in: 1_000_000...9_999_999)), kind: Int = 0, inMsec: Int) {
        self.id = id
        self.kind = kind
        self.inMsec = inMsec
    }

    /// rekordbox가 곡 분석 때 찍는 자동 메모리 큐("1.1Bars")
    public static func autoCue(at msec: Int) -> CueSpec {
        var cue = CueSpec(kind: 0, inMsec: msec)
        cue.comment = "1.1Bars"; cue.color = 255; cue.colorTableIndex = 0; cue.activeLoop = 0; cue.beatLoopSize = 0; cue.cueMicrosec = 0
        return cue
    }
}
