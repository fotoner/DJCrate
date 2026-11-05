import DJCDomain
import Foundation

/// USB 시점 스냅샷 → 변경 묶음(#226). 스냅샷에 담은 파일을 그대로 돌려놓는 계획이다. 새 형식 규칙도 새 쓰기 길도 아니다:
/// USB에는 `UsbWriter.write` 한 곳이 백업·저널·검증과 함께 쓴다(그래서 이 되돌리기도 `usb-restore`로 다시 되돌린다).
/// - DB: 스냅샷의 DB 셋을 사본으로 떠(`UsbSnapshot.take`, 담은 사이드카는 사본 안에서 합친다) 준비 폴더에 두고, 지금 USB와 다르거나
///   OneLibrary 사이드카가 있으면 바꾼다(쓰기 절차가 사이드카를 지운다). 스냅샷 뒤에 생긴 DB는 지울 수 없어 막는다
/// - 분석 파일·아트워크·설정 파일: 없으면 만들고, 다르면 덮고(분석 파일은 지금 PPTH를 기대값으로), 스냅샷에 없으면
///   지우기 허용 목록(`UsbRemovalPolicy`) 안의 것만 지운다. 목록 밖의 것은 남기고 수를 알린다. 되돌리는 설정 파일 수도 알린다
/// - 음원(`Contents/`)은 담지도 건드리지도 않는다. 스냅샷 DB가 가리키는 음원이 지금 없으면 그 수를 알린다
/// USB는 읽기만 한다(지금 파일의 크기·해시·PPTH). 막히거나 바꿀 것이 없으면 `changes`가 nil이고 준비 폴더는 지운다.
public enum UsbPointRestore {
    /// 변경 묶음 이름의 앞부분(저널·백업 폴더 이름에 쓰인다)
    public static let label = "point-restore"

    /// 변경 묶음 이름: 앞부분 + 돌려놓는 스냅샷 ID. 기기 변경 판정이 이 쓰기가 어느 스냅샷을 돌려놓았는지 읽는다
    /// (담은 사이드카를 합친 DB는 해시가 스냅샷과 달라 해시로는 모른다)
    public static func label(for entry: UsbPointSnapshotEntry) -> String { label + "-" + entry.id }

    /// 변경 묶음 이름이 시점 되돌리기면 돌려놓은 스냅샷 ID(모르면 빈 문자열), 아니면 nil
    public static func restoredSnapshot(label name: String) -> String? {
        if name == label { return "" }
        return name.hasPrefix(label + "-") ? String(name.dropFirst(label.count + 1)) : nil
    }

