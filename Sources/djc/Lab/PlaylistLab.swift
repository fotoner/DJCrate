import CryptoKit
import DJCDomain
import Foundation
import RekordboxKit

/// 재생 목록 쓰기 규칙을 알아낼 때 쓰는 실험(#38).
enum PlaylistLab {
    static let all: [Command] = [
        Command("playlist-watch", "--out <폴더> [--interval 초] [--minutes N]",
                "rekordbox가 켜져 있는 동안 라이브 DB를 읽기용으로 복사해, 재생 목록·변경 카운터가 바뀔 때마다 사본을 남긴다(읽기 전용)",
                PlaylistLab.watch),
        Command("playlist-repro", "--old <실험 전.db> --new <실험 뒤.db> --edits <편집.json> --work <폴더> [--old-xml F] [--new-xml F]",
                "rekordbox 재생 목록 실험을 실험 전 사본에 같은 편집으로 써서 rekordbox 결과와 칸마다 비교(사본만)", PlaylistLab.repro),
    ]

    /// 실험 중 단계마다 상태를 잡는다. 라이브 DB는 파일 복사만 하고(스냅샷과 같은 방법) SQLite로 열지 않는다.
    /// 재생 목록이 바뀐 rekordbox 세션이 끝나면(rekordbox 종료) 멈춘다. 재생 목록을 바꾸지 않은 세션은 건너뛰고 계속 기다린다.
    static func watch(_ args: [String]) async throws {
        guard let out = value(after: "--out", in: args) else { throw UsageError() }
        setvbuf(stdout, nil, _IOLBF, 0)  // 파일로 받을 때도 줄마다 보이게
        let interval = Double(value(after: "--interval", in: args) ?? "") ?? 2
        let deadline = Date.now.addingTimeInterval(60 * (Double(value(after: "--minutes", in: args) ?? "") ?? 180))
        let fm = FileManager.default
        let folder = URL(filePath: out)
        let temp = folder.appending(path: ".poll")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let live = LibrarySnapshot.rekordboxDirectory
        let xmlURL = live.appending(path: "masterPlaylists6.xml")
        var lastPrint: String?, firstDigest: String?, lastXML: Data?, index = 0, sawRunning = false, playlistsChanged = false
        let time = DateFormatter()
        time.dateFormat = "HHmmss"

        while Date.now < deadline {
            let running = LibrarySnapshot.isRekordboxRunning()
            sawRunning = sawRunning || running
            let stamp = time.string(from: .now)
            if let copy = try? LibrarySnapshot.take(from: live.appending(path: "master.db"), into: temp, force: true),
               let print = try? fingerprint(copy) {
                let digest = String(print.split(separator: " ").last ?? "")
                firstDigest = firstDigest ?? digest
                playlistsChanged = playlistsChanged || digest != firstDigest
                if print != lastPrint {
                    index += 1
                    let kept = folder.appending(path: String(format: "%03d-%@.db", index, stamp))
                    try fm.moveItem(at: copy, to: kept)
                    Swift.print("\(stamp) #\(index) \(print)")
                    lastPrint = print
                } else {
                    try? fm.removeItem(at: copy)
                }
            }
            if let xml = try? Data(contentsOf: xmlURL), xml != lastXML {
                try xml.write(to: folder.appending(path: String(format: "%03d-%@-masterPlaylists6.xml", index, stamp)))
                Swift.print("\(stamp) masterPlaylists6.xml 바뀜(\(xml.count)바이트)")
                lastXML = xml
            }
            if sawRunning, !running {
                // 재생 목록이 그대로인 채 꺼졌으면(에이전트만 잠깐, 다른 실험 등) 계속 기다린다.
                guard playlistsChanged else { sawRunning = false; Swift.print("\(stamp) rekordbox가 재생 목록을 바꾸지 않고 꺼졌다. 계속 기다림"); continue }
                Swift.print("\(stamp) rekordbox 종료를 보았다. 끝.")
                break
            }
            // rekordbox를 켜기 전에는 천천히 본다.
            try await Task.sleep(for: .seconds(sawRunning ? interval : max(interval, 10)))
        }
        try? fm.removeItem(at: temp)
    }

    /// 변경 카운터와 재생 목록 표 세 개의 내용 요약. 둘 중 하나라도 바뀌면 새 상태로 본다.
    static func fingerprint(_ copy: URL) throws -> String {
        let db = try CipherDatabase.diagnostic(path: copy.path, key: RekordboxKey.derive())
        defer { db.close() }
        var hasher = SHA256()
        for table in ["djmdPlaylist", "djmdSongPlaylist", "djmdCloudFilterPlaylist"] {
            try db.query("SELECT * FROM \(table) ORDER BY ID") { row in
                for i in 0..<Int32(row.count) { hasher.update(data: Data((row.string(i) ?? "∅").utf8 + [0])) }
            }
        }
        let digest = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        let local = try localUpdateCount(copy)
        return "변경 카운터 \(local.map(String.init) ?? "없음") · 재생 목록 \(digest)"
    }

