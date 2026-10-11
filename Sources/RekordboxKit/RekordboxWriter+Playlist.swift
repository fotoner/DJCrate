import DJCDomain
import Foundation

/// 재생 목록 쓰기(#38): `djmdPlaylist`·`djmdSongPlaylist`·`djmdCloudFilterPlaylist`와 `masterPlaylists6.xml`.
///
/// rekordbox 7.2.18 화면에서 같은 조작을 했을 때 남는 행을 따른다(2026-09-26 "DJC 실험", docs/rekordbox-internals.md "재생 목록").
/// 번호(usn)를 받는 순서와 rekordbox가 비워 두는 번호까지 같게 해서, 같은 카운터에서 시작하면 번호 값도 같다.
extension RekordboxWriter {
    /// 재생 목록 표의 살아 있는 행(쓰기 계획·검증용). 쓰는 동안 편집마다 고쳐 두고, 다 쓴 뒤 DB를 다시 읽어 같은지 본다.
    struct PlaylistTree: Equatable {
        struct Node: Equatable {
            var id: String
            var name: String
            var parentID: String
            var seq: Int
            var attribute: Int
            var uuid: String
            var smartList: Bool
        }

        struct Entry: Equatable {
            var id: String
            var contentID: String
            var trackNo: Int
        }

        var nodes: [String: Node] = [:]
        /// 목록 ID → 곡 항목(TrackNo 순서)
        var entries: [String: [Entry]] = [:]

        static func read(_ db: CipherDatabase) throws -> PlaylistTree {
            var tree = PlaylistTree()
            try db.query("""
                SELECT ID, Name, ParentID, Seq, Attribute, UUID, SmartList FROM djmdPlaylist WHERE rb_local_deleted = 0
                """) { r in
                let id = r.string(0) ?? ""
                tree.nodes[id] = Node(id: id, name: r.string(1) ?? "", parentID: r.string(2) ?? "root", seq: r.int(3) ?? 0,
                                      attribute: r.int(4) ?? 0, uuid: r.string(5) ?? "", smartList: !(r.string(6) ?? "").isEmpty)
            }
            try db.query("""
                SELECT ID, PlaylistID, ContentID, TrackNo FROM djmdSongPlaylist WHERE rb_local_deleted = 0 ORDER BY PlaylistID, TrackNo, ID
                """) { r in
                tree.entries[r.string(1) ?? "", default: []].append(Entry(id: r.string(0) ?? "", contentID: r.string(2) ?? "", trackNo: r.int(3) ?? 0))
            }
            return tree
        }

        /// 부모 안의 목록(Seq 순서)
        func children(of parent: String) -> [Node] {
            nodes.values.filter { $0.parentID == parent }.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }
        }

        /// 자신과 그 아래 모든 목록·폴더 ID
        func subtree(of id: String) -> [String] {
            [id] + children(of: id).flatMap { subtree(of: $0.id) }
        }

