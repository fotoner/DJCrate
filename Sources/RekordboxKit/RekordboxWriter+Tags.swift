import DJCDomain
import Foundation

/// 태그(곡 정보) 쓰기: `djmdContent` 제자리 UPDATE + 새 이름이면 `djmdArtist`·`djmdAlbum`·`djmdGenre` 행(#1).
/// rekordbox 라이브러리만 바꾸고 음원 파일 태그는 건드리지 않는다(rekordbox는 파일 태그도 다시 쓰지만 DJCrate는 음원을 읽기만 한다).
///
/// rekordbox 7.2.18 정보 패널은 칸마다 따로 저장한다(2026-09-27 "DJC 실험곡 1~5"). DJCrate는 여러 칸을 한 번에 쓰지만
/// 결과는 그 칸들을 하나씩 저장한 것과 같게 한다: 칸마다 `TrackInfoUpdated` +1, 새 이름 행, 버려진 이름 행 삭제, 곡 행은 마지막 번호.
extension RekordboxWriter {
    /// rekordbox 실험으로 쓰기 규칙을 확인한 칸. 이 밖의 칸을 고친 초안은 곡째 막는다(docs/rekordbox-internals.md "태그 (곡 정보)").
    /// 공유 앨범 값 변경·동명 앨범 선택·미확인 상태는 `checkTags`에서 곡째 막는다.
    /// 평점·곡 색(#65)은 칸마다 확인한 범위(`TagWriteScope.byKey`, 상태 0·256·257, 재생 목록에 든 곡 포함 R65)로 곡마다 다시 거른다.
    public static let writableTagKeys: Set<TagFields.Key> = [.title, .artist, .album, .albumArtist, .genre, .composer, .year, .trackNumber, .comment,
                                                             .musicalKey, .rating, .color]
    /// 태그 쓰기를 확인한 곡·앨범 상태(#171·#173 2026-10-04). 0 그대로, 256 → 257, 257 그대로. 그 밖의 상태는 막는다.
    static let verifiedTagStates: Set<Int> = [0, 256, 257]
    /// 쓰면 재생 목록 XML(`masterPlaylists6.xml`)의 Timestamp를 고치는 칸. 정보 패널 아홉 칸(#173)과 키(S5 K1, 2026-10-04 rekordbox 7.2.18:
    /// 동기화 곡의 키 3B → 5A 저장이 그 곡이 든 목록의 Timestamp를 곡 행 `updated_at` 약 15ms 뒤 시각으로 고쳤다)가 모두 고친다[확인].
    /// 평점·곡 색도 같다(R65, 2026-10-09 rekordbox 7.2.18: 재생 목록에 든 곡의 평점·곡 색 저장이 그 곡이 든 일반 목록 NODE의 Timestamp만 고쳤다).
    /// XML 규칙은 이 집합과 `touchesPlaylistXML` 한 곳에서만 정한다. XML 규칙을 확인하지 않은 칸(`TagWriteScope.playlistXML` false)은 빠지고
    /// 재생 목록에 든 곡이면 쓰기 전에 막는다.
    static let playlistXMLTagKeys: Set<TagFields.Key> = Set(TagFields.Key.allCases.filter { TagWriteScope.scope(for: $0).playlistXML })

    /// 쓴 뒤 곡이 가져야 할 태그
    struct TagExpectation {
        var contentID: String
        var fields: TagFields
        var trackInfoUpdated: String
        var contentUSN: Int
        /// 쓴 뒤 곡의 `rb_data_status`(256 → 257, 0·257은 그대로)
        var dataStatus: Int?
        /// 곡 행에 쓴 `AlbumID`(앨범 칸을 쓰거나 같은 이름의 새 앨범으로 옮겼을 때). 이름·앨범 아티스트가 같아도 옮겼는지 본다.
        var albumID: String?
        /// 변경 번호를 준 앨범 행(ID → 번호·상태). 같은 반영 안의 뒤 편집은 마지막 기대값을 맡는다.
        var touchedAlbums: [String: (usn: Int, status: Int)] = [:]
        /// 아무 곡도 안 쓰게 되어 지운 이름 행(표, ID). 상태 0 행이다.
        var deletedNames: [(table: NameTable, id: String)] = []
        /// 아무 곡도 안 쓰게 되어 258로 표시한 동기화 이름·앨범 행(#173)
        var markedNames: [MarkedName] = []
        /// 쓴 `KeyID`(키 칸을 고쳤을 때만). 지우면 '0'
        var keyID: String?
        /// 쓴 `Rating`(평점 칸을 고쳤을 때만, 정수). 지우면 0
        var rating: Int?
        /// 쓴 `ColorID`(곡 색 칸을 고쳤을 때만, 글자). 지우면 '0'
        var colorID: String?

        /// 버려진 앨범 행(지웠거나 258로 표시). 같은 반영의 앞 편집이 그 행에 건 기대값은 뒤 편집이 맡는다.
        var releasedAlbums: Set<String> {
            Set(deletedNames.filter { $0.table == .album }.map(\.id) + markedNames.filter { $0.table == .album }.map(\.id))
        }
    }

    /// 258로 표시한 행이 가져야 할 칸. 클라우드 `usn`·`rb_local_synced`는 그대로다(#173 S1 T02, 2026-10-04).
    struct MarkedName {
        var table: NameTable
        var id: String
        var usn: Int
        /// `quote(usn)`
        var cloudUSN: String
        var synced: Int?
    }

    /// 쓰기 전 곡 행이 가리키는 이름·앨범과 곡의 앨범 행의 앨범 아티스트
    struct TagOldNames {
        var artist: String?
        var composer: String?
        var genre: String?
        var album: String?
        var albumArtist: String?
        var orgArtist: String?
        var remixer: String?
        /// 곡의 앨범 행이 살아 있는지(지운 앨범 행은 저장하지 않는다)
        var albumLive = false
        var albumName: String?

        static func read(_ db: CipherDatabase, contentID: String) throws -> TagOldNames? {
            var old: TagOldNames?
            try db.query("""
                SELECT c.ArtistID, c.ComposerID, c.GenreID, c.AlbumID, a.AlbumArtistID, c.OrgArtistID, c.RemixerID, a.rb_local_deleted, a.Name
                FROM djmdContent c LEFT JOIN djmdAlbum a ON a.ID = c.AlbumID WHERE c.ID = ?
                """, [.text(contentID)]) { r in
                old = TagOldNames(artist: r.string(0), composer: r.string(1), genre: r.string(2), album: r.string(3), albumArtist: r.string(4),
                                  orgArtist: r.string(5), remixer: r.string(6), albumLive: r.int(7) == 0, albumName: r.string(8))
            }
            return old
        }
    }

