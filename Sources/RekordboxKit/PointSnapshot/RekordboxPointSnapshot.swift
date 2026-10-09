import DJCDomain
import Foundation

/// 시점 스냅샷(#220·#223·#224): rekordbox 라이브러리에서 DJCrate가 쓰는 파일 전체를 한 시점으로 남긴다.
/// 쓰기 전 백업(`RekordboxWriter+Backup`)은 DB와 그 쓰기가 바꾸는 파일만 담아 연쇄로 되돌려야 하지만(#222),
/// 시점 스냅샷은 DB와 분석·앨범아트 폴더 전체를 담아 다른 스냅샷 없이 혼자 그 시점으로 되돌릴 수 있다. 그래서 보존 정리가
/// 어느 스냅샷을 지워도 남은 스냅샷의 복원은 끊기지 않는다.
///
/// - 범위(#223 결정): `master.db`, `masterPlaylists6.xml`, `playlists3.sync`, `share/PIONEER/USBANLZ`, `share/PIONEER/Artwork`
/// - 저장: `FileManager.copyItem`(같은 APFS 볼륨이면 클론이라 처음에는 공간을 거의 쓰지 않는다). 폴더 0700·파일 0600
/// - rekordbox·rekordboxAgent가 꺼져 있고 WAL이 비었을 때만 뜬다. 뜨는 동안 DB가 바뀌거나 rekordbox가 켜지면 버린다
/// - 보존: 수동·고정은 지우지 않는다. 자동은 최근 `autoDays`일과 그보다 옛 것 중 가장 최근 하나(#236), 복원 직전은 최근 3개(고정 제외)
/// - 자동(하루 한 번, #228)은 `RekordboxPointSnapshot+Auto`
public enum RekordboxPointSnapshot {
    // 값(종류·정보·항목)은 DJCDomain에 있다(#167). 옛 이름을 남긴다.
    public typealias Kind = RekordboxPointSnapshotKind
    public typealias Metadata = RekordboxPointSnapshotMetadata
    public typealias Entry = RekordboxPointSnapshotEntry

    static let metadataName = "snapshot.json"
    /// rekordbox 폴더에서 담는 파일(DB 옆)
    static let adjacentFiles = ["masterPlaylists6.xml", "playlists3.sync"]
    /// share 아래에서 담는 폴더
    public static let shareFolders = ["PIONEER/USBANLZ", "PIONEER/Artwork"]
    /// 복원 직전 스냅샷을 이만큼 남긴다(#223 결정)
    public static let beforeRestoreToKeep = 3
    /// 이름 길이 상한(목록 한 줄에 보이게)
    public static let maxNameLength = 80

    // MARK: - 만들기

    /// 지금 라이브러리를 시점 스냅샷으로 남긴다. 대상 DB·share는 부르는 쪽이 적는다(라이브 기본 인자 없음).
    /// - Parameters:
    ///   - shareRoot: 분석 파일 뿌리. nil이면 라이브 DB는 rekordbox share, 사본은 DB 옆 `share`
    ///   - directory: 스냅샷을 둘 폴더(앱은 `DJCPaths.pointSnapshots`)
    ///   - autoDays: 만든 뒤 보존 정리에 쓸 자동 스냅샷 보존 일수
    @discardableResult
    public static func create(name: String, kind: Kind = .manual, database: URL, shareRoot: URL?, in directory: URL,
                              autoDays: Int, now: Date = .now, guard writeGuard: RekordboxWriteGuard = .system) throws -> Entry {
        let entry = try take(name: name, kind: kind, database: database, shareRoot: shareRoot, in: directory, now: now, guard: writeGuard)
        prune(in: directory, autoDays: autoDays, now: now)
        return entry
    }