    private static func localUpdateCount(_ snapshot: URL) throws -> Int? {
        // 진단 연결의 인증 표 차단은 유지하고, 고정된 두 카운터의 정수 칸만 별도로 읽는다.
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        return try RekordboxCompatibility.updateCounters(db).local
    }

    // MARK: - 사본 재현

    /// 표 하나의 행(칸 이름 → 글자, NULL은 "NULL")
    typealias Rows = [String: [String: String]]

    static func rows(_ db: CipherDatabase, _ table: String) throws -> Rows {
        var out: Rows = [:]
        try db.query("SELECT * FROM \(table)") { r in
            var row: [String: String] = [:]
            for i in 0..<r.count { row[r.name(Int32(i))] = r.string(Int32(i)) ?? "NULL" }
            out[row["ID"] ?? ""] = row
        }
        return out
    }

    struct Library {
        var playlists: Rows
        var entries: Rows
        var mirrors: Rows
        var counter: Int?

        init(_ url: URL) throws {
            let db = try CipherDatabase.diagnostic(path: url.path, key: RekordboxKey.derive())
            defer { db.close() }
            playlists = try rows(db, "djmdPlaylist")
            entries = try rows(db, "djmdSongPlaylist")
            mirrors = try rows(db, "djmdCloudFilterPlaylist")
            counter = try PlaylistLab.localUpdateCount(url)
        }

        /// 목록 ID → 이름 경로("DJC 실험/DJC 폴더 가/가1"). 새로 만든 목록은 ID가 달라 이 경로로 짝짓는다.
        func path(_ id: String) -> String {
            guard let row = playlists[id] else { return id == "root" ? "" : "?\(id)" }
            let parent = row["ParentID"] ?? "root"
            return (parent == "root" ? "" : path(parent) + "/") + (row["Name"] ?? "")
        }
    }

