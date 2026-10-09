import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 곡을 넣을 때 사용자가 확인한 키도 함께 쓴다(#5, 2026-10-04).
///
/// 새 실험이 아니라 확인한 두 동작을 한 트랜잭션에 잇는다: rekordbox가 곡을 넣고(2026-09-26 묶음 1·2, 분석 포함은 같은 날 아트워크 세션) →
/// 사용자가 정보 패널에서 키를 저장한다(2026-10-04 묶음 2 S1, #173 S1 T13·S2 U10·S5 K1). 그래서 "넣기 + 키를 한 번에" 쓴 DB는
/// "넣은 뒤 따로 키를 쓴" DB와 칸 단위로 같아야 한다(난수 ID·UUID·시각은 빼고, 변경 번호는 순서로 본다).
/// 넣는 곡은 같은 쓰기에서 재생 목록에 들어가지 않으므로(목록 연결은 뒤의 재생 목록 초안) 키를 써도 `masterPlaylists6.xml`은 그대로다.
@Suite("rekordbox 곡 넣기 + 키")
struct RekordboxTrackAddKeyTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    static let startUSN = 3000
    static let xml = """
        <?xml version="1.0" encoding="UTF-8"?>\r\n<MASTER_PLAYLIST Version="3.0.0" AutomaticSync="0">\r\n  <PLAYLISTS>\r\n\
            <NODE Id="3E9" ParentId="0" Attribute="0" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>\r\n  </PLAYLISTS>\r\n</MASTER_PLAYLIST>\r\n
        """

    /// 같은 모양의 라이브러리: 기존 곡 하나(라이브러리 공통값, 목록 하나에 듦) + 실험 라이브러리 모양의 키 줄 + DB 옆 XML
    func library(extraKeys: [(id: String, name: String, deleted: Int)] = []) throws -> RekordboxFixture {
        let fixture = try RekordboxFixture(localUpdateCount: Self.startUSN)
        try fixture.add(TrackSpec(id: "500", uuid: "00000000-0000-4000-8000-000000000500"))
        // 두 라이브러리가 같도록 난수 없이 넣는다(PlaylistSpec은 UUID를 난수로 만든다)
        try fixture.insert("djmdPlaylist", ["ID": .text("1001"), "Seq": .int(1), "Name": .text("기존 목록"), "Attribute": .int(0),
                                            "ParentID": .text("root"), "UUID": .text("p-1001"), "rb_data_status": .int(256),
                                            "rb_local_deleted": .int(0), "rb_local_usn": .int(20)])
        try fixture.insert("djmdSongPlaylist", ["ID": .text("sp-1"), "PlaylistID": .text("1001"), "ContentID": .text("500"), "TrackNo": .int(1),
                                                "UUID": .text("sp-u1"), "rb_data_status": .int(256), "rb_local_deleted": .int(0),
                                                "rb_local_usn": .int(22)])
        for row in RekordboxTagWriterTests.keyRows + extraKeys {
            try fixture.insert("djmdKey", ["ID": .text(row.id), "ScaleName": .text(row.name), "Seq": .int(1), "UUID": .text("k-\(row.id)"),
                                           "rb_data_status": .int(row.deleted == 1 ? 262 : 256), "rb_local_deleted": .int(row.deleted),
                                           "rb_local_usn": .int(157_637)])
        }
        try Self.xml.write(to: fixture.root.appending(path: "masterPlaylists6.xml"), atomically: true, encoding: .utf8)
        return fixture
    }

    /// 태그가 없는 WAV(이름 행이 생기지 않는다). 두 라이브러리가 같은 음원을 넣도록 한 곳에 만든다.
    func plan(in fixture: RekordboxFixture, name: String = "key on add.wav") async throws -> TrackAddPlan {
        let wav = try AudioFixture.wav(seconds: 20, in: fixture.audio, name: name)
        return try TrackAddPlan.make(url: wav, tags: try await AudioTags.read(url: wav), now: now)
    }

    let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], loudness: -8, peak: 0.9)
    let cues = [EditableCue(kind: .memory, time: 1.373), EditableCue(kind: .hot(0), time: 10.973)]

    /// 표마다 행을 칸 값(`quote`)으로 읽어 난수·시각을 걷어낸다. `agentRegistry`는 읽지 않는다(카운터는 따로 본다).
    /// - 쓰기 전에 없던 행의 `ID`·`UUID` → "<새>", 넣은 곡 ID(칸 전체) → "<곡>", 곡 UUID(세 표기) → "<UUID>", share 경로 → "<share>"
    /// - `created_at`·`updated_at`은 빼고, 이번에 받은 변경 번호(시작 카운터보다 큰 `rb_local_usn`)는 순위 "#n"으로 바꾼다.
    /// - `contentCue.Cues`(JSON)는 큐 ID가 난수라 빼고 `rb_cue_count`로 본다.
    struct Dump: Equatable, CustomStringConvertible {
        var tables: [String: [String]]
        var description: String { tables.sorted { $0.key < $1.key }.map { "\($0.key):\n  " + $0.value.joined(separator: "\n  ") }.joined(separator: "\n") }
    }

    func ids(_ fixture: RekordboxFixture) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (table, rows) in try rawTables(fixture) { result[table] = Set(rows.compactMap { $0["ID"] }) }
        return result
    }

    func rawTables(_ fixture: RekordboxFixture) throws -> [String: [[String: String]]] {
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        var names: [String] = []
        try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
            if let name = $0.string(0), name != "agentRegistry" { names.append(name) }
        }
        var tables: [String: [[String: String]]] = [:]
        for name in names {
            var columns: [String] = []
            try db.query("PRAGMA table_info(\(name))") { if let column = $0.string(1) { columns.append(column) } }
            var rows: [[String: String]] = []
            try db.query("SELECT \(columns.map { "quote(\"\($0)\")" }.joined(separator: ", ")) FROM \(name)") { r in
                var row: [String: String] = [:]
                for (i, column) in columns.enumerated() { row[column] = r.string(Int32(i)) ?? "NULL" }
                rows.append(row)
            }
            tables[name] = rows
        }
        return tables
    }

    func dump(_ fixture: RekordboxFixture, before: [String: Set<String>], contentID: String, uuid: String) throws -> Dump {
        let raw = try rawTables(fixture)
        let fresh = Set(raw.values.flatMap { $0.compactMap { $0["rb_local_usn"].flatMap(Int.init) } }.filter { $0 > Self.startUSN })
        let rank = Dictionary(uniqueKeysWithValues: fresh.sorted().enumerated().map { ($1, "#\($0 + 1)") })
        let forms = [uuid, "\(uuid.prefix(3))/\(uuid.dropFirst(3))", "\(uuid.prefix(3))%2F\(uuid.dropFirst(3))"]
        var tables: [String: [String]] = [:]
        for (table, rows) in raw {
            let known = before[table] ?? []
            tables[table] = rows.map { row in
                let isNew = row["ID"].map { !known.contains($0) } ?? false
                return row.keys.sorted().compactMap { column -> String? in
                    guard column != "created_at", column != "updated_at", !(table == "contentCue" && column == "Cues") else { return nil }
                    var value = row[column] ?? "NULL"
                    if isNew, column == "ID" || column == "UUID" { value = "<새>" }
                    if value == "'\(contentID)'" { value = "<곡>" }
                    for form in forms { value = value.replacingOccurrences(of: form, with: "<UUID>") }
                    value = value.replacingOccurrences(of: fixture.shareRoot.path, with: "<share>")
                    if column == "rb_local_usn", let usn = Int(value), let r = rank[usn] { value = r }
                    return "\(column)=\(value)"
                }.joined(separator: " | ")
            }.sorted()
        }
        return Dump(tables: tables)
    }

    func content(_ fixture: RekordboxFixture, _ id: String) throws -> [String: String] {
        try #require(try fixture.rows("""
            SELECT quote(KeyID) AS KeyID, quote(TrackInfoUpdated) AS TrackInfoUpdated, rb_data_status, rb_local_usn, Analysed
            FROM djmdContent WHERE ID = ?
            """, [.text(id)]).first)
    }

    /// 따로 쓰기: 곡을 넣고(키 '0') → 넣은 곡에 키만 고친 태그 초안을 `RekordboxWriter.write`로 쓴다(정보 패널 키 저장과 같은 길).
    func addThenWriteKey(_ fixture: RekordboxFixture, _ plan: TrackAddPlan, key: String, analyses: [String: RekordboxTrackWriter.Analysis] = [:],
                         cues: [String: [EditableCue]] = [:]) throws -> (outcome: RekordboxTrackWriter.Outcome, key: RekordboxWriter.Report) {
        let added = try RekordboxTrackWriter.add([plan], analyses: analyses, cues: cues, to: fixture.database, shareRoot: fixture.shareRoot,
                                                 dryRun: false, now: now, backups: fixture.backups)
        let outcome = try #require(added.added.first)
        let id = try #require(outcome.contentID), uuid = try #require(outcome.uuid)
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        let base = try #require(try RekordboxWriter.currentTags(db: db, contentID: id))
        db.close()
        var draft = TagDraft(trackUUID: uuid, base: base)
        draft.fields.musicalKey = key
        let report = try RekordboxWriter.write(drafts: [], tags: [draft], to: fixture.database, dryRun: false, now: now,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        return (outcome, report)
    }

    func addWithKey(_ fixture: RekordboxFixture, _ plan: TrackAddPlan, key: String, analyses: [String: RekordboxTrackWriter.Analysis] = [:],
                    cues: [String: [EditableCue]] = [:], dryRun: Bool = false) throws -> RekordboxTrackWriter.Report {
        try RekordboxTrackWriter.add([plan], analyses: analyses, cues: cues, keys: [plan.path: key], to: fixture.database,
                                     shareRoot: fixture.shareRoot, dryRun: dryRun, now: now, backups: fixture.backups)
    }

    func xml(_ fixture: RekordboxFixture) throws -> String {
        try String(contentsOf: fixture.root.appending(path: "masterPlaylists6.xml"), encoding: .utf8)
    }

    // MARK: 한 번에 = 따로

    @Test func 분석_없이_넣으며_키를_쓰면_넣은_뒤_따로_키를_쓴_것과_같다() async throws {
        let sequential = try library(), batch = try library()
        let p = try await plan(in: sequential)
        let before = try ids(sequential)
        #expect(try ids(batch) == before)

        let (first, keyReport) = try addThenWriteKey(sequential, p, key: "8A")
        #expect(keyReport.tagWritten.count == 1 && keyReport.tagBlocked.isEmpty)
        let report = try addWithKey(batch, p, key: "8A")
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.keyWritten == "8A" && outcome.keyReason == nil)
        let id = try #require(outcome.contentID)

        // 묶음 2 S1: 분석 안 된 상태 0 곡의 키 넣기 = KeyID 8A 줄(글자), TrackInfoUpdated NULL → '1'(글자), 상태 0 그대로, 곡 행이 마지막 번호
        let row = try content(batch, id)
        #expect(row["KeyID"] == "'\(RekordboxTagWriterTests.keyID("8A"))'" && row["TrackInfoUpdated"] == "'1'")
        #expect(row["rb_data_status"] == "0" && row["Analysed"] == "0")
        #expect(try Int(row["rb_local_usn"] ?? "") == batch.localUpdateCount())
        #expect(report.finalUpdateCount == (try batch.localUpdateCount()))

        // 칸 단위로 같다(넣은 곡 ID·UUID는 각자 다른 난수라 자리표로)
        let a = try dump(sequential, before: before, contentID: try #require(first.contentID), uuid: try #require(first.uuid))
        let b = try dump(batch, before: before, contentID: id, uuid: try #require(outcome.uuid))
        #expect(a == b, "따로:\n\(a)\n한 번에:\n\(b)")
        #expect(try sequential.localUpdateCount() == batch.localUpdateCount(), "한 번에 써도 번호를 더 받지 않는다")
        // 넣는 곡은 아직 어느 목록에도 없어 키를 써도 재생 목록 XML은 그대로다
        #expect(try xml(batch) == Self.xml && xml(sequential) == Self.xml)
    }

    @Test func 분석과_큐까지_넣으며_키를_쓰면_넣은_뒤_따로_키를_쓴_것과_같다() async throws {
        let sequential = try library(), batch = try library()
        let p = try await plan(in: sequential)
        let before = try ids(sequential)

        let (first, keyReport) = try addThenWriteKey(sequential, p, key: "6A", analyses: [p.path: analysis], cues: [p.path: cues])
        #expect(keyReport.tagWritten.count == 1 && first.cuesWritten == 2)
        let report = try addWithKey(batch, p, key: "6A", analyses: [p.path: analysis], cues: [p.path: cues])
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.cuesWritten == 2 && outcome.keyWritten == "6A" && outcome.keyReason == nil)
        let id = try #require(outcome.contentID)

        // 분석까지 넣은 곡은 이미 '1'(첫 BPM/Grid)이라 키 저장으로 '2'. 분석 칸은 그대로다.
        let row = try content(batch, id)
        #expect(row["KeyID"] == "'\(RekordboxTagWriterTests.keyID("6A"))'" && row["TrackInfoUpdated"] == "'2'" && row["Analysed"] == "105")
        #expect(row["rb_data_status"] == "0")
        // 번호 순서: 오토게인 → 분석 파일 행 → 큐 기록 → 곡 행(키 저장이 마지막)
        let final = try batch.localUpdateCount()
        let cue = try #require(try batch.rows("SELECT rb_local_usn FROM contentCue WHERE ContentID = ?", [.text(id)]).first)
        let files = try batch.rows("SELECT rb_local_usn FROM contentFile WHERE ContentID = ?", [.text(id)]).compactMap { Int($0["rb_local_usn"] ?? "") }
        #expect(row["rb_local_usn"] == "\(final)" && cue["rb_local_usn"] == "\(final - 2)")
        #expect(files.count == 3 && files.allSatisfy { $0 < final - 2 })

        let a = try dump(sequential, before: before, contentID: try #require(first.contentID), uuid: try #require(first.uuid))
        let b = try dump(batch, before: before, contentID: id, uuid: try #require(outcome.uuid))
        #expect(a == b, "따로:\n\(a)\n한 번에:\n\(b)")
        #expect(try sequential.localUpdateCount() == batch.localUpdateCount())
        #expect(try xml(batch) == Self.xml)
        // 분석 파일도 바이트까지 같다
        let made = report.createdFiles.map { URL(filePath: $0) }
        #expect(made.count == 3)
        for file in made {
            let twin = URL(filePath: file.path.replacingOccurrences(of: batch.shareRoot.path, with: sequential.shareRoot.path)
                .replacingOccurrences(of: outcome.uuid!.prefix(3) + "/" + outcome.uuid!.dropFirst(3), with: first.uuid!.prefix(3) + "/" + first.uuid!.dropFirst(3)))
            #expect(try Data(contentsOf: file) == Data(contentsOf: twin), "\(file.lastPathComponent)")
        }
    }

    // MARK: 키가 막히면 키만

    /// 키 줄이 없거나(12B) 살아 있는 줄이 둘이거나(8A 하나 더) 삭제 표시 줄뿐이거나(7A) Camelot이 아닌 이름(Am)이면 키만 막는다.
    /// 따로 썼을 때도 곡 넣기는 되고 키 쓰기만 막히므로(같은 `resolveKeyID`), 한 번에 쓴 DB는 키 없이 넣은 DB와 같아야 한다.
    @Test(arguments: ["12B", "8A", "7A", "Am"]) func 키를_쓸_수_없으면_키만_막고_곡은_넣는다(key: String) async throws {
        let extra: [(id: String, name: String, deleted: Int)] = [("2000000008", "8A", 0), ("2000000007", "7A", 1)]
        let plain = try library(extraKeys: extra), batch = try library(extraKeys: extra)
        let p = try await plan(in: plain)
        let before = try ids(plain)
        let added = try RekordboxTrackWriter.add([p], to: plain.database, shareRoot: plain.shareRoot, dryRun: false, now: now, backups: plain.backups)
        let first = try #require(added.added.first)

        let report = try addWithKey(batch, p, key: key)
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.keyWritten == nil)
        #expect(outcome.keyReason?.isEmpty == false && outcome.keyReason?.contains("rekordbox") == true, "\(outcome.keyReason ?? "")")
        let id = try #require(outcome.contentID)
        let row = try content(batch, id)
        #expect(row["KeyID"] == "'0'" && row["TrackInfoUpdated"] == "NULL")

        let a = try dump(plain, before: before, contentID: try #require(first.contentID), uuid: try #require(first.uuid))
        let b = try dump(batch, before: before, contentID: id, uuid: try #require(outcome.uuid))
        #expect(a == b, "키 없이:\n\(a)\n한 번에:\n\(b)")
        #expect(try plain.localUpdateCount() == batch.localUpdateCount(), "막힌 키는 번호도 되돌린다")
    }

    @Test func 키를_비우면_아무것도_하지_않는다() async throws {
        // 넣는 곡의 키는 처음부터 '0'이라 비우기는 바꾸는 것이 없다(TrackInfoUpdated도 그대로 NULL).
        let plain = try library(), batch = try library()
        let p = try await plan(in: plain)
        let before = try ids(plain)
        let added = try RekordboxTrackWriter.add([p], to: plain.database, shareRoot: plain.shareRoot, dryRun: false, now: now, backups: plain.backups)
        let first = try #require(added.added.first)
        let report = try addWithKey(batch, p, key: "")
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.keyWritten == nil && outcome.keyReason == nil)
        let id = try #require(outcome.contentID)
        #expect(try content(batch, id)["TrackInfoUpdated"] == "NULL")
        #expect(try dump(plain, before: before, contentID: try #require(first.contentID), uuid: try #require(first.uuid))
                == dump(batch, before: before, contentID: id, uuid: try #require(outcome.uuid)))
    }

    // MARK: 미리 보기·되돌리기

    @Test func 시험_실행은_키까지_미리_보여_주고_DB는_그대로_둔다() async throws {
        let fixture = try library()
        let p = try await plan(in: fixture)
        let rows = try fixture.rows("SELECT * FROM djmdContent ORDER BY ID")
        let report = try addWithKey(fixture, p, key: "5A", analyses: [p.path: analysis], dryRun: true)
        #expect(report.added.first?.keyWritten == "5A" && report.backup == nil)
        let blocked = try addWithKey(fixture, p, key: "12B", dryRun: true)
        #expect(blocked.added.first?.written == true && blocked.added.first?.keyReason?.contains("12B") == true)
        #expect(try fixture.rows("SELECT * FROM djmdContent ORDER BY ID") == rows && fixture.localUpdateCount() == Self.startUSN)
    }

    @Test func 키까지_넣은_곡을_되돌리면_곡과_분석_파일이_함께_사라진다() async throws {
        let fixture = try library()
        let p = try await plan(in: fixture)
        let contents = try fixture.rows("SELECT * FROM djmdContent ORDER BY ID")
        let keys = try fixture.rows("SELECT * FROM djmdKey ORDER BY ID")
        let report = try addWithKey(fixture, p, key: "8A", analyses: [p.path: analysis], cues: [p.path: cues])
        #expect(report.added.first?.keyWritten == "8A")
        let created = report.createdFiles.map { URL(filePath: $0) }
        #expect(created.count == 3)
        let saved = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try fixture.rows("SELECT * FROM djmdContent ORDER BY ID") == contents && fixture.localUpdateCount() == Self.startUSN)
        #expect(try fixture.rows("SELECT * FROM djmdKey ORDER BY ID") == keys, "키 쓰기는 djmdKey를 고치지 않는다")
        #expect(try fixture.rows("SELECT * FROM djmdCue").isEmpty && fixture.rows("SELECT * FROM contentCue").isEmpty)
        #expect(created.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try xml(fixture) == Self.xml)
        // 되돌리기 직전 상태로 다시 되돌리면 키까지 돌아온다
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups)
        let id = try #require(report.added.first?.contentID)
        #expect(try content(fixture, id)["KeyID"] == "'\(RekordboxTagWriterTests.keyID("8A"))'")
    }

    /// #197: 분석 없이 키와 함께 넣은 곡은 `TrackInfoUpdated`가 '1'이 된다(만든 것은 DJCrate). 이후 분석 붙이기가 막힐 때 이유 문구가
    /// "rekordbox에서 곡 정보를 고친 적이 있는…"이면 사실과 다르다. 카운터를 누가 만들었는지는 DB로 알 수 없어 중립으로 적고 할 일(rekordbox 분석)을 남긴다.
    @Test func 키와_함께_분석_없이_넣은_곡의_분석_붙이기_막힘_이유는_사실과_맞다() async throws {
        let fixture = try library()
        let p = try await plan(in: fixture)
        let report = try addWithKey(fixture, p, key: "8A")
        let outcome = try #require(report.added.first)
        let id = try #require(outcome.contentID), uuid = try #require(outcome.uuid)
        #expect(outcome.keyWritten == "8A" && outcome.written)
        #expect(try content(fixture, id)["TrackInfoUpdated"] == "'1'", "키를 쓰면 곡 정보 카운터가 생긴다")
        let before = try fixture.rows("SELECT * FROM djmdContent ORDER BY ID")
        let attached = try RekordboxWriter.write(drafts: [], grids: [GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])],
                                                 gains: [:], analysisInputs: [uuid: .init(duration: p.duration, loudness: nil, peak: 1)], to: fixture.database,
                                                 dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot, attachesAnalysis: true)
        #expect(attached.analysisWritten.isEmpty, "막힌 조건은 그대로 막는다")
        let reason = try #require(attached.analysisBlocked.first?.reason)
        #expect(!reason.contains("고친 적"), "DJCrate가 만든 카운터를 rekordbox에서 고친 것처럼 적지 않는다: \(reason)")
        #expect(reason.contains("rekordbox에서 트랙 분석을 하세요"), "\(reason)")
        #expect(try fixture.rows("SELECT * FROM djmdContent ORDER BY ID") == before)
    }

    /// #197: 키가 막히면 곡은 키 없이 들어가고, 앱은 고른 키를 새 곡의 키 초안으로 남긴다. 그 초안의 기준(base)은 쓰기 결과에서 와야 한다:
    /// 쓰기 직후 다시 읽기가 실패해도(rekordbox를 켬 등) 초안이 만들어져야 하고, 기준은 곡 행에서 읽은 값과 같아야 쓸 때 기준 어긋남으로 막히지 않는다.
    @Test func 막힌_키의_보고에는_곡을_넣은_뒤_읽은_기준_태그가_담긴다() async throws {
        let fixture = try library()
        let p = try await plan(in: fixture)
        let blocked = try #require(try addWithKey(fixture, p, key: "12B").added.first)
        #expect(blocked.written && blocked.keyWritten == nil && blocked.keyReason != nil)
        let id = try #require(blocked.contentID)
        let db = try CipherDatabase(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let stored = try #require(try RekordboxWriter.currentTags(db: db, contentID: id))
        #expect(blocked.keyBase == stored && stored.musicalKey == "", "쓰기 결과의 기준이 곡 행에서 읽은 값과 같다")

        // 키를 쓴 곡·키를 주지 않은 곡에는 기준이 없다(할 일이 없다)
        let second = try await plan(in: fixture, name: "key base second.wav")
        let written = try #require(try addWithKey(fixture, second, key: "8A").added.first)
        #expect(written.keyWritten == "8A" && written.keyBase == nil)
        let third = try await plan(in: fixture, name: "key base third.wav")
        let plain = try #require(try RekordboxTrackWriter.add([third], to: fixture.database, shareRoot: fixture.shareRoot, dryRun: false,
                                                              now: now, backups: fixture.backups).added.first)
        #expect(plain.written && plain.keyBase == nil)
    }

    @Test func 기준_태그가_없는_옛_보고서도_읽는다() throws {
        let old = try JSONDecoder().decode(RekordboxTrackWriter.Outcome.self, from: Data(#"{"path":"p","title":"t","written":true,"keyReason":"이유"}"#.utf8))
        #expect(old.keyReason == "이유" && old.keyBase == nil)
    }
}
