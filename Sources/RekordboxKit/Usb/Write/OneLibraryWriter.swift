import DJCDomain
import Foundation

/// USB 편집 하나에 해당하는 단계. `target`은 지금까지 받아들인 모델에 이 편집을 적용한 모델을 돌려준다.
public struct OneLibraryEditStep: Sendable {
    public var id: Int
    public var target: @Sendable (UsbLibrary) throws -> UsbLibrary

    public init(id: Int, target: @escaping @Sendable (UsbLibrary) throws -> UsbLibrary) {
        self.id = id
        self.target = target
    }
}

public struct OneLibraryApplyResult: Sendable {
    /// 건너뛴 편집을 뺀 목표 = DB에 실제로 쓴 모델(투영하지 않은 모델 그대로 — pdb 전용 칸이 살아 있다)
    public var applied: UsbLibrary
    /// 편집 id → 실패 이유(기술 정보, 번역하지 않음)
    public var skipped: [Int: String]

    public init(applied: UsbLibrary, skipped: [Int: String]) {
        self.applied = applied
        self.skipped = skipped
    }
}

/// `UsbLibrary` → OneLibrary(`exportLibrary.db`). 새 파일은 Mac 준비 폴더에 만들고, 고치기는 USB DB **사본**에만 한다.
/// 모델의 OneLibrary 투영(`projected(to: .oneLibrary)`)만 쓴다.
public enum OneLibraryWriter {
    /// 새 DB를 만든다. 파일(또는 사이드카)이 이미 있으면 실패한다. 끝나면 -wal·-shm이 없다.
    /// 기기 기록·모델에 담지 않는 표의 행이 든 모델은 다시 만들 수 없어 막는다.
    public static func create(_ library: UsbLibrary, at url: URL) throws {
        try refuseVolumePath(url)
        let model = library.projected(to: .oneLibrary)
        guard model.histories.isEmpty, model.unknownRows.isEmpty else {
            let rule = UsbProvisionalRule.carriedDeviceRows
            throw UsbError.writeRefused([UsbBlock(code: rule.rawValue, scope: .format(.oneLibrary), message: rule.summary, rule: rule)])
        }
        for suffix in UsbLayout.oneLibrarySidecarSuffixes where exists(url.path + suffix) {
            throw DJCError.databaseOpenFailed(path: url.path + suffix, message: String(ui: "이미 있는 파일이라 새 DB를 만들지 않았습니다"))
        }
        let db = try CipherDatabase(path: url.path, key: key(), mode: .create)
        do {
            // WAL은 표를 만들기 전에 켠다(파일 머리가 WAL 모양이 된다)
            var mode = ""
            try db.query("PRAGMA journal_mode=WAL") { mode = $0.string(0) ?? "" }
            guard mode.lowercased() == "wal" else { throw failure("journal_mode: \(mode)") }
            try db.execute("BEGIN")
            for sql in OneLibrarySchema.ddl() { try db.execute(sql) }
            try OneLibraryRows.insertAll(model, db)
            try db.execute("COMMIT")
            let checkpoint = try walCheckpoint(db)
            guard checkpoint == [0, 0, 0] else { throw failure("wal_checkpoint: \(checkpoint)") }
            try checkIntegrity(db)
            db.close()
            let leftovers = UsbLayout.oneLibrarySidecarSuffixes.filter { exists(url.path + $0) }
            guard leftovers.isEmpty else { throw failure("sidecar left: \(leftovers.joined(separator: ", "))") }
            let problems = try verify(url, expected: library)
            guard problems.isEmpty else { throw failure("verify: " + problems.prefix(5).joined(separator: "; ")) }
        } catch {
            db.close()
            // 만든 것만 지운다(만들기 전에 있던 파일은 위에서 거부했다)
            for path in [url.path] + UsbLayout.oneLibrarySidecarSuffixes.map({ url.path + $0 }) { try? FileManager.default.removeItem(atPath: path) }
            throw error
        }
    }