        /// 초안의 base와 비교할 모양(`PlaylistLayout(rekordbox:)`와 같은 값)
        var layout: PlaylistLayout {
            PlaylistLayout(nodes.values.map { node in
                (PlaylistLayout.Item(id: node.id, name: node.name, parentID: node.parentID, isFolder: node.attribute == 1,
                                     isSmart: node.attribute > 1 || node.smartList,
                                     entries: (entries[node.id] ?? []).map { PlaylistEntry(trackNo: $0.trackNo, contentID: $0.contentID) }),
                 node.seq)
            })
        }
    }

    /// `masterPlaylists6.xml`에 할 일(DB를 커밋하고 확인한 뒤 적는다)
    enum PlaylistXMLChange: Equatable {
        case append(id: String, parentID: String, isFolder: Bool)
        /// Timestamp를 쓴 시각으로
        case touch(String)
        case parent(id: String, to: String)
    }

    /// 한 묶음을 쓰는 동안의 상태
    struct PlaylistWork {
        var tree: PlaylistTree
        /// 만들기 key → 새 목록 ID
        var keys: [String: String] = [:]
        var xml: [PlaylistXMLChange] = []
        /// XML에 이미 있는 NODE Id(지운 목록 것도 남아 있다). 새 ID가 겹치지 않게 한다.
        var xmlIDs: Set<String>
        /// 만든 목록(거울 행이 하나씩 있어야 한다)과 지운 목록 UUID
        var created: Set<String> = []
        var deletedUUIDs: Set<String> = []
    }

    struct PlaylistBlocked: Error {
        var name: String
        var reason: String
    }

    /// DB 옆 `masterPlaylists6.xml`(라이브면 rekordbox 폴더). 사본 폴더에 없으면 DB만 쓴다.
    static func playlistXMLURL(for database: URL) -> URL {
        database.deletingLastPathComponent().appending(path: "masterPlaylists6.xml")
    }

    // MARK: - 편집 하나

    /// 편집 하나를 쓴다. 막히면 `PlaylistBlocked`(호출하는 쪽이 SAVEPOINT로 되돌린다).
    static func applyPlaylist(_ edit: PlaylistEdit, work: inout PlaylistWork, db: CipherDatabase, usn: inout Int,
                              stamp: (db: String, json: String)) throws -> PlaylistOutcome {
        func done(_ node: PlaylistTree.Node, _ status: Outcome.Status = .written, _ reason: String? = nil) -> PlaylistOutcome {
            PlaylistOutcome(edit: edit, playlistID: node.id, name: node.name, status: status, reason: reason)
        }
        switch edit {
        case let .create(key, name, isFolder, parent):
            guard work.keys[key] == nil else { throw PlaylistBlocked(name: name, reason: String(ui: "같은 묶음에 같은 key(\(key))로 만든 목록이 있습니다")) }
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlaylistBlocked(name: name, reason: String(ui: "이름을 적어 주세요")) }
            let parentID = try folderID(parent, work: work, for: name)
            let siblings = work.tree.children(of: parentID)
            // rekordbox는 형제가 있으면 번호 하나를 비우고 시작한다(형제가 없으면 비우지 않는다).
            if !siblings.isEmpty { usn += 1 }
            let id = try newPlaylistID(db, work: work)
            let uuid = UUID().uuidString.lowercased()
            usn += 1
            try RekordboxTrackWriter.insert(db, table: "djmdPlaylist", [
                "ID": .text(id), "Seq": .int(1), "Name": .text(name), "ImagePath": .null, "Attribute": .int(isFolder ? 1 : 0),
                "ParentID": .text(parentID), "SmartList": .null, "UUID": .text(uuid),
            ].merging(RekordboxTrackWriter.syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
            // 새 목록은 맨 위: 형제는 Seq 순서대로 하나씩 번호를 받으며 한 칸씩 내려간다.
            for sibling in siblings {
                usn += 1
                try touchPlaylist(db, sibling.id, ["Seq": .int(sibling.seq + 1)], usn: usn, stamp: stamp)
                work.tree.nodes[sibling.id]?.seq += 1
            }
            usn += 1
            try RekordboxTrackWriter.insert(db, table: "djmdCloudFilterPlaylist", [
                "ID": .text(try RekordboxTrackWriter.newID(db, table: "djmdCloudFilterPlaylist", range: 1..<(1 << 32))),
                "PlaylistUUID": .text(uuid), "Seq": .int(0), "ParentID": .null, "UUID": .text(UUID().uuidString.lowercased()),
            ].merging(RekordboxTrackWriter.syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
            // rekordbox는 "무제 리스트"로 만든 뒤 이름을 붙인다. 그때 새 행이 번호를 한 번 더 받는다.
            usn += 1
            guard try db.run("UPDATE djmdPlaylist SET rb_local_usn = ? WHERE ID = ?", [.int(usn), .text(id)]) == 1 else {
                throw DJCError.writeVerificationFailed(String(ui: "새 재생 목록 행을 찾지 못했습니다"))
            }
            let node = PlaylistTree.Node(id: id, name: name, parentID: parentID, seq: 1, attribute: isFolder ? 1 : 0, uuid: uuid, smartList: false)
            work.tree.nodes[id] = node
            work.keys[key] = id
            work.created.insert(id)
            work.xml.append(.append(id: id, parentID: parentID, isFolder: isFolder))
            if parentID != "root" { work.xml.append(.touch(parentID)) }
            return done(node)

        case let .rename(playlist, name):
            var node = try target(playlist, work: work)
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlaylistBlocked(name: node.name, reason: String(ui: "이름을 적어 주세요")) }
            guard node.name != name else { return done(node, .unchanged) }
            usn += 1
            try touchPlaylist(db, node.id, ["Name": .text(name)], usn: usn, stamp: stamp)
            node.name = name
            work.tree.nodes[node.id] = node
            work.xml.append(.touch(node.id))
            return done(node)

        case let .move(playlist, into):
            var node = try target(playlist, work: work)
            let parentID = try folderID(into, work: work, for: node.name)
            guard parentID != node.parentID else { return done(node, .unchanged, String(ui: "이미 그 폴더에 있습니다")) }
            guard !work.tree.subtree(of: node.id).contains(parentID) else {
                throw PlaylistBlocked(name: node.name, reason: String(ui: "폴더를 제 안으로 옮길 수 없습니다"))
            }
            // 새 폴더의 맨 끝으로. 옛 폴더의 형제 Seq는 rekordbox처럼 당기지 않는다(빈칸이 남는다).
            let seq = (work.tree.children(of: parentID).map(\.seq).max() ?? 0) + 1
            usn += 1
            try touchPlaylist(db, node.id, ["ParentID": .text(parentID), "Seq": .int(seq)], usn: usn, stamp: stamp)
            node.parentID = parentID
            node.seq = seq
            work.tree.nodes[node.id] = node
            work.xml += [.parent(id: node.id, to: parentID), .touch(node.id)]
            if parentID != "root" { work.xml.append(.touch(parentID)) }
            return done(node)

        case let .reorder(playlist, index):
            let node = try target(playlist, work: work)
            var order = work.tree.children(of: node.parentID).filter { $0.id != node.id }
            order.insert(node, at: min(max(index, 0), order.count))
            // 부모 안을 1부터 다시 매기고, 자리가 바뀐 행만 새 순서대로 하나씩 번호를 받는다.
            var changed = false
            for (i, sibling) in order.enumerated() where sibling.seq != i + 1 {
                usn += 1
                try touchPlaylist(db, sibling.id, ["Seq": .int(i + 1)], usn: usn, stamp: stamp)
                work.tree.nodes[sibling.id]?.seq = i + 1
                changed = true
            }
            guard changed else { return done(node, .unchanged) }
            work.xml.append(.touch(node.id))
            if node.parentID != "root" { work.xml.append(.touch(node.parentID)) }
            return done(node)

        case let .delete(playlist):
            let node = try target(playlist, work: work)
            // 지운 행 몫으로 번호 하나를 비운다. 폴더면 안에 든 목록·곡 항목·거울 행까지 실제로 지운다.
            usn += 1
            for id in work.tree.subtree(of: node.id) {
                guard let uuid = work.tree.nodes[id]?.uuid else { continue }
                _ = try db.run("DELETE FROM djmdSongPlaylist WHERE PlaylistID = ?", [.text(id)])
                _ = try db.run("DELETE FROM djmdCloudFilterPlaylist WHERE PlaylistUUID = ?", [.text(uuid)])
                guard try db.run("DELETE FROM djmdPlaylist WHERE ID = ?", [.text(id)]) == 1 else {
                    throw DJCError.writeVerificationFailed(String(ui: "재생 목록 행을 지우지 못했습니다"))
                }
                work.tree.nodes[id] = nil
                work.tree.entries[id] = nil
                work.created.remove(id)
                work.deletedUUIDs.insert(uuid)
            }
            // 뒤 형제만 한 칸씩 당기고 번호 하나를 같이 받는다.
            let later = work.tree.children(of: node.parentID).filter { $0.seq > node.seq }
            if !later.isEmpty {
                usn += 1
                for sibling in later {
                    try touchPlaylist(db, sibling.id, ["Seq": .int(sibling.seq - 1)], usn: usn, stamp: stamp)
                    work.tree.nodes[sibling.id]?.seq -= 1
                }
            }
            return done(node)

        case let .addTracks(playlist, contentIDs):
            let node = try trackList(playlist, work: work)
            guard !contentIDs.isEmpty else { return done(node, .unchanged) }
            for id in Set(contentIDs) where try scalar(db, "SELECT count(*) FROM djmdContent WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) == 0 {
                throw PlaylistBlocked(name: node.name, reason: String(ui: "rekordbox 컬렉션에 없는 곡입니다(ContentID \(id))"))
            }
            var rows = work.tree.entries[node.id] ?? []
            let start = rows.map(\.trackNo).max() ?? 0
            // 끝에 붙이고, 한 번에 넣은 곡은 번호 하나를 같이 받는다.
            usn += 1
            for (i, contentID) in contentIDs.enumerated() {
                let entry = PlaylistTree.Entry(id: UUID().uuidString.lowercased(), contentID: contentID, trackNo: start + i + 1)
                try RekordboxTrackWriter.insert(db, table: "djmdSongPlaylist", [
                    "ID": .text(entry.id), "PlaylistID": .text(node.id), "ContentID": .text(contentID), "TrackNo": .int(entry.trackNo),
                    "UUID": .text(UUID().uuidString.lowercased()),
                ].merging(RekordboxTrackWriter.syncColumns(usn: usn, stamp: stamp)) { a, _ in a })
                rows.append(entry)
            }
            work.tree.entries[node.id] = rows
            work.xml.append(.touch(node.id))
            return done(node)

        case let .removeTracks(playlist, entries):
            let node = try trackList(playlist, work: work)
            let rows = work.tree.entries[node.id] ?? []
            let removed = try matching(entries, in: rows, playlist: node)
            guard !removed.isEmpty else { return done(node, .unchanged) }
            // 지운 행 몫으로 번호 하나를 비우고, 남은 곡은 자리가 그대로인 곡까지 모두 다시 매겨 번호 하나를 같이 받는다.
            usn += 1
            for entry in removed { _ = try db.run("DELETE FROM djmdSongPlaylist WHERE ID = ?", [.text(entry.id)]) }
            var remaining = rows.filter { row in !removed.contains { $0.id == row.id } }
            if !remaining.isEmpty {
                usn += 1
                for i in remaining.indices {
                    remaining[i].trackNo = i + 1
                    try touchEntry(db, remaining[i], usn: usn, stamp: stamp)
                }
            }
            work.tree.entries[node.id] = remaining.isEmpty ? nil : remaining
            work.xml.append(.touch(node.id))
            return done(node)

        case let .moveTracks(playlist, entries, to):
            let node = try trackList(playlist, work: work)
            let rows = work.tree.entries[node.id] ?? []
            let moving = try matching(entries, in: rows, playlist: node)
            var order = rows.filter { row in !moving.contains { $0.id == row.id } }
            order.insert(contentsOf: moving, at: min(max(to - 1, 0), order.count))
            // 자리가 바뀐 곡만 번호 하나를 같이 받는다.
            let changed = order.indices.filter { order[$0].trackNo != $0 + 1 }
            guard !changed.isEmpty else { return done(node, .unchanged) }
            usn += 1
            for i in changed {
                order[i].trackNo = i + 1
                try touchEntry(db, order[i], usn: usn, stamp: stamp)
            }
            work.tree.entries[node.id] = order
            work.xml.append(.touch(node.id))
            return done(node)
        }
    }

    // MARK: - 도움

    /// 편집할 목록(맨 위는 안 됨). 인텔리전트 재생 목록은 규칙을 확인하지 않아 막는다.
    static func target(_ ref: PlaylistRef, work: PlaylistWork) throws -> PlaylistTree.Node {
        let id: String
        switch ref {
        case .root: throw PlaylistBlocked(name: "root", reason: String(ui: "맨 위는 편집할 수 없습니다"))
        case let .id(value): id = value
        case let .new(key):
            guard let value = work.keys[key] else { throw PlaylistBlocked(name: key, reason: String(ui: "앞에서 만들지 못한 목록입니다")) }
            id = value
        }
        guard let node = work.tree.nodes[id] else { throw PlaylistBlocked(name: id, reason: String(ui: "rekordbox에서 재생 목록을 찾지 못했습니다")) }
        guard node.attribute <= 1, !node.smartList else { throw PlaylistBlocked(name: node.name, reason: String(ui: "인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)")) }
        return node
    }

    /// 곡을 담는 목록(폴더가 아님)
    static func trackList(_ ref: PlaylistRef, work: PlaylistWork) throws -> PlaylistTree.Node {
        let node = try target(ref, work: work)
        guard node.attribute == 0 else { throw PlaylistBlocked(name: node.name, reason: String(ui: "폴더에는 곡을 넣거나 뺄 수 없습니다")) }
        return node
    }

    /// 새 목록을 넣을 부모: 맨 위("root") 또는 폴더 ID
    static func folderID(_ ref: PlaylistRef, work: PlaylistWork, for name: String) throws -> String {
        if ref == .root { return "root" }
        let node = try target(ref, work: work)
        guard node.attribute == 1 else { throw PlaylistBlocked(name: name, reason: String(ui: "폴더가 아닌 재생 목록(\(node.name)) 안에는 넣을 수 없습니다")) }
        return node.id
    }

    /// 편집이 가리키는 곡 항목. 그 자리에 그 곡이 없으면(편집을 만든 뒤 rekordbox에서 목록이 바뀜) 막는다.
    static func matching(_ entries: [PlaylistEntry], in rows: [PlaylistTree.Entry], playlist: PlaylistTree.Node) throws -> [PlaylistTree.Entry] {
        guard Set(entries.map(\.trackNo)).count == entries.count else { throw PlaylistBlocked(name: playlist.name, reason: String(ui: "같은 자리를 두 번 가리킵니다")) }
        let picked = try entries.map { entry in
            guard let row = rows.first(where: { $0.trackNo == entry.trackNo && $0.contentID == entry.contentID }) else {
                throw PlaylistBlocked(name: playlist.name, reason: String(ui: "\(entry.trackNo)번째 곡이 편집을 만들 때와 다릅니다. 목록을 다시 읽은 뒤 고치세요"))
            }
            return row
        }
        return picked.sorted { $0.trackNo < $1.trackNo }
    }

    /// 재생 목록 행을 고친다: 칸 + 번호·시각·동기화 상태(256 → 257)
    static func touchPlaylist(_ db: CipherDatabase, _ id: String, _ values: [String: CipherDatabase.Value], usn: Int,
                              stamp: (db: String, json: String)) throws {
        let keys = values.keys.sorted()
        let sql = "UPDATE djmdPlaylist SET " + keys.map { "\"\($0)\" = ?" }.joined(separator: ", ")
            + ", rb_local_usn = ?, updated_at = ?, \(savedStatus) WHERE ID = ?"
        guard try db.run(sql, keys.map { values[$0]! } + [.int(usn), .text(stamp.db), .text(id)]) == 1 else {
            throw DJCError.writeVerificationFailed(String(ui: "재생 목록 행을 고치지 못했습니다"))
        }
    }

    static func touchEntry(_ db: CipherDatabase, _ entry: PlaylistTree.Entry, usn: Int, stamp: (db: String, json: String)) throws {
        guard try db.run("""
            UPDATE djmdSongPlaylist SET TrackNo = ?, rb_local_usn = ?, updated_at = ?,
                \(savedStatus) WHERE ID = ?
            """, [.int(entry.trackNo), .int(usn), .text(stamp.db), .text(entry.id)]) == 1 else {
            throw DJCError.writeVerificationFailed(String(ui: "재생 목록 곡 항목을 고치지 못했습니다"))
        }
    }

    /// rekordbox처럼 32비트 난수 ID. 지운 목록 행·XML에 남은 NODE와도 겹치지 않게.
    static func newPlaylistID(_ db: CipherDatabase, work: PlaylistWork) throws -> String {
        for _ in 0..<100 {
            let id = String(UInt32.random(in: 1...UInt32.max))
            if try scalar(db, "SELECT count(*) FROM djmdPlaylist WHERE ID = ?", [.text(id)]) == 0,
               let hex = MasterPlaylistsXML.hex(id), !work.xmlIDs.contains(hex) { return id }
        }
        throw DJCError.writeVerificationFailed(String(ui: "새 재생 목록 ID를 만들지 못했습니다"))
    }

    // MARK: - 검증

    /// 쓴 뒤 재생 목록 표가 계획과 같은지(쓰기 트랜잭션 안과 커밋 뒤 두 번)
    static func verifyPlaylists(_ work: PlaylistWork, db: CipherDatabase) throws {
        guard try PlaylistTree.read(db) == work.tree else { throw DJCError.writeVerificationFailed(String(ui: "재생 목록이 계획과 다릅니다")) }
        for id in work.created {
            guard let uuid = work.tree.nodes[id]?.uuid,
                  try scalar(db, "SELECT count(*) FROM djmdCloudFilterPlaylist WHERE PlaylistUUID = ?", [.text(uuid)]) == 1 else {
                throw DJCError.writeVerificationFailed(String(ui: "새 재생 목록의 클라우드 거울 행이 없습니다"))
            }
        }
        for uuid in work.deletedUUIDs where try scalar(db, "SELECT count(*) FROM djmdCloudFilterPlaylist WHERE PlaylistUUID = ?", [.text(uuid)]) != 0 {
            throw DJCError.writeVerificationFailed(String(ui: "지운 재생 목록의 클라우드 거울 행이 남았습니다"))
        }
    }

    // MARK: - masterPlaylists6.xml

    /// DB를 커밋한 뒤 XML을 고친다. 만든 NODE는 끝에 붙이고, 바뀐 목록·부모의 Timestamp를 쓴 시각으로 한다. 지운 목록의 NODE는 남긴다.
    static func applyPlaylistXML(_ changes: [PlaylistXMLChange], to xml: MasterPlaylistsXML, now: Date) throws -> MasterPlaylistsXML {
        var xml = xml
        let timestamp = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        // Timestamp는 모두 같은 값이라 모아서 마지막에 한 번 훑는다(만들기는 이미 그 시각, 옮기기는 Timestamp를 건드리지 않는다).
        var touched: Set<String> = []
        for change in changes {
            switch change {
            case let .append(id, parentID, isFolder): try xml.append(id: id, parentID: parentID, isFolder: isFolder, timestamp: timestamp)
            case let .touch(id): touched.insert(id)
            case let .parent(id, parentID): try xml.update(id: id, parentID: parentID)
            }
        }
        xml.touch(ids: touched, timestamp: timestamp)
        // 만들고 옮긴 NODE의 마지막 부모가 DB와 같은지
        var parents: [String: String] = [:]
        for change in changes {
            switch change {
            case let .append(id, parentID, _), let .parent(id, parentID): parents[id] = parentID
            case .touch: break
            }
        }
        for (id, parentID) in parents where xml.node(id: id)?.parentID != MasterPlaylistsXML.hex(parentID) {
            throw DJCError.writeVerificationFailed(String(ui: "masterPlaylists6.xml에 재생 목록을 적지 못했습니다"))
        }
        return xml
    }
}
