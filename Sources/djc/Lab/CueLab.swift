import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AVFoundation
import Foundation

/// 큐·DB 쓰기 규칙을 알아낼 때 쓴 실험(읽기 전용이거나 사본에만 쓴다).
enum CueLab {
    static let all: [Command] = [
        Command("cue-columns", nil, "djmdCue 칸 구성과 종류별 예시(개발용, 스냅샷 읽기 전용)", CueLab.cueColumns),
        Command("write-probe", nil, "직접 쓰기 설계를 위한 읽기 전용 조사(스냅샷 사본)", CueLab.writeProbe),
        Command("cue-consistency", nil, "djmdCue 행과 contentCue JSON이 같은지, JSON에 어떤 칸이 들어가는지(읽기 전용)", CueLab.cueConsistency),
        Command("cue-fields", nil, "rb_cue_count의 뜻과 MP3 큐의 MPEG 칸(읽기 전용)", CueLab.cueFields),
        Command("db-diff", "<전.db> <후.db>", "두 스냅샷 사본의 모든 표를 행·칸 단위로 비교한다(읽기 전용)", CueLab.dbDiff),
        Command("cue-json", nil, "한 곡의 contentCue JSON 원문(읽기 전용)", CueLab.cueJson),
        Command("cue-rows-probe", nil, "사본 DB의 큐 행 원문(읽기 전용)", CueLab.cueRowsProbe),
        Command("sql", "<사본.db> <SELECT…>", "스냅샷 사본에 읽기 전용 SELECT(개발용)", CueLab.sql),
        Command("loop-repro", "--old <실험 전.db> --new <실험 뒤.db> --ids <ContentID,…> --work <폴더>", "rekordbox 루프 실험을 사본에 재현해 칸마다 비교", CueLab.loopRepro),
        Command("cue-write-selftest", nil, "사본 DB에서 기존 큐 지우기·옮기기·핫큐 추가·막힘 조건을 시험한다(개발용, 사본만)", CueLab.cueWriteSelftest),
        Command("vbr-dump", nil, "VBR MP3 큐와 파일 구조를 JSON으로(규칙 맞추기용, 읽기 전용)", CueLab.vbrDump),
        Command("gain-write-test", nil, "사본 DB에 오토게인을 써 본다", CueLab.gainWriteTest),
        Command("vbr-cue-repro", "--work <폴더> [--limit N]", "VBR MP3 곡의 기존 큐를 사본에서 지우고 같은 시각으로 다시 써 rekordbox가 적은 칸과 비교(사본만)", CueLab.vbrCueRepro),
        Command("seekinfo-check", nil, "rekordbox가 적은 FLAC SeekInfo·VBR MP3 MPEG 위치를 우리 계산과 전수 대조(읽기 전용)", CueLab.seekinfoCheck),
        Command("cue-json-roundtrip", nil, "라이브러리의 모든 contentCue JSON을 읽고 다시 써서 원문과 같은지(읽기 전용)", CueLab.cueJsonRoundtrip),
        Command("eval-cues", nil, "섹션 경계 메모리 큐 후보를 직접 찍은 큐와 비교", CueLab.evalCues),
    ]

    /// djmdCue 칸 구성과 종류별 예시(개발용, 스냅샷 읽기 전용)
    static func cueColumns(_ args: [String]) async throws {
        let snapshot = try LibrarySnapshot.latest()
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        try db.query("PRAGMA table_info(djmdCue)") { row in print("  칸", row.string(1) ?? "", row.string(2) ?? "") }
        try db.query("""
            SELECT Kind, count(*), sum(OutMsec > 0), sum(ifnull(Color, -1) >= 0), sum(ifnull(ColorTableIndex, 0) > 0),
                   sum(length(ifnull(Comment, '')) > 0), sum(ifnull(ActiveLoop, 0) > 0)
            FROM djmdCue WHERE rb_local_deleted = 0 GROUP BY Kind ORDER BY Kind
            """) { row in
            print("  Kind \(row.int(0) ?? -1): \(row.int(1) ?? 0)개 · 루프(OutMsec>0) \(row.int(2) ?? 0) · Color \(row.int(3) ?? 0) · ColorTableIndex \(row.int(4) ?? 0) · 이름 \(row.int(5) ?? 0) · ActiveLoop \(row.int(6) ?? 0)")
        }
        try db.query("""
            SELECT Kind = 0, ifnull(Color, -1), ifnull(ColorTableIndex, -1), count(*) FROM djmdCue WHERE rb_local_deleted = 0
            GROUP BY 1, 2, 3 ORDER BY 1, 4 DESC LIMIT 30
            """) { row in print("  \(row.int(0) == 1 ? "메모리" : "핫큐") Color \(row.int(1) ?? -9) · ColorTableIndex \(row.int(2) ?? -9) · \(row.int(3) ?? 0)개") }
        try db.query("""
            SELECT Kind, InMsec, OutMsec, Color, ColorTableIndex, Comment, ActiveLoop, BeatLoopSize, InFrame, InMpegFrame
            FROM djmdCue WHERE rb_local_deleted = 0 AND OutMsec > 0 LIMIT 3
            """) { row in print("  루프 예:", (Int32(0)..<10).map { row.string($0) ?? "nil" }.joined(separator: " | ")) }
    }

    /// 직접 쓰기 설계를 위한 읽기 전용 조사(스냅샷 사본)
    static func writeProbe(_ args: [String]) async throws {
        let snapshot = try LibrarySnapshot.latest()
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        try db.query("SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%Cue%' OR name LIKE '%egistry%' OR name LIKE 'content%')") { print("표:", $0.string(0) ?? "") }
        try db.query("SELECT rb_local_deleted, count(*) FROM djmdCue GROUP BY 1") { print("  djmdCue 삭제표시", $0.int(0) ?? -1, $0.int(1) ?? 0) }
        try db.query("SELECT max(rb_local_usn), max(usn) FROM djmdCue") { print("  djmdCue 최대 usn", $0.string(0) ?? "", $0.string(1) ?? "") }
        try db.query("PRAGMA table_info(contentCue)") { print("  contentCue 칸", $0.string(1) ?? "", $0.string(2) ?? "") }
        if args.count > 1 {
            let id = args[1]
            try db.query("SELECT * FROM djmdCue WHERE ContentID = '\(id)' AND rb_local_deleted = 0 ORDER BY InMsec LIMIT 4") { r in
                print("  큐 행:", (Int32(0)..<29).map { r.string($0) ?? "nil" }.joined(separator: " | "))
            }
            try db.query("SELECT * FROM contentCue WHERE ContentID = '\(id)'") { r in
                print("  contentCue:", (Int32(0)..<12).map { String((r.string($0) ?? "nil").prefix(700)) }.joined(separator: " | "))
            }
            try db.query("SELECT ID, FileType, SampleRate, BitRate, BPM, AnalysisDataPath, rb_local_usn, usn, updated_at FROM djmdContent WHERE ID = '\(id)'") { r in
                print("  content:", (Int32(0)..<9).map { r.string($0) ?? "nil" }.joined(separator: " | "))
            }
        }
    }