    /// - base: 부르는 쪽이 기기 변경을 판정한 USB DB 지문(`UsbWriter.databaseFingerprint`). 변경 묶음의 base가 된다.
    ///   계획하는 동안 USB DB가 이것과 달라지면 막는다(판정하지 않은 상태를 덮지 않게, 쓰기 전 확인도 다시 본다)
    /// - staging: 이 계획의 준비 폴더(없어야 한다). 계획이 있으면 남기고, 없으면 지운다
    /// - highWater: 닫힌 저널이 이어 쓰라고 남긴 ID 상한. 옛 상태로 돌아가도 그 뒤에 쓴 ID를 다시 쓰지 않게 그대로 넘긴다
    public static func plan(_ entry: UsbPointSnapshotEntry, root: UsbRoot, fileSystem: any UsbFileSystem = PosixUsbFileSystem(), base: UsbFingerprint,
                            staging: URL, session: String, highWater: [String: Int]) throws -> UsbPointRestoreResult {
        var result = UsbPointRestoreResult()
        let metadata = entry.metadata
        // 1. 스냅샷이 온전한지(범위 안의 경로, 담은 파일의 크기·해시). 깨진 스냅샷으로 USB를 바꾸지 않는다
        guard try intact(entry) else {
            result.blocks = [Blocks.damaged]
            return result
        }
        let saved = metadata.databases
        guard !saved.isEmpty else {
            result.blocks = [Blocks.noDatabase]
            return result
        }
        // 2. 지금 USB의 같은 범위. 스냅샷 뒤에 생긴 DB는 쓰기 절차가 지우지 않는다(지우기 허용 목록 밖)
        let current = try UsbPointSnapshot.scopeFiles(root: root, fileSystem: fileSystem, restoring: true)
        guard try UsbWriter.databaseFingerprint(root: root, fileSystem: fileSystem).sameContent(as: base) else {
            result.blocks = [Blocks.changed]
            return result
        }
        let added = UsbPointSnapshotRules.databaseOrder.filter { current[$0] != nil && saved[$0] == nil }
        guard added.isEmpty else {
            result.blocks = [Blocks.newDatabase(added)]
            return result
        }
        let fm = FileManager.default
        var keepStaging = false
        defer { if !keepStaging { try? fm.removeItem(at: staging) } }

        // 3. DB 셋 사본(USB가 아니라 스냅샷 폴더에서 뜬다). 사이드카가 없던 DB는 담은 바이트 그대로다
        let copy: UsbSnapshot
        do {
            copy = try UsbSnapshot.take(root: UsbRoot(UsbPointSnapshot.filesRoot(entry)), into: staging.appending(path: "db"))
        } catch let error as UsbError {
            guard case .readFailed = error else { throw error }
            result.blocks = [Blocks.damaged]
            return result
        }
        let staged: [String: URL?] = [UsbLayout.oneLibrary: copy.oneLibrary, UsbLayout.exportPdb: copy.exportPdb,
                                      UsbLayout.exportExtPdb: copy.exportExtPdb]
        var databases: [UsbDatabaseReplacement] = []
        var writes: [UsbFileWrite] = []
        var removals: [UsbFileRemoval] = []
        var mustExist: [String: UsbTreeStamp] = [:]
        var mustNotExist: Set<String> = []
        let sidecars = UsbLayout.oneLibrarySidecarSuffixes.map { UsbLayout.oneLibrary + $0 }
        for path in UsbPointSnapshotRules.databaseOrder {
            guard let expected = saved[path] else { continue }
            guard let url = staged[path] ?? nil, let info = try fileSystem.stat(url) else {
                result.blocks = [Blocks.damaged]
                return result
            }
            let sha = try fileSystem.sha256(url, uncached: false)
            if path != UsbLayout.oneLibrary || !metadata.hasSidecars, sha != expected {
                result.blocks = [Blocks.damaged]
                return result
            }
            mustExist[path] = UsbTreeStamp(size: info.size, sha256: sha)
            let clearSidecars = path == UsbLayout.oneLibrary && sidecars.contains { base.files[$0] != nil }
            guard base.files[path]?.sha256 != sha || clearSidecars else { continue }
            databases.append(UsbDatabaseReplacement(format: path == UsbLayout.oneLibrary ? .oneLibrary : .deviceLibrary, destination: path,
                                                    staged: url.path, sha256: sha, size: info.size))
            if path == UsbLayout.oneLibrary { mustNotExist.formUnion(sidecars) }
        }
        // 본 DB 없이 남은 사이드카는 쓰기 절차가 지우지 않는다
        if saved[UsbLayout.oneLibrary] == nil { result.kept += sidecars.filter { base.files[$0] != nil }.count }

        // 4. 분석 파일·아트워크·설정 파일
        let others = Set(metadata.files.keys).union(current.keys).subtracting(UsbPointSnapshotRules.databaseFiles)
        for path in others.sorted() {
            let usb = root.url.appending(path: path)
            let analysis = UsbPath.isAnalysis(path)
            if let stamp = metadata.files[path] {
                mustExist[path] = UsbTreeStamp(size: stamp.size, sha256: stamp.sha256)
                var existing: String?
                if current[path] != nil {
                    existing = try fileSystem.sha256(usb, uncached: true)
                    if existing == stamp.sha256 { continue }
                }
                let target = staging.appending(path: "files").appending(path: path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: UsbPointSnapshot.fileURL(entry, path), to: target)
                writes.append(UsbFileWrite(staged: target.path, destination: path, sha256: stamp.sha256, size: stamp.size,
                                           modificationDate: stamp.mtime, disposition: existing == nil ? .create : .overwrite,
                                           expectedExistingPPTH: existing != nil && analysis ? try ppth(usb, fileSystem) : nil,
                                           expectedExistingSHA256: existing))
                if existing == nil { result.created += 1 } else { result.overwritten += 1 }
            } else if let info = current[path] {
                // 분석 파일은 PPTH를 읽어야 지운다(쓰기 절차가 같은 곡 것인지 다시 본다)
                let found = analysis ? try ppth(usb, fileSystem) : nil
                guard UsbRemovalPolicy.allows(path), !analysis || found != nil else {
                    result.kept += 1
                    continue
                }
                removals.append(UsbFileRemoval(path: path, expectedSHA256: try fileSystem.sha256(usb, uncached: true), expectedSize: info.size,
                                               expectedPPTH: found, localOriginal: nil, localOriginalSHA1: nil))
                mustNotExist.insert(path)
                result.removed += 1
            }
        }
        result.databases = databases.count

        // 5. 음원은 담지 않는다: 스냅샷 DB가 가리키는 음원이 지금 USB에 있는지 센다
        result.missingAudio = missingAudio(copy, root: root, fileSystem: fileSystem)
        switch result.missingAudio {
        case nil: result.notes.append(String(ui: "스냅샷 DB의 곡 음원이 USB에 있는지 확인하지 못했습니다"))
        case let count? where count > 0:
            result.notes.append(String(ui: "스냅샷 DB의 곡 \(count)개는 지금 USB에 음원이 없습니다. 음원은 스냅샷에 담지 않아 되돌려도 생기지 않습니다"))
        default: break
        }
        // 기기 설정 파일은 CDJ가 USB에 저장한 것일 수 있다(DB 지문으로는 모른다)
        let settings = writes.filter { UsbPointSnapshotRules.settingFiles.contains($0.destination) }.count
        if settings > 0 {
            result.notes.append(String(ui: "기기 설정 파일 \(settings)개를 스냅샷 때 것으로 되돌립니다. 기기에서 저장한 설정이었다면 그 설정은 쓰기 전 백업에만 남습니다"))
        }
        if result.kept > 0 {
            result.notes.append(String(ui: "되돌리기가 지우지 않는 파일 \(result.kept)개는 그대로 둡니다(스냅샷 뒤에 생긴 설정 파일 등)"))
        }
        // 바꿀 것이 없으면 계획 없이 돌려준다(`isUnchanged`, 부르는 쪽이 알린다)
        guard !databases.isEmpty || !writes.isEmpty || !removals.isEmpty else { return result }
        result.changes = UsbChangeSet(session: session, label: label(for: entry), purpose: .edit, formats: metadata.formats, requiredRules: [],
                                      databases: databases, copies: [], writes: writes, removals: removals, base: base,
                                      target: UsbTargetFingerprint(mustExist: mustExist, mustNotExist: mustNotExist),
                                      stagingDirectory: staging.path, idHighWater: highWater)
        keepStaging = true
        return result
    }