    /// 정리 없이 뜬다(복원 직전 스냅샷은 복원이 끝난 뒤 정리한다).
    static func take(name: String, kind: Kind, database: URL, shareRoot: URL?, in directory: URL, now: Date,
                     guard writeGuard: RekordboxWriteGuard, restoredFrom: String? = nil) throws -> Entry {
        let fm = FileManager.default
        let live = writeGuard.isLive(database)
        let share = try resolvedShare(database, shareRoot: shareRoot, guard: writeGuard)
        if live, writeGuard.isRekordboxRunning() {
            throw DJCError.writeRefused(String(ui: "rekordbox가 켜져 있어 시점 스냅샷을 남기지 않았습니다. rekordbox를 완전히 종료한 뒤 다시 누르세요"))
        }
        guard fm.fileExists(atPath: database.path) else {
            throw DJCError.writeRefused(String(ui: "rekordbox 라이브러리(master.db)를 찾지 못했습니다. rekordbox 폴더를 확인하세요"))
        }
        if let size = (try? fm.attributesOfItem(atPath: database.path + "-wal"))?[.size] as? Int, size > 0 {
            throw DJCError.writeRefused(String(ui: "rekordbox가 정상적으로 종료되지 않은 것 같습니다(WAL 파일이 남아 있음). rekordbox를 한 번 켰다가 종료한 뒤 다시 시도하세요"))
        }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 다 뜬 뒤에만 이름을 붙여 반쯤 뜬 스냅샷이 목록에 보이지 않게 한다.
        let partial = directory.appending(path: ".partial-\(UUID().uuidString)")
        try fm.createDirectory(at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let before = try fm.attributesOfItem(atPath: database.path)
            var items = ["master.db"]
            try copyFile(database, to: partial.appending(path: "master.db"))
            for name in adjacentFiles {
                let source = database.deletingLastPathComponent().appending(path: name)
                guard fm.fileExists(atPath: source.path) else { continue }
                try copyFile(source, to: partial.appending(path: name))
                items.append(name)
            }
            for folder in shareFolders {
                let source = share.appending(path: folder)
                guard try isPlainDirectory(source) else { continue }
                let destination = partial.appending(path: "share").appending(path: folder)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
                try rejectLinks(in: destination)
                items.append("share/" + folder)
            }
            let after = try fm.attributesOfItem(atPath: database.path)
            guard before[.size] as? Int == after[.size] as? Int,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  !(live && writeGuard.isRekordboxRunning()) else {
                throw DJCError.writeRefused(String(ui: "스냅샷을 뜨는 동안 rekordbox 라이브러리가 바뀌어 그 스냅샷은 버렸습니다. rekordbox를 종료한 채로 다시 누르세요"))
            }
            let copy = partial.appending(path: "master.db")
            var metadata = Metadata(name: trimmed, kind: kind, createdAt: now, items: items,
                                    cloned: canClone(from: database.deletingLastPathComponent(), to: directory))
            metadata.restoredFrom = restoredFrom
            metadata.source = (before[.size] as? Int).flatMap { size in
                (before[.modificationDate] as? Date).map { SourceStamp(size: Int64(size), modified: $0.timeIntervalSince1970) }
            }
            try describe(copy, into: &metadata)
            try save(metadata, in: partial)
            let folder = uniqueFolder(in: directory, now: now, kind: kind)
            try fm.moveItem(at: partial, to: folder)
            return Entry(url: folder, metadata: metadata)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// 뜬 DB를 검사하고 라이브러리 ID·카운터·곡 수를 적는다. 읽느라 생긴 빈 `-wal`·`-shm`은 치운다(스냅샷에는 DB 하나만).
    static func describe(_ copy: URL, into metadata: inout Metadata) throws {
        try RekordboxWriter.checkIntegrity(of: copy)
        metadata.libraryID = RekordboxWriter.libraryID(of: copy)
        do {
            let db = try CipherDatabase(path: copy.path, key: RekordboxKey.derive())
            defer { db.close() }
            let counters = try? RekordboxCompatibility.updateCounters(db)
            metadata.localUpdateCount = counters?.local
            metadata.cloudUpdateCount = counters?.cloud
            metadata.trackCount = try? db.scalarInt("SELECT count(*) FROM djmdContent WHERE rb_local_deleted = 0")
        }
        let fm = FileManager.default
        if ((try? fm.attributesOfItem(atPath: copy.path + "-wal"))?[.size] as? Int ?? 0) == 0 {
            try? fm.removeItem(atPath: copy.path + "-wal")
            try? fm.removeItem(atPath: copy.path + "-shm")
        }
    }

    /// 사본 DB는 옆 `share`, 라이브 DB는 그 라이브러리의 share. 시험 프로세스의 실제 라이브러리는 여기서 거부된다(#182).
    static func resolvedShare(_ database: URL, shareRoot: URL?, guard writeGuard: RekordboxWriteGuard) throws -> URL {
        let copyShare = writeGuard.isLive(database) ? nil : database.deletingLastPathComponent().appending(path: "share")
        return try writeGuard.resolveShareRoot(database, shareRoot: shareRoot ?? copyShare)
            ?? database.deletingLastPathComponent().appending(path: "share")
    }

    static func copyFile(_ source: URL, to destination: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular else {
            throw DJCError.writeRefused(String(ui: "\(source.lastPathComponent)가 일반 파일이 아니라 스냅샷에 담지 않았습니다. rekordbox 폴더를 확인하세요"))
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// 있는 일반 폴더면 true, 없으면 false. 심볼릭 링크는 따르지 않고 거부한다.
    static func isPlainDirectory(_ url: URL) throws -> Bool {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return false }
        guard type == .typeDirectory else {
            throw DJCError.writeRefused(String(ui: "\(url.lastPathComponent) 폴더가 심볼릭 링크이거나 폴더가 아니라 스냅샷을 남기지 않았습니다. rekordbox 폴더를 확인하세요"))
        }
        return true
    }

    /// 폴더 안에 심볼릭 링크가 있으면 거부한다(복원이 폴더 밖을 가리키는 링크를 되살리지 않게).
    static func rejectLinks(in folder: URL) throws {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw DJCError.writeRefused(String(ui: "분석·앨범아트 폴더에 심볼릭 링크(\(url.lastPathComponent))가 있어 스냅샷을 남기지 않았습니다. 링크를 정리한 뒤 다시 시도하세요"))
            }
        }
    }

    /// `2026-10-07T120000Z-manual`(UTC). 같은 초면 끝에 `-2`·`-3`…
    static func uniqueFolder(in directory: URL, now: Date, kind: Kind) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        let base = formatter.string(from: now) + "-" + kind.rawValue
        var name = base, suffix = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: name).path) {
            name = base + "-\(suffix)"
            suffix += 1
        }
        return directory.appending(path: name)
    }

    /// 같은 볼륨이고 그 볼륨이 클론을 지원하면 true(아니면 전체 복사가 된다)
    public static func canClone(from source: URL, to directory: URL) -> Bool {
        var target = directory
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 { target = target.deletingLastPathComponent() }
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey]
        guard let a = try? source.resourceValues(forKeys: keys), let b = try? target.resourceValues(forKeys: keys),
              let volumeA = a.volumeIdentifier, let volumeB = b.volumeIdentifier else { return false }
        return volumeA.isEqual(volumeB) && b.volumeSupportsFileCloning == true
    }

    // MARK: - 메타데이터

    static func save(_ metadata: Metadata, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestampFormatter(fractional: true).string(from: date))
        }
        let url = folder.appending(path: metadataName)
        try encoder.encode(metadata).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `2026-10-07T12:00:00.123Z`(UTC). 같은 초에 뜬 쓰기 전 백업과 목록 순서를 맞추려고 소수 초까지 적는다.
    static func timestampFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    static func metadata(in folder: URL) -> Metadata? {
        let url = folder.appending(path: metadataName)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = timestampFormatter(fractional: true).date(from: text) ?? timestampFormatter(fractional: false).date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        return try? decoder.decode(Metadata.self, from: data)
    }

    // MARK: - 목록·고정·지우기

    /// 스냅샷 목록(최근 것부터). 반쯤 뜬 것(`.partial-…`)·메타데이터나 DB가 없는 폴더는 뺀다.
    public static func list(in directory: URL) -> [Entry] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && fm.fileExists(atPath: $0.appending(path: "master.db").path) }
            .compactMap { folder in metadata(in: folder).map { Entry(url: folder, metadata: $0) } }
            .sorted { ($0.metadata.createdAt, $0.id) > ($1.metadata.createdAt, $1.id) }
    }

    /// 폴더 이름(ID) 또는 겹치지 않는 이름으로 찾는다.
    public static func find(_ key: String, in directory: URL) -> Entry? {
        let entries = list(in: directory)
        if let entry = entries.first(where: { $0.id == key }) { return entry }
        let named = entries.filter { !$0.metadata.name.isEmpty && $0.metadata.name == key }
        return named.count == 1 ? named[0] : nil
    }

    /// 고정하면 보존 정리가 지우지 않는다.
    @discardableResult
    public static func setPinned(_ pinned: Bool, _ entry: URL, in directory: URL) throws -> Entry {
        let folder = try owned(entry, in: directory)
        guard var metadata = metadata(in: folder) else {
            throw DJCError.writeRefused(String(ui: "시점 스냅샷 정보(snapshot.json)를 읽지 못했습니다. 스냅샷 목록을 새로 고친 뒤 다시 고르세요"))
        }
        metadata.pinned = pinned
        try save(metadata, in: folder)
        return Entry(url: folder, metadata: metadata)
    }

    /// 사용자가 고른 스냅샷을 지운다. 고정한 스냅샷은 고정을 푼 뒤에만 지운다.
    public static func delete(_ entry: URL, in directory: URL) throws {
        let folder = try owned(entry, in: directory)
        if metadata(in: folder)?.pinned == true {
            throw DJCError.writeRefused(String(ui: "고정한 시점 스냅샷은 지우지 않습니다. 고정을 푼 뒤 지우세요"))
        }
        try FileManager.default.removeItem(at: folder)
    }

    /// 스냅샷 폴더 바로 아래의 항목인지(다른 폴더를 고치거나 지우지 않게)
    static func owned(_ entry: URL, in directory: URL) throws -> URL {
        let parent = entry.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard parent.path == directory.standardizedFileURL.resolvingSymlinksInPath().path, !entry.lastPathComponent.hasPrefix("."),
              (try? FileManager.default.attributesOfItem(atPath: entry.path))?[.type] as? FileAttributeType == .typeDirectory else {
            throw DJCError.writeRefused(String(ui: "시점 스냅샷 폴더 밖의 항목은 고치지 않습니다. 목록에서 스냅샷을 고르세요"))
        }
        return entry
    }

    /// 보존 정리(#223 결정). 수동·고정은 지우지 않는다. 자동은 `autoDays`일보다 옛 것(가장 최근 하나는 남김, #236), 복원 직전은 최근 3개 밖의 것을 지운다.
    /// 스냅샷마다 전체를 담아 서로 기대지 않으므로 어느 것을 지워도 남은 것의 복원은 그대로다.
    /// 10분 넘은 반쯤 뜬 폴더도 치운다(뜨는 중인 것은 건드리지 않는다).
    @discardableResult
    public static func prune(in directory: URL, autoDays: Int, now: Date = .now) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        let entries = list(in: directory).filter { !$0.metadata.pinned }
        let cutoff = now.addingTimeInterval(-Double(max(autoDays, 1)) * 86_400)
        // 보존 일수를 넘은 자동 중 가장 최근 하나는 늘 남긴다(#236): 라이브러리를 오래 두다 바꿀 때 바꾸기 직전 상태가 보존 기간에 지워지지 않게.
        // 고정한 것도 옛 자동으로 세어(목록은 최근 순) 그것이 가장 최근이면 고정이 이미 그 몫을 한다.
        let expired = list(in: directory).filter { $0.metadata.kind == .auto && $0.metadata.createdAt < cutoff }
        removed += expired.dropFirst().filter { !$0.metadata.pinned }.map(\.url)
        removed += entries.filter { $0.metadata.kind == .beforeRestore }.dropFirst(beforeRestoreToKeep).map(\.url)
        removed = removed.filter { (try? fm.removeItem(at: $0)) != nil }
        for stale in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        where stale.lastPathComponent.hasPrefix(".partial-") {
            let created = (try? stale.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if now.timeIntervalSince(created) > 600 { try? fm.removeItem(at: stale) }
        }
        return removed
    }

    /// 파일 하나의 크기·수정 시각(클론·복사는 수정 시각을 그대로 둔다)
    public struct FileStamp: Sendable, Equatable {
        public var size: Int64
        public var modified: Date?
    }

    /// 폴더 아래 일반 파일(상대 경로 → 크기·수정 시각). 없는 폴더는 빈 목록. 복원 검증과 차이 요약이 쓴다.
    public static func fileStamps(_ folder: URL) -> [String: FileStamp] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        var stamps: [String: FileStamp] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.path + "/") else { continue }
            stamps[String(path.dropFirst(root.path.count + 1))] = FileStamp(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }
        return stamps
    }

    /// 담은 파일의 논리 크기 합(클론이면 실제 디스크 사용은 더 작다)
    public static func size(of entry: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: entry, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