    /// djmdCue 행과 contentCue JSON이 같은지, JSON에 어떤 칸이 들어가는지(읽기 전용)
    static func cueConsistency(_ args: [String]) async throws {
        let snapshot = try LibrarySnapshot.latest()
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        var rowsByContent: [String: [String: (Int, Int, Int)]] = [:]
        try db.query("SELECT ContentID, ID, InMsec, Kind, OutMsec FROM djmdCue WHERE rb_local_deleted = 0") { r in
            rowsByContent[r.string(0) ?? "", default: [:]][r.string(1) ?? ""] = (r.int(2) ?? 0, r.int(3) ?? 0, r.int(4) ?? 0)
        }
        var keys: [String: Int] = [:], same = 0, differ = 0, samples: [String] = [], countMismatch = 0, total = 0
        var withName = "", withColor = "", withLoop = ""
        try db.query("SELECT ContentID, Cues, rb_cue_count, rb_local_deleted FROM contentCue") { r in
            guard r.int(3) == 0 else { return }
            total += 1
            let id = r.string(0) ?? ""
            guard let data = r.string(1)?.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            if array.count != (r.int(2) ?? -1) { countMismatch += 1 }
            var json: [String: (Int, Int, Int)] = [:]
            for cue in array {
                for k in cue.keys { keys[k, default: 0] += 1 }
                json["\(cue["ID"] ?? "")"] = ((cue["InMsec"] as? Int) ?? 0, (cue["Kind"] as? Int) ?? 0, (cue["OutMsec"] as? Int) ?? 0)
                if withName.isEmpty, let c = cue["Comment"] as? String, !c.isEmpty { withName = String(describing: cue) }
                if withColor.isEmpty, let c = cue["ColorTableIndex"] as? Int, c > 0 { withColor = String(describing: cue) }
                if withLoop.isEmpty, let o = cue["OutMsec"] as? Int, o > 0 { withLoop = String(describing: cue) }
            }
            let db = rowsByContent[id] ?? [:]
            let matches = json.count == db.count && json.allSatisfy { entry in
                guard let row = db[entry.key] else { return false }
                return row.0 == entry.value.0 && row.1 == entry.value.1 && row.2 == entry.value.2
            }
            if matches { same += 1 } else {
                differ += 1
                if samples.count < 3 { samples.append("\(id): JSON \(json.count)개 · 행 \(db.count)개") }
            }
        }
        print("contentCue \(total)곡 · 행과 같음 \(same) · 다름 \(differ) · rb_cue_count 불일치 \(countMismatch)")
        print("다른 예:", samples)
        print("contentCue만 있고 행 없는 곡 수:", rowsByContent.count)
        print("JSON 칸:", keys.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("이름 있는 예:", withName.prefix(600))
        print("색 있는 예:", withColor.prefix(600))
        print("루프 예:", withLoop.prefix(600))
    }

    /// rb_cue_count의 뜻과 MP3 큐의 MPEG 칸(읽기 전용)
    static func cueFields(_ args: [String]) async throws {
        let snapshot = try LibrarySnapshot.latest()
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        var tallies: [String: Int] = [:]
        try db.query("""
            SELECT cc.rb_cue_count,
                   (SELECT count(*) FROM djmdCue c WHERE c.ContentID = cc.ContentID),
                   (SELECT count(*) FROM djmdCue c WHERE c.ContentID = cc.ContentID AND c.Kind = 0),
                   (SELECT count(*) FROM djmdCue c WHERE c.ContentID = cc.ContentID AND c.Kind > 0),
                   cc.rb_local_synced, cc.rb_data_status
            FROM contentCue cc WHERE cc.rb_local_deleted = 0
            """) { r in
            let n = r.int(0) ?? -1, all = r.int(1) ?? 0, memory = r.int(2) ?? 0, hot = r.int(3) ?? 0
            let label = n == all ? "전체와 같음" : n == memory ? "메모리 수" : n == hot ? "핫큐 수" : n == 0 ? "0" : "기타"
            tallies["rb_cue_count=\(label) · synced \(r.int(4) ?? -1) · status \(r.int(5) ?? -1)", default: 0] += 1
        }
        for (k, v) in tallies.sorted(by: { $0.value > $1.value }).prefix(12) { print("  \(k): \(v)") }
        try db.query("""
            SELECT c.InMsec, c.InFrame, c.InMpegFrame, c.InMpegAbs, c.OutMsec, c.OutFrame, c.OutMpegFrame, c.OutMpegAbs,
                   c.InPointSeekInfo, c.CueMicrosec, t.FileType, t.SampleRate, t.BitRate
            FROM djmdCue c JOIN djmdContent t ON t.ID = c.ContentID
            WHERE t.FileType = 1 AND (c.InMpegFrame != 0 OR c.InPointSeekInfo IS NOT NULL) LIMIT 5
            """) { r in print("  MP3 큐:", (Int32(0)..<13).map { String((r.string($0) ?? "nil").prefix(80)) }.joined(separator: " | ")) }
        try db.query("SELECT t.FileType, count(*), sum(c.InMpegFrame != 0), sum(c.InPointSeekInfo IS NOT NULL) FROM djmdCue c JOIN djmdContent t ON t.ID = c.ContentID GROUP BY 1") { r in
            print("  파일 종류 \(r.int(0) ?? -1): 큐 \(r.int(1) ?? 0) · MpegFrame≠0 \(r.int(2) ?? 0) · SeekInfo \(r.int(3) ?? 0)")
        }
        try db.query("SELECT InMsec, InFrame FROM djmdCue LIMIT 20000") { r in
            let ms = r.int(0) ?? 0, frame = r.int(1) ?? 0
            let floorMatch = frame == ms * 150 / 1000, roundMatch = frame == Int((Double(ms) * 0.15).rounded())
            tallies["InFrame: floor \(floorMatch) round \(roundMatch)", default: 0] += 1
        }
        for (k, v) in tallies where k.hasPrefix("InFrame") { print("  \(k): \(v)") }
    }

    /// 두 스냅샷 사본의 모든 표를 행·칸 단위로 비교한다(읽기 전용). 민감할 수 있는 값은 가린다.
    static func dbDiff(_ args: [String]) async throws {
        guard args.count > 2 else { throw UsageError() }
        let key = try RekordboxKey.derive()
        let before = try CipherDatabase.diagnostic(path: args[1], key: key), after = try CipherDatabase.diagnostic(path: args[2], key: key)
        var tables: [String] = []
        try after.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") { tables.append($0.string(0) ?? "") }
        func sensitive(_ table: String, _ column: String, _ rowKey: String) -> Bool {
            let text = (table + column + rowKey).lowercased()
            return ["credential", "token", "password", "secret", "auth", "session"].contains { text.contains($0) }
        }
        for table in tables {
            // 인증 표는 비교를 위해서도 읽지 않는다. 행 키 자체가 인증값일 수 있다.
            if CipherDatabase.isCredentialIdentifier(table) {
                print("■ \(table): (가림)")
                continue
            }
            var columns: [String] = [], pk: [Int] = []
            try after.query("PRAGMA table_info(\(table))") { r in
                let column = r.string(1) ?? ""
                guard !CipherDatabase.isCredentialIdentifier(column) else { return }
                columns.append(column)
                if (r.int(5) ?? 0) > 0 { pk.append(columns.count - 1) }
            }
            guard !columns.isEmpty else { continue }
            let keyColumns = pk.isEmpty ? (columns.firstIndex(of: "ID").map { [$0] } ?? []) : pk
            func load(_ db: CipherDatabase) throws -> [String: [String?]] {
                var rows: [String: [String?]] = [:]
                let select = "SELECT " + (keyColumns.isEmpty ? "rowid, " : "") + columns.map { "\"\($0)\"" }.joined(separator: ", ") + " FROM \(table)"
                try db.query(select) { r in
                    let offset: Int32 = keyColumns.isEmpty ? 1 : 0
                    let values = (0..<columns.count).map { r.string(Int32($0) + offset) }
                    let rowKey = keyColumns.isEmpty ? (r.string(0) ?? "") : keyColumns.map { values[$0] ?? "nil" }.joined(separator: "/")
                    rows[rowKey] = values
                }
                return rows
            }
            let a = (try? load(before)) ?? [:], b = try load(after)
            let added = b.keys.filter { a[$0] == nil }, removed = a.keys.filter { b[$0] == nil }
            let changed = b.keys.filter { key in a[key].map { $0 != b[key]! } ?? false }
            guard !added.isEmpty || !removed.isEmpty || !changed.isEmpty else { continue }
            print("■ \(table): 추가 \(added.count) · 삭제 \(removed.count) · 변경 \(changed.count)")
            func show(_ rowKey: String, _ values: [String?]) -> String {
                zip(columns, values).map { column, value in
                    let v = sensitive(table, column, rowKey) ? "(가림)" : String((value ?? "nil").prefix(column == "Cues" ? 60 : 90))
                    return "\(column)=\(v)"
                }.joined(separator: " | ")
            }
            for rowKey in added.sorted().prefix(6) { print("  + \(rowKey): \(show(rowKey, b[rowKey]!))") }
            for rowKey in removed.sorted().prefix(6) { print("  - \(rowKey): \(show(rowKey, a[rowKey]!))") }
            for rowKey in changed.sorted().prefix(8) {
                let diffs = columns.indices.filter { a[rowKey]![$0] != b[rowKey]![$0] }.map { i -> String in
                    let column = columns[i]
                    if sensitive(table, column, rowKey) { return "\(column): (바뀜)" }
                    let old = String((a[rowKey]![i] ?? "nil").prefix(column == "Cues" ? 40 : 90))
                    let new = String((b[rowKey]![i] ?? "nil").prefix(column == "Cues" ? 40 : 90))
                    return "\(column): \(old) → \(new)"
                }
                print("  ~ \(rowKey): \(diffs.joined(separator: " ; "))")
            }
        }
    }

    /// 한 곡의 contentCue JSON 원문(읽기 전용)
    static func cueJson(_ args: [String]) async throws {
        guard args.count > 2 else { return }
        let db = try CipherDatabase.diagnostic(path: args[1], key: RekordboxKey.derive())
        try db.query("SELECT Cues, rb_cue_count, rb_data_status, rb_local_synced FROM contentCue WHERE ContentID = '\(args[2])'") { r in
            print("rb_cue_count \(r.int(1) ?? -1) · status \(r.int(2) ?? -1) · synced \(r.int(3) ?? -1)")
            print(r.string(0) ?? "")
        }
        try db.query("SELECT CueUpdated, rb_data_status, rb_local_synced, UUID FROM djmdContent WHERE ID = '\(args[2])'") { r in
            print("content CueUpdated \(r.string(0) ?? "nil") · status \(r.int(1) ?? -1) · synced \(r.int(2) ?? -1)")
        }
    }

    static func cueRowsProbe(_ args: [String]) async throws {
        let db = try CipherDatabase.diagnostic(path: args[1], key: RekordboxKey.derive())
        try db.query("""
            SELECT count(*) FROM djmdContent t WHERE t.rb_local_deleted = 0
              AND NOT EXISTS (SELECT 1 FROM djmdCue c WHERE c.ContentID = t.ID)
            """) { print("큐 없는 곡:", $0.int(0) ?? 0) }
        try db.query("""
            SELECT count(*), sum(Cues = '[]'), sum(Cues IS NULL) FROM contentCue cc WHERE cc.rb_local_deleted = 0
              AND NOT EXISTS (SELECT 1 FROM djmdCue c WHERE c.ContentID = cc.ContentID)
            """) { print("큐 없는데 contentCue 있음:", $0.int(0) ?? 0, "빈 배열", $0.int(1) ?? 0, "NULL", $0.int(2) ?? 0) }
        try db.query("SELECT sum(ID = (SELECT UUID FROM djmdContent t WHERE t.ID = cc.ContentID)), count(*) FROM contentCue cc") { print("contentCue.ID = 곡 UUID:", $0.int(0) ?? 0, "/", $0.int(1) ?? 0) }
        try db.query("""
            SELECT ID, ContentID, rb_cue_count, UUID, rb_data_status, rb_local_data_status, rb_local_deleted, rb_local_synced, usn, rb_local_usn, created_at, updated_at
            FROM contentCue WHERE rb_data_status = 0 AND rb_local_synced = 0 ORDER BY created_at DESC LIMIT 2
            """) { r in print("로컬에서 만든 contentCue:", (Int32(0)..<12).map { r.string($0) ?? "nil" }.joined(separator: " | ")) }
        try db.query("SELECT Cues FROM contentCue WHERE Cues LIKE '%InPointSeekInfo%' LIMIT 1") { r in
            let text = r.string(0) ?? ""
            if let range = text.range(of: "InPointSeekInfo") {
                let lower = text.index(range.lowerBound, offsetBy: -160, limitedBy: text.startIndex) ?? text.startIndex
                let upper = text.index(range.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
                print("SeekInfo 주변:", String(text[lower..<upper]))
            }
        }
        try db.query("SELECT rb_data_status, count(*) FROM djmdContent WHERE rb_local_deleted = 0 GROUP BY 1") { print("djmdContent status \($0.int(0) ?? -1): \($0.int(1) ?? 0)") }
    }

    /// 스냅샷 사본에 읽기 전용 SELECT(개발용). 민감한 표(agentRegistry·자격 정보)는 막는다.
    static func sql(_ args: [String]) async throws {
        guard args.count > 2 else { throw UsageError() }
        let sql = args[2]
        guard sql.lowercased().hasPrefix("select") || sql.lowercased().hasPrefix("pragma table_info"),
              !["agentregistry", "credential", "token", "cloudagent"].contains(where: sql.lowercased().contains)
        else { print("허용하지 않는 쿼리"); return }
        let db = try CipherDatabase.diagnostic(path: args[1], key: RekordboxKey.derive())
        try db.query(sql) { r in print((Int32(0)..<Int32(r.count)).map { r.string($0) ?? "nil" }.joined(separator: " | ")) }
    }

    /// rekordbox 루프 실험 재현: 실험 전 사본(--old)에 실험 뒤(--new) 새로 생긴 큐를 DJCrate로 써 보고, rekordbox가 쓴 행·JSON과 칸마다 비교한다.
    static func loopRepro(_ args: [String]) async throws {
        guard let oldPath = value(after: "--old", in: args), let newPath = value(after: "--new", in: args),
              let ids = value(after: "--ids", in: args)?.components(separatedBy: ","),
              let work = value(after: "--work", in: args) else {
            throw UsageError()
        }
        let fm = FileManager.default
        let folder = try LabWorkFolder.reset(work)
        let copy = folder.appending(path: "master.db")
        try fm.copyItem(at: URL(filePath: oldPath), to: copy)
        let before = try RekordboxLibrary.load(snapshot: URL(filePath: oldPath))
        let after = try RekordboxLibrary.load(snapshot: URL(filePath: newPath))
        var drafts: [CueDraft] = []
        var added: [String: [Cue]] = [:]
        for id in ids {
            guard let track = before.tracks.first(where: { $0.id == id }), let newTrack = after.tracks.first(where: { $0.id == id }) else {
                print("곡 없음 \(id)"); continue
            }
            let oldIDs = Set(before.cues(for: track).map(\.id))
            let fresh = after.cues(for: newTrack).filter { !oldIDs.contains($0.id) }
            var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: before.cues(for: track))
            for cue in fresh {
                guard var editable = EditableCue(cue) else { print("편집 대상 아님: Kind \(cue.kind)"); continue }
                editable.id = UUID(); editable.sourceID = nil
                draft.place(editable)
            }
            added[id] = fresh
            drafts.append(draft)
            print("\(track.title.prefix(30)) · 새 큐 \(fresh.count) · 변경 \(draft.changes.count)")
        }
        let report = try RekordboxWriter.write(drafts: drafts, to: copy, dryRun: false, backups: folder.appending(path: "backups"))
        for outcome in report.outcomes {
            print(outcome.status == .written ? "✓" : "✗", outcome.title.prefix(30), outcome.reason ?? "")
        }
        // 칸마다 비교(ID·UUID·시각은 다를 수밖에 없다)
        let ours = try CipherDatabase.diagnostic(path: copy.path, key: RekordboxKey.derive())
        let theirs = try CipherDatabase.diagnostic(path: newPath, key: RekordboxKey.derive())
        func rows(_ db: CipherDatabase, _ sql: String, _ values: [CipherDatabase.Value]) throws -> [[String: String]] {
            var out: [[String: String]] = []
            try db.query(sql, values) { r in
                var row: [String: String] = [:]
                for i in 0..<r.count { row[r.name(Int32(i))] = r.string(Int32(i)) ?? "NULL" }
                out.append(row)
            }
            return out
        }
        let skip: Set<String> = ["ID", "UUID", "created_at", "updated_at", "usn", "rb_local_usn"]
        func maskJSON(_ text: String) -> String {
            text.replacingOccurrences(of: #""(ID|UUID|created_at|updated_at)":"[^"]*""#, with: "\"$1\":\"*\"", options: .regularExpression)
        }
        var differences = 0
        for (id, fresh) in added {
            let mine = try rows(ours, "SELECT * FROM djmdCue WHERE ContentID = ? ORDER BY InMsec, Kind", [.text(id)])
            let rb = try rows(theirs, "SELECT * FROM djmdCue WHERE ContentID = ? ORDER BY InMsec, Kind", [.text(id)])
            guard mine.count == rb.count else { print("  \(id) 큐 행 수 다름 \(mine.count) vs \(rb.count)"); differences += 1; continue }
            for (a, b) in zip(mine, rb) {
                for key in a.keys.sorted() where !skip.contains(key) && a[key] != b[key] {
                    print("  \(id) 큐 칸 \(key): DJCrate \(a[key]!) · rekordbox \(b[key] ?? "-")"); differences += 1
                }
            }
            let jsonA = try rows(ours, "SELECT * FROM contentCue WHERE ContentID = ?", [.text(id)])
            let jsonB = try rows(theirs, "SELECT * FROM contentCue WHERE ContentID = ?", [.text(id)])
            for (a, b) in zip(jsonA, jsonB) {
                for key in a.keys.sorted() where !skip.contains(key) {
                    let x = key == "Cues" ? maskJSON(a[key]!) : a[key]!, y = key == "Cues" ? maskJSON(b[key] ?? "") : b[key] ?? "-"
                    if x != y { print("  \(id) contentCue \(key):\n    DJCrate    \(x)\n    rekordbox \(y)"); differences += 1 }
                }
            }
            let cA = try rows(ours, "SELECT CueUpdated, rb_data_status, rb_local_data_status FROM djmdContent WHERE ID = ?", [.text(id)])
            let cB = try rows(theirs, "SELECT CueUpdated, rb_data_status, rb_local_data_status FROM djmdContent WHERE ID = ?", [.text(id)])
            if cA != cB { print("  \(id) djmdContent: DJCrate \(cA) · rekordbox \(cB)") }
            print("  \(id) 새 큐 \(fresh.count)개 비교 끝")
        }
        print(differences == 0 ? "행·JSON 모두 rekordbox와 같음(ID·UUID·시각·변경 번호 제외)" : "다른 칸 \(differences)개")
        ours.close(); theirs.close()

        // 2단계: 쓴 사본에서 루프 고치기(옮기기·활성 끄기/켜기·지우기·½박 메모리 루프). 쓰기 모듈의 검증을 통과해야 한다.
        let written = try RekordboxLibrary.load(snapshot: copy)
        var edits: [CueDraft] = []
        for (n, id) in ids.enumerated() {
            guard let track = written.tracks.first(where: { $0.id == id }) else { continue }
            var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: written.cues(for: track))
            guard var loop = draft.cues.first(where: { $0.loop != nil }) else { continue }
            if n == 0 {
                draft.remove(loop.id)   // 활성 루프 지우기
            } else {
                loop.time += 1; loop.loop?.end += 1; loop.loop?.active = true   // 옮기고 활성으로
                draft.place(loop)
                var half = EditableCue(id: UUID(), kind: .memory, time: 30)
                half.loop = EditableCue.Loop(end: 30.25, active: false, beats: 0.5)
                draft.place(half)
            }
            edits.append(draft)
            print("고치기 \(track.title.prefix(24)) · 변경 \(draft.changes.count)")
        }
        let second = try RekordboxWriter.write(drafts: edits, to: copy, dryRun: false, backups: folder.appending(path: "backups"))
        for outcome in second.outcomes {
            print(outcome.status == .written ? "✓" : "✗", outcome.title.prefix(30), "지움 \(outcome.removed) · 넣음 \(outcome.added)", outcome.reason ?? "")
        }
        let check = try RekordboxLibrary.load(snapshot: copy)
        for id in ids {
            guard let track = check.tracks.first(where: { $0.id == id }) else { continue }
            let loops = check.cues(for: track).filter(\.isLoop).map { "Kind \($0.kind) \($0.inMsec)~\($0.outMsec) 활성 \($0.activeLoop) BeatLoopSize \($0.beatLoopSize)" }
            print("  \(track.title.prefix(24)) 루프: \(loops.isEmpty ? "없음" : loops.joined(separator: " / "))")
        }
    }

    /// 사본 DB에서 기존 큐 지우기·옮기기·핫큐 추가·막힘 조건을 시험한다(개발용, 사본만).
    static func cueWriteSelftest(_ args: [String]) async throws {
        guard let path = value(after: "--db", in: args) else { throw UsageError() }
        let database = URL(filePath: path)
        try CLIGuards.refuseLiveDatabase(database)
        let library = try RekordboxLibrary.load(snapshot: database)
        let meta = try CipherDatabase.diagnostic(path: path, key: RekordboxKey.derive())
        var formats: [String: (Int, Int)] = [:]
        try meta.query("SELECT ID, FileType, BitRate FROM djmdContent") { formats[$0.string(0) ?? ""] = ($0.int(1) ?? 0, $0.int(2) ?? 0) }
        var seek: Set<String> = []
        try meta.query("SELECT DISTINCT ContentID FROM djmdCue WHERE InMpegFrame != 0 OR InPointSeekInfo IS NOT NULL") { seek.insert($0.string(0) ?? "") }
        var legacy: Set<String> = []
        try meta.query("SELECT ContentID FROM contentCue WHERE rb_cue_count IS NULL") { legacy.insert($0.string(0) ?? "") }
        meta.close()
        func editable(_ t: Track) -> Bool {
            guard let f = formats[t.id], !(seek.contains(t.id) && f.0 != 5), !t.isStreaming else { return false }
            return (f.0 == 1 && f.1 > 0) || f.0 == 4 || f.0 == 11 || (f.0 == 5 && args.contains("--flac"))
        }
        let candidates = library.tracks.filter { t in
            editable(t) && library.cues(for: t).filter { !$0.isAutoGenerated && !$0.isLoop && $0.activeLoop == 0 }.compactMap(EditableCue.init).count >= 3
        }
        let flacOnly = args.contains("--flac")
        let pool = flacOnly ? candidates.filter { formats[$0.id]?.0 == 5 } : candidates
        let newFormat = pool.filter { !legacy.contains($0.id) }.prefix(3)
        let oldFormat = pool.filter { legacy.contains($0.id) }.prefix(3)
        var drafts: [CueDraft] = []
        for (n, track) in (Array(newFormat) + Array(oldFormat)).enumerated() {
            var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: library.cues(for: track))
            let memories = draft.cues.filter { $0.kind == .memory }
            if let first = memories.first { draft.remove(first.id) }                  // 지우기
            if memories.count > 1 { var moved = memories[1]; moved.time += 0.5; moved.name = "DJCrate 옮김"; draft.place(moved) }  // 옮기기+이름
            let free = (0..<8).first { slot in !draft.cues.contains { $0.kind == .hot(slot) } }
            if let free { draft.place(EditableCue(id: UUID(), kind: .hot(free), time: 10 + Double(n), name: n == 0 ? "따옴표\"·역슬래시\\" : "")) }  // 핫큐 추가
            draft.place(EditableCue(id: UUID(), kind: .memory, time: 20.123 + Double(n)))        // 메모리 추가
            drafts.append(draft)
            print("시험 곡 \(track.title.prefix(24)) · \(legacy.contains(track.id) ? "옛 JSON" : "새 JSON") · 변경 \(draft.changes.count)")
        }
        // 막혀야 하는 경우: 초안 뒤 rekordbox가 바뀐 곡, VBR MP3, FLAC
        if let track = candidates.dropFirst(6).first {
            var stale = CueDraft(trackUUID: track.uuid, rekordboxCues: library.cues(for: track))
            stale.base[0].time += 1   // rekordbox 쪽 큐가 달라진 것처럼
            stale.place(EditableCue(id: UUID(), kind: .memory, time: 30))
            drafts.append(stale)
        }
        for (label, match) in [("VBR", { (f: (Int, Int)) in f.0 == 1 && f.1 == 0 }), ("FLAC", { (f: (Int, Int)) in f.0 == 5 })] {
            if let track = library.tracks.first(where: { formats[$0.id].map(match) ?? false }) {
                var d = CueDraft(trackUUID: track.uuid, rekordboxCues: library.cues(for: track))
                d.place(EditableCue(id: UUID(), kind: .memory, time: 12))
                drafts.append(d)
                print("막혀야 함(\(label)): \(track.title.prefix(24))")
            }
        }
        let report = try RekordboxWriter.write(drafts: drafts, to: database, dryRun: false,
                                               backups: database.deletingLastPathComponent().appending(path: "backups"))
        for o in report.outcomes {
            print("\(o.status.rawValue) \(o.title.prefix(24)) — 지움 \(o.removed) · 넣음 \(o.added)\(o.reason.map { " · \($0)" } ?? "")")
        }
        // 다시 읽어 초안과 같은지
        let after = try RekordboxLibrary.load(snapshot: database)
        for draft in drafts {
            guard report.outcomes.contains(where: { $0.trackUUID == draft.trackUUID && $0.status == .written }),
                  let track = after.tracks.first(where: { $0.uuid == draft.trackUUID }) else { continue }
            let now = CueDraft(trackUUID: track.uuid, rekordboxCues: after.cues(for: track)).cues
            let same = RekordboxWriter.key(now, withSource: false) == RekordboxWriter.key(RekordboxWriter.expectedCues(after: draft), withSource: false)
            print("재확인 \(track.title.prefix(24)): \(same ? "초안과 같음" : "다름!")")
        }
        print("백업:", report.backup ?? "")
    }

