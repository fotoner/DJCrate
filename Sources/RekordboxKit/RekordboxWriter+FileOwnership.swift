import DJCDomain
import Foundation

extension RekordboxWriter {
    struct OwnedTrackFiles {
        var uuid: String
        var analysis: String?
        var image: String?
        var audio: String
    }

    struct DeletionFiles {
        var files: [URL] = []
        var warning: String?
    }

    static var fileOwnershipWarning: String { String(ui: "분석 파일을 지우지 않음(경로가 예상과 다름)") }

    /// 그림 파일을 쓸 곳에 링크가 있을 때 막는 이유(곡 정보 그림·분석 붙이기·곡 넣기 공통)
    static var artworkLinkReason: String {
        String(ui: "앨범아트 폴더(share/PIONEER/Artwork) 아래에 링크가 있어 share 밖에 쓸 수 있으니 링크를 실제 폴더로 바꾼 뒤 다시 쓰세요")
    }

    /// `root` 아래 `url`까지 이미 있는 경로 조각 중 심볼릭 링크가 있는지(조각마다 lstat, `root` 자신 포함). 아직 없는 조각부터는 볼 것이 없다.
    /// `resolvingSymlinksInPath`는 마지막 폴더가 아직 없으면 그 위 링크도 풀지 않아, 새 곡 UUID 폴더를 만들 때 share 밖에 쓰게 된다(#66 리뷰).
    /// `root` 밖 경로는 참(막음)으로 본다.
    static func hasSymlinkComponent(_ url: URL, under root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let base = URL.comparablePath(rootPath), path = url.standardizedFileURL.comparablePath
        guard path.hasPrefix(base + "/") else { return true }
        var current = rootPath
        for part in [""] + path.dropFirst(base.count + 1).split(separator: "/").map(String.init) {
            if !part.isEmpty { current += "/" + part }
            guard let type = (try? FileManager.default.attributesOfItem(atPath: current))?[.type] as? FileAttributeType else { return false }
            if type == .typeSymbolicLink { return true }
        }
        return false
    }

    static func ownedTracks(_ db: CipherDatabase) throws -> [String: OwnedTrackFiles] {
        var tracks: [String: OwnedTrackFiles] = [:]
        try db.query("SELECT ID, UUID, AnalysisDataPath, ImagePath, FolderPath FROM djmdContent") {
            tracks[$0.string(0) ?? ""] = OwnedTrackFiles(uuid: $0.string(1) ?? "", analysis: $0.string(2), image: $0.string(3), audio: $0.string(4) ?? "")
        }
        return tracks
    }

    /// DB에 적힌 경로로 폴더를 고르지 않는다. UUID로 만든 폴더와 일치할 때만 정해진 파일명을 허용한다.
    static func ownedCandidates(_ track: OwnedTrackFiles, share: URL) -> [URL]? {
        guard track.uuid.count > 3, track.uuid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              (try? share.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        let root = share.resolvingSymlinksInPath().standardizedFileURL
        var candidates: [URL] = []
        for (path, category, names) in [
            (track.analysis, "USBANLZ", ["ANLZ0000.DAT", "ANLZ0000.EXT", "ANLZ0000.2EX", "ANLZ0000.3EX"]),
            (track.image, "Artwork", ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]),
        ] {
            guard let path, !path.isEmpty else { continue }
            let folder = root.appending(path: "PIONEER/\(category)/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))")
            guard let declared = RekordboxShare.analysisURL(path, root: root),
                  declared.deletingLastPathComponent().path == folder.path,
                  folder.resolvingSymlinksInPath().path == folder.path else { return nil }
            for name in names {
                let file = folder.appending(path: name)
                let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values?.isSymbolicLink != true, values?.isDirectory != true, !hasSymlinkComponent(file, under: root) else { return nil }
                candidates.append(file)
            }
        }
        return candidates
    }

    static func deletionFiles(_ id: String, db: CipherDatabase, share: URL?) throws -> DeletionFiles {
        let tracks = try ownedTracks(db)
        guard let track = tracks[id] else { return DeletionFiles() }
        guard track.analysis?.isEmpty == false || track.image?.isEmpty == false else { return DeletionFiles() }
        guard let share, let candidates = ownedCandidates(track, share: share) else {
            return DeletionFiles(warning: fileOwnershipWarning)
        }
        let audio = Set(tracks.values.map { URL(filePath: $0.audio).resolvingSymlinksInPath().path })
        let folders = Set(candidates.map { $0.deletingLastPathComponent().comparablePath })
        for (otherID, other) in tracks where otherID != id {
            for path in [other.analysis, other.image] {
                if let url = RekordboxShare.analysisURL(path, root: share),
                   folders.contains(url.resolvingSymlinksInPath().deletingLastPathComponent().comparablePath) {
                    return DeletionFiles(warning: fileOwnershipWarning)
                }
            }
        }
        guard candidates.allSatisfy({ !audio.contains($0.path) }) else { return DeletionFiles(warning: fileOwnershipWarning) }
        return DeletionFiles(files: candidates.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    static func backupDeletionFiles(_ files: [URL], in backup: URL?, shareRoot: URL?) throws {
        guard let backup, !files.isEmpty else { return }
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifestURL = folder.appending(path: "manifest.json")
        var manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        for file in Set(files) {
            let name = "delete-\(manifest.count).\(file.pathExtension)"
            try FileManager.default.copyItem(at: file, to: folder.appending(path: name))
            manifest[name] = try backupRelativePaths([file.path], shareRoot: shareRoot)[0]
        }
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    static func removeOwnedFiles(_ files: [URL]) throws {
        for file in Set(files) { try FileManager.default.removeItem(at: file) }
        for folder in Set(files.map { $0.deletingLastPathComponent() }) {
            // 다른 파일은 남기고, UUID의 두 경로 조각은 비었을 때만 지운다.
            for empty in [folder, folder.deletingLastPathComponent()] {
                if (try? FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty) == true {
                    try? FileManager.default.removeItem(at: empty)
                }
            }
        }
    }

    /// 옛 백업도 복원할 DB의 UUID와 경로를 확인한다.
    static func restorableFiles(_ paths: [String], database: URL, shareRoot: URL) throws -> Set<String> {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let tracks = try ownedTracks(db)
        let audio = Set(tracks.values.map { URL(filePath: $0.audio).resolvingSymlinksInPath().path })
        let byUUID = Dictionary(grouping: tracks.values, by: \.uuid)
        var allowed = Set<String>()
        for path in paths {
            let file = URL(filePath: path)
            guard file.path == file.standardizedFileURL.path, !audio.contains(file.resolvingSymlinksInPath().path) else { continue }
            let folder = file.deletingLastPathComponent()
            let uuid = folder.deletingLastPathComponent().lastPathComponent + folder.lastPathComponent
            if (byUUID[uuid] ?? []).contains(where: { ownedCandidates($0, share: shareRoot)?.contains(file) == true }) { allowed.insert(path) }
        }
        return allowed
    }

    static func markFileWarning(in backup: URL) throws {
        try Data().write(to: backup.appending(path: "file-ownership-warning"), options: .atomic)
    }

    public static func fileWarning(in backup: URL) -> String? {
        FileManager.default.fileExists(atPath: backup.appending(path: "file-ownership-warning").path) ? fileOwnershipWarning : nil
    }
}