    /// USB DB **사본**(병합 끝난 것)에 편집 단계마다 차이만 SQL로 적용한다. 한 단계가 실패하면 그 단계만 되돌리고 계속한다.
    /// `current`·단계 모델은 두 형식을 합친 모델이어도 된다 — 쓰기·다시 읽기 비교는 OneLibrary 투영으로 한다.
    /// - COMMIT 전 다시 읽기가 어긋나면 전체를 되돌리고 `UsbError.writeRolledBack`(사본은 그대로).
    /// - COMMIT 뒤 확인이 실패하면 `OneLibraryCommittedCopyError`(사본은 이미 고쳐졌다 — 버리고 USB에서 다시 떠야 한다).
    public static func apply(from current: UsbLibrary, steps: [OneLibraryEditStep], database url: URL) throws -> OneLibraryApplyResult {
        try apply(from: current, steps: steps, database: url, stopOnFailure: false, afterSteps: nil)
    }

    /// 단계 하나: 실패하면 전체를 되돌리고 던진다(COMMIT 뒤 실패는 위와 같이 `OneLibraryCommittedCopyError`)
    public static func apply(from current: UsbLibrary, to target: UsbLibrary, database url: URL) throws {
        _ = try apply(from: current, steps: [OneLibraryEditStep(id: 1) { _ in target }], database: url, stopOnFailure: true, afterSteps: nil)
    }