    /// VBR MP3 큐와 파일 구조를 JSON으로(규칙 맞추기용, 읽기 전용)
    static func vbrDump(_ args: [String]) async throws {
        let db = try CipherDatabase.diagnostic(path: value(after: "--db", in: args) ?? LibrarySnapshot.latest().path, key: RekordboxKey.derive())
        var byTrack: [String: (path: String, cues: [[Int]])] = [:]
        try db.query("""
            SELECT t.ID, t.FolderPath, c.InMsec, c.InMpegFrame, c.InMpegAbs, c.OutMsec, c.OutMpegFrame, c.OutMpegAbs FROM djmdCue c
            JOIN djmdContent t ON t.ID = c.ContentID WHERE t.FileType = 1 AND c.InMpegFrame != 0
            """) { r in
            byTrack[r.string(0) ?? "", default: (r.string(1) ?? "", [])].cues.append((2..<8).map { r.int(Int32($0)) ?? 0 })
        }
        var out: [[String: Any]] = []
        for (_, entry) in byTrack where FileManager.default.fileExists(atPath: entry.path) {
            guard let t = SeekInfo.mp3Frames(url: URL(filePath: entry.path)) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: entry.path)[.size] as? Int) ?? 0
            out.append(["name": (entry.path as NSString).lastPathComponent, "sr": t.sampleRate, "spf": t.samplesPerFrame,
                        "offsets": t.offsets.map { $0 - t.offsets[0] }, "first": t.offsets[0], "fileSize": size,
                        "info": t.hasInfoFrame, "xingFrames": t.xingFrames ?? -1, "xingBytes": t.xingBytes ?? -1,
                        "toc": t.toc.map { $0.map(Int.init) } ?? [], "cues": entry.cues])
        }
        let data = try JSONSerialization.data(withJSONObject: out)
        try data.write(to: URL(filePath: value(after: "--out", in: args) ?? "/dev/stdout"))
        print("곡 \(out.count)")
    }

    /// 사본 DB에 오토게인을 써 본다. DJCrate gain-write-test <사본.db> <UUID> <선형 게인>
    static func gainWriteTest(_ args: [String]) async throws {
        guard args.count > 3, let linear = Double(args[3]) else { throw UsageError() }
        let db = URL(filePath: args[1])
        try CLIGuards.refuseLiveDatabase(db)
        let report = try RekordboxWriter.write(drafts: [], gains: [args[2]: 20 * log10(Double(Float(linear)))], to: db, dryRun: false,
                                               backups: db.deletingLastPathComponent().appending(path: "backups"))
        for o in report.gainOutcomes ?? [] { print(o.status.rawValue, o.title, o.reason ?? "", o.added) }
    }

    /// VBR MP3 곡의 기존 큐(rekordbox가 적은 행)를 사본에서 지우고 같은 시각·종류로 DJCrate가 다시 써서 칸마다 비교한다.
    /// 색은 옮긴 큐가 아니라 새 큐로 넣으므로 비교하지 않는다.
    static func vbrCueRepro(_ args: [String]) async throws {
        guard let work = value(after: "--work", in: args) else { throw UsageError() }
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 50
        let fm = FileManager.default
        let folder = try LabWorkFolder.reset(work)
        let copy = folder.appending(path: "master.db")
        let original = try LibrarySnapshot.latest()
        try fm.copyItem(at: original, to: copy)
        let library = try RekordboxLibrary.load(snapshot: copy)
        var ids: [String] = []
        let meta = try CipherDatabase.diagnostic(path: copy.path, key: RekordboxKey.derive())
        try meta.query("""
            SELECT DISTINCT c.ContentID FROM djmdCue c JOIN djmdContent t ON t.ID = c.ContentID
            WHERE t.FileType = 1 AND c.InMpegFrame != 0 AND t.rb_local_deleted = 0 ORDER BY c.ContentID
            """) { ids.append($0.string(0) ?? "") }
        meta.close()
        var drafts: [CueDraft] = []
        var picked: [(id: String, uuid: String)] = []
        var skipped: [String: Int] = [:]
        for id in ids where picked.count < limit {
            guard let track = library.tracks.first(where: { $0.id == id }) else { skipped["목록에 없음", default: 0] += 1; continue }
            guard fm.fileExists(atPath: track.folderPath) else { skipped["파일 없음", default: 0] += 1; continue }
            var draft = CueDraft(trackUUID: track.uuid, rekordboxCues: library.cues(for: track))
            for cue in draft.cues {
                draft.remove(cue.id)
                var fresh = cue
                fresh.id = UUID(); fresh.sourceID = nil
                draft.place(fresh)
            }
            guard !draft.changes.isEmpty else { skipped["고칠 큐 없음", default: 0] += 1; continue }
            drafts.append(draft); picked.append((id, track.uuid))
        }
        if !skipped.isEmpty { print("건너뜀:", skipped.map { "\($0.key) \($0.value)" }.joined(separator: " · ")) }
        let report = try RekordboxWriter.write(drafts: drafts, to: copy, dryRun: false, backups: folder.appending(path: "backups"))
        let blocked = report.outcomes.filter { $0.status != .written }
        blocked.prefix(5).forEach { print("✗", $0.title.prefix(30), $0.reason ?? "") }
        let ours = try CipherDatabase.diagnostic(path: copy.path, key: RekordboxKey.derive())
        let theirs = try CipherDatabase.diagnostic(path: original.path, key: RekordboxKey.derive())
        defer { ours.close(); theirs.close() }
        let columns = ["InMsec", "InFrame", "InMpegFrame", "InMpegAbs", "OutMsec", "OutFrame", "OutMpegFrame", "OutMpegAbs", "Kind",
                       "InPointSeekInfo", "OutPointSeekInfo", "ActiveLoop", "BeatLoopSize"]
        func rows(_ db: CipherDatabase, _ id: String) throws -> [[String]] {
            var out: [[String]] = []
            try db.query("SELECT \(columns.joined(separator: ", ")) FROM djmdCue WHERE ContentID = ? AND Kind >= 0 ORDER BY InMsec, Kind", [.text(id)]) { r in
                out.append((0..<columns.count).map { r.string(Int32($0)) ?? "NULL" })
            }
            return out
        }
        var cues = 0, same = 0, mpegSame = 0, shown = 0
        // 옛 rekordbox는 루프가 아닌 큐에도 ActiveLoop·BeatLoopSize 0을 적었다(7.2는 NULL). 같은 것으로 본다.
        let loopColumns = Set(["ActiveLoop", "BeatLoopSize"].compactMap { columns.firstIndex(of: $0) })
        let mpegColumns = ["InMpegFrame", "InMpegAbs", "OutMpegFrame", "OutMpegAbs"].compactMap { columns.firstIndex(of: $0) }
        for (id, uuid) in picked where !blocked.contains(where: { $0.trackUUID == uuid }) {
            let mine = try rows(ours, id), rb = try rows(theirs, id)
            guard mine.count == rb.count else { print("  \(id) 큐 행 수 다름 \(mine.count) vs \(rb.count)"); continue }
            for (a, b) in zip(mine, rb) {
                cues += 1
                if mpegColumns.allSatisfy({ a[$0] == b[$0] }) { mpegSame += 1 }
                let differs = columns.indices.contains { i in a[i] != b[i] && !(loopColumns.contains(i) && Set([a[i], b[i]]) == ["NULL", "0"]) }
                if !differs { same += 1; continue }
                if shown < 10 {
                    shown += 1
                    let diff = columns.indices.filter { a[$0] != b[$0] && !loopColumns.contains($0) }.map { "\(columns[$0]) DJCrate \(a[$0]) · rekordbox \(b[$0])" }
                    print("  \(id) \(diff.joined(separator: " / "))")
                }
            }
        }
        print("VBR MP3 후보 \(ids.count)곡 중 \(picked.count)곡 다시 씀(막힘 \(blocked.count)) · 큐 \(cues)개 · MPEG 칸 같음 \(mpegSame) · 비교 칸 모두 같음 \(same)")
    }

    /// rekordbox가 적은 FLAC SeekInfo·VBR MP3 MPEG 위치를 우리 계산과 전수 대조(읽기 전용)
    static func seekinfoCheck(_ args: [String]) async throws {
        let db = try CipherDatabase.diagnostic(path: value(after: "--db", in: args) ?? LibrarySnapshot.latest().path, key: RekordboxKey.derive())
        defer { db.close() }
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 100_000
        var flac: [String: (path: String, cues: [(Int, String, String?, Int?)])] = [:]
        try db.query("""
            SELECT t.ID, t.FolderPath, c.InMsec, c.InPointSeekInfo, c.OutPointSeekInfo, c.OutMsec FROM djmdCue c JOIN djmdContent t ON t.ID = c.ContentID
            WHERE t.FileType = 5 AND c.InPointSeekInfo IS NOT NULL
            """) { r in
            let id = r.string(0) ?? ""
            flac[id, default: (r.string(1) ?? "", [])].cues.append((r.int(2) ?? 0, r.string(3) ?? "", r.string(4), r.int(5)))
        }
        var differ = 0, outDiffer = 0, missing = 0
        for (_, entry) in flac.prefix(limit) {
            guard FileManager.default.fileExists(atPath: entry.path), let table = SeekInfo.flacFrames(url: URL(filePath: entry.path)) else { missing += 1; continue }
            for (msec, stored, outStored, outMsec) in entry.cues {
                let floorSample = msec * table.sampleRate / 1000
                let roundSample = Int((Double(msec) * Double(table.sampleRate) / 1000).rounded())
                let a = SeekInfo.flacSeekInfo(frames: table.frames, sample: floorSample)
                let b = SeekInfo.flacSeekInfo(frames: table.frames, sample: roundSample)
                if a != stored && b != stored {
                    differ += 1
                    print("✘ 익명 FLAC 큐 \(differ): \(msec)ms · 저장 \(stored) · 현재 \(a ?? "없음")")
                    print("  이유: 현재 샘플이 든 프레임과 저장 SeekInfo가 다릅니다. 파일 변경·생성 규칙은 재분석 전후를 비교하세요")
                }
                if let outMsec, outMsec > 0, let outStored {
                    let o = SeekInfo.flacSeekInfo(frames: table.frames, sample: outMsec * table.sampleRate / 1000)
                    if o != outStored {
                        outDiffer += 1
                        print("✘ 익명 FLAC 루프 끝 \(outDiffer): 현재 프레임과 저장 SeekInfo가 다릅니다. 재분석 전후를 비교하세요")
                    }
                }
            }
        }
        print("FLAC: 큐 어긋남 \(differ) · 루프 끝 어긋남 \(outDiffer)")
        if missing > 0 { print("파일 없음·못 읽음으로 비교하지 못한 FLAC이 있습니다") }

        // VBR MP3: 큐마다 (시각, MPEG 칸) 쌍. 루프 끝도 같은 식으로 센다.
        var vbr: [String: (path: String, points: [(msec: Int, frame: Int, abs: Int)])] = [:]
        try db.query("""
            SELECT t.ID, t.FolderPath, c.InMsec, c.InMpegFrame, c.InMpegAbs, c.OutMsec, c.OutMpegFrame, c.OutMpegAbs FROM djmdCue c
            JOIN djmdContent t ON t.ID = c.ContentID WHERE t.FileType = 1 AND c.InMpegFrame != 0
            """) { r in
            let id = r.string(0) ?? ""
            vbr[id, default: (r.string(1) ?? "", [])].points.append((r.int(2) ?? 0, r.int(3) ?? 0, r.int(4) ?? 0))
            if let out = r.int(5), out > 0 { vbr[id]!.points.append((out, r.int(6) ?? 0, r.int(7) ?? 0)) }
        }
        var vbrDiffer = 0, vbrMissing = 0
        for (_, entry) in vbr.prefix(limit) {
            let url = URL(filePath: entry.path)
            guard FileManager.default.fileExists(atPath: entry.path), let frames = SeekInfo.mp3Frames(url: url) else { vbrMissing += 1; continue }
            let counted = SeekInfo.countedMp3Offsets(frames, url: url)
            for point in entry.points {
                let ours = SeekInfo.mp3CuePosition(msec: point.msec, counted: counted, sampleRate: frames.sampleRate, samplesPerFrame: frames.samplesPerFrame)
                if let ours, ours.mpegFrame == point.frame, ours.abs == point.abs { continue }
                vbrDiffer += 1
                print("✘ 익명 MP3 큐 \(vbrDiffer): \(point.msec)ms · 저장 \(point.frame)/\(point.abs) · 현재 \(ours.map { "\($0.mpegFrame)/\($0.abs)" } ?? "없음")")
                print("  이유: \(SeekDiagnostics.mp3Cue(stored: point.abs, counted: counted))")
                var analysis: String?
                try db.query("SELECT AnalysisDataPath FROM djmdContent WHERE FolderPath = ?", [.text(entry.path)]) { analysis = $0.string(0) }
                try TrackLab.diagnosticMetadata(db, path: entry.path, analysis: analysis.flatMap { RekordboxShare.analysisURL($0) })
            }
        }
        print("VBR MP3: 큐·루프 끝 MPEG 어긋남 \(vbrDiffer)")
        if vbrMissing > 0 { print("파일 없음·못 읽음으로 비교하지 못한 MP3가 있습니다") }
    }

    /// 라이브러리의 모든 contentCue JSON을 읽고 다시 써서 원문과 같은지(읽기 전용)
    static func cueJsonRoundtrip(_ args: [String]) async throws {
        let db = try CipherDatabase.diagnostic(path: args.count > 1 ? args[1] : LibrarySnapshot.latest().path, key: RekordboxKey.derive())
        var same = 0, differ = 0, failed = 0
        try db.query("SELECT ContentID, Cues FROM contentCue WHERE rb_local_deleted = 0") { r in
            guard let text = r.string(1) else { return }
            guard let objects = try? CueJSON.parse(text) else { failed += 1; return }
            let again = CueJSON.serialize(objects)
            if again == text { same += 1 } else {
                differ += 1
                if differ <= 2 {
                    let a = Array(text), b = Array(again)
                    let i = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
                    print("다름 \(r.string(0) ?? ""): 원문 …\(String(a[max(0, i - 60)..<min(a.count, i + 60)]))…\n       다시 …\(String(b[max(0, i - 60)..<min(b.count, i + 60)]))…")
                }
            }
        }
        print("원문과 같음 \(same) · 다름 \(differ) · 못 읽음 \(failed)")
    }

    static func evalCues(_ args: [String]) async throws {
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 30
        try await evaluateCues(limit: limit, snapshotPath: value(after: "--db", in: args))
    }

    // MARK: - 도움

    /// 직접 찍은 큐(자동 이름 제외)가 3개 이상인 로컬 곡을 UUID 순으로 뽑아 평가한다.
    static func evaluateCues(limit: Int, snapshotPath: String?) async throws {
        let snapshot = try snapshotPath.map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let sample = library.tracks
            .filter { !$0.isStreaming && FileManager.default.fileExists(atPath: $0.folderPath) }
            .filter { library.cues(for: $0).filter { !$0.isAutoGenerated }.count >= 3 }
            .sorted { $0.uuid < $1.uuid }
            .prefix(limit)

        var byBeat = CueEvaluation(), byQuarterSecond = CueEvaluation()
        var failures = 0
        var seconds: [Double] = []
        for (index, track) in sample.enumerated() {
            let started = Date()
            do {
                let analysis = try await PartAnalyzer.analyze(fileAt: URL(filePath: track.folderPath), cacheKey: track.uuid)
                seconds.append(Date().timeIntervalSince(started))
                // 같은 위치의 메모리 큐와 핫큐는 하나로 센다.
                var truth: [Double] = []
                for time in library.cues(for: track).filter({ !$0.isAutoGenerated }).map({ Double($0.inMsec) / 1000 }).sorted()
                where !truth.contains(where: { abs($0 - time) < 0.1 }) {
                    truth.append(time)
                }
                let predicted = MemoryCueSuggester.candidates(analysis)
                let beat = analysis.bpm.map { 60 / $0 } ?? 0.4
                let e1 = CueEvaluation(truth: truth, predicted: predicted, tolerance: beat)
                let e2 = CueEvaluation(truth: truth, predicted: predicted, tolerance: 0.25)
                byBeat = byBeat + e1
                byQuarterSecond = byQuarterSecond + e2
                print(String(format: "%3d  재현 %2d/%-2d  정밀 %2d/%-2d  %4.1fs  %@",
                             index + 1, e1.truthMatched, e1.truth, e1.predictedMatched, e1.predicted,
                             seconds.last!, String(track.comment.prefix(40))))
            } catch {
                failures += 1
                print(String(format: "%3d  실패: %@", index + 1, String(describing: error)))
            }
        }

        let average = seconds.isEmpty ? 0 : seconds.reduce(0, +) / Double(seconds.count)
        print(String(format: "\n곡 %d (실패 %d) · 곡당 분석 평균 %.1f초", sample.count, failures, average))
        print(String(format: "±1박:    재현율 %.1f%% (%d/%d) · 정밀도 %.1f%% (%d/%d)",
                     byBeat.recall * 100, byBeat.truthMatched, byBeat.truth,
                     byBeat.precision * 100, byBeat.predictedMatched, byBeat.predicted))
        print(String(format: "±0.25초: 재현율 %.1f%% · 정밀도 %.1f%%",
                     byQuarterSecond.recall * 100, byQuarterSecond.precision * 100))
    }
}
