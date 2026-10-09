import CryptoKit
import DJCDomain
import Foundation

/// rekordbox 컬렉션에 곡을 넣고 뺀다(rekordbox를 켜지 않고).
///
/// rekordbox 7.2.18 실험(2026-09-26, 묶음 1·2)에서 확인한 모양을 따른다:
/// - 추가(분석 전): `djmdContent` 행 하나 + 새 이름이면 `djmdArtist`·`djmdAlbum`·`djmdGenre` 행. 분석 파일·파일 행·오토게인 행은 없다.
///   곡 ID는 1~2^28 난수, 아티스트 등은 32비트 난수. 관련 행 번호(usn)를 먼저 받고 곡 행이 마지막 번호를 받는다.
/// - 추가(분석 포함): 변경 번호는 관련 행 → (아트워크 파일 행) → 오토게인 행 → 곡 행 → 파일 행 .2EX·.DAT·.EXT(2026-09-26 실험).
/// - 아트워크: 분석까지 붙여 넣는 곡만, 음원에 그림이 있으면 아트워크 파일 셋(`TrackArtwork`)·`ImagePath`·`artwork.jpg` 파일 행을 넣는다.
///   rekordbox는 자동 분석을 끄고 넣을 때는 만들지 않고 곡을 분석할 때 뽑는다(2026-09-26 실험 "DJC 실험 아트").
/// - 삭제: 행을 실제로 지운다(삭제 표시가 아님). 곡 행·큐(`djmdCue`·`contentCue`)·파일 행·오토게인 행·재생 목록·재생 이력 항목.
///   같은 목록·이력의 뒤 순번은 하나씩 당기고(한 번호로 몰아서), 그 곡만 쓰던 아티스트·앨범 행도 지운다. 분석 폴더·아트워크 파일도 지운다.
///   재생 목록 순번 당기기는 재생 이력에서 본 것을 따른 추정이다. 당기는 살아 있는 행이 동기화 상태 256이면 재생 목록 편집(`touchEntry`)처럼
///   257로 올린다(0·257은 그대로, 사용자 정책: 동기화 데이터를 DJCrate가 고친 행은 257). 당길 자리에 지운 표시가 남은 행이 있으면
///   그 곡을 막는다(미확인).
/// - 동기화 상태 곡은 빼지 않는다(#196): rekordbox는 동기화한 곡을 지울 때 행을 지우지 않고 삭제 표시(`rb_local_deleted` 1, 상태 258 →
///   클라우드 처리 뒤 262)로 남기는데, 삭제 규칙은 상태 0 시험 곡으로만 확인했다. 곡 행·딸린 행·함께 지울 앨범·아티스트 행 중 상태가
///   0이 아닌 것이 있으면 그 곡만 막고 "rekordbox에서 직접 빼세요"로 알린다. 묶음 3 실험(세션 D3)으로 규칙을 확인하면 연다.
/// - 확인하지 않은 표(MyTag·핫큐 뱅크·샘플러·관련 곡·신청곡·검열 구간·클라우드 내보내기·추천 좋아요)에 걸린 곡은 지우지 않는다.
///
/// 안전장치는 큐 쓰기(`RekordboxWriter`)와 같다: 사전 확인 → 전체 백업 → 한 트랜잭션 → 다시 읽어 검증 → 무결성 검사 → 실패 시 복원.
/// 커밋 뒤 실패는 복원했으면 `writeRolledBack`, 복원도 못 했으면 `restoreFailed`로 알린다.
public enum RekordboxTrackWriter {
    // 결과·입력 값은 DJCDomain에 있다(#167). 옛 이름을 남긴다.
    public typealias Outcome = RekordboxTrackWriteOutcome
    public typealias Report = RekordboxTrackWriteReport
    public typealias Analysis = RekordboxTrackAnalysis

    /// 분석까지 붙인 곡의 `ContentLink`(프레이즈·보컬 분석 없음, 라이브러리 426곡이 쓰는 값)
    static let analysedContentLink = 0x2C060E

    /// 분석까지 붙여 넣는 곡(#4)과 분석을 붙이는 분석 전 곡(`RekordboxWriter+Analysis`, #87)에 음원 내장 아트워크도 넣는지.
    /// 2026-09-26 실험(rekordbox가 아트워크 든 곡을 넣고 분석한 전후 비교)으로 파일 셋·파일 행 칸·변경 번호 순서를 확인해 열었다.
    /// 규칙이 맞지 않는 것이 드러나면 여기서 닫는다.
    public static let writesArtwork = true

    /// 지울 곡을 막는 표(아직 rekordbox 실험으로 확인하지 않음)
    static let unverifiedReferenceTables = ["contentActiveCensor", "djmdActiveCensor", "djmdCloudExportSongPlaylist", "djmdSongHotCueBanklist",
                                            "djmdSongMyTag", "djmdSongRelatedTracks", "djmdSongRequestList", "djmdSongSampler", "djmdSongTagList"]
    /// 곡을 가리키는 칸이 둘(`ContentID1`·`ContentID2`)이라 위 표들처럼 `ContentID`로 찾을 수 없는 미확인 표
    static let recommendLikeTable = "djmdRecommendLike"
    /// 곡을 빼면 뒤 순번을 당기는 표(표 이름, 목록 ID 칸)
    static let historyTable = (table: "djmdSongHistory", list: "HistoryID")
    static let renumberedTables = [(table: "djmdSongPlaylist", list: "PlaylistID"), historyTable]

    /// 동기화 상태 곡 빼기·합치기를 막는 이유(#196). 곡 행이 상태 0이 아닌 곡.
    public static var syncedTrackReason: String {
        String(ui: "rekordbox 클라우드와 동기화된 곡이라 빼는 규칙을 아직 확인하지 못했으니 rekordbox에서 직접 빼세요")
    }
    /// 곡 행은 상태 0인데 그 곡을 빼며 지울 딸린 행(큐·파일·오토게인·재생 목록 항목·재생 이력) 중 동기화 상태인 것이 있다.
    public static var syncedRowsReason: String {
        String(ui: "이 곡의 큐·파일·오토게인·재생 목록 항목·재생 이력 중 클라우드와 동기화된 행이 있어 빼는 규칙을 아직 확인하지 못했으니 rekordbox에서 직접 빼세요")
    }
    /// 곡을 빼면 같은 재생 목록·재생 이력의 뒤 항목 순번을 당기는데, 그 자리에 rekordbox가 지운 표시를 남긴 항목이 있다.
    public static var syncedRenumberReason: String {
        String(ui: "같은 재생 목록이나 재생 이력에서 이 곡 뒤에 rekordbox가 지운 표시를 남긴 항목이 있어 순번을 당기는 규칙을 아직 확인하지 못했으니 rekordbox에서 직접 빼세요")
    }
    /// 곡을 빼면 아무도 안 쓰게 되는 앨범·아티스트 행이 동기화 상태라 그 행을 지우는 규칙을 모른다.
    public static var syncedOrphanReason: String {
        String(ui: "이 곡만 쓰던 앨범·아티스트 행이 클라우드와 동기화된 행이라 지우는 규칙을 아직 확인하지 못했으니 rekordbox에서 직접 빼세요")
    }

    // MARK: - 추가