    /// `afterSteps`·`afterCommit`은 시험이 모든 단계 뒤(다시 읽기 전)·COMMIT 뒤에 같은 연결로 SQL을 더 부를 때만 쓴다.
    static func apply(from current: UsbLibrary, steps: [OneLibraryEditStep], database url: URL, stopOnFailure: Bool,
                      afterSteps: ((CipherDatabase) throws -> Void)?,
                      afterCommit: ((CipherDatabase) throws -> Void)? = nil) throws -> OneLibraryApplyResult {
        try refuseVolumePath(url)
        let db = try CipherDatabase(path: url.path, key: key(), mode: .readWrite)
        var isOpen = true
        defer { if isOpen { db.close() } }
        try OneLibraryCompatibility.check(db)
        try db.execute("BEGIN IMMEDIATE")
        var accepted = current
        var skipped: [Int: String] = [:]
        do {
            for step in steps {
                let savepoint = "\"step_\(step.id)\""
                try db.execute("SAVEPOINT \(savepoint)")
                do {
                    let target = try step.target(accepted)
                    let next = normalized(target, from: accepted)
                    try OneLibraryRows.applyDifference(from: accepted, to: next, db)
                    try db.execute("RELEASE \(savepoint)")
                    accepted = next
                } catch {
                    try db.execute("ROLLBACK TO \(savepoint)")
                    try db.execute("RELEASE \(savepoint)")
                    if stopOnFailure { throw error }
                    // 다음 단계는 이 편집이 빠진 모델 위에 적용된다
                    skipped[step.id] = String(describing: error)
                }
            }
            try afterSteps?(db)
            // 원래 목표(모든 편집)가 아니라 받아들인 모델과, 합친 모델이 아니라 그 OneLibrary 투영과 비교한다
            let reread = try OneLibraryReader.read(connection: db)
            let differences = UsbLibraryDiff.compare(reread, accepted.projected(to: .oneLibrary), options: .init(formats: [.oneLibrary]))
                .differences
            guard differences.isEmpty else { throw UsbError.writeRolledBack(reason: "reread differs: " + summary(differences)) }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        // 여기부터는 사본에 이미 COMMIT됐다. 되돌렸다고 알리지 않는다
        do {
            try afterCommit?(db)
            // 파일 머리 모양(WAL·롤백)은 바꾸지 않는다. 롤백 모양이면 체크포인트는 할 일이 없다
            guard try walCheckpoint(db).first == 0 else { throw failure("wal_checkpoint busy") }
            db.close()
            isOpen = false
            let problems = try verify(url, expected: accepted)
            guard problems.isEmpty else { throw failure("verify: " + problems.prefix(5).joined(separator: "; ")) }
        } catch {
            throw OneLibraryCommittedCopyError(reason: String(describing: error))
        }
        return OneLibraryApplyResult(applied: accepted, skipped: skipped)
    }

    /// 다시 열어 확인한다: 사이드카 없음, 스키마 = `OneLibrarySchema`, integrity ok, cipher_integrity_check 0줄,
    /// 다시 읽은 모델 = `expected`의 OneLibrary 투영(OneLibrary 칸만 비교). 문제마다 한 줄(칸 이름·ID·수만, 값은 넣지 않는다)
    /// 사이드카가 있으면 DB를 열지 않고 그것만 보고한다(열면 닫을 때 SQLite가 남은 -wal을 본 파일에 합치고 지운다).
    public static func verify(_ url: URL, expected: UsbLibrary) throws -> [String] {
        try refuseVolumePath(url)
        var problems = UsbLayout.oneLibrarySidecarSuffixes.filter { exists(url.path + $0) }.map { "sidecar \($0)" }
        guard problems.isEmpty else { return problems }
        // 쓰기 가능하게 열어야 닫을 때 SQLite가 이 연결이 만든 -wal·-shm을 치운다. 읽기만 한다
        let db = try CipherDatabase(path: url.path, key: key(), mode: .readWrite)
        defer { db.close() }
        try db.execute("PRAGMA query_only = ON")
        do {
            try checkIntegrity(db)
            let reread = try OneLibraryReader.read(connection: db)
            let differences = UsbLibraryDiff.compare(reread, expected.projected(to: .oneLibrary), options: .init(formats: [.oneLibrary]))
                .differences
            problems += differences.map { "\($0.table) \($0.key) \($0.field)" }
        } catch {
            problems.append(String(describing: error))
        }
        return problems
    }

    // MARK: - 편집 모델 다듬기

    /// 단계 모델에서 이 작성기가 쓰지 않는 것을 USB 값으로 되돌리고, 이 편집으로 고아가 된 행을 뺀다.
    /// - 기기 칸(rating·djPlayCount·hasModified, 형식별 기기 칸)은 USB 값을 지킨다(두 쪽에 다 있는 곡).
    /// - 색·메뉴·카테고리·정렬·My Tag·기록·모르는 표 행과 property의 기기·만들기 칸은 USB 값 그대로.
    /// - My Tag 연결은 더하지 않고, 뺀 곡의 연결만 없앤다.
    static func normalized(_ target: UsbLibrary, from accepted: UsbLibrary) -> UsbLibrary {
        var next = target
        let before = Dictionary(accepted.tracks.map { ($0.id, $0) }) { first, _ in first }
        for index in next.tracks.indices {
            guard let old = before[next.tracks[index].id] else { continue }
            next.tracks[index].rating = old.rating
            next.tracks[index].djPlayCount = old.djPlayCount
            next.tracks[index].hasModified = old.hasModified
            next.tracks[index].deviceFields = old.deviceFields
        }
        next.colors = accepted.colors
        next.menuItems = accepted.menuItems
        next.categories = accepted.categories
        next.sorts = accepted.sorts
        next.myTags = accepted.myTags
        next.histories = accepted.histories
        next.unknownRows = accepted.unknownRows
        next.property.deviceName = accepted.property.deviceName
        next.property.dbVersion = accepted.property.dbVersion
        next.property.createdDate = accepted.property.createdDate
        next.property.backgroundColorType = accepted.property.backgroundColorType
        next.property.myTagMasterDBID = accepted.property.myTagMasterDBID
        // 연결은 곡이 남은 형식에만 둔다(한 형식에서만 뺀 곡의 연결이 그 형식에 남지 않게)
        let presence = Dictionary(next.tracks.map { ($0.id, $0.presentIn) }) { first, _ in first }
        next.myTagLinks = accepted.myTagLinks.compactMap { link in
            guard let formats = presence[link.contentID] else { return nil }
            var link = link
            link.presentIn.formIntersection(formats)
            return link.presentIn.isEmpty ? nil : link
        }
        pruneNewOrphans(&next, accepted: accepted)
        // 곡 수는 단계 모델 값을 믿지 않고 OneLibrary에 있는 곡으로 센다(Device Library에만 있는 곡은 빼고)
        next.property.numberOfContents = next.tracks.filter { $0.presentIn.contains(.oneLibrary) }.count
        return next.canonicalized()
    }

    /// 받아들인 모델에서는 쓰이던 행 중 이 편집 뒤 아무도 가리키지 않는 행만 뺀다(원래 쓰이지 않던 행은 둔다)
    static func pruneNewOrphans(_ next: inout UsbLibrary, accepted: UsbLibrary) {
        let old = References(accepted)
        var now = References(next)
        next.albums.removeAll { old.albums.contains($0.id) && !now.albums.contains($0.id) }
        now = References(next)
        next.artists.removeAll { old.artists.contains($0.id) && !now.artists.contains($0.id) }
        next.genres.removeAll { old.genres.contains($0.id) && !now.genres.contains($0.id) }
        next.keys.removeAll { old.keys.contains($0.id) && !now.keys.contains($0.id) }
        next.labels.removeAll { old.labels.contains($0.id) && !now.labels.contains($0.id) }
        next.images.removeAll { old.images.contains($0.id) && !now.images.contains($0.id) }
    }

    /// 곡·앨범·목록이 가리키는 행 ID
    struct References {
        var artists: Set<Int> = [], albums: Set<Int> = [], genres: Set<Int> = [], keys: Set<Int> = [], labels: Set<Int> = []
        var images: Set<Int> = []

        init(_ library: UsbLibrary) {
            for track in library.tracks {
                artists.formUnion([track.artistID, track.remixerID, track.originalArtistID, track.composerID, track.lyricistArtistID]
                    .compactMap { $0 }.filter { $0 != 0 })
                if let album = track.albumID { albums.insert(album) }
                if let genre = track.genreID { genres.insert(genre) }
                if let key = track.keyID { keys.insert(key) }
                if let label = track.labelID { labels.insert(label) }
                if let image = track.imageID { images.insert(image) }
            }
            for album in library.albums where albums.contains(album.id) {
                if let artist = album.artistID { artists.insert(artist) }
                if let image = album.imageID { images.insert(image) }
            }
            images.formUnion(library.playlists.compactMap(\.imageID))
        }
    }

    // MARK: - 도움

    /// 이 작성기는 Mac 준비 폴더나 USB DB 사본만 다룬다. USB 볼륨(/Volumes 아래)의 파일은 `UsbWriter`만 쓴다
    /// (백업·저널·실물 관문을 거치지 않고 열면 -wal·-shm이 USB에 생기고 행이 바뀐다). 파일과 그 폴더를 realpath로 본다.
    static func refuseVolumePath(_ url: URL) throws {
        let paths = [url.path, url.deletingLastPathComponent().path].compactMap(UsbScratchRoots.realPath)
        guard paths.contains(where: isOnVolumes) else { return }
        throw UsbError.writeRefused([UsbBlock(code: "libraryOnVolume", scope: .format(.oneLibrary),
                                              message: String(ui: "USB 안의 라이브러리 파일은 바로 고치지 않습니다. DJCrate의 USB 쓰기로 다시 시도하세요"))])
    }

    /// realpath 결과가 /Volumes이거나 그 아래인지(대소문자 무시 — 대소문자를 가리지 않는 볼륨에서도 같은 곳이다)
    static func isOnVolumes(_ realPath: String?) -> Bool {
        guard let path = realPath?.lowercased() else { return false }
        return path == "/volumes" || path.hasPrefix("/volumes/")
    }

    static func key() throws -> CipherKey {
        .passphrase(try RekordboxKey.oneLibrary())
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func walCheckpoint(_ db: CipherDatabase) throws -> [Int] {
        var result: [Int] = []
        try db.query("PRAGMA wal_checkpoint(TRUNCATE)") { row in result = (0..<3).map { row.int(Int32($0)) ?? -1 } }
        return result
    }

    static func checkIntegrity(_ db: CipherDatabase) throws {
        var integrity: [String] = []
        try db.query("PRAGMA integrity_check") { integrity.append($0.string(0) ?? "") }
        guard integrity == ["ok"] else { throw failure("integrity_check: \(integrity.prefix(3).joined(separator: "; "))") }
        var cipherProblems = 0
        try db.query("PRAGMA cipher_integrity_check") { _ in cipherProblems += 1 }
        guard cipherProblems == 0 else { throw failure("cipher_integrity_check: \(cipherProblems)") }
    }

    /// "표.칸×수, …"(값은 넣지 않는다)
    static func summary(_ differences: [UsbLibraryDiff.Difference]) -> String {
        Dictionary(differences.map { ("\($0.table).\($0.field)", 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
    }

    static func failure(_ detail: String) -> OneLibraryWriteFailure { OneLibraryWriteFailure(description: detail) }
}

/// `apply`가 COMMIT한 뒤의 확인(체크포인트·다시 열어 확인)이 실패했다. 사본에는 편집이 이미 들어가 있다(되돌리지 않았다).
/// 호출하는 쪽은 이 사본을 버리고 USB에서 다시 떠야 한다. 같은 사본에 다시 적용하면 편집이 두 번 들어간다.
public struct OneLibraryCommittedCopyError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// 기술 정보(번역하지 않음)
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? {
        String(ui: "USB 라이브러리 사본을 고친 뒤 확인하지 못했습니다. USB를 다시 읽은 뒤 다시 시도하세요")
    }

    public var description: String { "OneLibrary copy committed but not confirmed: \(reason)" }
}

/// 작성기 안쪽 실패(기술 정보, 번역하지 않음)
struct OneLibraryWriteFailure: Error, CustomStringConvertible {
    let description: String
}

// MARK: - 행 쓰기

/// 모델 행 → OneLibrary 표 행. 글자 칸은 늘 TEXT(빈 글자 포함), 없을 수 있는 정수 칸만 NULL이 된다.
/// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
enum OneLibraryRows {
    typealias Values = [(column: String, value: CipherDatabase.Value)]

    /// 고칠 때 건드리지 않는 content 칸(기기가 바꾸는 칸)
    static let deviceColumns: Set<String> = ["rating", "djPlayCount", "hasModified"]

    static func text(_ value: String?) -> CipherDatabase.Value { value.map { .text($0) } ?? .null }
    static func integer(_ value: Int?) -> CipherDatabase.Value { value.map { .int($0) } ?? .null }

    static func content(_ track: UsbTrack) -> Values {
        [
            ("content_id", .int(track.id)), ("title", .text(track.title)), ("titleForSearch", text(track.titleForSearch)),
            ("subtitle", .text(track.subtitle)), ("bpmx100", .int(track.bpmx100)), ("length", .int(track.lengthSeconds)),
            ("trackNo", .int(track.trackNo)), ("discNo", .int(track.discNo)),
            ("artist_id_artist", integer(track.artistID)), ("artist_id_remixer", integer(track.remixerID)),
            ("artist_id_originalArtist", integer(track.originalArtistID)), ("artist_id_composer", integer(track.composerID)),
            ("artist_id_lyricist", integer(track.lyricistArtistID)), ("album_id", integer(track.albumID)),
            ("genre_id", integer(track.genreID)), ("label_id", integer(track.labelID)), ("key_id", integer(track.keyID)),
            ("color_id", .int(track.colorID)), ("image_id", integer(track.imageID)), ("djComment", .text(track.comment)),
            ("rating", .int(track.rating)), ("releaseYear", .int(track.releaseYear)), ("releaseDate", .text(track.releaseDate)),
            ("dateCreated", .text(track.dateCreated)), ("dateAdded", .text(track.dateAdded)), ("path", .text(track.path)),
            ("fileName", .text(track.fileName)), ("fileSize", .int(Int(track.fileSize))), ("fileType", .int(track.fileType)),
            ("bitrate", .int(track.bitrate)), ("bitDepth", .int(track.bitDepth)), ("samplingRate", .int(track.sampleRate)),
            ("isrc", .text(track.isrc)), ("djPlayCount", .int(track.djPlayCount)),
            ("isHotCueAutoLoadOn", .int(track.hotCueAutoLoad ? 1 : 0)), ("isKuvoDeliverStatusOn", .int(track.kuvoDeliver ? 1 : 0)),
            ("kuvoDeliveryComment", .text(track.kuvoDeliveryComment)), ("masterDbId", .int(Int(track.masterDbId))),
            ("masterContentId", .int(Int(track.masterContentId))), ("analysisDataFilePath", .text(track.analysisDataPath)),
            ("analysedBits", .int(track.analysedBits)), ("contentLink", .int(track.contentLink)), ("hasModified", .int(track.hasModified)),
            // TEXT로 넣는다: INTEGER 친화성 때문에 숫자 글자는 INTEGER, 빈 글자는 TEXT ''로 남는다
            ("cueUpdateCount", .text(track.cueUpdateCount)), ("analysisDataUpdateCount", .text(track.analysisDataUpdateCount)),
            ("informationUpdateCount", .text(track.informationUpdateCount)),
        ]
    }

    static func named(_ row: UsbNamedRow, id: String) -> Values { [(id, .int(row.id)), ("name", .text(row.name))] }

    static func artist(_ row: UsbNamedRow) -> Values {
        [("artist_id", .int(row.id)), ("name", .text(row.name)), ("nameForSearch", text(row.nameForSearch))]
    }

    static func album(_ row: UsbAlbum) -> Values {
        [("album_id", .int(row.id)), ("name", .text(row.name)), ("artist_id", integer(row.artistID)), ("image_id", integer(row.imageID)),
         ("isComplation", .int(row.isCompilation)), ("nameForSearch", text(row.nameForSearch))]
    }

    static func image(_ row: UsbImage) -> Values { [("image_id", .int(row.id)), ("path", text(row.oneLibraryPath))] }

    static func playlist(_ row: UsbPlaylist) -> Values {
        [("playlist_id", .int(row.id)), ("sequenceNo", .int(row.sortOrder[.oneLibrary] ?? 0)), ("name", .text(row.name)),
         ("image_id", integer(row.imageID)), ("attribute", .int(row.attribute)), ("playlist_id_parent", .int(row.parentID))]
    }

    static func menuName(_ name: String) -> String { "\u{FFFA}" + name + "\u{FFFB}" }

    static func insert(_ db: CipherDatabase, _ table: String, _ values: Values) throws {
        let columns = values.map(\.column).joined(separator: ", ")
        let marks = Array(repeating: "?", count: values.count).joined(separator: ", ")
        try db.run("INSERT INTO \(table) (\(columns)) VALUES (\(marks))", values.map(\.value))
    }

    /// 첫 칸이 키
    static func update(_ db: CipherDatabase, _ table: String, _ values: Values, skipping: Set<String> = []) throws {
        guard let key = values.first else { return }
        let changed = values.dropFirst().filter { !skipping.contains($0.column) }
        try db.run("UPDATE \(table) SET \(changed.map { "\($0.column) = ?" }.joined(separator: ", ")) WHERE \(key.column) = ?",
                   changed.map(\.value) + [key.value])
    }

    static func entries(_ db: CipherDatabase, _ playlist: UsbPlaylist) throws {
        for (index, content) in (playlist.entries[.oneLibrary] ?? []).enumerated() {
            try insert(db, "playlist_content", [("playlist_id", .int(playlist.id)), ("content_id", .int(content)), ("sequenceNo", .int(index + 1))])
        }
    }

    /// 새 DB의 행: `integer primary key` 표는 id 순(rowid = id), 항목 표는 목록 id·순번 순
    static func insertAll(_ library: UsbLibrary, _ db: CipherDatabase) throws {
        let model = library.canonicalized()
        for track in model.tracks { try insert(db, "content", content(track)) }
        for row in model.genres { try insert(db, "genre", named(row, id: "genre_id")) }
        for row in model.artists { try insert(db, "artist", artist(row)) }
        for row in model.albums { try insert(db, "album", album(row)) }
        for row in model.labels { try insert(db, "label", named(row, id: "label_id")) }
        for row in model.keys { try insert(db, "key", named(row, id: "key_id")) }
        for row in model.colors { try insert(db, "color", named(row, id: "color_id")) }
        for row in model.images { try insert(db, "image", image(row)) }
        for row in model.playlists { try insert(db, "playlist", playlist(row)) }
        for row in model.playlists { try entries(db, row) }
        for tag in model.myTags {
            try insert(db, "myTag", [("myTag_id", .int(Int(tag.id))), ("sequenceNo", .int(tag.sequenceNo)), ("name", .text(tag.name)),
                                     ("attribute", .int(tag.isCategory ? 1 : 0)), ("myTag_id_parent", .int(Int(tag.parentID)))])
        }
        for link in model.myTagLinks {
            try insert(db, "myTag_content", [("myTag_id", .int(Int(link.myTagID))), ("content_id", .int(link.contentID))])
        }
        for item in model.menuItems {
            try insert(db, "menuItem", [("menuItem_id", .int(item.id)), ("kind", .int(item.kind)), ("name", .text(menuName(item.name)))])
        }
        for row in model.categories {
            try insert(db, "category", [("category_id", .int(row.id)), ("menuItem_id", .int(row.menuItemID)), ("sequenceNo", .int(row.sequenceNo)),
                                        ("isVisible", .int(row.isVisible ? 1 : 0))])
        }
        for row in model.sorts {
            try insert(db, "sort", [("sort_id", .int(row.id)), ("menuItem_id", .int(row.menuItemID)), ("sequenceNo", .int(row.sequenceNo)),
                                    ("isVisible", .int(row.isVisible ? 1 : 0)), ("isSelectedAsSubColumn", .int(row.isSelectedAsSubColumn ? 1 : 0))])
        }
        let property = model.property
        try insert(db, "property", [("deviceName", .text(property.deviceName)), ("dbVersion", .text(property.dbVersion)),
                                    ("numberOfContents", .int(property.numberOfContents)), ("createdDate", .text(property.createdDate)),
                                    ("backGroundColorType", .int(property.backgroundColorType)),
                                    ("myTagMasterDBID", .int(Int(property.myTagMasterDBID)))])
    }

    // MARK: 차이 적용

    /// 받아들인 모델 → 다음 모델의 OneLibrary 차이만 SQL로. 지우기를 먼저 하고 더하기·고치기를 한다.
    /// 기기 행(기록·큐·추천·핫큐 뱅크)과 보존 표(색·메뉴·카테고리·정렬·My Tag)는 건드리지 않는다.
    /// 기기 행이 가리키는 곡·그림을 빼는 편집은 막는다.
    static func applyDifference(from accepted: UsbLibrary, to next: UsbLibrary, _ db: CipherDatabase) throws {
        let old = accepted.projected(to: .oneLibrary), new = next.projected(to: .oneLibrary)
        let newTrackIDs = Set(new.tracks.map(\.id))
        let oldTracks = Dictionary(old.tracks.map { ($0.id, $0) }) { first, _ in first }
        let removed = Set(oldTracks.keys).subtracting(newTrackIDs)

        // 뺀 곡을 아직 가리키는 목록 항목이 있으면(항목을 고치지 않은 목록도) 기기가 없는 곡을 가리키게 되므로 막는다.
        // 이번에 뺀 곡만 본다 — USB에 원래 있던 어긋남 때문에 모든 편집이 막히지 않게
        for list in new.playlists {
            if let id = (list.entries[.oneLibrary] ?? []).first(where: removed.contains) {
                throw OneLibraryWriter.failure("playlist \(list.id) entry references removed content \(id)")
            }
        }
        // 곡 빼기: 기기가 남긴 큐·추천·재생 기록이 그 곡을 가리키면 그 표를 바꿔야 하므로 막는다
        for id in removed.sorted() {
            let cues = try count(db, "SELECT count(*) FROM cue WHERE content_id = ?", id)
            let likes = try count(db, "SELECT count(*) FROM recommendedLike WHERE content_id_1 = ? OR content_id_2 = ?", id, id)
            let plays = try count(db, "SELECT count(*) FROM history_content WHERE content_id = ?", id)
            guard cues == 0, likes == 0, plays == 0 else {
                throw OneLibraryWriter.failure(
                    "content \(id) referenced by device rows (cue \(cues), recommendedLike \(likes), history_content \(plays))")
            }
            try db.run("DELETE FROM content WHERE content_id = ?", [.int(id)])
            try db.run("DELETE FROM myTag_content WHERE content_id = ?", [.int(id)])
        }
        // 그림 빼기: 모델에 담지 않는 핫큐 뱅크가 가리키는 그림이면 그 표를 바꿔야 하므로 막는다
        for id in Set(old.images.map(\.id)).subtracting(new.images.map(\.id)).sorted() {
            let banks = try count(db, "SELECT count(*) FROM hotCueBankList WHERE image_id = ?", id)
            guard banks == 0 else { throw OneLibraryWriter.failure("image \(id) referenced by hotCueBankList (\(banks))") }
        }
        try sync(db, "artist", "artist_id", old.artists, new.artists, id: \.id, values: artist)
        try sync(db, "album", "album_id", old.albums, new.albums, id: \.id, values: album)
        try sync(db, "genre", "genre_id", old.genres, new.genres, id: \.id) { named($0, id: "genre_id") }
        try sync(db, "key", "key_id", old.keys, new.keys, id: \.id) { named($0, id: "key_id") }
        try sync(db, "label", "label_id", old.labels, new.labels, id: \.id) { named($0, id: "label_id") }
        try sync(db, "image", "image_id", old.images, new.images, id: \.id, values: image)

        // 같은 id가 두 번 있으면 둘째 INSERT가 제약 위반으로 실패한다(그 단계만 되돌린다)
        for track in new.tracks {
            if let before = oldTracks[track.id] {
                if before != track { try update(db, "content", content(track), skipping: deviceColumns) }
            } else {
                try insert(db, "content", content(track))
            }
        }

        let oldPlaylists = Dictionary(old.playlists.map { ($0.id, $0) }) { first, _ in first }
        for id in Set(oldPlaylists.keys).subtracting(new.playlists.map(\.id)).sorted() {
            try db.run("DELETE FROM playlist WHERE playlist_id = ?", [.int(id)])
            try db.run("DELETE FROM playlist_content WHERE playlist_id = ?", [.int(id)])
        }
        for list in new.playlists {
            let items = list.entries[.oneLibrary] ?? []
            let before = oldPlaylists[list.id]
            let itemsChanged = before.map { ($0.entries[.oneLibrary] ?? []) != items } ?? true
            if itemsChanged, let missing = items.first(where: { !newTrackIDs.contains($0) }) {
                throw OneLibraryWriter.failure("playlist \(list.id) entry references missing content \(missing)")
            }
            if let before {
                // 철자(NFC·NFD)만 바꾼 이름도 쓴다(Swift 문자열 ==는 같다고 본다, #233)
                if playlist(before).map(\.value) != playlist(list).map(\.value) || !UsbNameSpelling.sameScalars(before.name, list.name) {
                    try update(db, "playlist", playlist(list))
                }
                if itemsChanged {
                    // 편집한 목록만 항목을 지우고 1..N으로 다시 넣는다
                    try db.run("DELETE FROM playlist_content WHERE playlist_id = ?", [.int(list.id)])
                    try entries(db, list)
                }
            } else {
                try insert(db, "playlist", playlist(list))
                try entries(db, list)
            }
        }

        if old.property.numberOfContents != new.property.numberOfContents {
            try db.run("UPDATE property SET numberOfContents = ?", [.int(new.property.numberOfContents)])
        }
    }

    /// id로 짝지어 지우기·더하기·고치기
    static func sync<Row: Equatable>(_ db: CipherDatabase, _ table: String, _ idColumn: String, _ old: [Row], _ new: [Row],
                                     id: KeyPath<Row, Int>, values: (Row) -> Values) throws {
        let before = Dictionary(old.map { ($0[keyPath: id], $0) }) { first, _ in first }
        for gone in Set(before.keys).subtracting(new.map { $0[keyPath: id] }).sorted() {
            try db.run("DELETE FROM \(table) WHERE \(idColumn) = ?", [.int(gone)])
        }
        for row in new {
            if let previous = before[row[keyPath: id]] {
                if previous != row { try update(db, table, values(row)) }
            } else {
                try insert(db, table, values(row))
            }
        }
    }

    static func count(_ db: CipherDatabase, _ sql: String, _ ids: Int...) throws -> Int {
        var value = 0
        try db.query(sql, ids.map { .int($0) }) { value = $0.int(0) ?? 0 }
        return value
    }
}
