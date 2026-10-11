import CryptoKit
import DJCDomain
import Foundation

/// 곡 정보에서 그림 넣기·바꾸기·지우기(#66). rekordbox 라이브러리의 그림 파일 셋·`ImagePath`·`artwork.jpg` 파일 행만 고치고
/// 음원 파일에 든 그림은 그대로 둔다(rekordbox는 음원의 APIC·covr·PICTURE도 바꾸지만 DJCrate는 음원을 쓰지 않는다).
///
/// rekordbox 7.2.18이 하는 것(docs/rekordbox-internals.md "그림 편집"):
/// - 넣기(`ImagePath` '', 살아 있는 파일 행 없음): 곡 행 `ImagePath`·상태 256 → 257·번호·시각 → 파일 행. 같은 ID의 삭제 표시 행(262·258)이
///   있으면 그 행을 되살리고(#173 S2 U08 262·S5 W3b 258: Hash·Size·→ 257·삭제 0·번호·시각), 없으면 `fileRow` 모양으로 넣는다(묶음 2 S1, #173 S3 V04).
/// - 바꾸기(`ImagePath`가 곡 UUID 폴더, 살아 있는 파일 행 하나): 곡 행은 그대로, 파일 행 Hash·Size·256 → 257·번호·시각(묶음 2 S2, #173 S1 X2·X3).
/// - 지우기: 곡 행 `ImagePath` ''·256 → 257·번호·시각, 파일 행은 상태 0이면 DELETE(번호 없음, 묶음 2 S3), 256·257이면 258·삭제 1·번호·시각
///   (#173 S2 U09·U03, S5 W1 256·W2b 257). 그림 셋은 지우고 폴더는 남긴다.
/// 셋 다 `TrackInfoUpdated`와 재생 목록 XML을 바꾸지 않는다(#173 S1 X2·S3 V04·S5 W1·W2b·W3a: 그 곡이 든 살아 있는 목록의 NODE가 그대로).
/// 그림 파일은 커밋하고 다시 읽어 확인한 뒤 쓴다. 바꾸거나 지울 옛 파일은 백업의 `anlz/`에 두어 "쓰기 전으로 복원…"과 실패 복원이 되살린다.
extension RekordboxWriter {
    /// 그림 쓰기를 확인한 곡 상태(묶음 2 상태 0, #173 256·257)
    static let verifiedArtworkTrackStates: Set<Int> = [0, 256, 257]

    /// 그림 초안 하나의 계획(트랜잭션 밖에서 정한다)
    struct ArtworkPlan {
        enum Action: Equatable {
            /// 새 파일 행(상태 0)
            case insert
            /// 같은 ID의 삭제 표시 행(262·258) 되살리기
            case revive
            /// 파일 행 제자리 고치기(상태 0·256·257)
            case replace(fileStatus: Int)
            /// 파일 행 지우기(0) 또는 258 표시(256·257)
            case delete(fileStatus: Int)
        }

        var edit: ArtworkEdit
        var contentID: String
        var title: String
        var action: Action
        /// 곡 UUID 폴더의 `artwork.jpg`(`ImagePath`)
        var imagePath: String
        /// `<곡 UUID>_<경로, /는 %2F>`
        var fileID: String
        /// 새 그림 셋(`artwork.jpg`·`_m`·`_s`, 넣기·바꾸기)
        var files: [(URL, Data)] = []
        /// 지금 있는 그림 셋(바꾸기·지우기)과 그 바이트. 백업한 뒤 덮거나 지우고, 실패하면 이 바이트로 되돌린다.
        var existing: [(URL, Data)] = []
        /// 그림을 쓰는 share 뿌리(쓰기 직전 링크를 다시 본다)
        var share: URL

        var uuid: String { edit.trackUUID }
        var kind: ArtworkWriteKind {
            switch action {
            case .insert, .revive: .add
            case .replace: .replace
            case .delete: .delete
            }
        }
    }

