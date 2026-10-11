import DJCDomain
import Foundation

public enum GridDraftStore {
    /// rekordbox에 반영이 확인된 곡의 초안을 지운다(이제 rekordbox 값이 원본이다).
    public static func remove(trackUUID: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(trackUUID).json"))
    }

    public static var directory: URL {
        DJCPaths.userData.appending(path: "grid-drafts")
    }

    public static func load(trackUUID: String) -> GridDraft? {
        load(trackUUID: trackUUID, directory: directory)
    }

    public static func load(trackUUID: String, directory: URL) -> GridDraft? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(trackUUID).json")) else { return nil }
        return try? JSONDecoder().decode(GridDraft.self, from: data)
    }

    public static func save(_ draft: GridDraft, directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(draft.trackUUID).json")
        // 손상된 파일은 덮거나 지우지 않고 옮겨 보관한다(#174).
        try DamagedDrafts.preserveIfDamaged(GridDraft.self, at: url, home: directory.deletingLastPathComponent(), trackUUID: draft.trackUUID)
        if draft.hasChanges {
            try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        } else {
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile { }
        }
    }

    public static func uuids(directory: URL = directory) -> Set<String> { DraftFiles.uuids(in: directory) }
}

enum DraftFiles {
    static func uuids(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }
}

public extension CueDraftStore {
    static func uuids(directory: URL = directory) -> Set<String> { DraftFiles.uuids(in: directory) }
}