    /// 실험 전 사본에 편집을 쓰고(`RekordboxWriter.write`), rekordbox가 쓴 실험 뒤 DB와 세 표·카운터·XML을 칸마다 비교한다.
    /// 새 행의 ID·UUID·시각은 무작위·실행 시각이라 비교하지 않고, 번호(rb_local_usn)는 같은 카운터에서 시작하므로 값까지 비교한다.
    static func repro(_ args: [String]) async throws {
        guard let old = value(after: "--old", in: args), let new = value(after: "--new", in: args),
              let editsPath = value(after: "--edits", in: args), let work = value(after: "--work", in: args) else { throw UsageError() }
        let fm = FileManager.default
        let folder = try LabWorkFolder.reset(work, attributes: [.posixPermissions: 0o700])
        let copy = folder.appending(path: "master.db")
        try fm.copyItem(at: URL(filePath: old), to: copy)
        if let xml = value(after: "--old-xml", in: args) { try fm.copyItem(at: URL(filePath: xml), to: folder.appending(path: "masterPlaylists6.xml")) }
        let edits = try JSONDecoder().decode([PlaylistEdit].self, from: Data(contentsOf: URL(filePath: editsPath)))
        let report = try RekordboxWriter.write(drafts: [], playlists: edits, to: copy, dryRun: false, backups: folder.appending(path: "backups"))
        print("편집 \(edits.count)개: 씀 \(report.playlistWritten.count) · 막힘 \(report.playlistBlocked.count)")
        for blocked in report.playlistBlocked { print("  ✗ \(blocked.name) — \(blocked.reason ?? "")") }

        let before = try Library(URL(filePath: old)), ours = try Library(copy), theirs = try Library(URL(filePath: new))
        var problems: [String] = []
        func compare(_ what: String, _ a: [String: String]?, _ b: [String: String]?, skip: Set<String>, map: [String: (String) -> String] = [:]) -> Bool {
            guard let a, let b else { problems.append("\(what): 한쪽에만 있음(DJCrate \(a != nil) · rekordbox \(b != nil))"); return false }
            let diffs = Set(a.keys).union(b.keys).subtracting(skip).sorted().filter { key in
                let f = map[key] ?? { $0 }
                return f(a[key] ?? "∅") != f(b[key] ?? "∅")
            }
            if !diffs.isEmpty { problems.append("\(what): " + diffs.map { "\($0) \(a[$0] ?? "∅") ≠ \(b[$0] ?? "∅")" }.joined(separator: ", ")) }
            return diffs.isEmpty
        }
        // 시각은 실제 값 대신 실험 전과 달라졌는지만 본다
        func touched(_ row: [String: String]?, _ base: [String: String]?, _ key: String) -> String {
            guard let row else { return "∅" }
            return row[key] == base?[key] ? "그대로" : "바뀜"
        }

        /// 원래 있던 행은 ID로, 새로 생긴 행은 `key`(이름 경로 등)로 짝지어 칸마다 비교한다. 시각은 바뀌었는지만 본다.
        func check(_ label: String, before base: Rows, ours a: Rows, theirs b: Rows, key: (Library, [String: String]) -> String,
                   skip: Set<String>, normalize: (Library, inout [String: String]) -> Void = { _, _ in }) {
            var same = 0, changed = 0
            func prepared(_ lib: Library, _ row: [String: String]?) -> [String: String]? {
                guard var row else { return nil }
                for column in ["created_at", "updated_at"] { row[column] = row[column] == base[row["ID"] ?? ""]?[column] ? "그대로" : "바뀜" }
                normalize(lib, &row)
                return row
            }
            for id in base.keys.sorted() where a[id] != base[id] || b[id] != base[id] {
                changed += 1
                if compare("\(label) \(id)", prepared(ours, a[id]), prepared(theirs, b[id]), skip: []) { same += 1 }
            }
            let newA = Dictionary(a.values.filter { base[$0["ID"] ?? ""] == nil }.map { (key(ours, $0), $0) }, uniquingKeysWith: { x, _ in x })
            let newB = Dictionary(b.values.filter { base[$0["ID"] ?? ""] == nil }.map { (key(theirs, $0), $0) }, uniquingKeysWith: { x, _ in x })
            for k in Set(newA.keys).union(newB.keys).sorted() {
                changed += 1
                if compare("\(label) 새 \(k)", prepared(ours, newA[k]), prepared(theirs, newB[k]), skip: skip) { same += 1 }
            }
            print("\(label): 바뀌거나 새로 생긴 행 \(changed)개 중 \(same)개 칸까지 일치(행 수 DJCrate \(a.count) · rekordbox \(b.count))")
        }
        let parentPath: (Library, inout [String: String]) -> Void = { lib, row in row["ParentID"] = lib.path(row["ParentID"] ?? "root") }
        check("djmdPlaylist", before: before.playlists, ours: ours.playlists, theirs: theirs.playlists, key: { $0.path($1["ID"] ?? "") },
              skip: ["ID", "UUID"], normalize: parentPath)
        check("djmdSongPlaylist", before: before.entries, ours: ours.entries, theirs: theirs.entries,
              key: { "\($0.path($1["PlaylistID"] ?? ""))#\($1["TrackNo"] ?? "")" }, skip: ["ID", "UUID"],
              normalize: { lib, row in row["PlaylistID"] = lib.path(row["PlaylistID"] ?? "") })
        func owner(_ lib: Library, _ row: [String: String]) -> String {
            lib.playlists.values.first { $0["UUID"] == row["PlaylistUUID"] }.map { lib.path($0["ID"] ?? "") } ?? "?\(row["ID"] ?? "")"
        }
        check("djmdCloudFilterPlaylist", before: before.mirrors, ours: ours.mirrors, theirs: theirs.mirrors, key: owner,
              skip: ["ID", "UUID", "PlaylistUUID"])
        if ours.counter != theirs.counter { problems.append("변경 카운터 DJCrate \(ours.counter ?? -1) ≠ rekordbox \(theirs.counter ?? -1)") }
        print("변경 카운터: 실험 전 \(before.counter ?? -1) → DJCrate \(ours.counter ?? -1) · rekordbox \(theirs.counter ?? -1)")

        // masterPlaylists6.xml: NODE 순서·부모·종류, Timestamp는 실험 전과 달라졌는지만
        if let oldXML = value(after: "--old-xml", in: args), let newXML = value(after: "--new-xml", in: args) {
            let base = try MasterPlaylistsXML(contentsOf: URL(filePath: oldXML))
            let a = try MasterPlaylistsXML(contentsOf: folder.appending(path: "masterPlaylists6.xml"))
            let b = try MasterPlaylistsXML(contentsOf: URL(filePath: newXML))
            func describe(_ xml: MasterPlaylistsXML, _ lib: Library) -> [String] {
                let byHex = Dictionary(lib.playlists.keys.compactMap { id in MasterPlaylistsXML.hex(id).map { ($0, id) } }, uniquingKeysWith: { a, _ in a })
                let baseTimes = Dictionary(base.nodes.map { ($0.id, $0.timestamp) }, uniquingKeysWith: { a, _ in a })
                return xml.nodes.map { node in
                    let name = byHex[node.id].map(lib.path) ?? (baseTimes[node.id] != nil ? "옛 \(node.id)" : "지운 목록")
                    let parent = node.parentID == "0" ? "" : (byHex[node.parentID].map(lib.path) ?? "지운 폴더")
                    let time = baseTimes[node.id] == node.timestamp ? "그대로" : (node.timestamp == 0 ? "0" : "바뀜")
                    return "\(name) < \(parent) · \(node.attribute) · \(node.libType)/\(node.checkType) · \(time)"
                }
            }
            let da = describe(a, ours), db = describe(b, theirs)
            let differing = zip(da, db).filter { $0 != $1 }
            for (x, y) in differing.prefix(10) { problems.append("XML: \(x) ≠ \(y)") }
            if da.count != db.count { problems.append("XML NODE 수 DJCrate \(da.count) ≠ rekordbox \(db.count)") }
            print("masterPlaylists6.xml: NODE \(da.count)개 중 다른 줄 \(differing.count)개")
        }
        print(problems.isEmpty ? "✓ 모두 일치" : "✗ 다른 곳 \(problems.count)개")
        for problem in problems.prefix(40) { print("  " + problem) }
    }
}