    /// 담은 경로가 모두 범위 안이고(누가 고친 `snapshot.json`이 USB의 다른 곳을 가리키지 않게) 파일의 크기·해시가 정보와 같은지
    static func intact(_ entry: UsbPointSnapshotEntry) throws -> Bool {
        let fs = PosixUsbFileSystem()
        for (path, stamp) in entry.metadata.files {
            guard UsbPointSnapshotRules.isInScope(path), UsbWriter.isSafeRelativePath(path) else { return false }
            let url = UsbPointSnapshot.fileURL(entry, path)
            guard let info = try fs.stat(url), info.kind == .file, info.size == stamp.size,
                  try fs.sha256(url, uncached: false) == stamp.sha256 else { return false }
        }
        return true
    }

    static func ppth(_ url: URL, _ fileSystem: any UsbFileSystem) throws -> String? {
        UsbExportAssembly.ppthReader(try fileSystem.read(url, maxBytes: 64 << 20))
    }

    /// 스냅샷 DB(OneLibrary가 있으면 그것, 없으면 Device Library)의 곡 중 지금 USB에 음원 파일이 없는 수. 읽지 못하면 nil
    static func missingAudio(_ copy: UsbSnapshot, root: UsbRoot, fileSystem: any UsbFileSystem) -> Int? {
        let library: UsbLibrary
        if let oneLibrary = copy.oneLibrary, let read = try? OneLibraryReader.read(copyAt: oneLibrary) {
            library = read
        } else if let read = try? PdbReader.read(snapshot: copy) {
            library = read.0
        } else {
            return nil
        }
        return library.tracks.filter { track in
            guard let relative = UsbLayout.readablePath(track.path, under: UsbLayout.contents) else { return true }
            return (try? fileSystem.stat(root.url.appending(path: relative)))?.kind != .file
        }.count
    }

    enum Blocks {
        static var damaged: UsbBlock {
            UsbBlock(code: "pointSnapshotDamaged", scope: .volume,
                     message: String(ui: "USB 스냅샷 파일이 없거나 바뀌어 되돌리지 않았습니다. 다른 스냅샷을 고르세요"))
        }

        static var noDatabase: UsbBlock {
            UsbBlock(code: "pointSnapshotNoDatabase", scope: .volume,
                     message: String(ui: "이 스냅샷에는 라이브러리 DB가 없어 되돌리지 않습니다. 라이브러리가 있을 때 뜬 스냅샷을 고르세요"))
        }

        static var changed: UsbBlock {
            UsbBlock(code: "usbChanged", scope: .volume, message: String(ui: "USB가 그 사이 바뀌었습니다. USB를 다시 읽은 뒤 쓰세요"))
        }

        static func newDatabase(_ paths: [String]) -> UsbBlock {
            let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return UsbBlock(code: "pointSnapshotNewDatabase", scope: .volume,
                            message: String(ui: "스냅샷 뒤에 생긴 DB(\(names))는 되돌리기가 지우지 않습니다. 그 DB를 만든 쓰기를 `djc usb-restore`로 먼저 되돌리세요"))
        }
    }
}
