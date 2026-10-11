import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 재생 기록 쓰기 규칙을 알아낼 때 쓰는 실험(#43). 사본에만 쓴다.
enum HistoryLab {
    static let all: [Command] = [
        Command("history-repro", "--old <실험 전.db> --new <실험 뒤.db> --work <새 폴더>",
                "rekordbox USB 기록 가져오기 실험을 실험 전 사본에 같은 기록으로 써서 rekordbox 결과와 칸마다 비교(사본만)", HistoryLab.repro),
    ]

    /// 표 하나(인증 칸은 뺀 칸 이름, 행 키 → 값). 행 키는 기본 키(없으면 ID, 그것도 없으면 rowid)다.
    struct Table {
        var columns: [String]
        var rows: [String: [String?]]
        /// SQLite 저장 형식과 값의 바이트 표현. TEXT·INTEGER가 같은 글자여도 다르게 비교한다.
        var storage: [String: [String]] = [:]

        func value(_ key: String, _ column: String) -> String? {
            guard let index = columns.firstIndex(of: column), let row = rows[key] else { return nil }
            return row[index]
        }

        func row(_ key: String) -> [String: String]? {
            rows[key].map { values in Dictionary(uniqueKeysWithValues: zip(columns, values.map { $0 ?? "NULL" })) }
        }

        func differingStorage(_ key: String, from other: Table, key otherKey: String, skip: Set<String>) -> [String] {
            let a = storage[key].map { Dictionary(uniqueKeysWithValues: zip(columns, $0)) } ?? [:]
            let b = other.storage[otherKey].map { Dictionary(uniqueKeysWithValues: zip(other.columns, $0)) } ?? [:]
            return Set(a.keys).union(b.keys).subtracting(skip).sorted().filter { a[$0] != b[$0] }
        }
    }

    static let historyTables: Set<String> = ["djmdHistory", "djmdSongHistory", "djmdContent"]

    /// 실험 전 사본에 rekordbox가 새로 가져온 기록(Attribute 0)을 같은 이름·시각·곡으로 쓰고(`RekordboxWriter.write(histories:)`,
    /// 쓰기 관문을 연 사본 실험), rekordbox가 쓴 실험 뒤 DB와 비교한다. 비교하지 않는 것: 기록·항목의 ID·UUID(난수, 모양만 본다), 변경 번호 값
    /// (순서만 본다, rekordbox의 빈 번호는 무시), created_at·updated_at(실행 시각). 인증 표·칸은 읽지 않는다. 출력에 칸 값은 기록 표만 찍는다.
    static func repro(_ args: [String]) async throws {
        guard let oldPath = value(after: "--old", in: args), let newPath = value(after: "--new", in: args),
              let workPath = value(after: "--work", in: args) else { throw UsageError() }
        let old = URL(filePath: oldPath), new = URL(filePath: newPath), requested = URL(filePath: workPath)
        try CLIGuards.refuseLiveDatabase(old)
        try CLIGuards.refuseLiveDatabase(new)
        // 실제 라이브 DB로 이어지는 하드 링크도 사본으로 받지 않는다.
        _ = try LibraryRead.resolve(database: old)
        _ = try LibraryRead.resolve(database: new)
        let fm = FileManager.default
        let folder = try refuseLibraryFolder(requested)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 쓸 사본(master.db)과 비교용 사본 둘(실험 전·뒤). 스냅샷 폴더의 원본은 복사만 한다.
        let target = folder.appending(path: "master.db")
        let before = folder.appending(path: "before/master.db"), after = folder.appending(path: "rekordbox/master.db")
        try copyDatabase(old, to: target)
        try copyDatabase(old, to: before)
        try copyDatabase(new, to: after)

        // rekordbox가 새로 만든 기록(만든 순서 = 변경 번호 순)
        let key = try RekordboxKey.derive()
        let base = try load(before, key: key), theirs = try load(after, key: key)
        guard let baseHistories = base["djmdHistory"], let theirHistories = theirs["djmdHistory"],
              let theirEntries = theirs["djmdSongHistory"] else {
            throw CLIGuards.Refusal("기록 재현: 기록 표를 읽지 못했습니다")
        }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let fresh = theirHistories.rows.keys.filter { baseHistories.rows[$0] == nil && theirHistories.value($0, "Attribute") == "0" }
            .sorted { (Int(theirHistories.value($0, "rb_local_usn") ?? "") ?? 0, $0) < (Int(theirHistories.value($1, "rb_local_usn") ?? "") ?? 0, $1) }
        var imports: [HistoryImport] = []
        for id in fresh {
            let name = theirHistories.value(id, "Name") ?? ""
            guard let date = parser.date(from: theirHistories.value(id, "DateCreated") ?? "") else {
                throw CLIGuards.Refusal("기록 재현: 새 기록의 DateCreated를 읽지 못했습니다")
            }
            let contentIDs = theirEntries.rows.keys.filter { theirEntries.value($0, "HistoryID") == id && theirEntries.value($0, "rb_local_deleted") == "0" }
                .sorted { (Int(theirEntries.value($0, "TrackNo") ?? "") ?? 0) < (Int(theirEntries.value($1, "TrackNo") ?? "") ?? 0) }
                .compactMap { theirEntries.value($0, "ContentID") }
            imports.append(HistoryImport(id: "repro-\(id)", name: name, dateCreated: date, contentIDs: contentIDs))
        }
        print("rekordbox가 새로 만든 기록 \(imports.count)개")
        guard !imports.isEmpty else { throw CLIGuards.Refusal("기록 재현: 비교할 기록이 없습니다") }

        let report = try RekordboxWriter.write(drafts: [], grids: [], gains: [:], analysisInputs: [:], histories: imports, to: target, dryRun: false,
                                               now: .now, backups: folder.appending(path: "backups"), shareRoot: nil, attachesAnalysis: false,
                                               writesHistories: true)
        for outcome in report.historyOutcomes ?? [] {
            if outcome.status == .written {
                print("✓ \(outcome.name) · 항목 \(outcome.entries) · 컬렉션에 없어 뺀 곡 \(outcome.skipped)")
            } else {
                print("✗ \(outcome.name) — \(outcome.reason ?? "")")
            }
        }
        let ours = try load(target, key: key)
        var problems: [String] = []
        compare(base: base, ours: ours, theirs: theirs, problems: &problems)
        // 변경 카운터(값은 비교하지 않는다: rekordbox는 곡 행 앞에 빈 번호를 둔다)
        func counter(_ url: URL) -> String {
            guard let db = try? CipherDatabase(path: url.path, key: key) else { return "?" }
            defer { db.close() }
            guard let local = (try? RekordboxCompatibility.updateCounters(db))?.local else { return "?" }
            return String(local)
        }
        print("변경 카운터: 실험 전 \(counter(before)) → DJCrate \(counter(target)) · rekordbox \(counter(after))(값은 비교하지 않음)")
        for problem in problems.prefix(60) { print("  " + problem) }
        if problems.count > 60 { print("  … 그 밖에 \(problems.count - 60)개") }
        print("기록 재현: 차이 \(problems.count)")
        guard problems.isEmpty else { throw CLIGuards.Refusal("기록 재현이 rekordbox 결과와 다릅니다. 차이를 고친 뒤 다시 확인하세요") }
    }

    // MARK: - 비교

    static func compare(base: [String: Table], ours: [String: Table], theirs: [String: Table], problems: inout [String]) {
        guard let baseH = base["djmdHistory"], let ourH = ours["djmdHistory"], let theirH = theirs["djmdHistory"],
              let baseE = base["djmdSongHistory"], let ourE = ours["djmdSongHistory"], let theirE = theirs["djmdSongHistory"],
              let baseC = base["djmdContent"], let ourC = ours["djmdContent"], let theirC = theirs["djmdContent"] else {
            problems.append("기록·곡 표를 읽지 못했습니다")
            return
        }
        let times: Set<String> = ["rb_local_usn", "created_at", "updated_at"]
        func differing(_ a: [String: String], _ b: [String: String], skip: Set<String>) -> [String] {
            Set(a.keys).union(b.keys).subtracting(skip).sorted().filter { a[$0] != b[$0] }
        }
        func describe(_ columns: [String], _ a: [String: String], _ b: [String: String]) -> String {
            columns.map { "\($0) \(a[$0] ?? "∅") ≠ \(b[$0] ?? "∅")" }.joined(separator: ", ")
        }

        // 1. 기존 기록·폴더·항목 행은 두 쪽이 같아야 한다(rekordbox는 기존 폴더를 고치지 않는다).
        for (label, b, o, t) in [("djmdHistory", baseH, ourH, theirH), ("djmdSongHistory", baseE, ourE, theirE)] {
            for key in b.rows.keys.sorted() where o.rows[key] != t.rows[key] || o.storage[key] != t.storage[key] {
                let columns = o.row(key).flatMap { a in t.row(key).map { differing(a, $0, skip: []) } } ?? ["행"]
                problems.append("\(label) 기존 \(key): \(columns.joined(separator: "·"))")
            }
        }

        // 2. 새 폴더(ID로 짝)·새 기록(부모·이름으로 짝)
        func fresh(_ table: Table, attribute: String) -> [String] {
            table.rows.keys.filter { baseH.rows[$0] == nil && table.value($0, "Attribute") == attribute }.sorted()
        }
        let ourFolders = fresh(ourH, attribute: "1"), theirFolders = fresh(theirH, attribute: "1")
        for (side, table) in [("DJCrate", ourH), ("rekordbox", theirH)] {
            let added = table.rows.keys.filter { baseH.rows[$0] == nil }
            let unknown = added.filter { !["0", "1"].contains(table.value($0, "Attribute") ?? "") }
            if !unknown.isEmpty { problems.append("\(side) 새 기록 표에 비교하지 못한 Attribute 행 \(unknown.count)개") }
            let grouped = Dictionary(grouping: fresh(table, attribute: "0")) { "\(table.value($0, "ParentID") ?? "∅")/\(table.value($0, "Name") ?? "∅")" }
            let duplicates = grouped.values.reduce(0) { $0 + max(0, $1.count - 1) }
            if duplicates > 0 { problems.append("\(side) 새 기록의 부모·이름 중복 행 \(duplicates)개") }
        }
        for id in Set(ourFolders).union(theirFolders).sorted() {
            guard let a = ourH.row(id), let b = theirH.row(id) else {
                problems.append("새 폴더 \(id): 한쪽에만 있음(DJCrate \(ourH.rows[id] != nil) · rekordbox \(theirH.rows[id] != nil))")
                continue
            }
            let columns = Set(differing(a, b, skip: times)).union(ourH.differingStorage(id, from: theirH, key: id, skip: times)).sorted()
            if !columns.isEmpty { problems.append("새 폴더 \(id): \(describe(columns, a, b))") }
            if a["UUID"] != id || b["UUID"] != id { problems.append("새 폴더 \(id): UUID가 ID와 다름(DJCrate \(a["UUID"] ?? "∅") · rekordbox \(b["UUID"] ?? "∅"))") }
        }
        func historyKey(_ table: Table, _ id: String) -> String { "\(table.value(id, "ParentID") ?? "∅")/\(table.value(id, "Name") ?? "∅")" }
        let ourHistories = Dictionary(fresh(ourH, attribute: "0").map { (historyKey(ourH, $0), $0) }, uniquingKeysWith: { a, _ in a })
        let theirHistories = Dictionary(fresh(theirH, attribute: "0").map { (historyKey(theirH, $0), $0) }, uniquingKeysWith: { a, _ in a })
        for key in Set(ourHistories.keys).union(theirHistories.keys).sorted() {
            guard let ourID = ourHistories[key], let theirID = theirHistories[key], let a = ourH.row(ourID), let b = theirH.row(theirID) else {
                problems.append("새 기록 \(key): 한쪽에만 있음(DJCrate \(ourHistories[key] != nil) · rekordbox \(theirHistories[key] != nil))")
                continue
            }
            let columns = Set(differing(a, b, skip: times.union(["ID", "UUID"])))
                .union(ourH.differingStorage(ourID, from: theirH, key: theirID, skip: times.union(["ID", "UUID"]))).sorted()
            if !columns.isEmpty { problems.append("새 기록 \(key): \(describe(columns, a, b))") }
            for (side, row) in [("DJCrate", a), ("rekordbox", b)] {
                if !isDigits(row["ID"]) { problems.append("새 기록 \(key): \(side) ID가 숫자 글자가 아님") }
                if !isUUID(row["UUID"]) { problems.append("새 기록 \(key): \(side) UUID가 소문자 v4가 아님") }
            }
        }

        // 3. 새 항목(기록 키·TrackNo로 짝)
        let ourKeys = Dictionary(ourHistories.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let theirKeys = Dictionary(theirHistories.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        func entries(_ table: Table, keys: [String: String]) -> [String: String] {
            let added = table.rows.keys.filter { baseE.rows[$0] == nil }.map { id in
                ("\(keys[table.value(id, "HistoryID") ?? ""] ?? "?\(table.value(id, "HistoryID") ?? "")")#\(table.value(id, "TrackNo") ?? "∅")", id)
            }
            let result = Dictionary(added, uniquingKeysWith: { a, _ in a })
            if result.count != added.count { problems.append("새 항목의 기록·TrackNo 중복 행 \(added.count - result.count)개") }
            return result
        }
        let ourNew = entries(ourE, keys: ourKeys), theirNew = entries(theirE, keys: theirKeys)
        for key in Set(ourNew.keys).union(theirNew.keys).sorted() {
            guard let ourID = ourNew[key], let theirID = theirNew[key], let a = ourE.row(ourID), let b = theirE.row(theirID) else {
                problems.append("새 항목 \(key): 한쪽에만 있음(DJCrate \(ourNew[key] != nil) · rekordbox \(theirNew[key] != nil))")
                continue
            }
            let columns = Set(differing(a, b, skip: times.union(["ID", "UUID", "HistoryID"])))
                .union(ourE.differingStorage(ourID, from: theirE, key: theirID, skip: times.union(["ID", "UUID", "HistoryID"]))).sorted()
            if !columns.isEmpty { problems.append("새 항목 \(key): \(describe(columns, a, b))") }
            for (side, row) in [("DJCrate", a), ("rekordbox", b)] {
                if !isUUID(row["ID"]) || !isUUID(row["UUID"]) || row["ID"] == row["UUID"] {
                    problems.append("새 항목 \(key): \(side) ID·UUID가 서로 다른 소문자 v4가 아님")
                }
            }
        }

        // 4. 기록에 든 곡 행: 시각·변경 번호를 뺀 모든 칸의 값·저장 형식을 비교한다. 값(경로 등)은 찍지 않는다.
        let touched = Set((ourNew.values.compactMap { ourE.value($0, "ContentID") }) + theirNew.values.compactMap { theirE.value($0, "ContentID") })
        for id in touched.sorted() {
            guard let old = baseC.row(id), let a = ourC.row(id), let b = theirC.row(id) else {
                problems.append("곡 \(id): 한쪽 DB에 행이 없음")
                continue
            }
            let ourChanged = differing(old, a, skip: []), theirChanged = differing(old, b, skip: [])
            if ourChanged != theirChanged {
                problems.append("곡 \(id): 바뀐 칸이 다름(DJCrate \(ourChanged.joined(separator: "·")) · rekordbox \(theirChanged.joined(separator: "·")))")
            }
            let values = Set(differing(a, b, skip: times)).union(ourC.differingStorage(id, from: theirC, key: id, skip: times)).sorted()
            if !values.isEmpty { problems.append("곡 \(id): 칸 값·저장 형식이 다름(\(values.joined(separator: "·")))") }
        }
        for id in Set(ourC.rows.keys).union(theirC.rows.keys).subtracting(touched).sorted() where ourC.rows[id] != theirC.rows[id] || ourC.storage[id] != theirC.storage[id] {
            problems.append("곡 \(id): 기록에 없는 곡 행이 다름(\(changedSide(baseC.rows[id], ourC.rows[id], theirC.rows[id])))")
        }

        // 5. 그 밖의 표: 두 쪽이 같아야 한다(행 수·행 값). 값은 찍지 않는다.
        for name in Set(ours.keys).union(theirs.keys).subtracting(historyTables).sorted() {
            guard let o = ours[name], let t = theirs[name] else { problems.append("표 \(name): 한쪽에만 있음"); continue }
            let keys = Set(o.rows.keys).union(t.rows.keys).filter { o.rows[$0] != t.rows[$0] || o.storage[$0] != t.storage[$0] }
            guard !keys.isEmpty else { continue }
            let sides = Dictionary(grouping: keys) { changedSide(base[name]?.rows[$0], o.rows[$0], t.rows[$0]) }.mapValues(\.count)
            problems.append("표 \(name): 행 수 DJCrate \(o.rows.count) · rekordbox \(t.rows.count), 다른 행 \(keys.count)개("
                + sides.keys.sorted().map { "\($0) \(sides[$0]!)" }.joined(separator: ", ") + ")")
        }

        // 6. 변경 번호 순서: 새 폴더 → 새 기록 → 새 항목(TrackNo) → 곡 행. 값과 rekordbox의 빈 번호는 보지 않는다.
        func order(_ h: Table, _ e: Table, _ c: Table, folderIDs: [String], historyIDs: [String: String], entryIDs: [String: String]) -> [String] {
            var labeled: [(usn: Int, label: String)] = []
            func add(_ table: Table, _ id: String, _ label: String) {
                if let usn = Int(table.value(id, "rb_local_usn") ?? "") { labeled.append((usn, label)) }
            }
            for id in folderIDs { add(h, id, "폴더 \(id)") }
            for (key, id) in historyIDs { add(h, id, "기록 \(key)") }
            for (key, id) in entryIDs { add(e, id, "항목 \(key)") }
            for id in touched where c.value(id, "rb_local_usn") != baseC.value(id, "rb_local_usn") { add(c, id, "곡 \(id)") }
            return labeled.sorted { ($0.usn, $0.label) < ($1.usn, $1.label) }.map(\.label)
        }
        let ourOrder = order(ourH, ourE, ourC, folderIDs: ourFolders, historyIDs: ourHistories, entryIDs: ourNew)
        let theirOrder = order(theirH, theirE, theirC, folderIDs: theirFolders, historyIDs: theirHistories, entryIDs: theirNew)
        if ourOrder != theirOrder {
            problems.append("변경 번호 순서가 다름: DJCrate [\(ourOrder.joined(separator: " → "))] · rekordbox [\(theirOrder.joined(separator: " → "))]")
        } else {
            print("변경 번호 순서: \(ourOrder.joined(separator: " → "))")
        }
    }

    /// 어느 쪽이 실험 전과 달라졌는지
    static func changedSide(_ base: [String?]?, _ ours: [String?]?, _ theirs: [String?]?) -> String {
        switch (ours == base, theirs == base) {
        case (true, false): "rekordbox만 바뀜"
        case (false, true): "DJCrate만 바뀜"
        default: "둘 다 바뀜"
        }
    }

    static func isDigits(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func isUUID(_ text: String?) -> Bool {
        (text ?? "").range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    // MARK: - 읽기·복사

    /// 인증 표·칸을 뺀 모든 표(진단 연결: 인증 표·칸은 읽기부터 막힌다)
    static func load(_ url: URL, key: String) throws -> [String: Table] {
        let db = try CipherDatabase.diagnostic(path: url.path, key: key)
        defer { db.close() }
        var names: [String] = []
        try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") { names.append($0.string(0) ?? "") }
        var tables: [String: Table] = [:]
        for name in names where !CipherDatabase.isCredentialIdentifier(name) {
            var columns: [String] = [], primary: [Int] = []
            try db.query("PRAGMA table_info(\"\(name)\")") { r in
                let column = r.string(1) ?? ""
                guard !CipherDatabase.isCredentialIdentifier(column) else { return }
                columns.append(column)
                if (r.int(5) ?? 0) > 0 { primary.append(columns.count - 1) }
            }
            guard !columns.isEmpty else { continue }
            let keyColumns = primary.isEmpty ? (columns.firstIndex(of: "ID").map { [$0] } ?? []) : primary
            var rows: [String: [String?]] = [:]
            var storage: [String: [String]] = [:]
            let storageColumns = columns.map { column in
                let quoted = "\"\(column)\""
                return "typeof(\(quoted)) || ':' || CASE WHEN typeof(\(quoted)) = 'real' THEN printf('%!.26g', \(quoted)) ELSE hex(CAST(\(quoted) AS BLOB)) END"
            }
            let select = "SELECT " + (keyColumns.isEmpty ? "rowid, " : "")
                + (columns.map { "\"\($0)\"" } + storageColumns).joined(separator: ", ") + " FROM \"\(name)\""
            try db.query(select) { r in
                let offset: Int32 = keyColumns.isEmpty ? 1 : 0
                let values = (0..<columns.count).map { r.string(Int32($0) + offset) }
                let rowKey = keyColumns.isEmpty ? (r.string(0) ?? "") : keyColumns.map { values[$0] ?? "nil" }.joined(separator: "/")
                rows[rowKey] = values
                storage[rowKey] = (0..<columns.count).map { r.string(Int32(columns.count + $0) + offset) ?? "null:" }
            }
            tables[name] = Table(columns: columns, rows: rows, storage: storage)
        }
        return tables
    }

    /// DB와 딸린 -wal·-shm을 복사한다(원본은 읽기만)
    static func copyDatabase(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: source.path + suffix) {
            try fm.copyItem(at: URL(filePath: source.path + suffix), to: URL(filePath: destination.path + suffix))
        }
    }

    /// 임시 폴더 아래의 빈(또는 없는) 폴더만 받는다. 실험 작업 폴더 관문(`LabWorkFolder.check`)이 임시 폴더 밖과
    /// rekordbox·DJCrate 데이터 폴더와 겹치는 폴더를 거부한다. 이 도구는 폴더를 지우지 않으므로 비어 있지 않은 폴더는 받지 않는다.
    /// 통과하면 링크를 푼 실제 경로를 돌려준다
    @discardableResult
    static func refuseLibraryFolder(_ folder: URL) throws -> URL {
        let checked = try LabWorkFolder.check(folder.path)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: checked.path), !items.isEmpty {
            throw CLIGuards.Refusal("작업 폴더가 비어 있지 않습니다. --work에 mktemp -d로 만든 폴더 아래 새 경로를 주세요")
        }
        return checked
    }
}