    /// 트랜잭션 안에서 확인을 통과한 곡
    struct CheckedTag {
        var id: String
        var title: String
        var trackInfoUpdated: String?
        var state: Int?
        var old: TagOldNames
        /// 아티스트를 고치며 같은 이름의 새 앨범으로 옮기는지(`migratesToSameNameAlbum`)
        var migratesAlbum = false
        /// 키 칸을 고칠 때 `KeyID`에 쓸 값: 고른 이름의 살아 있는 `djmdKey` 줄 ID, 지우면 '0'(`resolveKeyID`)
        var keyID: String?
        /// 쓰기 전 곡 정보(`currentTags`). 고치지 않은 독립 칸(키·평점·곡 색)의 기대값이다.
        var current = TagFields()
    }

    /// 백업에 둔 태그 초안(되돌리면 DJCrate에 다시 살린다)
    public static func tagDrafts(in backup: URL) -> [TagDraft] {
        let folder = backup.appending(path: "tag-drafts")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(TagDraft.self, from: $0) }
    }

    /// 곡의 지금 태그. 라이브러리 읽기(`RekordboxLibrary.load` → `TagFields(track:)`)와 같은 규칙이라 초안의 base와 바로 비교한다.
    package static func currentTags(db: CipherDatabase, contentID: String) throws -> TagFields? {
        var fields: TagFields?
        try db.query("""
            SELECT c.Title, a.Name, al.Name, aa.Name, g.Name, cp.Name, c.ReleaseYear, c.TrackNo, c.Commnt, k.ScaleName,
                   c.Rating, c.ColorID
            FROM djmdContent c
            LEFT JOIN djmdArtist a ON a.ID = c.ArtistID
            LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
            LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID
            LEFT JOIN djmdGenre g ON g.ID = c.GenreID
            LEFT JOIN djmdArtist cp ON cp.ID = c.ComposerID
            LEFT JOIN djmdKey k ON k.ID = c.KeyID
            WHERE c.ID = ?
            """, [.text(contentID)]) { r in
            var f = TagFields()
            f.title = r.string(0) ?? ""
            f.artist = r.string(1) ?? ""
            f.album = r.string(2) ?? ""
            f.albumArtist = r.string(3) ?? ""
            f.genre = r.string(4) ?? ""
            f.composer = r.string(5) ?? ""
            f.year = (r.int(6)).flatMap { $0 > 0 ? String($0) : nil } ?? ""
            f.trackNumber = (r.int(7)).flatMap { $0 > 0 ? String($0) : nil } ?? ""
            f.comment = r.string(8) ?? ""
            // 라이브러리 읽기와 같다: 삭제 표시 줄이어도 가리키는 줄의 이름을 읽고, 줄이 없으면(KeyID '0'·NULL·옛 번호) 빈칸이다.
            f.musicalKey = r.string(9) ?? ""
            // 라이브러리 읽기(`Track` → `TagFields(track:)`)와 같다: 평점 0·NULL과 색 '0'·''·NULL은 없음(빈칸)
            f.rating = r.int(10).flatMap { $0 > 0 ? String($0) : nil } ?? ""
            f.color = r.string(11).flatMap { $0.isEmpty || $0 == "0" ? nil : $0 } ?? ""
            fields = f
        }
        return fields
    }

    /// 백업 전 확인: DB를 바꾸지 않고 분명히 알 수 있는 막힘만 거른다(읽기 연결만 쓴다, 초안마다 시작 DB로). 버려질 옛 행을 어떻게 정리할지와
    /// 그 상태(257 등)로 막을지는 트랜잭션 안에서 실제로 쓴 뒤 센 참조로 정한다(`releaseNames`). 시험 실행(미리 보기)도 트랜잭션을 돌리므로
    /// 사용자에게 보이는 결과는 같다.
    /// 앞 초안이 쓰며 바꿀 수 있는 앨범 조건(같은 이름 앨범 수·앨범을 쓰는 곡 수·앨범 아티스트)은 첫 앨범 초안만 시작 DB로 본다. 뒤 초안은
    /// 앞 초안을 쓴 DB로만 정할 수 있어 트랜잭션 안의 `checkTags`가 정한다(하나씩 쓴 결과와 같게, `AlbumChecks`).
    /// - Parameter mergesPending: 합치기가 있으면 트랜잭션에서 곡·앨범 행이 먼저 바뀌므로 모든 초안이 그렇다.
    /// - Returns: 통과한 초안, 막힌 결과, 통과한 초안 중 재생 목록 XML을 고쳐야 하는 곡(UUID → DB `Title`, `tagTouchesPlaylistXML`)
    /// - Parameter scopes: 칸별로 좁게 확인한 범위(앱은 `TagWriteScope.byKey`, 사본 실험만 비운다)
    static func checkTagDrafts(_ tags: [TagDraft], db: CipherDatabase, writable: Set<TagFields.Key>, mergesPending: Bool = false,
                               playlistSteps: [PlaylistDraft.Step] = [],
                               scopes: [TagFields.Key: TagWriteScope] = TagWriteScope.byKey)
        throws -> (passed: [TagDraft], blocked: [Outcome], touchesXML: [String: String]) {
        var passed: [TagDraft] = [], blocked: [Outcome] = [], touchesXML: [String: String] = [:]
        var albumsMayChange = mergesPending
        // 트랜잭션은 재생 목록 편집을 태그보다 먼저 쓴다. 같은 쓰기에서 목록에 들어갈 곡도 백업 전에 목록에 든 곡으로 본다.
        let added = Set(playlistSteps.flatMap { step -> [String] in
            if case let .addTracks(_, contentIDs) = step.edit { contentIDs } else { [] }
        })
        for draft in tags {
            do {
                let checked = try checkTags(draft, db: db, writable: writable, albumChecks: albumsMayChange ? .startOnly : .all,
                                            addedToPlaylists: added, scopes: scopes)
                passed.append(draft)
                if !Set(draft.changedKeys).isDisjoint(with: [.artist, .album, .albumArtist]) { albumsMayChange = true }
                if try tagTouchesPlaylistXML(draft, contentID: checked.id, db: db) { touchesXML[draft.trackUUID] = checked.title }
            } catch let error as Blocked {
                blocked.append(Outcome(trackUUID: draft.trackUUID, title: error.title, status: .blocked, reason: error.reason, removed: 0, added: 0))
            }
        }
        return (passed, blocked, touchesXML)
    }

    /// `checkTags`가 어느 앨범 조건까지 볼지. 앞 초안을 쓴 DB에서만 정해지는 조건(`.all`에서만 본다)은 백업 전에는 첫 앨범 초안만 시작 DB로 본다.
    enum AlbumChecks {
        /// 모든 앨범 조건(트랜잭션 안, 백업 전 첫 앨범 초안·합치기가 없는 때)
        case all
        /// 앞 초안과 상관없는 조건만(곡의 앨범 상태·앨범과 앨범 아티스트를 함께 바꾸기). 같은 이름 앨범 수·붙일 앨범의 상태·앨범을 쓰는 곡 수·
        /// 앨범 아티스트 일치는 앞 초안이 바꿀 수 있어 트랜잭션에서 정한다.
        case startOnly
    }

    /// 쓰기 전에 막을 조건: 곡 없음·지운 곡·닫힌 칸·잘못된 값·곡·앨범 상태·앨범 조건·base 불일치. 막히면 `Blocked`, 통과하면 곡 행 정보.
    /// 백업을 뜨기 전(읽기 연결, 시작 DB)과 트랜잭션 안(앞 초안을 쓴 DB)에서 같은 함수로 두 번 본다. 버려질 옛 행은 여기서 보지 않는다.
    /// 동명 앨범으로 옮길지(`migratesAlbum`)는 트랜잭션 안에서 부른 결과만 쓴다(백업 전 결과는 버린다).
    /// - Parameter addedToPlaylists: 같은 쓰기의 재생 목록 초안이 목록에 넣을 곡(ContentID). 백업 전 확인만 준다(트랜잭션 안에서는 이미 들어가 있다).
    static func checkTags(_ draft: TagDraft, db: CipherDatabase, writable: Set<TagFields.Key>, albumChecks: AlbumChecks = .all,
                          addedToPlaylists: Set<String> = [],
                          scopes: [TagFields.Key: TagWriteScope] = TagWriteScope.byKey) throws -> CheckedTag {
        var contents: [(id: String, title: String, deleted: Bool, trackInfoUpdated: String?, state: Int?)] = []
        try db.query("SELECT ID, Title, rb_local_deleted, TrackInfoUpdated, rb_data_status FROM djmdContent WHERE UUID = ?",
                     [.text(draft.trackUUID)]) { r in
            contents.append((r.string(0) ?? "", r.string(1) ?? "", (r.int(2) ?? 0) != 0, r.string(3), r.int(4)))
        }
        guard contents.count == 1, let content = contents.first else {
            throw Blocked(title: draft.trackUUID, reason: contents.isEmpty ? String(ui: "rekordbox 컬렉션에서 곡을 찾지 못했으니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요") : String(ui: "같은 UUID의 곡이 여럿인 구조는 지원하지 않으니 rekordbox에서 곡을 확인하고 직접 편집하세요"))
        }
        func block(_ reason: String) -> Blocked { Blocked(title: content.title, reason: reason) }
        guard !content.deleted else { throw block(String(ui: "rekordbox 컬렉션에서 지운 곡이니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요")) }
        let closed = draft.changedKeys.filter { !writable.contains($0) }
        guard closed.isEmpty else {
            throw block(String(ui: "rekordbox에 쓰는 규칙을 아직 확인하지 않은 칸(\(closed.map(\.label).joined(separator: "·")))이 있습니다. 그 칸을 되돌리면 나머지는 쓸 수 있습니다"))
        }
        if let issue = draft.issues.first { throw block(issue) }
        for key in [TagFields.Key.year, .trackNumber] where draft.changedKeys.contains(key) {
            guard (Int(draft.fields[key]) ?? 0) >= 0 else { throw block(String(ui: "\(key.label)는 0 이상이어야 합니다")) }
        }
        // 앨범을 비우면 rekordbox가 앨범 아티스트도 함께 비운다(2026-09-27 실험곡 3). 비운 앨범에 새 앨범 아티스트는 쓸 수 없다.
        if draft.changedKeys.contains(.albumArtist), draft.fields.album.isEmpty, !draft.fields.albumArtist.isEmpty {
            throw block(String(ui: "앨범이 없는 곡에는 앨범 아티스트를 쓸 수 없습니다"))
        }
        try checkTagState(draft, state: content.state, block: block)
        // 칸별로 확인한 범위(평점·곡 색, #65). 판단은 `TagWriteScope` 한 곳이다.
        let narrowed = draft.changedKeys.filter { scopes[$0] != nil }
        if !narrowed.isEmpty {
            var listed = false
            if narrowed.contains(where: { !TagWriteScope.scope(for: $0, in: scopes).playlistXML }) {
                listed = try addedToPlaylists.contains(content.id) || !tagPlaylists(db, contentID: content.id).isEmpty
            }
            if let reason = TagWriteScope.blockReason(keys: narrowed, state: content.state, inPlaylist: listed, scopes: scopes, hasDraft: true) {
                throw block(reason)
            }
        }
        try checkTagAlbum(draft, contentID: content.id, db: db, checks: albumChecks, block: block)
        // 독립 칸(키·평점·곡 색)은 이 초안이 고칠 때만 기준과 비교한다. 그 칸이 없던 때의 초안(기준이 빈칸)이 이미 값이 있는 곡에서, 또는 그 뒤
        // rekordbox에서 그 칸만 바뀐 곡에서 다른 칸 편집까지 막히지 않게 한다(그 칸은 쓰지 않으니 어긋나도 이 초안에는 상관없다).
        let current = try currentTags(db: db, contentID: content.id)
        var comparable = current
        for key in TagFields.Key.independent where !draft.changedKeys.contains(key) { comparable?[key] = draft.base[key] }
        guard comparable == draft.base else {
            throw block(String(ui: "초안을 만든 뒤 rekordbox에서 곡 정보가 바뀌었습니다. DJCrate에서 다시 불러와 확인하세요"))
        }
        let keyID = draft.changedKeys.contains(.musicalKey) ? try resolveKeyID(draft.fields.musicalKey, db: db, block: block) : nil
        if draft.changedKeys.contains(.color) { try checkColorID(draft.fields.color, db: db, block: block) }
        guard let old = try TagOldNames.read(db, contentID: content.id) else {
            throw block(String(ui: "곡 행을 다시 읽지 못했으니 rekordbox 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요"))
        }
        let migrates = try migratesToSameNameAlbum(draft, old: old, db: db)
        return CheckedTag(id: content.id, title: content.title, trackInfoUpdated: content.trackInfoUpdated, state: content.state, old: old,
                          migratesAlbum: migrates, keyID: keyID, current: current ?? TagFields())
    }

    /// 곡 색은 `djmdColor`의 살아 있는 줄 번호만 쓴다(rekordbox 7.2.18은 여덟 줄, 묶음 2 S1·S2: Red '2', Blue '7'). `djmdColor`는 고치지 않는다.
    /// 지우기(빈칸 → '0')는 색 목록과 상관없다(S3).
    static func checkColorID(_ id: String, db: CipherDatabase, block: (String) -> Blocked) throws {
        guard !id.isEmpty else { return }
        guard try scalar(db, "SELECT count(*) FROM djmdColor WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) == 1 else {
            throw block(String(ui: "rekordbox 색 목록에 이 곡 색(\(id))이 없으니 rekordbox에서 이 곡의 색을 직접 고르세요"))
        }
    }

    /// 아티스트를 저장(바꾸기·비우기)할 때 곡의 앨범 이름을 살아 있는 앨범 둘 이상이 쓰면, rekordbox는 옛 앨범을 저장하지 않고 같은 이름의
    /// 새 앨범을 만들어 곡을 옮긴다. 곡·앨범 상태, 앨범 아티스트 유무, 다른 곡이 쓰는지, 같은 이름 행 중 몇째로 만든 행인지와 무관하다(#173 S3 V02,
    /// S2 U13, S4 C·D·F 2026-10-04: C는 곡의 앨범이 어느 순서로도 첫 행이고 앨범 아티스트가 있었는데도 새 앨범, D는 비우기). 지운 같은 이름
    /// 행은 세지 않는다(S1 T05). 앨범·앨범 아티스트 칸도 고치면 그 칸을 먼저 쓰므로 옮기지 않는다. 트랜잭션 안에서는 앞 초안을 쓴 DB로 센다.
    /// - Returns: 새 앨범으로 옮기는지
    private static func migratesToSameNameAlbum(_ draft: TagDraft, old: TagOldNames, db: CipherDatabase) throws -> Bool {
        let keys = draft.changedKeys
        guard keys.contains(.artist), !keys.contains(.album), !keys.contains(.albumArtist), old.albumLive,
              let album = old.album, !album.isEmpty, let name = old.albumName else { return false }
        return try scalar(db, "SELECT count(*) FROM djmdAlbum WHERE Name = ? AND rb_local_deleted = 0", [.text(name)]) ?? 0 >= 2
    }

    /// 이 초안을 쓰면 고칠 재생 목록 XML이 있는지: 그 곡(`contentID`, `checkTags`가 찾은 살아 있는 곡 행)이 든 살아 있는 목록이 있을 때만(백업 전
    /// 확인). 정보 패널 아홉 칸과 키가 모두 Timestamp를 고친다(#173 S1 X1 아티스트, S2 U11·U12 제목, S3 V07 장르, S4 A1~A6·B2 앨범·앨범 아티스트·
    /// 작곡가·연도·트랙 번호·코멘트, S5 K1 키).
    static func tagTouchesPlaylistXML(_ draft: TagDraft, contentID: String, db: CipherDatabase) throws -> Bool {
        guard touchesPlaylistXML(draft) else { return false }
        return try !tagPlaylists(db, contentID: contentID).isEmpty
    }

    /// 이 초안이 고치는 칸 가운데 재생 목록 XML을 고치는 칸이 있는지(`playlistXMLTagKeys`)
    static func touchesPlaylistXML(_ draft: TagDraft) -> Bool {
        !Set(draft.changedKeys).isDisjoint(with: playlistXMLTagKeys)
    }

    /// 곡이 든 살아 있는 재생 목록(곡 정보를 쓰면 XML Timestamp를 고친다, #173). 지운 목록·지운 곡 항목은 뺀다.
    static func tagPlaylists(_ db: CipherDatabase, contentID: String) throws -> [String] {
        var ids: [String] = []
        try db.query("""
            SELECT DISTINCT sp.PlaylistID FROM djmdSongPlaylist sp JOIN djmdPlaylist p ON p.ID = sp.PlaylistID
            WHERE sp.ContentID = ? AND sp.rb_local_deleted = 0 AND p.rb_local_deleted = 0 ORDER BY sp.PlaylistID
            """, [.text(contentID)]) { if let id = $0.string(0) { ids.append(id) } }
        return ids
    }

    // MARK: - 버려지는 이름·앨범 행

    /// 참조를 세는 곡·앨범 행
    enum ReferenceRows {
        /// 살아 있는 곡 + 모든 앨범(지운 앨범의 앨범 아티스트 칸도)
        case liveSongs
        /// 지운 곡·앨범까지 모두
        case all

        /// 버려졌는지 볼 때의 범위. 동기화(256·257) 행은 표와 상관없이 곡 참조를 살아 있는 것만 센다(#173 S2 U04 앨범, S4 E1 아티스트·E2 장르,
        /// 2026-10-04: 지운 곡이 가리키던 동기화 행도 258이 됐다). 아티스트를 가리키는 앨범의 앨범 아티스트 칸은 지운(258·262) 앨범까지 센다:
        /// 지운 앨범만 남은 동기화 아티스트는 보지 못해[미확인] 쓰지 않는 쪽으로 남긴다. 상태 0 행은 예전처럼 지운 것까지 센다(지워도 외래 키가
        /// 끊기지 않게).
        static func scope(state: Int?) -> ReferenceRows {
            state == 256 || state == 257 ? .liveSongs : .all
        }
    }

    /// 행 하나를 가리키는 곡(살아 있음·지움별)과 앨범 수. 칸마다 인덱스가 있어 칸별 질의를 UNION ALL로 잇고 개수만 센다(OR는 표 전체를 훑는다).
    struct ReferenceCount {
        var liveSongs = 0
        var deletedSongs = 0
        /// 앨범 아티스트 칸으로 가리키는 앨범(아티스트 행만, 지운 앨범 포함)
        var albums = 0

        init(_ db: CipherDatabase, table: NameTable, id: String) throws {
            // 칸 목록은 곡 빼기와 같다(RekordboxTrackWriter.contentReferenceColumns)
            var parts = RekordboxTrackWriter.contentReferenceColumns(table: table).map {
                "SELECT rb_local_deleted != 0 AS gone, 0 AS album FROM djmdContent WHERE \($0) = ?1"
            }
            if table == .artist {
                parts.append("SELECT rb_local_deleted != 0 AS gone, 1 AS album FROM djmdAlbum WHERE \(RekordboxTrackWriter.albumArtistColumn) = ?1")
            }
            var liveSongs = 0, deletedSongs = 0, albums = 0
            try db.query("SELECT gone, album, count(*) FROM (\(parts.joined(separator: " UNION ALL "))) GROUP BY gone, album", [.text(id)]) {
                let count = $0.int(2) ?? 0
                if $0.int(1) == 1 { albums += count } else if $0.int(0) == 1 { deletedSongs += count } else { liveSongs += count }
            }
            self.liveSongs = liveSongs
            self.deletedSongs = deletedSongs
            self.albums = albums
        }

        func count(_ rows: ReferenceRows) -> Int { rows == .all ? liveSongs + deletedSongs + albums : liveSongs + albums }
    }

    /// 이 초안을 쓰면 놓는 옛 이름·앨범 행(앨범 먼저: 버려진 앨범의 앨범 아티스트 참조가 먼저 빠진다).
    static func releasedNames(_ keys: Set<TagFields.Key>, old: TagOldNames, migratesAlbum: Bool) -> [(table: NameTable, id: String)] {
        var released: [(table: NameTable, id: String?)] = []
        if keys.contains(.album) || keys.contains(.albumArtist) || migratesAlbum { released.append((.album, old.album)) }
        if keys.contains(.artist) { released.append((.artist, old.artist)) }
        if keys.contains(.albumArtist), !keys.contains(.album) { released.append((.artist, old.albumArtist)) }
        if keys.contains(.composer) { released.append((.artist, old.composer)) }
        if keys.contains(.genre) { released.append((.genre, old.genre)) }
        var result: [(table: NameTable, id: String)] = []
        for (table, id) in released {
            guard let id, !id.isEmpty, id != "0", !result.contains(where: { $0 == (table, id) }) else { continue }
            result.append((table, id))
        }
        return result
    }

    /// 버려질 행을 정리할 수 없는 상태면 막을 이유. 0(지움)·256(258 표시)·257 앨범(258 표시)만 확인했다.
    static func releaseProblem(table: NameTable, state: Int?) -> String? {
        switch state {
        case 0, 256:
            return nil
        case 257 where table == .album:
            // #173 S4 B2(2026-10-04): 257 앨범이 버려지면 256과 같은 네 칸으로 258·삭제 표시다.
            return nil
        case 257:
            // 257 아티스트·장르가 버려질 때는 보지 못했다(라이브러리에도 그런 행이 없었다).
            return String(ui: "rekordbox에서 이미 고친 동기화 아티스트·장르라 비우는 규칙을 확인하지 못했으므로 rekordbox에서 직접 고치세요")
        default:
            return String(ui: "이 곡이 더 쓰지 않게 될 앨범·이름의 동기화 상태에서는 정리 규칙을 확인하지 못했으므로 rekordbox에서 직접 고치세요")
        }
    }

    /// 이름·앨범 행이 살아 있는지와 그 동기화 상태
    enum LiveNameState: Equatable {
        /// 행이 없거나 이미 지웠다
        case missing
        /// 살아 있다. `status`는 `rb_data_status`(NULL이면 nil)
        case live(status: Int?)
    }

    static func liveNameState(_ db: CipherDatabase, table: NameTable, id: String) throws -> LiveNameState {
        var state = LiveNameState.missing
        try db.query("SELECT rb_data_status FROM \(table.rawValue) WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) { state = .live(status: $0.int(0)) }
        return state
    }

    /// 아무도 안 쓰게 된 옛 행을 정리한다. 트랜잭션 안에서 곡 행·앨범 행·새 이름 행을 실제로 쓴 뒤 부르고, 후보마다 실제 참조 수를 센다
    /// (미리 계산하지 않는다, #173 3차 리뷰): 참조가 남으면 그대로, 상태 0이면 지우고, 256·257 앨범이면 258로 표시한다. 257 아티스트·장르나
    /// 그 밖의 상태가 버려지면 `Blocked`를 던져 부른 쪽이 그 초안만 SAVEPOINT로 되돌린다(번호도). 258을 쓰면 rekordbox처럼 곡 행이 마지막 번호를
    /// 다시 받는다(옛 행 → 곡 행).
    static func releaseNames(_ content: CheckedTag, keys: Set<TagFields.Key>, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String))
        throws -> (deleted: [(table: NameTable, id: String)], marked: [MarkedName]) {
        var deleted: [(table: NameTable, id: String)] = []
        var marked: [MarkedName] = []
        for (table, id) in releasedNames(keys, old: content.old, migratesAlbum: content.migratesAlbum) {
            guard case let .live(state) = try liveNameState(db, table: table, id: id),
                  try ReferenceCount(db, table: table, id: id).count(ReferenceRows.scope(state: state)) == 0 else { continue }
            if let problem = releaseProblem(table: table, state: state) { throw Blocked(title: content.title, reason: problem) }
            if state == 0 {
                _ = try db.run("DELETE FROM \(table.rawValue) WHERE ID = ?", [.text(id)])
                deleted.append((table, id))
            } else {
                var kept: (usn: String, synced: Int?)?
                try db.query("SELECT quote(usn), rb_local_synced FROM \(table.rawValue) WHERE ID = ?", [.text(id)]) { kept = ($0.string(0) ?? "NULL", $0.int(1)) }
                usn += 1
                guard try db.run("""
                    UPDATE \(table.rawValue) SET rb_data_status = 258, rb_local_deleted = 1, rb_local_usn = ?, updated_at = ? WHERE ID = ?
                    """, [.int(usn), .text(stamp.db), .text(id)]) == 1, let kept else {
                    throw DJCError.writeVerificationFailed(String(ui: "더 쓰지 않는 이름 행을 표시하지 못했으니 rekordbox를 그대로 둔 채 문제를 알려 주세요 (\(content.title))"))
                }
                marked.append(MarkedName(table: table, id: id, usn: usn, cloudUSN: kept.usn, synced: kept.synced))
            }
        }
        if !marked.isEmpty {
            usn += 1
            guard try db.run("UPDATE djmdContent SET rb_local_usn = ? WHERE ID = ?", [.int(usn), .text(content.id)]) == 1 else {
                throw DJCError.writeVerificationFailed(String(ui: "곡 행의 변경 번호를 다시 매기지 못했으니 rekordbox를 그대로 둔 채 문제를 알려 주세요 (\(content.title))"))
            }
        }
        return (deleted, marked)
    }

    /// 곡 상태 0·256·257만 쓴다. 동기화(256·257) 곡도 상태 0과 같은 칸을 쓰고 곡 행만 256 → 257로 올린다
    /// (#171 2026-10-01 코멘트, #173 2026-10-04 S1·S2: 아홉 칸 모두·코멘트 비우기). 그 밖의 상태는 확인하지 않아 막는다.
    private static func checkTagState(_ draft: TagDraft, state: Int?, block: (String) -> Blocked) throws {
        guard let state, verifiedTagStates.contains(state) else {
            throw block(String(ui: "이 곡의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
    }

    /// 같은 이름이 여러 개인 앨범의 선택 규칙과 선택 밖 곡의 변경은 이번 쓰기 범위에 넣지 않는다.
    /// 붙일 앨범에 관한 조건(이름이 유일한지·상태·쓰는 곡 수·앨범 아티스트)은 앞 초안을 쓴 DB로 정해져야 하나씩 쓴 결과와 같으므로
    /// `checks`가 `.startOnly`인 백업 전 확인에서는 보지 않는다.
    private static func checkTagAlbum(_ draft: TagDraft, contentID: String, db: CipherDatabase, checks: AlbumChecks,
                                      block: (String) -> Blocked) throws {
        let keys = draft.changedKeys
        guard keys.contains(.artist) || keys.contains(.album) || keys.contains(.albumArtist) else { return }
        var oldState = 0
        var oldAlbumArtist = ""
        try db.query("SELECT a.rb_data_status, a.AlbumArtistID FROM djmdAlbum a JOIN djmdContent c ON c.AlbumID = a.ID WHERE c.ID = ?",
                     [.text(contentID)]) { oldState = $0.int(0) ?? -1; oldAlbumArtist = $0.string(1) ?? "" }
        // 앨범 행은 자기 상태로 저장된다: 0 그대로, 256 → 257, 257 그대로(#173 S1 T02·T03·T05·X1, S2 U01·U02·U07·U14, S3 V01·V03·V05).
        guard Self.verifiedTagStates.contains(oldState) else {
            throw block(String(ui: "이 앨범의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        guard keys.contains(.album) || keys.contains(.albumArtist), !draft.fields.album.isEmpty else { return }
        if keys.contains(.album) && keys.contains(.albumArtist) {
            throw block(String(ui: "앨범과 앨범 아티스트를 함께 바꾸는 규칙은 확인하지 못했으므로 한 칸씩 쓰세요"))
        }
        guard checks == .all else { return }
        var albums: [(id: String, artist: String, state: Int?)] = []
        try db.query("""
            SELECT al.ID, ifnull(al.AlbumArtistID, ''), al.rb_data_status FROM djmdAlbum al
            WHERE al.Name = ? AND al.rb_local_deleted = 0
            """, [.text(draft.fields.album)]) { albums.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2))) }
        guard albums.count <= 1 else {
            throw block(String(ui: "같은 이름의 앨범이 여럿이라 선택 규칙을 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        guard let album = albums.first else { return }
        guard let state = album.state, Self.verifiedTagStates.contains(state) else {
            throw block(String(ui: "이 앨범의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
        }
        if keys.contains(.albumArtist) {
            // 동기화 앨범은 지운 곡을 세지 않는다(#173 S2 U01·U14: 지운 곡도 쓰던 동기화 앨범의 앨범 아티스트를 제자리에서 넣고 비웠다).
            // 상태 0 앨범은 예전처럼 지운 곡까지 센다.
            guard try ReferenceCount(db, table: .album, id: album.id).count(ReferenceRows.scope(state: state)) == 1 else {
                throw block(String(ui: "여러 곡이 쓰는 앨범이라 앨범 아티스트는 rekordbox에서 직접 고치세요"))
            }
        } else if album.artist != oldAlbumArtist {
            throw block(String(ui: "기존 앨범의 앨범 아티스트가 달라 다른 곡도 바뀔 수 있으므로 rekordbox에서 직접 고치세요"))
        }
    }

    /// 태그 초안 하나를 쓴다. 트랜잭션 안에서 부르고, 막히면 `Blocked`(부른 쪽이 SAVEPOINT로 되돌린다).
    /// - Parameter writable: 쓰기를 연 칸(앱은 `writableTagKeys`, 시험만 바꾼다)
    static func applyTags(_ draft: TagDraft, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String),
                          writable: Set<TagFields.Key>, scopes: [TagFields.Key: TagWriteScope] = TagWriteScope.byKey)
        throws -> (outcome: Outcome, expectation: TagExpectation) {
        let content = try checkTags(draft, db: db, writable: writable, scopes: scopes)
        let keys = draft.changedKeys, fields = draft.fields
        let old = content.old
        // 쓴 뒤 읽힐 값(숫자 칸은 읽기 규칙대로 다듬는다. 앨범을 비우면 앨범 아티스트도 빈칸)
        var expected = draft.base
        // 안 고친 독립 칸(키·평점·곡 색)은 쓴 뒤에도 곡의 지금 값 그대로여야 한다(옛 초안의 기준은 비어 있을 수 있다)
        for key in TagFields.Key.independent where !keys.contains(key) { expected[key] = content.current[key] }
        for key in keys { expected[key] = fields[key] }
        for key in [TagFields.Key.year, .trackNumber] where keys.contains(key) {
            let number = Int(fields[key]) ?? 0
            expected[key] = number > 0 ? String(number) : ""
        }
        if fields.album.isEmpty { expected.albumArtist = "" }

        var columns: [(String, CipherDatabase.Value)] = []
        var touchedAlbums: [String: (usn: Int, status: Int)] = [:]
        func name(_ table: String, _ value: String) throws -> CipherDatabase.Value {
            .text(try RekordboxTrackWriter.findOrCreate(db, table: table, name: value, usn: &usn, stamp: stamp))
        }
        /// 기존 앨범 행 저장: 앨범 아티스트(nil이면 NULL만 ''로) + 상태 256 → 257 + 변경 번호·시각
        func saveAlbum(_ album: String, albumArtist: String?) throws {
            guard case let .live(status?) = try liveNameState(db, table: .album, id: album), verifiedTagStates.contains(status) else {
                throw Blocked(title: content.title, reason: String(ui: "이 앨범의 동기화 상태에서는 태그 쓰기를 확인하지 못했으므로 rekordbox에서 직접 고치세요"))
            }
            usn += 1
            let artist = albumArtist == nil ? "ifnull(AlbumArtistID, '')" : "?"
            try db.run("UPDATE djmdAlbum SET AlbumArtistID = \(artist), \(savedStatus), rb_local_usn = ?, updated_at = ? WHERE ID = ?",
                       (albumArtist.map { [CipherDatabase.Value.text($0)] } ?? []) + [.int(usn), .text(stamp.db), .text(album)])
            touchedAlbums[album] = (usn, savedState(status))
        }
        // 정보 패널 칸 순서대로(제목 → 앨범 → 아티스트 → 장르 → 작곡가 → …). 새 이름 행과 앨범 행이 곡 행보다 먼저 번호를 받는다.
        // 앨범을 아티스트보다 먼저 쓴다(#173 명세 4.2-7): rekordbox에서 앨범 → 아티스트 순으로 저장한 결과와 같게, 아티스트가 저장하는
        // 앨범 행은 바뀐 뒤의 앨범이다(이 곡만 쓰던 옛 앨범을 저장한 뒤 버리지 않는다).
        if keys.contains(.title) { columns.append(("Title", .text(fields.title))) }
        var currentAlbum = old.albumLive ? old.album.flatMap { $0.isEmpty ? nil : $0 } : nil
        if keys.contains(.album) || keys.contains(.albumArtist) {
            if fields.album.isEmpty {
                // 비우면 '' (2026-09-27 실험곡 3)
                columns.append(("AlbumID", .text("")))
                currentAlbum = nil
            } else {
                // S1~S5: 이름이 유일한 기존 앨범은 제자리 저장, 새 앨범의 빈 아티스트는 NULL이 아니라 ''.
                let albumArtistID: String
                if keys.contains(.albumArtist) {
                    albumArtistID = fields.albumArtist.isEmpty ? ""
                        : try RekordboxTrackWriter.findOrCreate(db, table: "djmdArtist", name: fields.albumArtist, usn: &usn, stamp: stamp)
                } else {
                    albumArtistID = old.albumArtist ?? ""
                }
                var existing: String?
                try db.query("SELECT ID FROM djmdAlbum WHERE Name = ? AND rb_local_deleted = 0", [.text(fields.album)]) { existing = $0.string(0) }
                if let existing {
                    // 동기화된 대상 앨범도 256 → 257(#173 S2 U02), 제자리 앨범 아티스트도(S2 U01·U14)
                    try saveAlbum(existing, albumArtist: albumArtistID)
                    columns.append(("AlbumID", .text(existing)))
                    currentAlbum = existing
                } else {
                    let album = try RekordboxTrackWriter.findOrCreateAlbum(db, name: fields.album, albumArtistID: albumArtistID, usn: &usn, stamp: stamp)
                    columns.append(("AlbumID", .text(album)))
                    touchedAlbums[album] = (usn, 0)
                    currentAlbum = album
                }
            }
        }
        if keys.contains(.artist) {
            columns.append(("ArtistID", fields.artist.isEmpty ? .text("") : try name("djmdArtist", fields.artist)))
            // 아티스트를 고치면 곡의 앨범 행도 저장된다: NULL 앨범 아티스트는 '', 변경 번호·시각(2026-09-27 실험곡 5, 묶음 2),
            // 동기화 앨범은 256 → 257·257 그대로(#173 S1 T02·T05·X1, S2 U07, S3 V01·V03·V05)
            if content.migratesAlbum, let name = old.albumName {
                // 같은 이름 앨범이 여럿이면 옛 앨범은 저장하지 않고 같은 이름의 새 앨범으로 옮긴다(#173 S3 V02·S2 U13·S4 C·D·F). (이름, 앨범
                // 아티스트) 짝이 같은 행이 있어도 늘 새로 만든다(`findOrCreateAlbum`을 쓰지 않는다). 앨범 아티스트는 이어받고 NULL이면 ''(S4 D).
                let id = try RekordboxTrackWriter.insertAlbum(db, name: name, albumArtistID: old.albumArtist ?? "", usn: &usn, stamp: stamp)
                columns.append(("AlbumID", .text(id)))
                touchedAlbums[id] = (usn, 0)
            } else if let album = currentAlbum {
                try saveAlbum(album, albumArtist: nil)
            }
        }
        // 장르를 비우면 '0', 작곡가를 비우면 ''(2026-09-27 실험곡 4 세션 2)
        if keys.contains(.genre) { columns.append(("GenreID", fields.genre.isEmpty ? .text("0") : try name("djmdGenre", fields.genre))) }
        if keys.contains(.composer) { columns.append(("ComposerID", fields.composer.isEmpty ? .text("") : try name("djmdArtist", fields.composer))) }
        if keys.contains(.year) { columns.append(("ReleaseYear", .int(Int(fields.year) ?? 0))) }
        if keys.contains(.trackNumber) { columns.append(("TrackNo", .int(Int(fields.trackNumber) ?? 0))) }
        if keys.contains(.comment) { columns.append(("Commnt", .text(fields.comment))) }
        // 키: 고른 줄의 ID(글자), 지우면 '0'(글자). `djmdKey`는 고치지 않는다(2026-10-04 묶음 2 S1·S3·S4, #173 T13·U10)
        if keys.contains(.musicalKey) { columns.append(("KeyID", .text(content.keyID ?? "0"))) }
        // 평점: 별 수 정수, 지우면 0(NULL 아님). 곡 색: `djmdColor.ID`(글자), 지우면 '0'(글자). 다른 표는 고치지 않는다(2026-10-04 묶음 2 S1~S3)
        if keys.contains(.rating) { columns.append(("Rating", .int(Int(fields.rating) ?? 0))) }
        if keys.contains(.color) { columns.append(("ColorID", .text(fields.color.isEmpty ? "0" : fields.color))) }

        // 곡 행: 바뀐 칸 + TrackInfoUpdated(글자) 칸마다 +1 + 동기화 상태 256 → 257 + 변경 번호(마지막).
        // 앨범을 비우며 앨범 아티스트도 비우면 rekordbox에서는 한 번 저장이다.
        let saves = keys.count - (keys.contains(.album) && keys.contains(.albumArtist) && fields.album.isEmpty ? 1 : 0)
        let trackInfoUpdated = String((Int(content.trackInfoUpdated ?? "0") ?? 0) + saves)
        usn += 1
        let assignments = columns.map { "\"\($0.0)\" = ?" } + [
            "TrackInfoUpdated = ?",
            savedStatus,
            "rb_local_usn = ?", "updated_at = ?",
        ]
        let changed = try db.run("UPDATE djmdContent SET \(assignments.joined(separator: ", ")) WHERE ID = ?",
                                 columns.map(\.1) + [.text(trackInfoUpdated), .int(usn), .text(stamp.db), .text(content.id)])
        guard changed == 1 else { throw DJCError.writeVerificationFailed(String(ui: "곡 정보를 고치지 못했습니다 (\(content.title))")) }

        // 아무 곡·앨범도 안 쓰게 된 옛 행: 상태 0은 실제로 지우고(2026-09-27: 아티스트 A·작곡가·장르·앨범), 동기화(256, 257 앨범)는 258·삭제
        // 표시로 네 칸만 바꾼다(#173 S1 T02·T04·T05, S2 U02~U05·U14, S3 V03, S4 B2·F). 지운 앨범의 앨범 아티스트 행은 rekordbox도 남겼다(앨범 칸을 고칠 때는
        // 앨범 아티스트를 놓는 것으로 보지 않는다). 쓴 뒤의 실제 참조 수로 정한다.
        let (deleted, marked) = try releaseNames(content, keys: Set(keys), db: db, usn: &usn, stamp: stamp)
        var expectation = TagExpectation(contentID: content.id, fields: expected, trackInfoUpdated: trackInfoUpdated, contentUSN: usn,
                                         dataStatus: savedState(content.state), touchedAlbums: touchedAlbums, deletedNames: deleted)
        expectation.markedNames = marked
        if keys.contains(.musicalKey) { expectation.keyID = content.keyID ?? "0" }
        if keys.contains(.rating) { expectation.rating = Int(fields.rating) ?? 0 }
        if keys.contains(.color) { expectation.colorID = fields.color.isEmpty ? "0" : fields.color }
        // 버린 앨범(지움·258)은 저장한 앨범 기대값에서 뺀다
        for id in expectation.releasedAlbums { expectation.touchedAlbums.removeValue(forKey: id) }
        if case let .text(album)? = columns.last(where: { $0.0 == "AlbumID" })?.1 { expectation.albumID = album }
        try verifyTags(db: db, expectation)
        let outcome = Outcome(trackUUID: draft.trackUUID, title: content.title, status: .written, reason: nil, removed: 0, added: keys.count,
                              fields: keys.map(\.rawValue))
        return (outcome, expectation)
    }

    /// 곡의 태그·카운터·변경 번호가 쓴 그대로인지 다시 읽어 확인한다(트랜잭션 안과 커밋 뒤).
    static func verifyTags(db: CipherDatabase, _ expected: TagExpectation) throws {
        func fail(_ reason: String) -> DJCError { .writeVerificationFailed("\(reason) (ContentID \(expected.contentID))") }
        guard try currentTags(db: db, contentID: expected.contentID) == expected.fields else { throw fail(String(ui: "곡 정보가 초안과 다릅니다")) }
        var stored: (info: String?, type: String?, usn: Int?, status: Int?)?
        try db.query("SELECT TrackInfoUpdated, typeof(TrackInfoUpdated), rb_local_usn, rb_data_status FROM djmdContent WHERE ID = ?",
                     [.text(expected.contentID)]) { stored = ($0.string(0), $0.string(1), $0.int(2), $0.int(3)) }
        guard stored?.info == expected.trackInfoUpdated, stored?.type == "text" else { throw fail(String(ui: "곡 정보 변경 횟수(TrackInfoUpdated)가 다릅니다")) }
        guard stored?.usn == expected.contentUSN else { throw fail(String(ui: "곡의 변경 번호가 다릅니다")) }
        guard let stored, stored.status == expected.dataStatus else { throw fail(String(ui: "곡의 동기화 상태(rb_data_status)가 다릅니다")) }
        if let keyID = expected.keyID {
            // ScaleName 조인으로는 '0'·''·NULL이 모두 키 없음이라 칸 자체를 본다(지우기는 '0' 글자)
            var raw: (value: String?, type: String?)?
            try db.query("SELECT KeyID, typeof(KeyID) FROM djmdContent WHERE ID = ?", [.text(expected.contentID)]) { raw = ($0.string(0), $0.string(1)) }
            guard raw?.value == keyID, raw?.type == "text" else { throw fail(String(ui: "곡의 키(KeyID)가 쓴 것과 다릅니다")) }
        }
        if expected.rating != nil || expected.colorID != nil {
            // 읽기 규칙으로는 평점 0·NULL, 색 '0'·''·NULL이 모두 없음이라 칸 자체(값·자료형)를 본다
            var raw: (rating: Int?, ratingType: String?, color: String?, colorType: String?)?
            try db.query("SELECT Rating, typeof(Rating), ColorID, typeof(ColorID) FROM djmdContent WHERE ID = ?", [.text(expected.contentID)]) {
                raw = ($0.int(0), $0.string(1), $0.string(2), $0.string(3))
            }
            if let rating = expected.rating, raw?.rating != rating || raw?.ratingType != "integer" {
                throw fail(String(ui: "곡의 평점(Rating)이 쓴 것과 다릅니다"))
            }
            if let color = expected.colorID, raw?.color != color || raw?.colorType != "text" {
                throw fail(String(ui: "곡의 곡 색(ColorID)이 쓴 것과 다릅니다"))
            }
        }
        if let album = expected.albumID {
            var stored: String?
            try db.query("SELECT AlbumID FROM djmdContent WHERE ID = ?", [.text(expected.contentID)]) { stored = $0.string(0) }
            guard stored == album else { throw fail(String(ui: "곡의 앨범 행이 쓴 것과 다르니 rekordbox를 그대로 둔 채 문제를 알려 주세요")) }
        }
        for (id, album) in expected.touchedAlbums {
            guard try scalar(db, "SELECT rb_local_usn FROM djmdAlbum WHERE ID = ? AND AlbumArtistID IS NOT NULL", [.text(id)]) == album.usn else {
                throw fail(String(ui: "앨범 행의 변경 번호가 다릅니다"))
            }
            guard try scalar(db, "SELECT rb_data_status FROM djmdAlbum WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) == album.status else {
                throw fail(String(ui: "앨범 행의 동기화 상태(rb_data_status)가 쓴 것과 다르니 rekordbox를 그대로 둔 채 문제를 알려 주세요"))
            }
        }
        for (table, id) in expected.deletedNames {
            guard try scalar(db, "SELECT count(*) FROM \(table.rawValue) WHERE ID = ?", [.text(id)]) == 0 else { throw fail(String(ui: "지운 이름 행이 남아 있습니다")) }
        }
        for name in expected.markedNames {
            var rows: [(status: Int?, deleted: Int?, usn: Int?, cloud: String?, synced: Int?)] = []
            try db.query("SELECT rb_data_status, rb_local_deleted, rb_local_usn, quote(usn), rb_local_synced FROM \(name.table.rawValue) WHERE ID = ?",
                         [.text(name.id)]) { rows.append(($0.int(0), $0.int(1), $0.int(2), $0.string(3), $0.int(4))) }
            guard rows.count == 1, let row = rows.first, row.status == 258, row.deleted == 1, row.usn == name.usn,
                  row.cloud == name.cloudUSN, row.synced == name.synced else {
                throw fail(String(ui: "더 쓰지 않는 동기화 이름 행의 표시가 쓴 것과 다르니 rekordbox를 그대로 둔 채 문제를 알려 주세요"))
            }
        }
    }
}
