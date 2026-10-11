import DJCDomain
import Foundation

extension RekordboxWriter {
    struct AnalysisRestoreFile {
        var target: URL
        var relative: String
        var data: Data
    }

    static func invalidBackup(_ reason: String) -> DJCError {
        .writeRefused(String(ui: "백업을 복원할 수 없습니다: \(reason). 올바른 백업과 share 폴더를 선택하세요"))
    }

    /// 새 백업은 share 기준 상대 경로만 쓴다. 옛 절대 경로는 같은 허용 루트 안에서만 해석한다.
    static func backupTarget(_ path: String, shareRoot: URL) throws -> (url: URL, relative: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"), !path.contains("\\"),
              !parts.contains(".."), !parts.contains("."),
              !parts.dropFirst(path.hasPrefix("/") ? 1 : 0).contains("") else {
            throw invalidBackup(String(ui: "경로에 상위 폴더 이동 또는 빈 이름이 있음"))
        }
        let root = shareRoot.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let relative: String
        if path.hasPrefix("/") {
            let spelled = URL.comparablePath(path)
            guard let prefix = [root, resolvedRoot].map({ $0.comparablePath + "/" }).first(where: spelled.hasPrefix) else {
                throw invalidBackup(String(ui: "허용된 분석·앨범아트 경로가 아님"))
            }
            relative = String(spelled.dropFirst(prefix.count))
        } else { relative = path }
        let components = relative.split(separator: "/")
        let names: [String]
        if components.count >= 3, components[0] == "PIONEER", components[1] == "USBANLZ" {
            names = ["ANLZ0000.DAT", "ANLZ0000.EXT", "ANLZ0000.2EX", "ANLZ0000.3EX"]
        } else if components.count >= 3, components[0] == "PIONEER", components[1] == "Artwork" {
            names = ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]
        } else { throw invalidBackup(String(ui: "허용된 분석·앨범아트 경로가 아님")) }
        guard names.contains(String(components.last!)) else {
            throw invalidBackup(String(ui: "허용된 분석·앨범아트 경로가 아님"))
        }
        let file = root.appending(path: relative)
        try validateBackupFile(file, under: root, required: false)
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.comparablePath.hasPrefix(resolvedRoot.appending(path: "PIONEER/\(components[1])").comparablePath + "/") else {
            throw invalidBackup(String(ui: "허용된 분석·앨범아트 경로가 아님"))
        }
        return (resolved, relative)
    }

    static func backupRelativePaths(_ paths: [String], shareRoot: URL?) throws -> [String] {
        guard !paths.isEmpty else { return [] }
        guard let shareRoot else { throw invalidBackup(String(ui: "허용된 분석·앨범아트 경로가 아님")) }
        return try paths.map { try backupTarget($0, shareRoot: shareRoot).relative }
    }

    /// 루트 자체와 그 아래 모든 조각을 검사한다. 없는 대상은 허용하지만 링크·디렉터리 파일은 거부한다.
    static func validateBackupFile(_ file: URL, under root: URL, required: Bool) throws {
        let filePath = file.comparablePath, rootPath = root.comparablePath
        guard filePath.hasPrefix(rootPath + "/") else {
            throw invalidBackup(String(ui: "허용된 분석·앨범아트 경로가 아님"))
        }
        let parts = filePath.dropFirst(rootPath.count + 1).split(separator: "/")
        var current = root
        for index in 0...parts.count {
            if index > 0 { current.append(path: String(parts[index - 1])) }
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: current.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                if !required { continue }
                throw invalidBackup(String(ui: "백업 파일이 없거나 일반 파일이 아님"))
            }
            guard attributes[.type] as? FileAttributeType == (index == parts.count ? .typeRegular : .typeDirectory) else {
                throw invalidBackup(String(ui: "심볼릭 링크 또는 일반 파일이 아닌 항목이 있음"))
            }
        }
    }

    static func backupMetadata<T: Decodable>(_ type: T.Type, at file: URL, in backup: URL) throws -> T? {
        try validateBackupFile(file, under: backup, required: false)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: file)) }
        catch { throw invalidBackup(String(ui: "백업 메타데이터가 손상됨")) }
    }

    static func analysisRestoreFiles(from backup: URL, shareRoot: URL) throws -> [AnalysisRestoreFile] {
        let folder = backup.appending(path: "anlz")
        let manifest = try backupMetadata([String: String].self, at: folder.appending(path: "manifest.json"), in: backup) ?? [:]
        var files: [AnalysisRestoreFile] = []
        for (name, path) in manifest.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
                throw invalidBackup(String(ui: "경로에 상위 폴더 이동 또는 빈 이름이 있음"))
            }
            let target = try backupTarget(path, shareRoot: shareRoot)
            let source = folder.appending(path: name)
            try validateBackupFile(source, under: backup, required: true)
            files.append(AnalysisRestoreFile(target: target.url, relative: target.relative, data: try Data(contentsOf: source)))
        }
        try validateRestoreTargets(files.map(\.target), database: backup.appending(path: "master.db"), shareRoot: shareRoot)
        return files
    }

    /// 그 쓰기가 새로 만든 파일(복원 때 지운다). 이미 없는 파일은 건너뛴다(그 뒤 그림을 지웠거나 rekordbox에서 지움, 소유권 실패가 아니다).
    /// 남은 파일은 지금 DB의 곡 경로로 소유권을 본다. 그림 파일은 그 뒤 `ImagePath`가 비었을 수 있어, 보고서가 그림을 쓴 곡 UUID의
    /// 폴더(`PIONEER/Artwork/<앞 3자>/<나머지>/artwork{,_m,_s}.jpg`)이고 그 곡이 DB에 있으면 받는다(#66 리뷰). 그 밖은 계속 막는다.
    /// `exists`: 연쇄 복원(#222)은 앞 단계를 되돌린 뒤 파일이 있을지를 셈해 넘긴다.
    static func createdRestoreFiles(from backup: URL, database: URL, shareRoot: URL,
                                    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> [URL] {
        struct Files: Decodable {
            struct Outcome: Decodable { var trackUUID: String?; var status: String?; var uuid: String?; var written: Bool? }
            var createdFiles: [String]?
            /// report.json: 곡 정보 그림 결과·분석 붙이기로 그림을 넣은 곡
            var artworkOutcomes: [Outcome]?
            var artworkAdded: [String]?
            /// track-report.json: 넣은 곡
            var added: [Outcome]?
        }
        var files: [(url: URL, relative: String)] = []
        var owners = Set<String>()
        for name in ["report.json", "track-report.json"] {
            let report = try backupMetadata(Files.self, at: backup.appending(path: name), in: backup)
            files += try (report?.createdFiles ?? []).map { try backupTarget($0, shareRoot: shareRoot) }
            owners.formUnion((report?.artworkOutcomes ?? []).filter { $0.status == "written" }.compactMap(\.trackUUID))
            owners.formUnion(report?.artworkAdded ?? [])
            owners.formUnion((report?.added ?? []).filter { $0.written == true }.compactMap(\.uuid))
        }
        let existing = files.filter { exists($0.url) }
        guard !existing.isEmpty else { return [] }
        try rejectDuplicateTargets(existing.map(\.url))
        let allowed = try restorableFiles(existing.map(\.url.path), database: database, shareRoot: shareRoot)
        for file in existing where !allowed.contains(file.url.path) {
            guard try createdArtworkOwned(file.url, relative: file.relative, owners: owners, database: database, shareRoot: shareRoot) else {
                throw invalidBackup(String(ui: "파일이 백업의 곡 소유권과 맞지 않음"))
            }
        }
        return existing.map(\.url)
    }

    /// 보고서가 그림을 쓴 곡의 UUID 폴더 그림 파일인지(그 곡이 DB에 있고, 링크·음원 경로가 아니다)
    static func createdArtworkOwned(_ file: URL, relative: String, owners: Set<String>, database: URL, shareRoot: URL) throws -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count == 5, parts[0] == "PIONEER", parts[1] == "Artwork", TrackArtwork.fileNames.contains(parts[4]), parts[2].count == 3 else {
            return false
        }
        let uuid = parts[2] + parts[3]
        guard owners.contains(uuid), uuid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !hasSymlinkComponent(file, under: shareRoot.resolvingSymlinksInPath()) else { return false }
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        defer { db.close() }
        return try scalar(db, "SELECT count(*) FROM djmdContent WHERE UUID = ?", [.text(uuid)]) ?? 0 > 0
            && scalar(db, "SELECT count(*) FROM djmdContent WHERE FolderPath = ?", [.text(file.path)]) == 0
    }

    static func validateRestoreTargets(_ files: [URL], database: URL, shareRoot: URL) throws {
        guard !files.isEmpty else { return }
        try rejectDuplicateTargets(files)
        let paths = files.map(\.path)
        guard try restorableFiles(paths, database: database, shareRoot: shareRoot).count == files.count else {
            throw invalidBackup(String(ui: "파일이 백업의 곡 소유권과 맞지 않음"))
        }
    }

    static func rejectDuplicateTargets(_ files: [URL]) throws {
        // 대소문자를 구분하지 않는 볼륨과 유니코드 이름도 같은 대상으로 본다.
        let keys = files.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(keys).count == keys.count else { throw invalidBackup(String(ui: "대상 파일이 중복됨")) }
    }
}