    /// - Parameters:
    ///   - analyses: 경로마다 붙일 분석. 있으면 분석 파일(.DAT·.EXT·.2EX)·파일 행·오토게인 행까지 넣는다(CBR MP3·AAC·WAV만).
    ///   - shareRoot: 분석 파일 뿌리. 라이브 DB면 rekordbox share 폴더, 사본이면 명시해야 분석을 붙인다.
    ///   - cues: 경로마다 함께 넣을 큐. 곡을 넣은 같은 트랜잭션에서 큐 쓰기(`RekordboxWriter`)와 같은 규칙으로 쓴다.
    ///     큐가 막히면 곡만 넣고 이유를 `cueReason`에 남긴다.
    ///   - keys: 경로마다 함께 쓸 키(사용자가 고른 Camelot 이름, #5). 곡을 넣고(분석·큐까지) 같은 트랜잭션에서 그 곡에 키만 고친 태그
    ///     쓰기(`RekordboxWriter.applyTags`)를 한다. rekordbox에서 곡을 넣은 뒤 정보 패널에서 키를 저장한 것과 같다. 빈 이름은 할 일이 없다
    ///     (넣는 곡의 키는 '0'). 키가 막히면(키 줄이 없거나 둘 이상 등) 곡만 넣고 이유를 `keyReason`에 남긴다.
    ///   - writesArtwork: 분석까지 붙이는 곡에 음원 내장 아트워크로 아트워크 파일 셋·`ImagePath`·파일 행을 넣는지. 앱은 `writesArtwork`를 따른다.
    public static func add(_ plans: [TrackAddPlan], analyses: [String: Analysis] = [:], cues: [String: [EditableCue]] = [:],
                           keys: [String: String] = [:], to database: URL,
                           shareRoot: URL? = nil, dryRun: Bool, now: Date = .now, backups: URL,
                           guard writeGuard: RekordboxWriteGuard = .system,
                           writesArtwork: Bool = RekordboxTrackWriter.writesArtwork) throws -> Report {
        var report = Report(dryRun: dryRun)
        guard !plans.isEmpty else { return report }
        let share = try preflight(database, shareRoot: shareRoot, dryRun: dryRun, guard: writeGuard)
        let live = writeGuard.isLive(database)
        // 곡 UUID를 먼저 정한다(분석·아트워크 폴더 이름이 된다)
        let uuids = Dictionary(plans.map { ($0.path, UUID().uuidString.lowercased()) }) { first, _ in first }
        // 분석·아트워크 파일은 DB 밖에서 미리 만든다(오래 걸리고 실패해도 DB를 건드리기 전에 알 수 있게)
        var prepared: [String: PreparedAnalysis] = [:]
        var artworks: [String: PreparedArtwork] = [:]
        for plan in plans {
            let uuid = uuids[plan.path]!
            guard let analysis = analyses[plan.path] else { continue }
            do {
                prepared[plan.path] = try prepare(path: plan.path, fileName: plan.fileName, duration: plan.duration, uuid: uuid,
                                                  analysis: analysis, share: share)
            } catch {
                prepared[plan.path] = PreparedAnalysis(uuid: uuid, blocked: String(ui: "분석 파일을 만들지 못했습니다: \(String(describing: error))"))
            }
            // 아트워크는 분석과 함께만 넣는다(rekordbox는 분석할 때 뽑고, 자동 분석을 끄고 넣으면 만들지 않는다)
            if writesArtwork, prepared[plan.path]?.blocked == nil, let share, let image = plan.artwork, let files = TrackArtwork.make(image) {
                artworks[plan.path] = PreparedArtwork(uuid: uuid, files: files, share: share)
            }
        }
        let stamp = CueJSON.timestamps(now)
        let backup = dryRun ? nil : try RekordboxWriter.makeBackup(of: database, in: backups, now: now, label: "add")
        report.backup = backup?.path
        var inserted: [(id: String, expected: [String: CipherDatabase.Value])] = []
        /// 곡과 함께 넣은 파일 행·오토게인 행(커밋 뒤 다시 읽어 비교)
        var extraRows: [InsertedRow] = []
        var cueChecks: [(contentID: String, expectation: RekordboxWriter.Expectation)] = []
        /// 곡과 함께 쓴 키(커밋 뒤 태그 쓰기와 같은 검증으로 다시 읽는다)
        var keyChecks: [RekordboxWriter.TagExpectation] = []
        report.finalUpdateCount = try transaction(database, dryRun: dryRun) { db, usn in
            let library = try libraryIdentity(db)
            for plan in plans {
                try db.execute("SAVEPOINT djc_add")
                do {
                    guard FileManager.default.fileExists(atPath: plan.path) else { throw Blocked(String(ui: "음원 파일이 없습니다")) }
                    guard try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE FolderPath = ? AND rb_local_deleted = 0",
                                                     [.text(plan.path)]) == 0 else { throw Blocked(String(ui: "이미 rekordbox 컬렉션에 있는 파일입니다")) }
                    let artistID = try plan.artist.map { try findOrCreate(db, table: "djmdArtist", name: $0, usn: &usn, stamp: stamp) }
                    let albumArtistID = try plan.albumArtist.map { try findOrCreate(db, table: "djmdArtist", name: $0, usn: &usn, stamp: stamp) }
                    let albumID = try plan.album.map { try findOrCreateAlbum(db, name: $0, albumArtistID: albumArtistID, usn: &usn, stamp: stamp) }
                    let genreID = try plan.genre.map { try findOrCreate(db, table: "djmdGenre", name: $0, usn: &usn, stamp: stamp) }
                    let composerID = try plan.composer.map { try findOrCreate(db, table: "djmdArtist", name: $0, usn: &usn, stamp: stamp) }
                    let id = try newID(db, table: "djmdContent", range: 1..<(1 << 28))
                    let ready = prepared[plan.path]
                    if let reason = ready?.blocked { throw Blocked(reason) }
                    let uuid = uuids[plan.path]!
                    let artwork = artworks[plan.path]
                    // 그림 폴더 위가 링크면 share 밖에 쓰게 된다(#66 리뷰). 그 곡은 넣지 않는다.
                    if let artwork, artwork.files.contains(where: { RekordboxWriter.hasSymlinkComponent($0.0, under: artwork.share) }) {
                        throw Blocked(RekordboxWriter.artworkLinkReason)
                    }
                    // rekordbox가 분석할 때의 순서: 아트워크 파일 행 → 오토게인 행 → 곡 행 → 분석 파일 행(2026-09-26 실험)
                    var planRows: [InsertedRow] = []
                    func insertRow(_ row: InsertedRow) throws {
                        try insert(db, table: row.table, row.values)
                        try verify(db, table: row.table, id: row.id, row.values)
                        planRows.append(row)
                    }
                    if let artwork {
                        // 아트워크 파일 행은 artwork.jpg 하나(_m·_s는 행이 없다)
                        usn += 1
                        try insertRow(fileRow(uuid: uuid, share: artwork.share, artwork.files[0], contentID: id, usn: usn, stamp: stamp))
                    }
                    if let ready {
                        usn += 1
                        try insertRow(mixerRow(ready, contentID: id, usn: usn, stamp: stamp))
                    }
                    usn += 1
                    var row = contentRow(plan, id: id, uuid: uuid, artistID: artistID, albumID: albumID,
                                         genreID: genreID, composerID: composerID, library: library, usn: usn, stamp: stamp)
                    if let ready { row.merge(ready.columns) { _, new in new } }
                    if let artwork { row["ImagePath"] = .text(artwork.imagePath) }
                    try insert(db, table: "djmdContent", row)
                    try verify(db, table: "djmdContent", id: id, row)
                    if let ready {
                        for file in analysisFileRows(ready, contentID: id, usn: &usn, stamp: stamp) { try insertRow(file) }
                    }
                    var outcome = Outcome(path: plan.path, contentID: id, title: plan.title, written: true, reason: nil, uuid: uuid)
                    if let list = cues[plan.path], !list.isEmpty {
                        var draft = CueDraft(trackUUID: uuid, rekordboxCues: [])
                        for cue in list { draft.place(cue) }
                        try db.execute("SAVEPOINT djc_add_cues")
                        do {
                            let result = try RekordboxWriter.apply(draft, db: db, usn: &usn, stamp: stamp)
                            if let expectation = result.expectation {
                                try RekordboxWriter.verify(db: db, contentID: id, expectation)
                                cueChecks.append((id, expectation))
                                // 큐를 쓰면 곡 행의 CueUpdated·변경 번호가 바뀐다
                                row["CueUpdated"] = .text(String(result.outcome.added))
                                row["rb_local_usn"] = .int(expectation.contentUSN)
                                outcome.cuesWritten = result.outcome.added
                            }
                            try db.execute("RELEASE djc_add_cues")
                        } catch let blocked as RekordboxWriter.Blocked {
                            try db.execute("ROLLBACK TO djc_add_cues")
                            try db.execute("RELEASE djc_add_cues")
                            outcome.cueReason = blocked.reason
                        }
                    }
                    // 키(#5): 곡 넣기(분석·큐까지)를 마친 뒤 키만 고친 태그 초안을 태그 쓰기로 쓴다. 태그는 마지막이라 곡 행이 마지막 번호를 받고,
                    // 분석을 넣은 곡은 첫 BPM/Grid '1' 뒤에 +1이 된다. 넣는 곡은 아직 어느 재생 목록에도 없어 XML Timestamp는 고칠 것이 없다.
                    if let name = keys[plan.path], !name.isEmpty {
                        try db.execute("SAVEPOINT djc_add_key")
                        let savedUSN = usn
                        var currentBase: TagFields?
                        do {
                            guard let base = try RekordboxWriter.currentTags(db: db, contentID: id) else {
                                throw DJCError.writeVerificationFailed(String(ui: "넣은 곡의 정보를 다시 읽지 못했습니다 (\(plan.title))"))
                            }
                            currentBase = base
                            var draft = TagDraft(trackUUID: uuid, base: base)
                            draft.fields.musicalKey = name
                            let result = try RekordboxWriter.applyTags(draft, db: db, usn: &usn, stamp: stamp,
                                                                       writable: RekordboxWriter.writableTagKeys)
                            // 곡 행 기대값을 키를 쓴 뒤 모양으로(커밋 뒤 곡 행 전체를 다시 비교한다). 같은 곡의 큐 검증도 마지막 번호를 본다.
                            row["KeyID"] = .text(result.expectation.keyID ?? "0")
                            row["TrackInfoUpdated"] = .text(result.expectation.trackInfoUpdated)
                            row["rb_local_usn"] = .int(result.expectation.contentUSN)
                            for i in cueChecks.indices where cueChecks[i].contentID == id {
                                cueChecks[i].expectation.contentUSN = result.expectation.contentUSN
                            }
                            keyChecks.append(result.expectation)
                            outcome.keyWritten = name
                            try db.execute("RELEASE djc_add_key")
                        } catch let blocked as RekordboxWriter.Blocked {
                            // 따로 쓸 때처럼 키만 막는다(번호도 되돌린다). 곡은 키 없이('0') 넣는다.
                            try db.execute("ROLLBACK TO djc_add_key")
                            try db.execute("RELEASE djc_add_key")
                            usn = savedUSN
                            outcome.keyReason = blocked.reason
                            outcome.keyBase = currentBase
                        }
                    }
                    try db.execute("RELEASE djc_add")
                    inserted.append((id, row))
                    extraRows += planRows
                    report.added.append(outcome)
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_add")
                    try db.execute("RELEASE djc_add")
                    report.added.append(Outcome(path: plan.path, contentID: nil, title: plan.title, written: false, reason: blocked.reason))
                }
            }
            return !inserted.isEmpty
        }
        if let backup, !inserted.isEmpty {
            try afterCommit(database, backup: backup, live: live) { db in
                for item in inserted { try verify(db, table: "djmdContent", id: item.id, item.expected) }
                for row in extraRows { try verify(db, table: row.table, id: row.id, row.values) }
                for check in cueChecks { try RekordboxWriter.verify(db: db, contentID: check.contentID, check.expectation) }
                for expectation in keyChecks { try RekordboxWriter.verifyTags(db: db, expectation) }
            }
            // 분석·아트워크 파일: DB가 끝난 뒤 쓴다. 실패하면 쓴 파일과 만든 빈 폴더를 지우고 DB를 되돌린다.
            let written = report.added.filter(\.written).map(\.path)
            var created: [URL] = []
            do {
                for path in written {
                    if let artwork = artworks[path], artwork.files.contains(where: { RekordboxWriter.hasSymlinkComponent($0.0, under: artwork.share) }) {
                        throw DJCError.writeVerificationFailed(RekordboxWriter.artworkLinkReason)
                    }
                    let analysisFiles = prepared[path].flatMap { $0.blocked == nil ? $0.files : nil } ?? []
                    for (url, data) in analysisFiles + (artworks[path]?.files ?? []) {
                        guard !FileManager.default.fileExists(atPath: url.path) else { throw DJCError.writeVerificationFailed(String(ui: "파일이 이미 있습니다: \(url.path)")) }
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                        created.append(url)
                        guard try Data(contentsOf: url) == data else { throw DJCError.writeVerificationFailed(String(ui: "파일 확인 실패: \(url.lastPathComponent)")) }
                    }
                }
            } catch {
                throw RekordboxWriter.recover(from: error, database: database, backup: backup, live: live) {
                    try RekordboxWriter.removeAnalysisFiles(created)
                }
            }
            report.createdFiles = created.map(\.path)
        }
        if let backup {
            try? save(report, in: backup, shareRoot: share)
            RekordboxWriter.prune(backups)
        }
        return report
    }

    /// DB 밖에서 미리 만든 분석(파일 바이트·곡 행 분석 칸·파일 행·오토게인)
    struct PreparedAnalysis {
        var uuid: String
        var columns: [String: CipherDatabase.Value] = [:]
        var files: [(URL, Data)] = []
        var gain: (high: Int, low: Int) = (0, 0)
        var peak: (high: Int, low: Int) = (0, 0)
        var share: URL?
        /// 분석을 붙일 수 없는 이유(곡을 넣지 않는다)
        var blocked: String?
        /// PQTZ 박 수
        var beats = 0
    }

    /// DB 밖에서 미리 만든 아트워크 파일 셋(`artwork.jpg`·`_m`·`_s` 순서, 파일 행은 첫 파일만)
    struct PreparedArtwork {
        var imagePath: String
        var files: [(URL, Data)]
        var share: URL

        init(uuid: String, files: TrackArtwork.Files, share: URL) {
            imagePath = TrackArtwork.imagePath(uuid: uuid)
            let folder = share.appending(path: String(TrackArtwork.folder(uuid: uuid).dropFirst()))
            self.files = zip(TrackArtwork.fileNames, [files.full, files.medium, files.small]).map { (folder.appending(path: $0), $1) }
            self.share = share
        }
    }

    /// 곡 UUID로 정하는 분석 폴더(`/PIONEER/USBANLZ/<앞 3자>/<나머지>`)
    static func analysisFolder(uuid: String) -> String { "/PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))" }

    /// 곡 넣기와 분석 붙이기(`RekordboxWriter+Analysis`)가 함께 쓰는 레시피. 분석 폴더는 곡 UUID로 정한다.
    /// - Parameter duration: AVFoundation 길이(초). `Length`에 버림해 적는다.
    static func prepare(path: String, fileName: String, duration: Double, uuid: String, analysis: Analysis,
                        share: URL?) throws -> PreparedAnalysis {
        var ready = PreparedAnalysis(uuid: uuid, share: share)
        guard let share else { ready.blocked = String(ui: "사본 DB에는 분석 파일 뿌리(share)를 주어야 분석을 붙입니다"); return ready }
        let url = URL(filePath: path)
        let facts = AudioFacts.read(url: url)
        if let reason = facts.unsupported { ready.blocked = reason; return ready }
        guard let first = analysis.segments.first, first.bpm > 0 else { ready.blocked = String(ui: "그리드가 없습니다"); return ready }
        let waveforms = try RekordboxWaveforms.analyze(url: url)
        let waveformDuration = Double(waveforms.columns) / RekordboxWaveforms.columnsPerSecond
        let generated = RekordboxGridWriter.generate(segments: analysis.segments, duration: waveformDuration, preserving: [:])
        let beats = generated.beats
        guard !RekordboxGridWriter.hasEmptyVisibleSegment(segments: analysis.segments, counts: generated.counts,
                                                    duration: waveformDuration) else {
            ready.blocked = String(ui: "그리드 구간의 첫 박이 사라집니다. 변속 지점이나 BPM을 조정하세요")
            return ready
        }
        ready.beats = beats.count
        let files = try TrackAnalysisFiles.make(fileName: fileName, beats: beats, waveforms: waveforms, facts: facts)
        let folder = analysisFolder(uuid: uuid)
        let datPath = folder + "/ANLZ0000.DAT"
        ready.files = [("DAT", files.dat), ("EXT", files.ext), ("2EX", files.twoEx)].map { ext, data in
            (share.appending(path: String(folder.dropFirst()) + "/ANLZ0000.\(ext)"), data)
        }
        ready.columns = [
            "BPM": .int(Int((first.bpm * 100).rounded())), "Length": .int(Int(duration.rounded(.down))),
            "BitRate": .int(facts.bitRate), "BitDepth": .int(facts.bitDepth), "SampleRate": .int(facts.sampleRate),
            "AnalysisDataPath": .text(datPath), "Analysed": .int(105), "ContentLink": .int(analysedContentLink),
            "AnalysisUpdated": .text("1"), "TrackInfoUpdated": .text("1"),
        ]
        // 오토게인: rekordbox는 약 −10 LUFS에 맞춘다(라이브러리 비교 2026-09-26)
        let gainDB = analysis.loudness.map { RekordboxAutoGain.targetLoudness - $0 } ?? 0
        ready.gain = RekordboxAutoGain.halves(Float(pow(10, gainDB / 20)))
        ready.peak = RekordboxAutoGain.halves(Float(min(max(analysis.peak, 0), 1)))
        return ready
    }

    /// 분석 파일 행을 rekordbox 순서(.2EX → .DAT → .EXT)로 만든다. rekordbox는 .2EX 앞에 .3EX 행도 넣는다(DJCrate는 만들지 못한다).
    static func analysisFileRows(_ ready: PreparedAnalysis, contentID: String, usn: inout Int,
                                 stamp: (db: String, json: String)) -> [InsertedRow] {
        guard ready.share != nil else { return [] }
        var rows: [InsertedRow] = []
        for ext in ["2EX", "DAT", "EXT"] {
            guard let file = ready.files.first(where: { $0.0.pathExtension == ext }) else { continue }
            usn += 1
            rows.append(fileRow(ready, file, contentID: contentID, usn: usn, stamp: stamp))
        }
        return rows
    }

    /// 분석 파일 하나의 `contentFile` 행(ID = `<곡 UUID>_<경로, /는 %2F>`, MD5·크기·로컬 경로)
    static func fileRow(_ ready: PreparedAnalysis, _ file: (url: URL, data: Data), contentID: String, usn: Int,
                        stamp: (db: String, json: String)) -> InsertedRow {
        fileRow(uuid: ready.uuid, share: ready.share, file, contentID: contentID, usn: usn, stamp: stamp)
    }

    /// share 아래 파일 하나의 `contentFile` 행. 분석 파일과 아트워크(`artwork.jpg`) 행이 같은 칸 모양이다(라이브러리 조사 2026-09-26).
    static func fileRow(uuid: String, share root: URL?, _ file: (url: URL, data: Data), contentID: String, usn: Int,
                        stamp: (db: String, json: String)) -> InsertedRow {
        let share = root?.path ?? ""
        let path = "/" + file.url.path.dropFirst(share.count).drop(while: { $0 == "/" })
        let row: [String: CipherDatabase.Value] = [
            "ID": .text(fileRowID(uuid: uuid, path: path)), "ContentID": .text(contentID), "Path": .text(path),
            "Hash": .text(Insecure.MD5.hash(data: file.data).map { String(format: "%02x", $0) }.joined()), "Size": .int(file.data.count),
            "rb_local_path": .text(file.url.path), "rb_insync_hash": .null, "rb_insync_local_usn": .null, "rb_file_hash_dirty": .int(0),
            "rb_local_file_status": .int(0), "rb_in_progress": .int(0), "rb_process_type": .int(0), "rb_temp_path": .null,
            "rb_priority": .int(50), "rb_file_size_dirty": .int(0), "UUID": .text(UUID().uuidString.lowercased()),
        ]
        return InsertedRow(table: "contentFile", values: row.merging(syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
    }

    /// 파일 행 ID: `<곡 UUID>_<share 기준 경로, /는 %2F>`(라이브러리 조사 2026-09-26)
    static func fileRowID(uuid: String, path: String) -> String {
        "\(uuid)_\(path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path)"
    }

    /// 오토게인 `djmdMixerParam` 행
    static func mixerRow(_ ready: PreparedAnalysis, contentID: String, usn: Int, stamp: (db: String, json: String)) -> InsertedRow {
        let mixer: [String: CipherDatabase.Value] = [
            "ID": .text(UUID().uuidString.lowercased()), "ContentID": .text(contentID), "GainHigh": .int(ready.gain.high),
            "GainLow": .int(ready.gain.low), "PeakHigh": .int(ready.peak.high), "PeakLow": .int(ready.peak.low),
            "UUID": .text(UUID().uuidString.lowercased()),
        ]
        return InsertedRow(table: "djmdMixerParam", values: mixer.merging(syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
    }

    /// 넣은 행 하나(표·칸 값)
    struct InsertedRow {
        var table: String
        var values: [String: CipherDatabase.Value]
        var id: String { if case let .text(id)? = values["ID"] { id } else { "" } }
    }

    /// 분석 전 곡 행(78칸). 칸 형식(글자·정수·NULL)까지 rekordbox 7.2.18과 같게.
    static func contentRow(_ plan: TrackAddPlan, id: String, uuid: String, artistID: String?, albumID: String?, genreID: String?,
                           composerID: String?, library: (masterDBID: String, deviceID: String), usn: Int,
                           stamp: (db: String, json: String)) -> [String: CipherDatabase.Value] {
        func text(_ s: String?) -> CipherDatabase.Value { s.map { .text($0) } ?? .null }
        return [
            "ID": .text(id), "FolderPath": .text(plan.path), "FileNameL": .text(plan.fileName), "FileNameS": .text(""),
            "Title": .text(plan.title), "ArtistID": text(artistID), "AlbumID": text(albumID), "GenreID": text(genreID),
            "BPM": .int(0), "Length": .int(plan.length), "TrackNo": .int(plan.trackNumber), "BitRate": .int(0), "BitDepth": .int(0),
            "Commnt": .text(plan.comment), "FileType": .int(plan.fileType), "Rating": .int(0), "ReleaseYear": .int(plan.year),
            "RemixerID": .null, "LabelID": .null, "OrgArtistID": .null, "KeyID": .text("0"), "StockDate": .text(plan.stockDate),
            "ColorID": .text("0"), "DJPlayCount": .int(0), "ImagePath": .text(""), "MasterDBID": .text(library.masterDBID),
            "MasterSongID": .text(id), "AnalysisDataPath": .text(""), "SearchStr": .null, "FileSize": .int(plan.fileSize),
            "DiscNo": .int(plan.discNumber), "ComposerID": text(composerID), "Subtitle": .text(""), "SampleRate": .int(0),
            "DisableQuantize": .null, "Analysed": .int(0), "ReleaseDate": .text(""), "DateCreated": .text(plan.dateCreated),
            "ContentLink": .int(14), "Tag": .null, "ModifiedByRBM": .text(""), "HotCueAutoLoad": .text("on"), "DeliveryControl": .text("on"),
            "DeliveryComment": .text(""), "CueUpdated": .null, "AnalysisUpdated": .null, "TrackInfoUpdated": .null,
            "Lyricist": .text(plan.lyricist), "ISRC": .text(plan.isrc), "SamplerTrackInfo": .int(0), "SamplerPlayOffset": .int(0),
            "SamplerGain": .real(0), "VideoAssociate": .text("0"), "LyricStatus": .int(0), "ServiceID": .int(0), "OrgFolderPath": .text(""),
            "Reserved1": .text(""), "Reserved2": .null, "Reserved3": .null, "Reserved4": .null, "ExtInfo": .text("null"),
            "rb_file_id": .text(plan.fileID), "DeviceID": .text(library.deviceID), "rb_LocalFolderPath": .null, "SrcID": .null,
            "SrcTitle": .null, "SrcArtistName": .null, "SrcAlbumName": .null, "SrcLength": .null, "UUID": .text(uuid),
            "rb_data_status": .int(0), "rb_local_data_status": .int(0), "rb_local_deleted": .int(0), "rb_local_synced": .int(0),
            "usn": .null, "rb_local_usn": .int(usn), "created_at": .text(stamp.db), "updated_at": .text(stamp.db),
        ]
    }

    /// 이 라이브러리의 공통값(곡 행마다 같은 값)
    static func libraryIdentity(_ db: CipherDatabase) throws -> (masterDBID: String, deviceID: String) {
        var result: (String, String)?
        try db.query("""
            SELECT MasterDBID, DeviceID, count(*) AS n FROM djmdContent
            WHERE rb_local_deleted = 0 AND MasterDBID IS NOT NULL AND DeviceID IS NOT NULL AND DeviceID != ''
            GROUP BY MasterDBID, DeviceID ORDER BY n DESC LIMIT 1
            """) { result = ($0.string(0) ?? "", $0.string(1) ?? "") }
        guard let result, !result.0.isEmpty else {
            throw DJCError.writeRefused(String(ui: "컬렉션에 곡이 하나도 없어 이 라이브러리의 기기 정보를 알 수 없습니다. rekordbox에서 곡을 하나 넣은 뒤 다시 시도하세요"))
        }
        return result
    }

    static func findOrCreate(_ db: CipherDatabase, table: String, name: String, usn: inout Int, stamp: (db: String, json: String)) throws -> String {
        var existing: String?
        try db.query("SELECT ID FROM \(table) WHERE Name = ? AND rb_local_deleted = 0 ORDER BY created_at LIMIT 1", [.text(name)]) { existing = $0.string(0) }
        if let existing { return existing }
        let id = try newID(db, table: table, range: 1..<(1 << 32))
        usn += 1
        var row: [String: CipherDatabase.Value] = ["ID": .text(id), "Name": .text(name), "UUID": .text(UUID().uuidString.lowercased())]
        if table == "djmdArtist" { row["SearchStr"] = .null }
        try insert(db, table: table, row.merging(syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
        return id
    }

    static func findOrCreateAlbum(_ db: CipherDatabase, name: String, albumArtistID: String?, usn: inout Int,
                                  stamp: (db: String, json: String)) throws -> String {
        var existing: String?
        try db.query("SELECT ID FROM djmdAlbum WHERE Name = ? AND AlbumArtistID IS ? AND rb_local_deleted = 0 ORDER BY created_at LIMIT 1",
                     [.text(name), albumArtistID.map { .text($0) } ?? .null]) { existing = $0.string(0) }
        if let existing { return existing }
        return try insertAlbum(db, name: name, albumArtistID: albumArtistID, usn: &usn, stamp: stamp)
    }

    /// 새 앨범 행 하나(rekordbox가 만드는 모양: `ImagePath`·`SearchStr` NULL, `Compilation` 0, 상태 칸 0). 곡 넣기와 태그 쓰기(새 앨범·
    /// 동명 앨범 옮기기)가 같은 모양을 쓴다.
    static func insertAlbum(_ db: CipherDatabase, name: String, albumArtistID: String?, usn: inout Int,
                            stamp: (db: String, json: String)) throws -> String {
        let id = try newID(db, table: "djmdAlbum", range: 1..<(1 << 32))
        usn += 1
        let row: [String: CipherDatabase.Value] = ["ID": .text(id), "Name": .text(name), "AlbumArtistID": albumArtistID.map { .text($0) } ?? .null,
                                                   "ImagePath": .null, "Compilation": .int(0), "SearchStr": .null,
                                                   "UUID": .text(UUID().uuidString.lowercased())]
        try insert(db, table: "djmdAlbum", row.merging(syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
        return id
    }

    static func syncColumns(usn: Int, stamp: (db: String, json: String)) -> [String: CipherDatabase.Value] {
        ["rb_data_status": .int(0), "rb_local_data_status": .int(0), "rb_local_deleted": .int(0), "rb_local_synced": .int(0),
         "usn": .null, "rb_local_usn": .int(usn), "created_at": .text(stamp.db), "updated_at": .text(stamp.db)]
    }

    // MARK: - 삭제

    public static func delete(contentIDs: [String], from database: URL, shareRoot: URL? = nil,
                              dryRun: Bool, now: Date = .now, backups: URL, guard writeGuard: RekordboxWriteGuard = .system) throws -> Report {
        var report = Report(dryRun: dryRun)
        guard !contentIDs.isEmpty else { return report }
        let share = try preflight(database, shareRoot: shareRoot, dryRun: dryRun, guard: writeGuard)
        let live = writeGuard.isLive(database)
        let stamp = CueJSON.timestamps(now)
        let backup = dryRun ? nil : try RekordboxWriter.makeBackup(of: database, in: backups, now: now, label: "delete")
        report.backup = backup?.path
        var gone: [String] = []
        var files: [URL] = []
        var renumbered = Renumbered()
        report.finalUpdateCount = try transaction(database, dryRun: dryRun) { db, usn in
            for id in contentIDs {
                try db.execute("SAVEPOINT djc_delete")
                let savedRenumbered = renumbered
                var title = id
                do {
                    try db.query("SELECT Title FROM djmdContent WHERE ID = ?", [.text(id)]) { title = $0.string(0) ?? id }
                    let filePlan = try RekordboxWriter.deletionFiles(id, db: db, share: share)
                    var deleted = try deleteRow(id, db: db, usn: &usn, stamp: stamp, renumbered: &renumbered)
                    try RekordboxWriter.backupDeletionFiles(filePlan.files, in: backup, shareRoot: share)
                    deleted.reason = filePlan.warning
                    title = deleted.title
                    try db.execute("RELEASE djc_delete")
                    gone.append(id)
                    files += filePlan.files
                    report.deleted.append(deleted)
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_delete")
                    try db.execute("RELEASE djc_delete")
                    renumbered = savedRenumbered
                    report.deleted.append(Outcome(path: "", contentID: id, title: title, written: false, reason: blocked.reason))
                }
            }
            return !gone.isEmpty
        }
        // 백업은 시험 실행이 아닐 때만 있다
        guard let backup else { return report }
        guard !gone.isEmpty else {
            RekordboxWriter.prune(backups)
            return report
        }
        try afterCommit(database, backup: backup, live: live) { db in
            for id in gone where try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE ID = ?", [.text(id)]) != 0 {
                throw DJCError.writeVerificationFailed(String(ui: "지운 곡이 다시 읽혔습니다"))
            }
            try verifyRenumbered(renumbered, db: db)
        }
        do {
            try RekordboxWriter.removeOwnedFiles(files)
        } catch {
            throw RekordboxWriter.recover(from: error, database: database, backup: backup, live: live) {
                try RekordboxWriter.restoreAnalysis(from: backup,
                                                     shareRoot: share ?? database.deletingLastPathComponent().appending(path: "share"))
            }
        }
        report.removedFiles = files.map(\.path).sorted()
        try? save(report, in: backup, shareRoot: share)
        RekordboxWriter.prune(backups)
        return report
    }

    /// 뒤 순번을 당긴 행(표 이름 + 행 ID)이 쓴 뒤 가져야 할 순번·상태. 커밋 뒤 다시 읽어 비교한다(`verifyRenumbered`).
    struct RenumberKey: Hashable {
        var table: String
        var id: String
    }
    typealias Renumbered = [RenumberKey: (trackNo: Int, status: Int?)]

    /// 이미 열린 쓰기 트랜잭션에서 곡 하나를 뺀다. 합치기도 같은 삭제 규칙을 쓴다.
    /// - Parameter renumbered: 뒤 순번을 당긴 행의 기대 값. 같은 요청의 앞 곡이 이미 당긴 행은 그 기대 값에서 이어 가고(순번이 곡마다 줄어든다),
    ///   이 곡이 지우는 행은 뺀다. 막혀서 던지면 부른 쪽이 SAVEPOINT와 함께 되돌린다.
    static func deleteRow(_ id: String, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String),
                          renumbered: inout Renumbered) throws -> Outcome {
        var found: (title: String, path: String)?
        try db.query("SELECT Title, FolderPath FROM djmdContent WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) { r in
            found = (r.string(0) ?? "", r.string(1) ?? "")
        }
        guard let track = found else { throw Blocked(String(ui: "rekordbox 컬렉션에서 곡을 찾지 못했습니다")) }
        // 막는 검사는 모두 변경 번호(usn)를 쓰기 전에 한다: 막힌 곡이 번호를 가져가면 같은 요청의 다른 곡 번호가 밀린다.
        let orphans = try orphanedRows(db, contentID: id, gone: [id])
        if let reason = try removalBlock(of: id, orphans: orphans, renumbering: renumberedTables, db: db) { throw Blocked(reason) }
        usn += 1
        for (table, list) in renumberedTables {
            var entries: [(list: String, trackNo: Int)] = []
            try db.query("SELECT \(list), TrackNo, ID FROM \(table) WHERE ContentID = ?", [.text(id)]) {
                entries.append(($0.string(0) ?? "", $0.int(1) ?? 0))
                renumbered[RenumberKey(table: table, id: $0.string(2) ?? "")] = nil
            }
            _ = try db.run("DELETE FROM \(table) WHERE ContentID = ?", [.text(id)])
            try expectRenumbered(entries, table: table, list: list, db: db, into: &renumbered)
            // 같은 목록의 뒤 순번을 하나씩 당긴다(한 번호로 몰아서). 뒤에서부터 지운 순번만큼. 당기는 살아 있는 행(지운 표시가 남은 행이
            // 있으면 위에서 막았다)이 256이면 재생 목록 편집처럼 257로 올린다.
            for entry in entries.sorted(by: { $0.trackNo > $1.trackNo }) {
                _ = try db.run("""
                    UPDATE \(table) SET TrackNo = TrackNo - 1, rb_local_usn = ?, updated_at = ?, \(RekordboxWriter.savedStatus)
                    WHERE \(list) = ? AND TrackNo > ?
                    """, [.int(usn), .text(stamp.db), .text(entry.list), .int(entry.trackNo)])
            }
        }
        for table in ["djmdCue", "contentCue", "contentFile", "djmdMixerParam"] {
            _ = try db.run("DELETE FROM \(table) WHERE ContentID = ?", [.text(id)])
        }
        guard try db.run("DELETE FROM djmdContent WHERE ID = ?", [.text(id)]) == 1 else { throw Blocked(String(ui: "곡 행을 지우지 못했습니다")) }
        // 그 곡만 쓰던 앨범·아티스트(곡 행을 지우기 전에 센 목록, 상태 0임을 확인했다)
        for (table, rowID) in orphans.rows { _ = try db.run("DELETE FROM \(table) WHERE ID = ?", [.text(rowID)]) }
        guard try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE ID = ?", [.text(id)]) == 0 else {
            throw DJCError.writeVerificationFailed(String(ui: "곡 행이 남아 있습니다"))
        }
        return Outcome(path: track.path, contentID: id, title: track.title, written: true, reason: nil)
    }

    /// 순번을 당기기 전에(곡의 자기 행은 이미 지웠다) 뒤 항목이 가질 값을 센다. 순번은 그 앞에서 지운 항목 수만큼 줄고(한 목록에서 같은 곡이 여러 번
    /// 들었어도 그 수만큼), 상태는 256만 257이 된다(`savedState`). 순번이 NULL인 행은 당기는 UPDATE(`TrackNo > ?`)도 건드리지 않으므로 세지 않는다.
    static func expectRenumbered(_ entries: [(list: String, trackNo: Int)], table: String, list: String, db: CipherDatabase,
                                 into renumbered: inout Renumbered) throws {
        for target in Set(entries.map(\.list)).sorted() {
            let removed = entries.filter { $0.list == target }.map(\.trackNo)
            guard let first = removed.min() else { continue }
            var rows: [(id: String, trackNo: Int, status: Int?)] = []
            try db.query("SELECT ID, TrackNo, rb_data_status FROM \(table) WHERE \(list) = ? AND TrackNo > ?", [.text(target), .int(first)]) {
                rows.append(($0.string(0) ?? "", $0.int(1) ?? 0, $0.int(2)))
            }
            for row in rows {
                let key = RenumberKey(table: table, id: row.id)
                let before = renumbered[key] ?? (row.trackNo, row.status)
                renumbered[key] = (before.trackNo - removed.filter { $0 < row.trackNo }.count, RekordboxWriter.savedState(before.status))
            }
        }
    }

    /// 커밋 뒤(합치기는 쓰기 트랜잭션 안에서도) 당긴 행을 다시 읽어 순번·상태가 기대와 같은지 본다. 다르면 `writeVerificationFailed`.
    static func verifyRenumbered(_ renumbered: Renumbered, db: CipherDatabase) throws {
        for (key, expected) in renumbered {
            var read: (trackNo: Int?, status: Int?)?
            try db.query("SELECT TrackNo, rb_data_status FROM \(key.table) WHERE ID = ?", [.text(key.id)]) { read = ($0.int(0), $0.int(1)) }
            guard let read, read.trackNo == expected.trackNo, read.status == expected.status else {
                throw DJCError.writeVerificationFailed(String(ui: "곡을 뺀 뒤 당긴 재생 목록·이력 항목의 순번이나 상태가 쓴 값과 다릅니다"))
            }
        }
    }

    /// 이름·앨범 행을 가리키는 곡 행 칸(곡 빼기와 태그 쓰기가 같이 쓴다). 아티스트는 여기에 앨범의 `albumArtistColumn`도 더한다.
    static func contentReferenceColumns(table: NameTable) -> [String] {
        switch table {
        case .artist: ["ArtistID", "ComposerID", "OrgArtistID", "RemixerID"]
        case .album: ["AlbumID"]
        case .genre: ["GenreID"]
        }
    }
    /// 아티스트를 가리키는 앨범 칸
    static let albumArtistColumn = "AlbumArtistID"

    /// 곡 빼기에서 아무 곡도 안 쓰게 됐는지 보는 참조 수(지운 곡·앨범도 센다, 묶음 1·2 규칙). 칸 목록은 태그 쓰기와 같다.
    /// - Parameters:
    ///   - gone: 이 곡들은 이미 빠진 것으로 센다(지우는 곡, 합치기면 함께 빠지는 곡까지)
    ///   - droppedAlbum: 이 앨범은 이미 지운 것으로 센다
    static func referenceCount(_ db: CipherDatabase, artist: String, gone: Set<String> = [], droppedAlbum: String? = nil) throws -> Int {
        let columns = contentReferenceColumns(table: .artist).map { "\($0) = ?1" }.joined(separator: " OR ")
        var count = 0
        try db.query("SELECT ID FROM djmdContent WHERE \(columns)", [.text(artist)]) { if !gone.contains($0.string(0) ?? "") { count += 1 } }
        try db.query("SELECT ID FROM djmdAlbum WHERE \(albumArtistColumn) = ?", [.text(artist)]) { if $0.string(0) != droppedAlbum { count += 1 } }
        return count
    }

    static func referenceCount(_ db: CipherDatabase, album: String, gone: Set<String> = []) throws -> Int {
        let column = contentReferenceColumns(table: .album)[0]
        var count = 0
        try db.query("SELECT ID FROM djmdContent WHERE \(column) = ?", [.text(album)]) { if !gone.contains($0.string(0) ?? "") { count += 1 } }
        return count
    }

    /// 곡을 빼면 아무도 안 쓰게 되어 함께 지우는 앨범·아티스트 행(앨범 → 그 앨범 아티스트 → 곡의 아티스트 순).
    struct OrphanedRows {
        var album: String?
        var artists: [String] = []
        var rows: [(table: String, id: String)] {
            (album.map { [("djmdAlbum", $0)] } ?? []) + artists.map { ("djmdArtist", $0) }
        }
    }

    /// `contentID` 곡을 빼면 지우게 되는 앨범·아티스트 행. 지우기 전에 센다(곡 행이 아직 있어도 `gone`은 빠진 것으로 본다).
    /// `gone`: 이 곡과 같은 합치기에서 함께 빠지는 곡들.
    static func orphanedRows(_ db: CipherDatabase, contentID: String, gone: Set<String>) throws -> OrphanedRows {
        var albumID: String?
        var artistIDs: [String] = []
        try db.query("SELECT AlbumID, ArtistID, ComposerID, OrgArtistID, RemixerID FROM djmdContent WHERE ID = ?", [.text(contentID)]) { r in
            albumID = r.string(0)
            artistIDs = [1, 2, 3, 4].compactMap { r.string(Int32($0)) }
        }
        var orphans = OrphanedRows()
        if let albumID, try referenceCount(db, album: albumID, gone: gone) == 0 {
            orphans.album = albumID
            var albumArtist: String?
            try db.query("SELECT AlbumArtistID FROM djmdAlbum WHERE ID = ?", [.text(albumID)]) { albumArtist = $0.string(0) }
            if let albumArtist, try referenceCount(db, artist: albumArtist, gone: gone, droppedAlbum: albumID) == 0 { orphans.artists.append(albumArtist) }
        }
        for artist in Set(artistIDs).sorted() where !orphans.artists.contains(artist) {
            if try referenceCount(db, artist: artist, gone: gone, droppedAlbum: orphans.album) == 0 { orphans.artists.append(artist) }
        }
        return orphans
    }

    /// 곡 행에 딸려 지우는 행이 있는 표(곡 ID 칸은 모두 `ContentID`)
    static let ownRowTables = ["djmdCue", "contentCue", "contentFile", "djmdMixerParam", "djmdSongPlaylist", "djmdSongHistory"]

    /// 동기화 상태(`rb_data_status` ≠ 0, NULL 포함)인 행이 있는지
    static func isSynced(_ db: CipherDatabase, table: String, column: String, id: String) throws -> Bool {
        (try RekordboxWriter.scalar(db, "SELECT count(*) FROM \(table) WHERE \(column) = ? AND ifnull(rb_data_status, 1) != 0", [.text(id)]) ?? 1) > 0
    }

    /// 곡 행과 지울 딸린 행이 동기화 상태라 막는 이유(#196). 막을 게 없거나 컬렉션에 없는 곡이면 nil(없는 곡은 부른 쪽이 처리).
    /// rekordbox는 동기화 곡을 지울 때 행을 지우지 않고 삭제 표시로 남긴다. 규칙은 상태 0 시험 곡으로만 확인했다.
    static func syncedTrackBlock(of id: String, db: CipherDatabase) throws -> String? {
        guard try RekordboxWriter.scalar(db, "SELECT count(*) FROM djmdContent WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) == 1 else { return nil }
        if try isSynced(db, table: "djmdContent", column: "ID", id: id) { return syncedTrackReason }
        for table in ownRowTables where try isSynced(db, table: table, column: "ContentID", id: id) { return syncedRowsReason }
        return nil
    }

    /// 함께 지울 앨범·아티스트 행이 동기화 상태라 막는 이유
    static func syncedOrphanBlock(_ orphans: OrphanedRows, db: CipherDatabase) throws -> String? {
        for (table, rowID) in orphans.rows where try isSynced(db, table: table, column: "ID", id: rowID) { return syncedOrphanReason }
        return nil
    }

    /// 아직 규칙을 확인하지 않은 표(`unverifiedReferenceTables`, 추천 좋아요)에 걸린 곡이라 막는 이유
    static func unverifiedReferenceBlock(of id: String, db: CipherDatabase) throws -> String? {
        for table in unverifiedReferenceTables where try RekordboxWriter.scalar(db, "SELECT count(*) FROM \(table) WHERE ContentID = ?", [.text(id)]) ?? 0 > 0 {
            return String(ui: "\(table)에도 들어 있는 곡이라 아직 지우지 않습니다(rekordbox에서 지우세요)")
        }
        // 추천 좋아요는 곡을 가리키는 칸이 둘이라 따로 센다(안 막으면 지운 곡을 가리키는 행이 남는다)
        if try RekordboxWriter.scalar(db, "SELECT count(*) FROM \(recommendLikeTable) WHERE ContentID1 = ?1 OR ContentID2 = ?1", [.text(id)]) ?? 0 > 0 {
            return String(ui: "\(recommendLikeTable)에도 들어 있는 곡이라 아직 지우지 않습니다(rekordbox에서 지우세요)")
        }
        return nil
    }

    /// 곡을 빼며 뒤 순번을 당길 자리에 지운 표시가 남은 행(`rb_local_deleted` ≠ 0, NULL 포함)이 있어 막는 이유.
    /// 지운 표시 행의 순번을 어떻게 다뤄야 하는지 확인하지 못했다(곡의 자기 행은 먼저 지우므로 세지 않는다).
    static func syncedRenumberBlock(of id: String, tables: [(table: String, list: String)], db: CipherDatabase) throws -> String? {
        for (table, list) in tables {
            var entries: [(list: String, trackNo: Int)] = []
            try db.query("SELECT \(list), TrackNo FROM \(table) WHERE ContentID = ?", [.text(id)]) { entries.append(($0.string(0) ?? "", $0.int(1) ?? 0)) }
            for entry in entries where try RekordboxWriter.scalar(db, """
                SELECT count(*) FROM \(table) WHERE \(list) = ? AND TrackNo > ? AND ContentID IS NOT ? AND ifnull(rb_local_deleted, 1) != 0
                """, [.text(entry.list), .int(entry.trackNo), .text(id)]) ?? 0 > 0 {
                return syncedRenumberReason
            }
        }
        return nil
    }

    /// 곡 하나를 뺄 때 쓰기 전에 보는 막힘 전부(변경 번호를 쓰기 전에). 곡 빼기(`deleteRow`)와 합치기 사전 검사가 같이 쓴다.
    /// - Parameters:
    ///   - orphans: 이 곡을 빼면 함께 지울 앨범·아티스트 행(`orphanedRows`)
    ///   - renumbering: 뒤 순번을 당기는 표. 합치기는 원본의 재생 목록 항목을 검증된 목록 편집이 먼저 빼고 살아 있는 행만 다시 매기므로 이력만 본다.
    static func removalBlock(of id: String, orphans: OrphanedRows, renumbering: [(table: String, list: String)],
                             db: CipherDatabase) throws -> String? {
        if let reason = try syncedTrackBlock(of: id, db: db) { return reason }
        if let reason = try unverifiedReferenceBlock(of: id, db: db) { return reason }
        if let reason = try syncedOrphanBlock(orphans, db: db) { return reason }
        return try syncedRenumberBlock(of: id, tables: renumbering, db: db)
    }

    // MARK: - 공통

    struct Blocked: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// 라이브 DB면 rekordbox 꺼짐·WAL·버전, 어느 DB든 구조·카운터(백업 전에).
    static func preflight(_ database: URL, shareRoot: URL?, dryRun: Bool, guard writeGuard: RekordboxWriteGuard) throws -> URL? {
        let share = try writeGuard.checkTargets(database, shareRoot: shareRoot, dryRun: dryRun)
        let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        defer { reader.close() }
        try RekordboxCompatibility.checkSchema(reader)
        let counters = try RekordboxCompatibility.updateCounters(reader)
        if let local = counters.local { try RekordboxCompatibility.checkCounters(local: local, cloud: counters.cloud) }
        return share
    }

    /// 한 트랜잭션 안에서 `body`를 돌린다. 변경 카운터를 올려 적고, 시험 실행이거나 바뀐 게 없으면 되돌린다.
    /// 커밋했으면 마지막 변경 카운터를 돌려준다.
    @discardableResult
    static func transaction(_ database: URL, dryRun: Bool, _ body: (CipherDatabase, inout Int) throws -> Bool) throws -> Int? {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive(), writable: true)
        defer { db.close() }
        try db.execute("BEGIN IMMEDIATE")
        var finished = false
        defer { if !finished { try? db.execute("ROLLBACK") } }
        var usn = try RekordboxWriter.localUpdateCount(db)
        let start = usn
        let changed = try body(db, &usn)
        if usn != start {
            guard try db.run("UPDATE agentRegistry SET int_1 = ? WHERE registry_id = 'localUpdateCount'", [.int(usn)]) == 1 else {
                throw DJCError.writeVerificationFailed(String(ui: "변경 카운터를 올리지 못했습니다"))
            }
        }
        if dryRun || !changed {
            try db.execute("ROLLBACK")
            finished = true
            return nil
        }
        try db.execute("COMMIT")
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        finished = true
        return usn
    }

    /// 커밋 뒤 무결성 검사와 다시 읽기. 실패하면 백업으로 되돌린다(되돌리지 못하면 `restoreFailed`).
    static func afterCommit(_ database: URL, backup: URL, live: Bool, _ check: (CipherDatabase) throws -> Void) throws {
        do {
            try RekordboxWriter.checkIntegrity(of: database)
            let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { db.close() }
            try check(db)
        } catch {
            throw RekordboxWriter.recover(from: error, database: database, backup: backup, live: live)
        }
    }

    static func newID(_ db: CipherDatabase, table: String, range: Range<Int>) throws -> String {
        for _ in 0..<100 {
            let id = String(Int.random(in: range))
            if try RekordboxWriter.scalar(db, "SELECT count(*) FROM \(table) WHERE ID = ?", [.text(id)]) == 0 { return id }
        }
        throw DJCError.writeVerificationFailed(String(ui: "\(table) 새 ID를 만들지 못했습니다"))
    }

    static func insert(_ db: CipherDatabase, table: String, _ row: [String: CipherDatabase.Value]) throws {
        let keys = row.keys.sorted()
        let sql = "INSERT INTO \(table) (\(keys.map { "\"\($0)\"" }.joined(separator: ", "))) VALUES (\(keys.map { _ in "?" }.joined(separator: ", ")))"
        guard try db.run(sql, keys.map { row[$0]! }) == 1 else { throw DJCError.writeVerificationFailed(String(ui: "\(table) 행을 넣지 못했습니다")) }
    }

    /// 넣은 행을 다시 읽어 칸마다(형식까지) 비교한다.
    static func verify(_ db: CipherDatabase, table: String, id: String, _ expected: [String: CipherDatabase.Value]) throws {
        let keys = expected.keys.sorted()
        var ok = false
        try db.query("SELECT \(keys.map { "\"\($0)\", typeof(\"\($0)\")" }.joined(separator: ", ")) FROM \(table) WHERE ID = ?", [.text(id)]) { r in
            ok = keys.enumerated().allSatisfy { i, key in
                let type = r.string(Int32(i * 2 + 1))
                switch expected[key]! {
                case .null: return type == "null"
                case let .text(value): return type == "text" && r.string(Int32(i * 2)) == value
                case let .int(value): return type == "integer" && r.int(Int32(i * 2)) == value
                case let .real(value): return type == "real" && r.double(Int32(i * 2)) == value
                }
            }
        }
        guard ok else { throw DJCError.writeVerificationFailed(String(ui: "\(table) \(id) 행이 넣은 값과 다릅니다")) }
    }

    /// 백업 폴더의 곡 추가·삭제 보고서
    public static func report(in backup: URL) -> Report? {
        (try? Data(contentsOf: backup.appending(path: "track-report.json"))).flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
    }

    static func save(_ report: Report, in backup: URL, shareRoot: URL? = nil) throws {
        var report = report
        report.createdFiles = try RekordboxWriter.backupRelativePaths(report.createdFiles, shareRoot: shareRoot)
        report.removedFiles = try RekordboxWriter.backupRelativePaths(report.removedFiles, shareRoot: shareRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: backup.appending(path: "track-report.json"), options: .atomic)
    }
}

/// 곡 행이 이름으로 가리키는 이름·앨범 표. 표 이름 글자 대신 쓴다(모르는 표가 조용히 다른 표의 칸으로 읽히지 않게, 칸 목록에 기본값이 없다).
enum NameTable: String {
    case artist = "djmdArtist"
    case album = "djmdAlbum"
    case genre = "djmdGenre"
}
