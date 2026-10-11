import DJCDomain
import DJCEnvironment
import Foundation

/// rekordbox 라이브 DB를 건드리지 않기 위한 스냅샷.
/// 툴의 모든 읽기는 이 사본에서 한다.
public enum LibrarySnapshot {
    /// URL의 디렉터리 힌트(`/`)가 달라도 같은 파일시스템 폴더면 같은 출처다.
    public static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool { lhs.isSameDirectory(as: rhs) }

    public static func hasRekordboxDirectoryOverride(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["DJC_REKORDBOX_DIR"]?.isEmpty == false
    }

    /// rekordbox 라이브러리 폴더. 개발 시험은 `DJC_REKORDBOX_DIR`로 사본 폴더를 가리킨다(실제 라이브러리를 건드리지 않게).
    public static var rekordboxDirectory: URL {
        rekordboxDirectory(in: ProcessInfo.processInfo.environment)
    }

    public static func rekordboxDirectory(in environment: [String: String]) -> URL {
        if hasRekordboxDirectoryOverride(in: environment), let override = environment["DJC_REKORDBOX_DIR"] {
            return URL(filePath: override)
        }
        // 시험 프로세스는 실제 라이브러리 대신 빈 임시 폴더를 기본으로 본다(#182).
        if TestProcess.isRunning { return TestProcess.sandbox.appending(path: "rekordbox") }
        return realRekordboxDirectory
    }