    /// 쓴 뒤 다시 읽어 볼 것(트랜잭션 안과 커밋 뒤)
    struct ArtworkExpectation {
        var plan: ArtworkPlan
        /// 곡 행에서 볼 칸. 바꾸기는 곡 행을 건드리지 않으므로 `ImagePath`만 본다. 같은 쓰기의 태그가 곡 행을 다시 고치면 번호를 맞춘다.
        var track: [String: CipherDatabase.Value]
        /// 쓴 뒤 파일 행 전체(지운 행이면 nil)
        var file: [String: CipherDatabase.Value]?
    }

    /// 백업에 둔 그림 초안과 그림 사본(되돌리면 DJCrate에 다시 살린다)
    public static func artworkDrafts(in backup: URL) -> [ArtworkEdit] {
        let folder = backup.appending(path: "artwork-drafts")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let draft = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(ArtworkDraft.self, from: $0) }) else { return nil }
            let image = draft.change == .set ? try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("image")) : nil
            return ArtworkEdit(draft: draft, image: image)
        }
    }

    /// 곡의 지금 그림 상태(초안의 base). 곡이 없으면 nil.
    public static func artworkBase(db: CipherDatabase, contentID: String) throws -> ArtworkBase? {
        var imagePath: String??
        try db.query("SELECT ImagePath FROM djmdContent WHERE ID = ?", [.text(contentID)]) { imagePath = .some($0.string(0)) }
        guard let imagePath else { return nil }
        return ArtworkBase(imagePath: imagePath ?? "", files: try artworkRows(db, contentID: contentID).filter { !$0.deleted }.map(\.base))
    }

    /// 곡의 그림 파일 행(지운 행까지)
    struct ArtworkRow {
        var id: String
        var base: ArtworkFileRow
        var deleted: Bool
    }

    static func artworkRows(_ db: CipherDatabase, contentID: String) throws -> [ArtworkRow] {
        var rows: [ArtworkRow] = []
        try db.query("""
            SELECT ID, Path, Hash, Size, rb_data_status, rb_local_deleted FROM contentFile
            WHERE ContentID = ? AND substr(Path, 1, 17) = '/PIONEER/Artwork/' ORDER BY ID
            """, [.text(contentID)]) { r in
            rows.append(ArtworkRow(id: r.string(0) ?? "", base: ArtworkFileRow(path: r.string(1) ?? "", hash: r.string(2), size: r.int(3), status: r.int(4)),
                                   deleted: (r.int(5) ?? 0) != 0))
        }
        return rows
    }

    /// 쓰기 전에 막을 조건을 보고 할 일을 정한다. 백업 전(읽기 연결)과 트랜잭션 안에서 같은 함수로 두 번 본다. 막히면 `Blocked`.
    /// - Parameter prepare: 새 그림 셋을 만든다(백업 전 한 번. 트랜잭션 안에서는 앞서 만든 셋을 쓴다).
    static func checkArtwork(_ edit: ArtworkEdit, db: CipherDatabase, share: URL?, prepare: Bool) throws -> ArtworkPlan {
        let draft = edit.draft
        var contents: [(id: String, title: String, deleted: Bool, state: Int?, imagePath: String?, analysis: String?, audio: String)] = []
        try db.query("""
            SELECT ID, Title, rb_local_deleted, rb_data_status, ImagePath, AnalysisDataPath, FolderPath FROM djmdContent WHERE UUID = ?
            """, [.text(draft.trackUUID)]) { r in
            contents.append((r.string(0) ?? "", r.string(1) ?? "", (r.int(2) ?? 0) != 0, r.int(3), r.string(4), r.string(5), r.string(6) ?? ""))
        }
        guard contents.count == 1, let content = contents.first else {
            throw Blocked(title: draft.trackUUID, reason: contents.isEmpty ? String(ui: "rekordbox 컬렉션에서 곡을 찾지 못했으니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요") : String(ui: "같은 UUID의 곡이 여럿인 구조는 지원하지 않으니 rekordbox에서 곡을 확인하고 직접 편집하세요"))
        }
        func block(_ reason: String) -> Blocked { Blocked(title: content.title, reason: reason) }
        guard !content.deleted else { throw block(String(ui: "rekordbox 컬렉션에서 지운 곡이니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요")) }
        guard let state = content.state, verifiedArtworkTrackStates.contains(state) else {
            throw block(String(ui: "이 곡의 동기화 상태에서는 앨범아트 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        guard let share else { throw block(String(ui: "사본 DB에는 share 폴더를 주어야 앨범아트를 씁니다")) }
        // 묶음 2·#173 실험 곡은 모두 분석한 곡이었다. 분석 전 곡에 그림을 넣는 모양은 보지 못했다.
        guard !(content.analysis ?? "").isEmpty else {
            throw block(String(ui: "분석 전 곡의 앨범아트 쓰기는 확인하지 못했으니 rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요"))
        }
        let imagePath = TrackArtwork.imagePath(uuid: draft.trackUUID)
        let fileID = RekordboxTrackWriter.fileRowID(uuid: draft.trackUUID, path: imagePath)
        let rows = try artworkRows(db, contentID: content.id)
        let live = rows.filter { !$0.deleted }, dead = rows.filter(\.deleted)
        let current = content.imagePath ?? ""
        var plan = ArtworkPlan(edit: edit, contentID: content.id, title: content.title, action: .insert, imagePath: imagePath, fileID: fileID,
                               share: share)
        // 그림 폴더 위가 링크면 아직 없는 곡 UUID 폴더를 통해 share 밖에 쓰게 된다(#66 리뷰).
        let folderURL = share.appending(path: String(TrackArtwork.folder(uuid: draft.trackUUID).dropFirst()))
        guard !TrackArtwork.fileNames.contains(where: { hasSymlinkComponent(folderURL.appending(path: $0), under: share) }) else {
            throw block(artworkLinkReason)
        }

        // 곡 UUID 폴더의 세 파일만 다룬다(곡 빼기와 같은 경계: 심볼릭 링크·음원 경로·다른 곡과 같은 폴더는 건드리지 않는다).
        let owned = OwnedTrackFiles(uuid: draft.trackUUID, analysis: nil, image: imagePath, audio: content.audio)
        guard let candidates = ownedCandidates(owned, share: share),
              try scalar(db, "SELECT count(*) FROM djmdContent WHERE ID != ? AND substr(ImagePath, 1, ?) = ?",
                         [.text(content.id), .int(TrackArtwork.folder(uuid: draft.trackUUID).count + 1),
                          .text(TrackArtwork.folder(uuid: draft.trackUUID) + "/")]) == 0,
              try scalar(db, "SELECT count(*) FROM djmdContent WHERE FolderPath IN (?, ?, ?)", candidates.map { .text($0.path) }) == 0 else {
            throw block(String(ui: "앨범아트 폴더가 예상과 달라(링크·다른 곡과 같은 폴더) 쓰지 않으니 rekordbox에서 앨범아트를 직접 고치세요"))
        }
        let present = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }

        if current.isEmpty {
            guard draft.change == .set else { throw block(String(ui: "앨범아트가 없는 곡이라 지울 것이 없으니 앨범아트 초안을 버리세요")) }
            guard live.isEmpty else {
                throw block(String(ui: "앨범아트 경로는 비었는데 앨범아트 기록이 남아 있어 쓰지 않으니 rekordbox에서 앨범아트를 다시 넣은 뒤 쓰세요"))
            }
            if let row = dead.first {
                guard dead.count == 1, row.id == fileID, row.base.path == imagePath else {
                    throw block(String(ui: "지운 앨범아트 기록이 예상과 달라 쓰지 않으니 rekordbox에서 앨범아트를 직접 넣으세요"))
                }
                // 262(옛 동기화에서 지운 행, #173 S2 U08)·258(DJCrate·rekordbox가 지운 동기화 행, S5 W3b) 모두 같은 행을 되살린다.
                guard row.base.status == 262 || row.base.status == 258 else {
                    throw block(String(ui: "지운 앨범아트 기록의 동기화 상태에서는 앨범아트 넣기를 확인하지 못했으니 rekordbox에서 직접 넣으세요"))
                }
                plan.action = .revive
            }
            guard present.isEmpty else { throw block(String(ui: "앨범아트 폴더에 파일이 이미 있어 쓰지 않으니 rekordbox에서 앨범아트를 확인하세요")) }
        } else {
            guard current == imagePath else {
                throw block(String(ui: "앨범아트 경로가 곡 폴더와 달라 쓰지 않으니 rekordbox에서 앨범아트를 다시 넣은 뒤 쓰세요"))
            }
            guard let row = live.first else {
                throw block(String(ui: "앨범아트 기록(contentFile)이 없는 곡이라 쓰지 않으니 rekordbox에서 앨범아트를 다시 넣은 뒤 쓰세요"))
            }
            guard live.count == 1 else { throw block(String(ui: "앨범아트 기록이 여럿인 곡이라 쓰지 않으니 rekordbox에서 앨범아트를 확인하세요")) }
            guard row.id == fileID, row.base.path == imagePath else {
                throw block(String(ui: "앨범아트 경로가 곡 폴더와 달라 쓰지 않으니 rekordbox에서 앨범아트를 다시 넣은 뒤 쓰세요"))
            }
            let status = row.base.status ?? -1
            switch draft.change {
            case .set:
                guard [0, 256, 257].contains(status) else {
                    throw block(String(ui: "이 앨범아트 기록의 동기화 상태에서는 바꾸는 규칙을 확인하지 못했으니 rekordbox에서 직접 고치세요"))
                }
                plan.action = .replace(fileStatus: status)
            case .delete:
                // 0은 지우고, 256·257은 258·삭제 표시(#173 S2 U09, S5 W1 256·W2b 257)
                guard [0, 256, 257].contains(status) else {
                    throw block(String(ui: "이 앨범아트 기록의 동기화 상태에서는 지우는 규칙을 확인하지 못했으니 rekordbox에서 직접 지우세요"))
                }
                plan.action = .delete(fileStatus: status)
            }
            plan.existing = try present.map { ($0, try Data(contentsOf: $0)) }
        }
        guard ArtworkBase(imagePath: current, files: live.map(\.base)) == draft.base else {
            throw block(String(ui: "초안을 만든 뒤 rekordbox에서 앨범아트가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요"))
        }
        if draft.change == .set {
            guard let image = edit.image else { throw block(String(ui: "앨범아트 사본이 없으니 앨범아트를 다시 고르세요")) }
            if let sha = draft.imageSHA256, sha != SHA256.hash(data: image).map({ String(format: "%02x", $0) }).joined() {
                throw block(String(ui: "앨범아트 사본이 초안과 다르니 앨범아트를 다시 고르세요"))
            }
            if let reason = TrackArtwork.unsupportedReason(image) { throw block(reason) }
            if prepare {
                guard let files = TrackArtwork.make(image) else { throw block(String(ui: "앨범아트를 읽지 못했으니 다른 JPEG·PNG 앨범아트를 고르세요")) }
                plan.files = RekordboxTrackWriter.PreparedArtwork(uuid: draft.trackUUID, files: files, share: share).files
            }
        }
        return plan
    }

    /// 백업 전 확인: DB를 바꾸지 않고 막힘을 거르고 그림 셋을 만든다.
    /// - Returns: 통과한 계획, 막힌 결과
    static func checkArtworkDrafts(_ edits: [ArtworkEdit], db: CipherDatabase, share: URL?) throws -> (passed: [ArtworkPlan], blocked: [Outcome]) {
        var passed: [ArtworkPlan] = [], blocked: [Outcome] = []
        var seen: Set<String> = []
        for edit in edits {
            do {
                guard seen.insert(edit.trackUUID).inserted else {
                    throw Blocked(title: edit.trackUUID, reason: String(ui: "한 곡에 앨범아트 초안이 여럿이니 하나만 남기고 다시 쓰세요"))
                }
                passed.append(try checkArtwork(edit, db: db, share: share, prepare: true))
            } catch let error as Blocked {
                blocked.append(Outcome(trackUUID: edit.trackUUID, title: error.title, status: .blocked, reason: error.reason, removed: 0, added: 0,
                                       artwork: edit.draft.kind))
            }
        }
        return (passed, blocked)
    }

    /// 바꾸거나 지울 옛 그림 파일을 백업 `anlz/`에 둔다(이름 `artwork-<n>.jpg`, 원래 자리는 manifest.json에 더한다).
    /// 그리드 백업(`backupAnalysis`)이 manifest를 새로 쓰므로 그 뒤에 부른다.
    static func backupArtworkFiles(_ plans: [ArtworkPlan], in backup: URL, shareRoot: URL) throws {
        let files = plans.flatMap(\.existing)
        guard !files.isEmpty else { return }
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifestURL = folder.appending(path: "manifest.json")
        var manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        for (file, data) in files {
            let name = "artwork-\(manifest.count).\(file.pathExtension)"
            try data.write(to: folder.appending(path: name))
            manifest[name] = try backupTarget(file.path, shareRoot: shareRoot).relative
        }
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    /// 그림 초안 하나를 트랜잭션 안에서 쓴다. 막히면 `Blocked`(부른 쪽이 SAVEPOINT로 되돌린다).
    static func applyArtwork(_ prepared: ArtworkPlan, db: CipherDatabase, share: URL?, usn: inout Int,
                             stamp: (db: String, json: String)) throws -> ArtworkExpectation {
        var plan = try checkArtwork(prepared.edit, db: db, share: share, prepare: false)
        guard plan.action == prepared.action else {
            throw Blocked(title: plan.title, reason: String(ui: "초안을 만든 뒤 rekordbox에서 앨범아트가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요"))
        }
        plan.files = prepared.files
        func fail(_ reason: String) -> DJCError { .writeVerificationFailed("\(reason) (\(plan.title))") }
        var track: [String: CipherDatabase.Value] = [:]
        var file: [String: CipherDatabase.Value]?
        /// 곡 행: `ImagePath`·상태 256 → 257·번호·시각(넣기·지우기). TIU는 그대로다.
        func saveTrack(imagePath: String) throws {
            var state: Int?
            try db.query("SELECT rb_data_status FROM djmdContent WHERE ID = ?", [.text(plan.contentID)]) { state = $0.int(0) }
            usn += 1
            guard try db.run("UPDATE djmdContent SET ImagePath = ?, \(savedStatus), rb_local_usn = ?, updated_at = ? WHERE ID = ?",
                             [.text(imagePath), .int(usn), .text(stamp.db), .text(plan.contentID)]) == 1 else {
                throw fail(String(ui: "곡 행에 앨범아트 경로를 쓰지 못했습니다"))
            }
            track = ["ImagePath": .text(imagePath), "rb_data_status": raisedStatus(state), "rb_local_usn": .int(usn), "updated_at": .text(stamp.db)]
        }
        /// 파일 행 제자리 고치기. 고치지 않는 칸은 고치기 전 값 그대로인지까지 본다.
        /// - Parameter raisesStatus: 상태 256 → 257(0·257 그대로). 아니면 `assignments`에 상태를 직접 적는다.
        func updateFile(_ assignments: [(String, CipherDatabase.Value)], raisesStatus: Bool) throws {
            var expected = try rowValues(db, table: "contentFile", id: plan.fileID)
            usn += 1
            let values = assignments + [("rb_local_usn", .int(usn)), ("updated_at", .text(stamp.db))]
            let sets = values.map { "\"\($0.0)\" = ?" } + (raisesStatus ? [savedStatus] : [])
            guard try db.run("UPDATE contentFile SET \(sets.joined(separator: ", ")) WHERE ID = ?", values.map(\.1) + [.text(plan.fileID)]) == 1 else {
                throw fail(String(ui: "앨범아트 기록을 고치지 못했습니다"))
            }
            if raisesStatus, case let .int(status)? = expected["rb_data_status"] { expected["rb_data_status"] = .int(savedState(status)) }
            file = expected.merging(values) { _, new in new }
        }
        let hash: CipherDatabase.Value = .text(plan.files.first.map { md5($0.1) } ?? "")
        let size: CipherDatabase.Value = .int(plan.files.first?.1.count ?? 0)
        switch plan.action {
        case .insert:
            // 곡 행 → 파일 행(묶음 2 S1 1006079·1006080, #173 S3 V04 119·120)
            try saveTrack(imagePath: plan.imagePath)
            usn += 1
            guard let full = plan.files.first else { throw fail(String(ui: "앨범아트 파일을 만들지 못했습니다")) }
            let row = RekordboxTrackWriter.fileRow(uuid: plan.uuid, share: share, full, contentID: plan.contentID, usn: usn, stamp: stamp)
            try RekordboxTrackWriter.insert(db, table: row.table, row.values)
            file = row.values
        case .revive:
            // #173 S2 U08(262)·S5 W3b(258): 곡 행(132·116) → 같은 ID 행 되살리기(133·117). 바뀌는 칸은 여섯뿐이다.
            try saveTrack(imagePath: plan.imagePath)
            try updateFile([("Hash", hash), ("Size", size), ("rb_data_status", .int(257)), ("rb_local_deleted", .int(0))], raisesStatus: false)
        case .replace:
            // 곡 행은 그대로(묶음 2 S2, #173 S1 X2·X3). 파일 행만 번호 하나.
            try updateFile([("Hash", hash), ("Size", size)], raisesStatus: true)
            track = ["ImagePath": .text(plan.imagePath)]
        case let .delete(status):
            // 곡 행 → 파일 행. 상태 0은 실제로 지우고(번호 없음, 묶음 2 S3), 256·257은 258·삭제 표시 네 칸(#173 S2 U09 134·135, S5 W1·W2b).
            try saveTrack(imagePath: "")
            if status == 0 {
                guard try db.run("DELETE FROM contentFile WHERE ID = ?", [.text(plan.fileID)]) == 1 else { throw fail(String(ui: "앨범아트 기록을 지우지 못했습니다")) }
            } else {
                try updateFile([("rb_data_status", .int(258)), ("rb_local_deleted", .int(1))], raisesStatus: false)
            }
        }
        let expectation = ArtworkExpectation(plan: plan, track: track, file: file)
        try verifyArtwork(db: db, expectation)
        return expectation
    }

    /// 곡 행·파일 행이 쓴 그대로인지 다시 읽어 확인한다(트랜잭션 안과 커밋 뒤).
    static func verifyArtwork(db: CipherDatabase, _ expected: ArtworkExpectation) throws {
        do {
            try RekordboxTrackWriter.verify(db, table: "djmdContent", id: expected.plan.contentID, expected.track)
            if let file = expected.file {
                try RekordboxTrackWriter.verify(db, table: "contentFile", id: expected.plan.fileID, file)
            } else {
                guard try scalar(db, "SELECT count(*) FROM contentFile WHERE ID = ?", [.text(expected.plan.fileID)]) == 0 else {
                    throw DJCError.writeVerificationFailed("")
                }
            }
        } catch DJCError.writeVerificationFailed {
            throw DJCError.writeVerificationFailed("\(String(ui: "앨범아트 기록 확인 실패")) (\(expected.plan.title))")
        }
    }

    /// 커밋 뒤 그림 파일을 쓰거나 지운다. 새로 만든 파일은 `created`에 더한다(실패하면 지우고, "쓰기 전으로 복원…"도 지운다).
    /// 바꾸기·지우기의 옛 파일은 백업에 있어 실패하면 `restoreAnalysis`가 되살린다. 쓴 뒤 `artwork.jpg`의 MD5·크기가 파일 행과 같은지 본다.
    static func writeArtworkFiles(_ expected: ArtworkExpectation, created: inout [URL]) throws {
        let fm = FileManager.default
        let plan = expected.plan
        func fail(_ reason: String) -> DJCError { .writeVerificationFailed("\(reason) (\(plan.title))") }
        // 확인한 뒤 링크가 생겼어도 share 밖에 쓰거나 지우지 않는다.
        guard !(plan.files.map(\.0) + plan.existing.map(\.0)).contains(where: { hasSymlinkComponent($0, under: plan.share) }) else {
            throw fail(artworkLinkReason)
        }
        switch plan.kind {
        case .add, .replace:
            for (url, data) in plan.files {
                let existed = fm.fileExists(atPath: url.path)
                if plan.kind == .add, existed { throw fail(String(ui: "파일이 이미 있습니다: \(url.lastPathComponent)")) }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                if !existed { created.append(url) }
                guard try Data(contentsOf: url) == data else { throw fail(String(ui: "파일 확인 실패: \(url.lastPathComponent)")) }
            }
            guard let full = plan.files.first, case .text(md5(try Data(contentsOf: full.0)))? = expected.file?["Hash"],
                  case .int(try Data(contentsOf: full.0).count)? = expected.file?["Size"] else {
                throw fail(String(ui: "앨범아트 파일과 앨범아트 기록의 해시·크기가 다릅니다"))
            }
        case .delete:
            // 폴더는 남긴다(묶음 2 S3·#173 S2 U09)
            for (url, _) in plan.existing where fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            guard plan.existing.allSatisfy({ !fm.fileExists(atPath: $0.0.path) }) else { throw fail(String(ui: "앨범아트 파일을 지우지 못했습니다")) }
        }
    }

    /// 바꾸거나 지운 옛 그림을 원래 바이트로 되돌린다(쓰기 실패 뒤). 그대로인 파일은 건드리지 않는다(잠긴 폴더에서 쓰기 전에 실패한 경우).
    static func restoreArtworkFiles(_ expectations: [ArtworkExpectation]) throws {
        let files = expectations.flatMap(\.plan.existing).filter { (try? Data(contentsOf: $0.0)) != $0.1 }
        try each(files) { url, original in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: url, options: .atomic)
        }
    }

    /// 행 하나의 모든 칸(형식 그대로). 고치지 않는 칸이 그대로인지 볼 때 쓴다.
    static func rowValues(_ db: CipherDatabase, table: String, id: String) throws -> [String: CipherDatabase.Value] {
        var columns: [String] = []
        try db.query("PRAGMA table_info(\(table))") { columns.append($0.string(1) ?? "") }
        var values: [String: CipherDatabase.Value] = [:]
        try db.query("SELECT \(columns.map { "\"\($0)\", typeof(\"\($0)\")" }.joined(separator: ", ")) FROM \(table) WHERE ID = ?", [.text(id)]) { r in
            for (i, column) in columns.enumerated() {
                switch r.string(Int32(i * 2 + 1)) {
                case "integer": values[column] = .int(r.int(Int32(i * 2)) ?? 0)
                case "real": values[column] = .real(r.double(Int32(i * 2)) ?? 0)
                case "text": values[column] = .text(r.string(Int32(i * 2)) ?? "")
                default: values[column] = .null
                }
            }
        }
        return values
    }

    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

