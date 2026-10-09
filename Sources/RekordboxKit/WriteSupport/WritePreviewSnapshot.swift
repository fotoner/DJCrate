import DJCDomain
import Foundation

/// 미리보기 한 번의 DB·분석 파일 사본. 성공·실패·취소 모두 폴더째 정리한다.
public enum WritePreviewSnapshot {
    /// 원본 DB·share는 부르는 쪽이 적는다(라이브 기본값을 두지 않는다).
    public static func withCopy<T>(from source: URL,
                                    shareRoot: URL,
                                    grids: [GridDraft] = [], merges: [DuplicateMergeDraft] = [],
                                    artworks: [String] = [],
                                    directory: URL = FileManager.default.temporaryDirectory,
                                    body: (URL, URL) async throws -> T) async throws -> T {
        let fm = FileManager.default
        let root = directory.appending(path: "djc-preview-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        try Task.checkCancellation()
        // DB 별칭도 링크 자체가 아닌 실제 파일을 복사한다. 읽기용 상시 스냅샷을 교체하거나 가지치기하지 않는다.
        let original = source.resolvingSymlinksInPath()
        let database = try LibrarySnapshot.take(from: original, into: root)
        let share = root.appending(path: "share")
        try fm.createDirectory(at: share, withIntermediateDirectories: true)
        let xml = original.deletingLastPathComponent().appending(path: "masterPlaylists6.xml")
        try copyFile(xml, to: root.appending(path: xml.lastPathComponent), within: original.deletingLastPathComponent())

        if !grids.isEmpty || !merges.isEmpty {
            let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { db.close() }
            var files = Set<URL>()
            // 그리드 계획이 읽는 파일은 DAT·EXT뿐이다. 없는 파일은 그대로 없어야 기존 차단 이유가 유지된다.
            for grid in grids where grid.hasChanges {
                try db.query("SELECT AnalysisDataPath FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0", [.text(grid.trackUUID)]) { row in
                    guard let path = row.string(0), !path.isEmpty else {
                        // 분석 붙이기는 UUID 폴더의 비어 있음도 검사한다. 기존 파일을 빼면 충돌을 놓친다.
                        for folder in [RekordboxTrackWriter.analysisFolder(uuid: grid.trackUUID), TrackArtwork.folder(uuid: grid.trackUUID)] {
                            let relative = String(folder.drop(while: { $0 == "/" }))
                            try copyDirectory(shareRoot.appending(path: relative), to: share.appending(path: relative), within: shareRoot)
                        }
                        return
                    }
                    let dat = shareRoot.appending(path: String(path.drop(while: { $0 == "/" })))
                    try checkPath(dat, within: shareRoot)
                    files.insert(dat)
                    files.insert(dat.deletingPathExtension().appendingPathExtension("EXT"))
                }
            }
            // 합치기의 삭제 계획과 같은 파일 집합을 복사한다. 위험한 원본 경로를 빈 사본으로 위장하지 않는다.
            for member in merges.flatMap(\.removing) {
                let plan = try RekordboxWriter.deletionFiles(member.contentID, db: db, share: shareRoot)
                guard plan.warning == nil else { throw unsafePath() }
                files.formUnion(plan.files)
            }
            for file in files.sorted(by: { $0.path < $1.path }) {
                try checkPath(file, within: shareRoot)
                let relative = String(file.path.dropFirst(shareRoot.path.count + 1))
                try copyFile(file, to: share.appending(path: relative), within: shareRoot)
            }
        }
        // 그림 초안(#66): 쓰기 전 확인이 곡 UUID 그림 폴더의 파일 유무·링크를 보므로 그 폴더를 그대로 복사한다(없으면 없는 채로,
        // 분석 전 곡의 그리드 초안으로 이미 복사했으면 그대로).
        for uuid in artworks {
            let relative = String(TrackArtwork.folder(uuid: uuid).drop(while: { $0 == "/" }))
            guard !fm.fileExists(atPath: share.appending(path: relative).path) else { continue }
            try copyDirectory(shareRoot.appending(path: relative), to: share.appending(path: relative), within: shareRoot)
        }
        try Task.checkCancellation()
        let result = try await body(database, share)
        try Task.checkCancellation()
        return result
    }

    private static func unsafePath() -> DJCError {
        .writeRefused(String(ui: "미리 보기 파일 경로가 안전하지 않습니다. rekordbox에서 분석 파일 위치를 확인한 뒤 다시 시도하세요"))
    }

    /// 경로 이탈·중간 폴더 링크·파일 링크를 허용하지 않아 사본 밖으로 쓰기 경로가 생기지 않게 한다.
    private static func checkPath(_ file: URL, within root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        guard !file.pathComponents.contains(".."), !file.pathComponents.contains("."),
              file.path.hasPrefix(root.path + "/"),
              file.resolvingSymlinksInPath().standardizedFileURL.comparablePath
                == base.appending(path: String(file.path.dropFirst(root.path.count + 1))).comparablePath,
              (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw unsafePath() }
    }

    private static func copyDirectory(_ source: URL, to destination: URL, within root: URL) throws {
        try Task.checkCancellation()
        try checkPath(source, within: root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        guard try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw unsafePath() }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let file = source.appending(path: name)
            try checkPath(file, within: root)
            let target = destination.appending(path: file.lastPathComponent)
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try copyDirectory(file, to: target, within: root)
            } else {
                try copyFile(file, to: target, within: root)
            }
        }
    }

    private static func copyFile(_ source: URL, to destination: URL, within root: URL) throws {
        try Task.checkCancellation()
        try checkPath(source, within: root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw unsafePath() }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // copyItem은 하드 링크도 독립 파일로 복사한다. 링크를 만들거나 원본 파일을 이동하지 않는다.
        try fm.copyItem(at: source, to: destination)
    }
}