    /// 사용자의 실제 rekordbox 라이브러리 폴더. 환경 변수·시험 여부와 상관없이 늘 이 경로다(보호할 대상을 가리킬 때 쓴다).
    public static var realRekordboxDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox")
    }

    public static var defaultDirectory: URL {
        defaultDirectory(in: ProcessInfo.processInfo.environment)
    }

    public static func defaultDirectory(in environment: [String: String]) -> URL {
        // 사본 rekordbox 폴더로 시험할 때는 스냅샷도 그 안에 둔다(사용자 스냅샷과 섞이지 않게). 캐시 비우기와 같은 규칙을 쓴다.
        DJCIdentity.snapshotsDirectory(environment: environment, support: DJCIdentity.supportDirectory)
    }

    /// rekordbox가 실행 중인지 프로세스 이름으로 확인한다.
    public static func isRekordboxRunning() -> Bool {
        ["rekordbox", "rekordboxAgent"].contains { name in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
    }

    /// master.db를 복사한다. 복사 전후로 원본 크기·수정 시각이 같아야 성공이다.
    /// - Parameter force: rekordbox 실행 중이거나 WAL이 남아 있어도 읽기용 사본을 뜬다.
    @discardableResult
    public static func take(
        from source: URL = rekordboxDirectory.appending(path: "master.db"),
        into directory: URL = defaultDirectory,
        force: Bool = false,
        now: Date = .now
    ) throws -> URL {
        let fm = FileManager.default
        if !force {
            if isRekordboxRunning() { throw DJCError.rekordboxRunning }
            let wal = source.deletingLastPathComponent().appending(path: source.lastPathComponent + "-wal")
            if let size = try? fm.attributesOfItem(atPath: wal.path)[.size] as? Int, size > 0 {
                throw DJCError.writeAheadLogPresent(path: wal.path)
            }
        }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let before = try fm.attributesOfItem(atPath: source.path)
        // 명시한 사본을 다시 뜰 때는 그 사본의 iTunes 목록만 함께 가져온다.
        let iTunesData = try? Data(contentsOf: source.appendingPathExtension("itunes.json"))
        // 재생 목록 XML(USB 동기화가 선택 파일의 Timestamp를 옮긴다)도 DB와 같은 때의 사본을 둔다. 사본에서 다시 뜨면 그 사본 옆 것을,
        // 아니면 DB 옆 것을 읽는다. 라이브 폴더의 XML은 여기서 한 번만 읽는다.
        let masterXMLData = (try? Data(contentsOf: masterPlaylistsURL(of: source)))
            ?? (try? Data(contentsOf: source.deletingLastPathComponent().appending(path: "masterPlaylists6.xml")))

        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
            .replacingOccurrences(of: ":", with: "")
        let destination = directory.appending(path: "master-\(stamp).db")
        // 같은 초에 두 번 떠도 서로의 임시 파일을 지우지 않도록 고유 이름을 쓴다.
        let partial = directory.appending(path: ".\(UUID().uuidString).part")
        try fm.copyItem(at: source, to: partial)

        let after = try fm.attributesOfItem(atPath: source.path)
        guard before[.size] as? Int == after[.size] as? Int,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date
        else {
            try? fm.removeItem(at: partial)
            throw DJCError.sourceChangedDuringCopy(path: source.path)
        }

        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        try fm.moveItem(at: partial, to: destination)
        let iTunesDestination = destination.appendingPathExtension("itunes.json")
        // 같은 초의 파일 이름을 재사용해도 이전 DB의 목록을 붙들지 않는다.
        try? fm.removeItem(at: iTunesDestination)
        let masterXMLDestination = masterPlaylistsURL(of: destination)
        try? fm.removeItem(at: masterXMLDestination)

        // rekordbox가 켜져 있으면 최근 변경이 WAL에만 있다. WAL도 사본 옆에 복사해 사본 안에서 합친다.
        let sourceWAL = source.deletingLastPathComponent().appending(path: source.lastPathComponent + "-wal")
        if force, let size = try? fm.attributesOfItem(atPath: sourceWAL.path)[.size] as? Int, size > 0 {
            let copyWAL = URL(filePath: destination.path + "-wal")
            try? fm.removeItem(at: copyWAL)
            try fm.copyItem(at: sourceWAL, to: copyWAL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copyWAL.path)
            do {
                try CipherDatabase.mergeWriteAheadLog(ofCopyAt: destination.path, key: RekordboxKey.derive())
            } catch {
                try? fm.removeItem(at: copyWAL)
                throw error
            }
            try? fm.removeItem(at: copyWAL)
            try? fm.removeItem(at: URL(filePath: destination.path + "-shm"))
        }
        if let iTunesData {
            try iTunesData.write(to: iTunesDestination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: iTunesDestination.path)
        }
        if let masterXMLData {
            try masterXMLData.write(to: masterXMLDestination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: masterXMLDestination.path)
        }
        prune(keeping: 3, in: directory)
        return destination
    }

    /// 스냅샷은 한 개에 150MB 안팎이다. 최근 `keeping`개만 남긴다.
    public static func prune(keeping: Int, in directory: URL = defaultDirectory) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "db" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(keeping) {
            try? fm.removeItem(at: old)
            if !fm.fileExists(atPath: old.path) {
                try? fm.removeItem(at: old.appendingPathExtension("itunes.json"))
                try? fm.removeItem(at: masterPlaylistsURL(of: old))
            }
        }
        // 읽는 연결이 남긴 -shm·-wal 중 본 파일이 지워진 것
        for leftover in ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        where ["db-shm", "db-wal"].contains(leftover.pathExtension) {
            let main = leftover.deletingPathExtension().path + ".db"
            if !fm.fileExists(atPath: main) { try? fm.removeItem(at: leftover) }
        }
        // 진행 중인 다른 복사본을 지우지 않도록 10분 넘은 임시 파일만 정리한다.
        for stale in ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        where stale.pathExtension == "part" {
            let modified = (try? stale.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 600 { try? fm.removeItem(at: stale) }
        }
    }

    /// 스냅샷을 뜰 때 함께 복사한 `masterPlaylists6.xml`(`master-….db.masterPlaylists6.xml`)
    public static func masterPlaylistsURL(of snapshot: URL) -> URL { snapshot.appendingPathExtension("masterPlaylists6.xml") }

    /// 스냅샷 파일 이름(`master-2026-09-26T083646.db`, UTC)에 적힌 뜬 시각
    public static func takenAt(_ snapshot: URL) -> Date? {
        let name = snapshot.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("master-") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return formatter.date(from: String(name.dropFirst("master-".count)))
    }

    /// 스냅샷을 뜬 뒤에 rekordbox 라이브러리(master.db나 WAL)가 바뀌었는지.
    /// rekordbox가 켜져 있으면 변경이 WAL에만 있으므로 둘 다 본다. 시각을 모르면 false.
    public static func changed(since snapshot: URL, source: URL = rekordboxDirectory.appending(path: "master.db")) -> Bool {
        guard let taken = takenAt(snapshot) else { return false }
        let fm = FileManager.default
        let modified = [source.path, source.path + "-wal"].compactMap { try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        // 이름의 시각은 초 단위로 버린 값이라 1초 여유를 둔다
        return modified.contains { $0 > taken.addingTimeInterval(1) }
    }

    /// 가장 최근 스냅샷.
    public static func latest(in directory: URL = defaultDirectory) throws -> URL {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let newest = files.filter({ $0.pathExtension == "db" }).max(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { throw DJCError.snapshotNotFound }
        return newest
    }
}
