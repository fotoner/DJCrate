import DJCDomain
import Foundation

/// USB 시점 스냅샷(#226): USB 라이브러리 파일(DB 셋·사이드카, 분석 파일, 아트워크, 기기 설정 파일)을 이름 붙여 Mac에 그대로 남긴다.
/// 음원은 담지 않는다. 쓰기 전 백업(`UsbWriter+Backup`)은 그 쓰기가 덮거나 지울 파일만 담지만, 시점 스냅샷은 범위 전체를 담아
/// 다른 백업 없이 혼자 그 시점으로 되돌린다. 되돌리기는 `UsbPointRestore`가 변경 묶음으로 바꿔 `UsbWriter.write` 한 길로 쓴다.
///
/// - 저장: `<폴더>/<볼륨키>/<yyyy-MM-dd'T'HHmmss'Z'>-<종류>/`의 `snapshot.json`과 `files/<USB 상대 경로>`(폴더 0700·파일 0600)
/// - USB는 읽기만 한다. 정해진 이름만 stat하고 분석·아트워크 폴더만 내려가므로 열지 않는 곳(`UsbLayout.neverRead`)은 이름도 보지 않는다
/// - rekordbox가 꺼져 있고 끝나지 않은 DJCrate 쓰기·임시 파일이 없고 라이브러리 DB가 있을 때만 뜬다. 뜨는 동안 볼륨 잠금을 쥐고, 파일이 바뀌면 버린다
/// - 보존: 볼륨마다 최근 5개(USB 백업 정리와 같은 수) + 고정. 고정한 것은 고정을 푼 뒤에만 지운다
public enum UsbPointSnapshot {
    public typealias Entry = UsbPointSnapshotEntry
    public typealias Metadata = UsbPointSnapshotMetadata

    static let metadataName = "snapshot.json"
    static let filesFolder = "files"
    /// 이름 길이 상한(로컬 시점 스냅샷과 같다)
    public static let maxNameLength = 80

    // MARK: - 만들기

    /// 지금 USB의 라이브러리 파일을 스냅샷으로 남기고 이 볼륨의 보존 정리를 한다. USB에는 쓰지 않는다.
    /// - Parameters:
    ///   - directory: 스냅샷을 둘 폴더(앱·CLI는 DJC_HOME의 `usb-point-snapshots`). 볼륨마다 하위 폴더를 둔다
    ///   - paths: 저널·잠금을 보는 Mac 쪽 USB 폴더(쓰기 절차와 같은 것)
    @discardableResult
    public static func create(name: String, kind: RekordboxPointSnapshotKind = .manual, root: UsbRoot, in directory: URL, paths: UsbWritePaths,
                              guard writeGuard: UsbWriteGuard, fileSystem: any UsbFileSystem = PosixUsbFileSystem(),
                              now: Date = .now) throws -> Entry {
        let mountPoint = try mountCheck(root, fileSystem)
        // Mac 쪽 폴더(스냅샷·저널·잠금)가 그 볼륨 안이면 뜨기가 그 볼륨에 쓰게 된다. rekordbox 라이브러리·DJCrate 데이터 폴더와
        // 겹치는 볼륨도 받지 않는다(쓰기 절차의 보호 경로와 같은 판정). 여기서 막히면 Mac 쪽 폴더도 만들지 않는다
        if [directory, paths.sessions].contains(where: { UsbSnapshot.isInside($0.path, root: root.url.path) })
            || isProtected(mountPoint, writeGuard.protectedRoots) {
            throw refused("protectedPath",
                          String(ui: "DJCrate 데이터 폴더나 rekordbox 라이브러리와 겹치는 볼륨은 USB 스냅샷을 뜨지 않습니다. USB 볼륨을 고르세요"))
        }
        // 볼륨 정보를 읽기 전에 루트를 붙잡는다: 읽은 볼륨 번호가 붙잡은 볼륨의 것인지 아래에서 본다(쓰기 절차의 열기와 같은 순서)
        let hold = try fileSystem.holdVolume(root.url)
        defer { hold.release() }
        let volume = try writeGuard.volume(root.url)
        guard let uuid = volume.volumeUUID?.uppercased(), !uuid.isEmpty, uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw refused("noVolumeUUID", String(ui: "이 USB의 볼륨 번호를 읽지 못했습니다. 다시 연결한 뒤 시도하세요"))
        }
        guard hold.isSameVolume() else { throw UsbError.writeRefused([UsbWriteRun.volumeChangedBlock]) }
        if writeGuard.isRekordboxRunning() { throw rekordboxRunning }
        switch UsbWriter.journalStatus(paths: paths, volumeKey: uuid) {
        case .open: throw refused("recoveryNeeded", String(ui: "지난 USB 쓰기가 끝나지 않았습니다. `djc usb-recover`로 먼저 회복하세요"))
        case .corrupt: throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        case .missing, .closed: break
        }
        // 이 Mac의 다른 DJCrate 쓰기가 뜨는 도중 USB를 바꾸지 않게 쓰기와 같은 볼륨 잠금을 쥔다
        let lock = try UsbVolumeLock.acquire(directory: paths.sessions, key: uuid)
        defer { lock.release() }
        let base = try UsbWriter.databaseFingerprint(root: root, fileSystem: fileSystem)
        let found = try scopeFiles(root: root, fileSystem: fileSystem)
        // 라이브러리 DB가 없는 스냅샷은 되돌릴 수 없다(되돌리기가 DB를 지우지 않는다)
        guard UsbPointSnapshotRules.databaseOrder.contains(where: { found[$0] != nil }) else {
            throw refused("pointSnapshotNoDatabase",
                          String(ui: "이 USB에는 라이브러리 DB가 없어 스냅샷을 남기지 않았습니다. rekordbox나 DJCrate로 내보낸 USB를 고르세요"))
        }

        let fm = FileManager.default
        let volumeFolder = directory.appending(path: uuid)
        try fm.createDirectory(at: volumeFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 다 뜬 뒤에만 이름을 붙여 반쯤 뜬 스냅샷이 목록에 보이지 않게 한다
        let partial = volumeFolder.appending(path: ".partial-\(UUID().uuidString)")
        try fm.createDirectory(at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var files: [String: UsbFingerprint.Stamp] = [:]
            for (path, before) in found.sorted(by: { $0.key < $1.key }) {
                let source = root.url.appending(path: path)
                let destination = partial.appending(path: filesFolder).appending(path: path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let copied = try fileSystem.copyDataNew(from: source, to: destination) { _ in }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                guard copied.size == before.size, try unchanged(source, before, fileSystem),
                      base.files[path].map({ $0.sha256 == copied.sha256 }) ?? true else { throw sourceChanged }
                files[path] = .init(size: copied.size, mtime: before.modificationDate, sha256: copied.sha256)
            }
            // 앞서 뜬 파일이 뒤의 파일을 뜨는 동안 바뀌었거나, DB가 생기거나 없어졌거나, 다른 볼륨이 붙었으면 버린다
            for (path, before) in found where try !unchanged(root.url.appending(path: path), before, fileSystem) { throw sourceChanged }
            let databases = Set(try UsbWriter.databaseFamily.filter { try fileSystem.stat(root.url.appending(path: $0)) != nil })
            guard databases == Set(base.files.keys) else { throw sourceChanged }
            guard hold.isSameVolume(), try fileSystem.mountedOn(root.url) == mountPoint else {
                throw UsbError.writeRefused([UsbWriteRun.volumeChangedBlock])
            }
            if writeGuard.isRekordboxRunning() { throw rekordboxRunning }
            let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
            let metadata = Metadata(name: trimmed, kind: kind, createdAt: now, volumeUUID: uuid, volumeName: volume.name,
                                    appVersion: UsbManifest.currentAppVersion, files: files)
            try save(metadata, in: partial, fileSystem: fileSystem)
            let folder = uniqueFolder(in: volumeFolder, now: now, kind: kind)
            try fm.moveItem(at: partial, to: folder)
            prune(in: directory, volumeKey: uuid, now: now)
            return Entry(url: folder, metadata: metadata)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// 루트가 정말 마운트 지점인지(쓰기 절차의 첫 확인과 같은 판정). 아니면 다른 볼륨 번호로 스냅샷이 묶인다
    static func mountCheck(_ root: UsbRoot, _ fileSystem: any UsbFileSystem) throws -> String {
        guard let real = UsbScratchRoots.realPath(root.url.path), try fileSystem.mountedOn(root.url) == real else {
            throw refused("notMountPoint", String(ui: "USB 볼륨의 맨 위 폴더를 고르세요"))
        }
        return real
    }

    /// 마운트 지점(realpath)이 보호 폴더와 같거나 그 안이거나 그것을 품는지(`UsbWriteRun.isProtected`와 같은 판정)
    static func isProtected(_ mountPoint: String, _ protectedRoots: [URL]) -> Bool {
        protectedRoots.contains { protected in
            let path = UsbScratchRoots.realPath(protected.path) ?? protected.path
            return mountPoint == path || mountPoint.hasPrefix(path + "/") || path.hasPrefix(mountPoint + "/")
        }
    }

    static func unchanged(_ url: URL, _ before: UsbFileStat, _ fileSystem: any UsbFileSystem) throws -> Bool {
        guard let after = try fileSystem.stat(url) else { return false }
        return after.kind == .file && after.size == before.size && after.modificationDate == before.modificationDate
    }

    /// 스냅샷 범위의 파일(USB 상대 경로 NFC → lstat). DB 셋·설정 파일은 정해진 이름만 stat하고, 분석·아트워크 폴더만 내려간다
    /// (`PIONEER/` 자체는 열거하지 않는다). `._*`는 뺀다. 임시 파일(`.djc-part-*`)이 있으면 끝나지 않은 쓰기로 보고,
    /// 링크·일반 파일이 아닌 것이 있으면 USB 밖을 읽지 않게 거부한다. 되돌리기 계획도 같은 함수로 지금 USB를 본다(`restoring`: 막힘 문구)
    static func scopeFiles(root: UsbRoot, fileSystem: any UsbFileSystem, restoring: Bool = false) throws -> [String: UsbFileStat] {
        let unreadable = restoring ? unreadableForRestore : unreadable
        var found: [String: UsbFileStat] = [:]
        func url(_ relative: String) -> URL { root.url.appending(path: relative) }
        for folder in ["PIONEER", UsbLayout.rekordboxDir] {
            if let info = try fileSystem.stat(url(folder)), info.kind != .directory { throw unreadable }
        }
        if try fileSystem.stat(url(UsbLayout.rekordboxDir)) != nil,
           try fileSystem.list(url(UsbLayout.rekordboxDir)).contains(where: UsbLayout.isTemp) { throw tempFilesPresent }
        for path in UsbPointSnapshotRules.databaseFiles + UsbPointSnapshotRules.settingFiles {
            guard let info = try fileSystem.stat(url(path)) else { continue }
            guard info.kind == .file else { throw unreadable }
            found[path] = info
        }
        func walk(_ relative: String) throws {
            guard let info = try fileSystem.stat(url(relative)) else { return }
            guard info.kind == .directory else { throw unreadable }
            for name in try fileSystem.list(url(relative)) {
                let child = relative + "/" + name
                if UsbLayout.isTemp(name) { throw tempFilesPresent }
                if UsbLayout.isAppleDouble(name) || UsbLayout.isNeverRead(child) { continue }
                guard let childInfo = try fileSystem.stat(url(child)) else { continue }
                switch childInfo.kind {
                case .directory: try walk(child)
                case .file: found[UsbLayout.nfc(child)] = childInfo
                case .symlink, .other: throw unreadable
                }
            }
        }
        for folder in UsbPointSnapshotRules.folders { try walk(folder) }
        return found
    }

    // MARK: - 정보

    static func save(_ metadata: Metadata, in folder: URL, fileSystem: any UsbFileSystem = PosixUsbFileSystem()) throws {
        let url = folder.appending(path: metadataName)
        try UsbDurableFile.write(metadata, to: url, fileSystem: fileSystem)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func metadata(in folder: URL) -> Metadata? {
        let url = folder.appending(path: metadataName)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? UsbJournal.decoder().decode(Metadata.self, from: data)
    }

    /// 담은 파일의 자리(`files/<상대 경로>`)
    public static func fileURL(_ entry: Entry, _ path: String) -> URL {
        filesRoot(entry).appending(path: path)
    }

    /// 담은 파일의 뿌리. USB 루트와 같은 모양이라 DB 사본 뜨기(`UsbSnapshot.take`)가 USB처럼 읽는다
    static func filesRoot(_ entry: Entry) -> URL { entry.url.appending(path: filesFolder) }

    /// `2026-10-16T120000Z-manual`(UTC). 같은 초면 끝에 `-2`·`-3`…
    static func uniqueFolder(in directory: URL, now: Date, kind: RekordboxPointSnapshotKind) -> URL {
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

    // MARK: - 목록·고정·지우기

    /// 이 볼륨의 스냅샷(최근 것부터). 반쯤 뜬 것(`.partial-…`)·정보가 없거나 다른 볼륨 것은 뺀다
    public static func list(in directory: URL, volumeKey: String) -> [Entry] {
        let key = volumeKey.uppercased()
        let folder = directory.appending(path: key)
        // 폴더 URL은 만들 때와 같은 모양으로 다시 짓는다(목록이 돌려준 URL은 끝에 "/"가 붙는다)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.map { folder.appending(path: $0) }
            .compactMap { url in metadata(in: url).flatMap { $0.volumeUUID.uppercased() == key ? Entry(url: url, metadata: $0) : nil } }
            .sorted { ($0.metadata.createdAt, $0.id) > ($1.metadata.createdAt, $1.id) }
    }

    /// 폴더 이름(ID) 또는 겹치지 않는 이름으로 찾는다
    public static func find(_ key: String, in directory: URL, volumeKey: String) -> Entry? {
        let entries = list(in: directory, volumeKey: volumeKey)
        if let entry = entries.first(where: { $0.id == key }) { return entry }
        let named = entries.filter { !$0.metadata.name.isEmpty && $0.metadata.name == key }
        return named.count == 1 ? named[0] : nil
    }

    /// 고정하면 보존 정리가 지우지 않는다
    @discardableResult
    public static func setPinned(_ pinned: Bool, _ entry: Entry, in directory: URL) throws -> Entry {
        let folder = try owned(entry, in: directory)
        guard var metadata = metadata(in: folder) else {
            throw refused("pointSnapshotUnreadable", String(ui: "USB 스냅샷 정보(snapshot.json)를 읽지 못했습니다. 스냅샷 목록을 다시 본 뒤 고르세요"))
        }
        metadata.pinned = pinned
        try save(metadata, in: folder)
        return Entry(url: folder, metadata: metadata)
    }

    /// 사용자가 고른 스냅샷을 지운다. 고정한 것은 고정을 푼 뒤에만 지운다
    public static func delete(_ entry: Entry, in directory: URL) throws {
        let folder = try owned(entry, in: directory)
        if metadata(in: folder)?.pinned == true {
            throw refused("pointSnapshotPinned", String(ui: "고정한 USB 스냅샷은 지우지 않습니다. 고정을 푼 뒤 지우세요"))
        }
        try FileManager.default.removeItem(at: folder)
    }

    /// 스냅샷 폴더(`<폴더>/<볼륨키>/`) 바로 아래의 항목인지(다른 폴더를 고치거나 지우지 않게). 경로는 realpath끼리 견준다
    static func owned(_ entry: Entry, in directory: URL) throws -> URL {
        let volumeFolder = directory.appending(path: entry.metadata.volumeUUID.uppercased())
        guard let base = UsbScratchRoots.realPath(volumeFolder.path), let real = UsbScratchRoots.realPath(entry.url.path),
              (real as NSString).deletingLastPathComponent == base, !entry.id.hasPrefix("."),
              (try? FileManager.default.attributesOfItem(atPath: real))?[.type] as? FileAttributeType == .typeDirectory else {
            throw refused("pointSnapshotOutside", String(ui: "USB 스냅샷 폴더 밖의 항목은 고치지 않습니다. 목록에서 스냅샷을 고르세요"))
        }
        return entry.url
    }

    /// 보존 정리: 이 볼륨의 최근 5개 밖에서 고정하지 않은 것을 지운다. 스냅샷마다 범위 전체를 담아 서로 기대지 않으므로
    /// 어느 것을 지워도 남은 것의 되돌리기는 그대로다. 10분 넘은 반쯤 뜬 폴더도 치운다(뜨는 중인 것은 건드리지 않는다)
    @discardableResult
    public static func prune(in directory: URL, volumeKey: String, keep: Int = UsbPointSnapshotRules.keep, now: Date = .now) -> [URL] {
        let fm = FileManager.default
        let removed = UsbPointSnapshotRules.expired(list(in: directory, volumeKey: volumeKey), keep: keep).map(\.url)
            .filter { (try? fm.removeItem(at: $0)) != nil }
        let folder = directory.appending(path: volumeKey.uppercased())
        for stale in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        where stale.lastPathComponent.hasPrefix(".partial-") {
            let created = (try? stale.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if now.timeIntervalSince(created) > 600 { try? fm.removeItem(at: stale) }
        }
        return removed
    }

    // MARK: - 사건

    /// 그 볼륨에서 DJCrate가 본 것과 한 일: 시점 스냅샷과 쓰기 절차의 백업 폴더 기록(manifest·journal·report·restored).
    /// 기기 변경 판정(`UsbPointSnapshotRules.deviceChanged`)이 시각 순으로 따라간다. 읽지 못한 기록은 빼므로 판정은 모른다고 본다
    public static func volumeEvents(in directory: URL, paths: UsbWritePaths, volumeKey: String) -> [UsbVolumeEvent] {
        var events = list(in: directory, volumeKey: volumeKey).map {
            UsbVolumeEvent.snapshot(date: $0.metadata.createdAt, databases: $0.metadata.databases, sidecars: $0.metadata.hasSidecars)
        }
        let decoder = UsbJournal.decoder()
        func decode<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(type, from: $0) }
        }
        for backup in UsbWriter.backups(paths: paths, volumeKey: volumeKey.uppercased()) {
            guard let manifest = decode(UsbManifest.self, backup.appending(path: "manifest.json")),
                  let journal = decode(UsbJournal.self, backup.appending(path: "journal.json")),
                  let report = decode(UsbWriteReport.self, backup.appending(path: "report.json")) else { continue }
            let id = backup.lastPathComponent
            let before = manifest.files.filter { UsbPointSnapshotRules.databaseOrder.contains($0.key) }.mapValues(\.sha256)
            let sidecars = UsbLayout.oneLibrarySidecarSuffixes.contains { manifest.files[UsbLayout.oneLibrary + $0] != nil }
            let kind: UsbWriteEventKind = UsbPointRestore.restoredSnapshot(label: journal.changes.label).map { .exact(snapshot: $0) }
                ?? (journal.changes.purpose == .export ? .fresh : .carry)
            events.append(.write(id: id, date: manifest.createdAt, before: before, beforeSidecars: sidecars, after: report.resultDatabases,
                                 kind: kind, outcome: report.outcome))
            let marker = backup.appending(path: UsbWriter.restoredMarkerName)
            if let restored = decode(UsbWriteReport.self, marker),
               let date = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date {
                events.append(.restore(writeID: id, date: date, after: restored.resultDatabases))
            }
        }
        return events
    }

    // MARK: - 막힘

    static func refused(_ code: String, _ message: String) -> UsbError {
        .writeRefused([UsbBlock(code: code, scope: .volume, message: message)])
    }

    static var rekordboxRunning: UsbError {
        refused("rekordboxRunning", String(ui: "rekordbox가 켜져 있어 USB 스냅샷을 남기지 않았습니다. rekordbox를 완전히 종료한 뒤 다시 시도하세요"))
    }

    static var tempFilesPresent: UsbError {
        refused("tempFilesPresent", String(ui: "USB에 끝나지 않은 쓰기의 임시 파일이 있습니다. `djc usb-recover --discard-temp`로 지운 뒤 다시 시도하세요"))
    }

    static var unreadable: UsbError {
        refused("pointSnapshotUnreadable",
                String(ui: "USB 라이브러리 폴더에 링크나 일반 파일이 아닌 것이 있어 스냅샷을 남기지 않았습니다. USB를 확인한 뒤 다시 시도하세요"))
    }

    static var unreadableForRestore: UsbError {
        refused("pointSnapshotUnreadable",
                String(ui: "USB 라이브러리 폴더에 링크나 일반 파일이 아닌 것이 있어 되돌리지 않았습니다. USB를 확인한 뒤 다시 시도하세요"))
    }

    static var sourceChanged: UsbError {
        refused("sourceChangedDuringCopy",
                String(ui: "스냅샷을 뜨는 동안 USB 파일이 바뀌어 그 스냅샷은 버렸습니다. 다른 프로그램이 USB를 쓰지 않는지 확인한 뒤 다시 시도하세요"))
    }
}
